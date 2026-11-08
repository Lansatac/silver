module silver.interpreter.evaluator;

static import std.meta;
import std.sumtype;
import std.traits : isSigned;
import std.variant : Variant;
import silver.ast;
import silver.interpreter.environment : Environment, ImportScope;
import silver.interpreter.errors : CodedException;
import silver.interpreter.values;
import silver.sema : Analysis, ConstInt, ConstUInt, ConstUnit, IntegerInfo, Type;

/// The D type holding each Silver integer type's values.
private alias IntegerTypes = std.meta.AliasSeq!(byte, short, int, long, ubyte, ushort, uint, ulong);

class RuntimeError : DiagnosticException
{
    this(Diagnostic diagnostic)
    {
        super(diagnostic);
    }
}

/// Runs a Program by walking its AST.
class Evaluator
{
    private Program program;
    private const Analysis analysis;

    private bool useStdOut;
    private string outputText;

    /// Everything the program has printed so far.
    string output() const
    {
        return outputText;
    }

    /// `analysis` is sema's result for `program`, which must have no errors. What sema rejects
    /// isn't checked again here, so only panics and missing native bindings fail at runtime.
    nothrow this(Program program, const Analysis analysis, bool useStdOut = false)
    in (analysis !is null)
    {
        this.program = program;
        this.analysis = analysis;
        this.useStdOut = useStdOut;
    }

    /// Every module run so far, by dotted name, so each runs once however often it's imported.
    private ModuleValue[string] modules;
    /// Implementations for `native def`s, by function name.
    private NativeFunction[string] nativeBindings;

    void run()
    {
        bindNatives();
        auto prelude = new ModuleValue("prelude", new Environment(new ImportScope));
        modules["prelude"] = prelude;
        auto preludeModule = program.modules.get("prelude", null);
        if (preludeModule !is null)
        {
            execute(*preludeModule, prelude.environment);
        }
        callMain();
    }

    /// Runs the module that defines `main`, which runs everything it imports, then calls `main`.
    private void callMain()
    {
        auto mains = mainFunctions(program);
        assert(mains.length == 1, "sema reports a program without exactly one `main`");
        auto environment = moduleValue(mains[0].moduleName).environment;
        call(environment.variables["main"], [], environment);
    }

    private void execute(const Module ast, Environment variables)
    {
        foreach (declaration; ast.declarations)
        {
            execute(declaration, variables);
        }
    }

    private void execute(const Decl ast, Environment variables)
    {
        try
        {
            ast.kind.match!(d => execute(d, variables));
        }
        catch (RuntimeError e)
        {
            throw e;
        }
        catch (Exception e)
        {
            throw runtimeError(ast.span, e);
        }
    }

    private void execute(const Stmt ast, Environment variables)
    {
        try
        {
            ast.kind.match!(s => execute(s, variables));
        }
        catch (RuntimeError e)
        {
            throw e;
        }
        catch (Exception e)
        {
            throw runtimeError(ast.span, e);
        }
    }

    private void execute(const VarDecl ast, Environment variables)
    {
        auto value = evaluate(ast.value, variables);
        if (ast.name != discardName) variables.defineVariable(ast.name, value);
    }

    private void execute(const PatternDecl ast, Environment variables)
    {
        bindPattern(ast.pattern, ast.value, variables);
    }

    /// Binds each part of `value` as `pattern` takes it apart, as sema checked it: a tuple literal
    /// element by element, and anything else evaluated whole first.
    private void bindPattern(const Pattern pattern, const Expr value, Environment variables)
    {
        if (auto literal = elementwise(pattern, value))
        {
            auto parts = pattern.kind.match!(
                (const TuplePattern tuple) => tuple.elements,
                (_) => assert(0, "only a tuple pattern goes element by element"),
            );
            foreach (i, element; literal.elements)
            {
                bindPattern(parts[i], element, variables);
            }
            return;
        }
        bindValue(pattern, evaluate(value, variables), variables);
    }

    private void bindValue(const Pattern pattern, Variant value, Environment variables)
    {
        pattern.kind.match!(
            (const VarDecl binding) {
                if (binding.name != discardName) variables.defineVariable(binding.name, value);
            },
            (const TuplePattern tuple) {
                auto parts = value.get!TupleValue.elements;
                foreach (i, element; tuple.elements)
                {
                    bindValue(element, parts[i], variables);
                }
            },
        );
    }

    private void execute(const AssignStmt ast, Environment variables)
    {
        assign(ast.target, evaluate(ast.value, variables), variables);
    }

    /// `p.x = v` rebuilds: it assigns `p` a copy of itself with `x` replaced, so `a.b.c = v`
    /// works back through the chain until it reaches the binding, which is the only thing stored to.
    private void assign(const Expr target, Variant value, Environment variables)
    {
        target.kind.match!(
            (const Identifier i) { variables.setVariable(i.name, value); },
            (const MemberAccess m) {
                auto updated = withField(evaluate(*m.object, variables), m.member, value);
                assign(*m.object, updated, variables);
            },
            (_) { assert(0, "sema only lets a variable or field be assigned"); });
    }

    private void bindNatives()
    {
        import std.stdio : readln;

        nativeBindings["print"] = (Variant[] args) => print(args[0], false);
        nativeBindings["printl"] = (Variant[] args) => print(args[0], true);
        nativeBindings["read"] = (Variant[] args) {
            auto line = readln();
            if (line.length == 0) return Variant(OptionValue.none());
            return Variant(OptionValue.some(Variant(line)));
        };
        nativeBindings["length"] = (Variant[] args) => Variant(cast(long) args[0].get!ArrayValue.elements.length);
        bindNumericNatives();
    }

    /// Each is the same D expression as the compiled backend's, in the runtime's numeric module.
    private void bindNumericNatives()
    {
        import libm = core.stdc.math;
        import std.datetime.systime : Clock;

        static NativeFunction floatFunction(alias f)()
        {
            return (Variant[] args) => Variant(f(args[0].get!double));
        }

        nativeBindings["nowNanos"] = (Variant[] args) => Variant((Clock.currStdTime - 621_355_968_000_000_000L) * 100);
        nativeBindings["pow"] = (Variant[] args) => Variant(libm.pow(args[0].get!double, args[1].get!double));
        nativeBindings["sqrt"] = floatFunction!(libm.sqrt);
        nativeBindings["exp"] = floatFunction!(libm.exp);
        nativeBindings["log"] = floatFunction!(libm.log);
        nativeBindings["sin"] = floatFunction!(libm.sin);
        nativeBindings["cos"] = floatFunction!(libm.cos);
        nativeBindings["atan"] = floatFunction!(libm.atan);
    }

    private Variant print(Variant value, bool newline)
    {
        import std.conv : to;
        import std.stdio : write, writeln;

        outputText ~= value.to!string ~ (newline ? "\n" : "");
        if (useStdOut)
        {
            if (newline)
            {
                writeln(value);
            }
            else
            {
                write(value);
            }
        }
        return Variant(Unit());
    }

    private void execute(const FunctionDecl ast, Environment variables)
    {
        if (!ast.native)
        {
            variables.defineVariable(ast.name, Variant(new Function(ast, variables)));
            return;
        }
        auto binding = ast.name in nativeBindings;
        if (binding is null)
        {
            import std.format : format;

            throw new CodedException(DiagnosticCode.MissingNativeBinding, "No native binding for %s".format(ast.name));
        }
        variables.defineVariable(ast.name, Variant(new Function(ast, variables, *binding)));
    }

    /// A marker's name is its one value; any other type's name is its constructor.
    private void execute(const TypeDecl ast, Environment variables)
    {
        auto constructor = new Constructor(ast);
        variables.defineVariable(ast.name, ast.fields.length == 0
                ? Variant(new Instance(constructor, []))
                : Variant(constructor));
    }

    /// Sema has already evaluated it, so nothing here depends on the order modules run in.
    private void execute(const ConstDecl ast, Environment variables)
    {
        auto type = analysis.typeOf(ast.id);
        auto value = analysis.valueOf(ast.id).match!(
            (const ConstInt v) => integerValue(v.value, type),
            (const ConstUInt v) => integerValue(v.value, type),
            (const bool v) => makeValue(v),
            (const double v) => makeValue(v),
            (string v) => Variant(v),
            (const ConstUnit _) => Variant(Unit()),
        );
        variables.defineVariable(ast.name, value);
    }

    /// `value` as the D type holding Silver's `type`.
    private Variant integerValue(V)(V value, Type type)
    {
        auto info = analysis.types.integerOf(type);
        foreach (T; IntegerTypes)
        {
            if (isType!T(info)) return Variant(cast(T) value);
        }
        assert(0, "every integer type has a D type");
    }

    /// Adds the module to the importing module's ImportScope. It isn't bound as a variable;
    /// identifiers and member accesses find it there.
    private void execute(const ImportStmt ast, Environment variables)
    {
        import std.array : join;

        auto name = ast.path.join(".");
        ImportScope.of(variables).modules[name] = moduleValue(name);
    }

    /// The module `name`, running it first if this is its first import.
    private ModuleValue moduleValue(string name)
    {
        import std.format : format;

        if (auto existing = name in modules)
        {
            return *existing;
        }
        auto loaded = program.modules.get(name, null);
        if (loaded is null)
        {
            throw new CodedException(DiagnosticCode.InternalError, "Module %s was not loaded".format(name));
        }
        auto imports = new ImportScope;
        imports.modules["prelude"] = modules["prelude"];
        auto value = new ModuleValue(name, new Environment(imports));
        // Recorded before running, so an import cycle gets this module back instead of recursing.
        modules[name] = value;
        execute(*loaded, value.environment);
        return value;
    }

    private void execute(const ExprStmt ast, Environment variables)
    {
        evaluate(ast.expr, variables);
    }

    private Variant evaluate(const Expr ast, Environment variables)
    {
        try
        {
            auto value = ast.kind.match!(
                (const IntLiteral literal) => intLiteralValue(literal, ast.id),
                (const CallExpr call) => evaluateCall(call, ast.id, variables),
                (const BinaryExpr binary) => evaluateBinary(binary, ast.id, variables),
                s => evaluate(s, variables));
            if (auto option = analysis.promotionOf(ast.id))
            {
                return promote(value, analysis.typeOf(ast.id), *option);
            }
            return value;
        }
        catch (RuntimeError e)
        {
            throw e;
        }
        catch (Exception e)
        {
            throw runtimeError(ast.span, e);
        }
    }

    /// `value`, of type `from`, as the option `to`. A `None` is the outermost one, however deep
    /// `to` is, and anything else gets one `Some` for each level between the types. A `[]` taking
    /// on an array type stays as it is.
    private Variant promote(Variant value, Type from, Type to)
    {
        if (from == to || from == analysis.types.none || !analysis.types.isOption(to)) return value;
        return Variant(OptionValue.some(promote(value, from, analysis.types.optionInner(to))));
    }

    private Variant evaluate(const SomeExpr ast, Environment variables)
    {
        return Variant(OptionValue.some(evaluate(*ast.value, variables)));
    }

    private Variant evaluate(const NoneLiteral ast, Environment variables)
    {
        return Variant(OptionValue.none());
    }

    private Variant evaluate(const PropagateExpr ast, Environment variables)
    {
        auto option = evaluate(*ast.operand, variables).get!OptionValue;
        if (!option.present) throw new ReturnSignal(Variant(OptionValue.none()));
        return option.payload;
    }

    /// A field that's already an option isn't wrapped again. Only such a field holds an OptionValue.
    private Variant evaluate(const SafeMemberAccess ast, Environment variables)
    {
        auto option = evaluate(*ast.object, variables).get!OptionValue;
        if (!option.present) return Variant(OptionValue.none());

        auto field = member(option.payload, ast.member);
        if (field.peek!OptionValue) return field;
        return Variant(OptionValue.some(field));
    }

    /// `a ?? b`: `a` itself where the result is an option of the same type, and otherwise its
    /// payload. `b` is only evaluated when `a` is `None`.
    private Variant evaluateCoalesce(const BinaryExpr ast, Id!Expr id, Environment variables)
    {
        auto left = evaluate(*ast.left, variables);
        auto option = left.get!OptionValue;
        if (!option.present) return evaluate(*ast.right, variables);
        if (analysis.typeOf(id) == analysis.typeOf(ast.left.id)) return left;
        return option.payload;
    }

    private Variant evaluateBinary(const BinaryExpr ast, Id!Expr id, Environment variables)
    {
        if (ast.op == BinaryOp.Coalesce) return evaluateCoalesce(ast, id, variables);
        if (ast.op == BinaryOp.Concat) return evaluateConcat(id, variables);
        return evaluate(ast, variables);
    }

    /// A `~` chain, every operand evaluated in order and then joined at once.
    private Variant evaluateConcat(Id!Expr id, Environment variables)
    {
        Variant[] operands;
        foreach (operand; analysis.concatOperands(id))
        {
            operands ~= evaluate(operand, variables);
        }

        if (operands[0].peek!string)
        {
            string text;
            foreach (operand; operands)
            {
                text ~= operand.get!string;
            }
            return Variant(text);
        }
        Variant[] elements;
        foreach (operand; operands)
        {
            elements ~= operand.get!ArrayValue.elements;
        }
        return Variant(new ArrayValue(elements));
    }

    private Variant evaluate(const ArrayLiteral ast, Environment variables)
    {
        Variant[] elements;
        foreach (element; ast.elements)
        {
            elements ~= evaluate(element, variables);
        }
        return Variant(new ArrayValue(elements));
    }

    private Variant evaluate(const TupleLiteral ast, Environment variables)
    {
        Variant[] elements;
        foreach (element; ast.elements)
        {
            elements ~= evaluate(element, variables);
        }
        return Variant(new TupleValue(elements));
    }

    private Variant evaluate(const MapLiteral ast, Environment variables)
    {
        assert(0, "sema rejects maps");
    }

    private Variant evaluate(const RangeExpr ast, Environment variables)
    {
        assert(0, "sema only allows a range as a slice's index or in a `for`, which read its bounds");
    }

    private Variant evaluate(const IndexExpr ast, Environment variables)
    {
        auto elements = evaluate(*ast.object, variables).get!ArrayValue.elements;
        if (auto range = asRange(ast.index))
        {
            auto start = evaluate(*range.start, variables).get!long;
            auto end = evaluate(*range.end, variables).get!long;
            if (start < 0 || start > end || end > elements.length)
            {
                throw new CodedException(DiagnosticCode.IndexOutOfRange, "Slice is out of range");
            }
            return Variant(new ArrayValue(elements[cast(size_t) start .. cast(size_t) end]));
        }

        auto position = evaluate(*ast.index, variables).get!long;
        if (position < 0 || position >= elements.length)
        {
            throw new CodedException(DiagnosticCode.IndexOutOfRange, "Index is out of range");
        }
        return elements[cast(size_t) position];
    }

    /// `if`, not `?:`: with dmd 2.113, an exception thrown from a `?:` that produces a Variant
    /// could vanish, so the statement was skipped without any error.
    private Variant evaluateCall(const CallExpr call, Id!Expr id, Environment variables)
    {
        if (analysis.isConversion(id))
        {
            return convert(evaluate(call.args[0], variables), analysis.typeOf(id));
        }
        return evaluate(call, variables);
    }

    /// Sema gives an integer literal the type expected of it, as in `half(3)`.
    private Variant intLiteralValue(const IntLiteral literal, Id!Expr id)
    {
        auto type = analysis.typeOf(id);
        if (type == analysis.types.float_) return Variant(cast(double) literal.value);
        auto info = analysis.types.integerOf(type);
        foreach (T; IntegerTypes)
        {
            if (isType!T(info)) return Variant(cast(T) literal.value);
        }
        assert(0, "every integer type has a D type");
    }

    private static bool isType(T)(IntegerInfo info)
    {
        return T.sizeof * 8 == info.bits && isSigned!T == info.signed;
    }

    /// `UInt8(x)`. A value that doesn't fit panics, as does NaN; a Float is truncated first.
    /// `String(x)` formats it as `print` would.
    private Variant convert(Variant value, Type target)
    {
        import std.conv : to;

        if (target == analysis.types.string_) return Variant(value.to!string);
        if (target == analysis.types.float_)
        {
            if (value.peek!double) return value;
            foreach (S; IntegerTypes)
            {
                if (auto source = value.peek!S) return Variant(cast(double) *source);
            }
            assert(0, "sema only converts numbers");
        }

        auto info = analysis.types.integerOf(target);
        foreach (T; IntegerTypes)
        {
            if (!isType!T(info)) continue;

            if (auto source = value.peek!double)
            {
                if (!floatFits!T(*source)) throw conversionFailure!T();
                return Variant(cast(T) *source);
            }
            foreach (S; IntegerTypes)
            {
                if (auto source = value.peek!S)
                {
                    if (!integerFits!T(*source)) throw conversionFailure!T();
                    return Variant(cast(T) *source);
                }
            }
        }
        assert(0, "sema only converts numbers");
    }

    private static CodedException conversionFailure(T)()
    {
        import std.format : format;

        auto name = "%sInt%s".format(isSigned!T ? "" : "U", T.sizeof * 8);
        return new CodedException(DiagnosticCode.InvalidConversion, "Value is out of range for " ~ name);
    }

    /// Whether `value`, truncated toward zero, is a `T`. False for NaN.
    private static bool floatFits(T)(double value)
    {
        enum bits = T.sizeof * 8;
        static if (isSigned!T)
        {
            enum double limit = 2.0 ^^ (bits - 1);
            static if (bits == 64)
            {
                return value >= -limit && value < limit;
            }
            else
            {
                return value > -limit - 1 && value < limit;
            }
        }
        else
        {
            enum double limit = 2.0 ^^ bits;
            return value > -1 && value < limit;
        }
    }

    private static bool integerFits(T, S)(S value)
    {
        static if (isSigned!S)
        {
            if (value < 0)
            {
                static if (isSigned!T)
                {
                    return long(value) >= long(T.min);
                }
                else
                {
                    return false;
                }
            }
        }
        return cast(ulong) value <= cast(ulong) T.max;
    }

    /// An exception without a code, e.g. from a failed Variant operation, gets
    /// DiagnosticCode.RuntimeError.
    private RuntimeError runtimeError(Span span, Exception error)
    {
        auto coded = cast(CodedException) error;
        auto code = coded is null ? DiagnosticCode.RuntimeError : coded.code;
        return new RuntimeError(Diagnostic(code, span, error.msg, Severity.Error));
    }

    /// Wraps a value in a Variant with type qualifiers stripped.
    /// Fields of const AST nodes are const, and Variant records that, so
    /// `Variant(ast.value)` would make a later `get!long` throw.
    private static Variant makeValue(T)(T value)
    {
        import std.traits : Unqual;

        Unqual!T unqualified = value;
        return Variant(unqualified);
    }

    private Variant evaluate(const BoolLiteral ast, Environment variables)
    {
        return makeValue(ast.value);
    }

    private Variant evaluate(const FloatLiteral ast, Environment variables)
    {
        return makeValue(ast.value);
    }

    private Variant evaluate(const StringLiteral ast, Environment variables)
    {
        return makeValue(ast.value);
    }

    private Variant evaluate(const InterpolatedString ast, Environment variables)
    {
        import std.conv : to;

        string text;
        foreach (part; ast.parts)
        {
            text ~= evaluate(part, variables).to!string;
        }
        return Variant(text);
    }

    private Variant evaluate(const Identifier ast, Environment variables)
    {
        auto value = variables.find(ast.name);
        assert(value !is null, "sema reports a name that isn't in scope");
        return *value;
    }

    private Variant evaluate(const UnaryExpr ast, Environment variables)
    {
        auto value = evaluate(*ast.operand, variables);
        // A negated literal is a constant: `-128` is an Int8 even though `128` alone isn't.
        auto negatedLiteral = ast.op == UnaryOp.Minus
            && (*ast.operand).kind.match!((const IntLiteral _) => true, _ => false);
        if (negatedLiteral)
        {
            return negateLiteral(value);
        }
        return unaryOperate(ast.op, value);
    }

    private static Variant negateLiteral(Variant value)
    {
        foreach (T; IntegerTypes)
        {
            if (auto literal = value.peek!T) return Variant(cast(T)(0 - *literal));
        }
        return Variant(-value.get!double);
    }

    private Variant evaluate(const BinaryExpr ast, Environment variables)
    {
        auto lhs = evaluate(*ast.left, variables);

        // `and`/`or` short-circuit, so the right side is only evaluated if needed.
        if (ast.op == BinaryOp.And || ast.op == BinaryOp.Or)
        {
            auto left = lhs.get!bool;
            if (ast.op == BinaryOp.And ? !left : left)
            {
                return Variant(left);
            }
            return Variant(evaluate(*ast.right, variables).get!bool);
        }

        auto rhs = evaluate(*ast.right, variables);
        return operate(ast.op, lhs, rhs);
    }

    private Variant evaluate(const CallExpr ast, Environment variables)
    {
        auto callee = evaluate(*ast.callee, variables);

        Variant[] args;
        foreach (arg; ast.args)
        {
            args ~= evaluate(arg, variables);
        }
        return call(callee, args, variables);
    }

    /// Thrown by `return` and caught by the call that's running the function.
    /// It's a Throwable rather than an Exception so that the `catch (Exception)`
    /// handlers that turn errors into RuntimeErrors don't swallow it.
    private class ReturnSignal : Throwable
    {
        Variant value;

        this(Variant value)
        {
            super("return outside of a function");
            this.value = value;
        }
    }

    private void execute(const ReturnStmt r, Environment env)
    {
        throw new ReturnSignal(evaluate(r.value, env));
    }

    /// Thrown by `break` and `continue` and caught by the running loop's `runLoopBody`.
    private class BreakSignal : Throwable
    {
        this()
        {
            super("break outside of a loop");
        }
    }

    private class ContinueSignal : Throwable
    {
        this()
        {
            super("continue outside of a loop");
        }
    }

    private void execute(const BreakStmt, Environment)
    {
        throw new BreakSignal();
    }

    private void execute(const ContinueStmt, Environment)
    {
        throw new ContinueSignal();
    }

    /// Runs a loop's body once, and returns whether the loop goes on. Only the body is covered, so
    /// a `break` in a condition belongs to any loop around this one.
    private bool runLoopBody(const Expr body, Environment bodyScope)
    {
        try
        {
            evaluate(body, bodyScope);
        }
        catch (ContinueSignal)
        {
        }
        catch (BreakSignal)
        {
            return false;
        }
        return true;
    }

    private Variant call(Variant callee, Variant[] args, Environment variables)
    {
        if (auto constructor = callee.peek!Constructor)
        {
            return Variant(new Instance(*constructor, args));
        }
        auto fn = callee.get!Function;
        if (fn.native !is null)
        {
            return fn.native(args);
        }

        Environment functionEnv = new Environment(fn.closure);
        foreach (i, arg; args)
        {
            // Arguments are evaluated in the caller's environment.
            functionEnv.defineVariable(fn.declaration.params[i].name, arg);
        }

        try
        {
            auto value = evaluate(*fn.declaration.body, functionEnv);
            // Whatever the body ended in, a Unit function's value is dropped.
            if (analysis.signatureOf(fn.declaration.id).ret == analysis.types.unit)
            {
                return Variant(Unit());
            }
            return value;
        }
        catch (ReturnSignal signal)
        {
            return signal.value;
        }
    }

    private Variant evaluate(const MemberAccess ast, Environment variables)
    {
        // A chain like `std.math.pow` whose first name isn't a variable is a module path.
        auto base = dottedPath(*ast.object);
        if (base !is null && variables.find(base[0]) is null)
        {
            return resolveModulePath(base ~ ast.member, variables);
        }
        return member(evaluate(*ast.object, variables), ast.member);
    }

    private static Variant member(Variant object, string name)
    {
        return object.get!Instance.field(name);
    }

    private static Variant withField(Variant object, string name, Variant value)
    {
        return Variant(object.get!Instance.withField(name, value));
    }

    /// `a.b.c` as ["a", "b", "c"], or null if the chain doesn't start with an identifier.
    private static string[] dottedPath(const Expr expr)
    {
        return expr.kind.match!(
            (const Identifier i) { string[] path = [i.name]; return path; },
            (const MemberAccess m) {
                auto base = dottedPath(*m.object);
                return base is null ? null : base ~ m.member;
            },
            (_) => cast(string[]) null);
    }

    /// Looks `path` up as an imported module's member: the longest prefix that's an imported
    /// module, then members within it.
    private Variant resolveModulePath(string[] path, Environment variables)
    {
        import std.array : join;

        auto imports = ImportScope.of(variables);
        foreach_reverse (length; 1 .. path.length)
        {
            if (auto imported = path[0 .. length].join(".") in imports.modules)
            {
                auto value = imported.member(path[length]);
                foreach (name; path[length + 1 .. $])
                {
                    value = member(value, name);
                }
                return value;
            }
        }
        assert(0, "sema resolves every module path");
    }

    private Variant evaluate(const WhileExpr ast, Environment variables)
    {
        while (true)
        {
            auto bodyScope = variables;
            if (ast.binding is null)
            {
                if (!evaluate(*ast.condition, variables).get!bool) break;
            }
            else
            {
                auto option = evaluate(ast.binding.value, variables).get!OptionValue;
                if (!option.present) break;
                bodyScope = new Environment(variables);
                bodyScope.defineVariable(ast.binding.name, option.payload);
            }
            if (!runLoopBody(*ast.body, bodyScope)) break;
        }
        return Variant(Unit());
    }

    private Variant evaluate(const ForExpr ast, Environment variables)
    {
        bool iterate(Variant value)
        {
            auto bodyScope = new Environment(variables);
            bodyScope.defineVariable(ast.binding.name, value);
            return runLoopBody(*ast.body, bodyScope);
        }

        auto range = asRange(&ast.binding.value);
        if (range is null)
        {
            foreach (element; evaluate(ast.binding.value, variables).get!ArrayValue.elements)
            {
                if (!iterate(element)) break;
            }
            return Variant(Unit());
        }

        auto start = evaluate(*range.start, variables);
        auto end = evaluate(*range.end, variables);
        foreach (T; IntegerTypes)
        {
            if (auto first = start.peek!T)
            {
                auto last = end.get!T;
                // `i` stays below `last` until the step that ends the loop, so this can't overflow.
                for (T i = *first; i < last; i++)
                {
                    if (!iterate(Variant(i))) break;
                }
                return Variant(Unit());
            }
        }
        assert(0, "sema requires integer bounds");
    }

    private Variant evaluate(const IfExpr ast, Environment variables)
    {
        auto trueScope = variables;
        bool taken;
        if (ast.binding is null)
        {
            taken = evaluate(*ast.condition, variables).get!bool;
        }
        else
        {
            auto option = evaluate(ast.binding.value, variables).get!OptionValue;
            taken = option.present;
            if (taken)
            {
                trueScope = new Environment(variables);
                trueScope.defineVariable(ast.binding.name, option.payload);
            }
        }

        if (taken)
        {
            auto value = evaluate(*ast.trueBody, trueScope);
            if (ast.falseBody is null) return Variant(Unit());
            return value;
        }
        if (ast.falseBody !is null) return evaluate(*ast.falseBody, variables);
        return Variant(Unit());
    }

    private Variant evaluate(const BlockExpr ast, Environment variables)
    {
        auto blockEnv = new Environment(variables);
        foreach (statement; ast.statements)
        {
            execute(statement, blockEnv);
        }
        if (ast.value is null)
        {
            return Variant(Unit());
        }
        return evaluate(*ast.value, blockEnv);
    }

    private Variant evaluate(const UnitLiteral ast, Environment variables)
    {
        return Variant(Unit());
    }

    /// Numbers are unwrapped first: Variant's own operators compute two longs as ulong.
    private Variant operate(BinaryOp operator, Variant lhs, Variant rhs)
    {
        if (auto left = lhs.peek!double)
        {
            return operate(operator, *left, rhs.get!double);
        }
        foreach (T; IntegerTypes)
        {
            if (auto left = lhs.peek!T)
            {
                return operateInteger(operator, *left, rhs.get!T);
            }
        }
        if (auto left = lhs.peek!string)
        {
            auto right = rhs.get!string;
            if (operator == BinaryOp.Append)
            {
                auto text = *left;
                text ~= right;
                return Variant(text);
            }
            return compare(operator, *left, right);
        }
        if (operator == BinaryOp.Append)
        {
            auto elements = lhs.get!ArrayValue.elements;
            elements ~= rhs.get!ArrayValue.elements;
            return Variant(new ArrayValue(elements));
        }
        switch (operator)
        {
        case BinaryOp.Equal:
            return Variant(valuesEqual(lhs, rhs));
        case BinaryOp.NotEqual:
            return Variant(!valuesEqual(lhs, rhs));
        default:
            assert(0, "sema checked the operator against the operands' type");
        }
    }

    /// Instances compare structurally. Variant alone would compare them by reference,
    /// which would expose whether two values share an Instance.
    private bool valuesEqual(Variant lhs, Variant rhs)
    {
        if (auto left = lhs.peek!Instance)
        {
            return (*left).fieldsEqual(rhs.get!Instance, (a, b) => operate(BinaryOp.Equal, a, b).get!bool);
        }
        if (auto left = lhs.peek!OptionValue)
        {
            auto right = rhs.get!OptionValue;
            if (left.present != right.present) return false;
            if (!left.present) return true;
            return operate(BinaryOp.Equal, left.payload, right.payload).get!bool;
        }
        if (auto left = lhs.peek!TupleValue)
        {
            auto right = rhs.get!TupleValue;
            foreach (i, element; left.elements)
            {
                if (!operate(BinaryOp.Equal, element, right.elements[i]).get!bool) return false;
            }
            return true;
        }
        if (auto left = lhs.peek!ArrayValue)
        {
            auto right = rhs.get!ArrayValue;
            if (left.elements.length != right.elements.length) return false;
            foreach (i, element; left.elements)
            {
                if (!operate(BinaryOp.Equal, element, right.elements[i]).get!bool) return false;
            }
            return true;
        }
        return lhs == rhs;
    }

    private Variant operate(BinaryOp operator, double lhs, double rhs)
    {
        switch (operator)
        {
        case BinaryOp.Add:
            return Variant(lhs + rhs);
        case BinaryOp.Subtract:
            return Variant(lhs - rhs);
        case BinaryOp.Multiply:
            return Variant(lhs * rhs);
        case BinaryOp.Divide:
            return Variant(lhs / rhs);
        case BinaryOp.Modulo:
            return Variant(lhs % rhs);
        default:
            return compare(operator, lhs, rhs);
        }
    }

    /// Arithmetic that doesn't fit the type panics; only the `&` forms wrap.
    private Variant operateInteger(T)(BinaryOp operator, T lhs, T rhs)
    {
        switch (operator)
        {
        case BinaryOp.Add:
            return Variant(checked!"+"(lhs, rhs));
        case BinaryOp.Subtract:
            return Variant(checked!"-"(lhs, rhs));
        case BinaryOp.Multiply:
            return Variant(checked!"*"(lhs, rhs));
        case BinaryOp.WrappingAdd:
            return Variant(cast(T)(lhs + rhs));
        case BinaryOp.WrappingSubtract:
            return Variant(cast(T)(lhs - rhs));
        case BinaryOp.WrappingMultiply:
            return Variant(cast(T)(lhs * rhs));
        case BinaryOp.Divide:
        case BinaryOp.Modulo:
            if (rhs == 0)
            {
                throw new CodedException(DiagnosticCode.DivisionByZero, "Division by zero");
            }
            static if (isSigned!T)
            {
                if (lhs == T.min && rhs == -1) throw overflow();
            }
            return Variant(cast(T)(operator == BinaryOp.Divide ? lhs / rhs : lhs % rhs));
        case BinaryOp.BitAnd:
            return Variant(cast(T)(lhs & rhs));
        case BinaryOp.BitOr:
            return Variant(cast(T)(lhs | rhs));
        case BinaryOp.BitXor:
            return Variant(cast(T)(lhs ^ rhs));
        case BinaryOp.ShiftLeft:
        case BinaryOp.ShiftRight:
            static if (isSigned!T)
            {
                auto inRange = rhs >= 0 && rhs < T.sizeof * 8;
            }
            else
            {
                auto inRange = rhs < T.sizeof * 8;
            }
            if (!inRange)
            {
                throw new CodedException(DiagnosticCode.InvalidShift, "Shift amount is out of range");
            }
            auto count = cast(int) rhs;
            return Variant(cast(T)(operator == BinaryOp.ShiftLeft ? lhs << count : lhs >> count));
        default:
            return compare(operator, lhs, rhs);
        }
    }

    private static Variant compare(T)(BinaryOp operator, T lhs, T rhs)
    {
        switch (operator)
        {
        case BinaryOp.Equal:
            return Variant(lhs == rhs);
        case BinaryOp.NotEqual:
            return Variant(lhs != rhs);
        case BinaryOp.Less:
            return Variant(lhs < rhs);
        case BinaryOp.LessEqual:
            return Variant(lhs <= rhs);
        case BinaryOp.Greater:
            return Variant(lhs > rhs);
        case BinaryOp.GreaterEqual:
            return Variant(lhs >= rhs);
        default:
            assert(0, "sema checked the operator against the operands' type, and and/or short-circuit earlier");
        }
    }

    private static CodedException overflow()
    {
        return new CodedException(DiagnosticCode.IntegerOverflow, "Integer overflow");
    }

    private static T checked(string op, T)(T lhs, T rhs)
    {
        static if (T.sizeof < 4)
        {
            // These fit an int, whatever the operator.
            int wide = mixin("int(lhs) " ~ op ~ " int(rhs)");
            if (wide < T.min || wide > T.max) throw overflow();
            return cast(T) wide;
        }
        else
        {
            import core.checkedint : adds, addu, muls, mulu, subs, subu;

            bool overflowed;
            static if (isSigned!T)
            {
                static if (op == "+") T result = adds(lhs, rhs, overflowed);
                else static if (op == "-") T result = subs(lhs, rhs, overflowed);
                else T result = muls(lhs, rhs, overflowed);
            }
            else
            {
                static if (op == "+") T result = addu(lhs, rhs, overflowed);
                else static if (op == "-") T result = subu(lhs, rhs, overflowed);
                else T result = mulu(lhs, rhs, overflowed);
            }
            if (overflowed) throw overflow();
            return result;
        }
    }

    private Variant unaryOperate(UnaryOp operator, Variant value)
    {
        if (operator == UnaryOp.Plus) return value;
        if (operator == UnaryOp.Not) return Variant(!value.get!bool);

        if (auto number = value.peek!double)
        {
            if (operator == UnaryOp.Minus) return Variant(-*number);
        }
        foreach (T; IntegerTypes)
        {
            if (auto number = value.peek!T)
            {
                if (operator == UnaryOp.BitNot) return Variant(cast(T)~*number);
                static if (isSigned!T)
                {
                    if (*number == T.min) throw overflow();
                    return Variant(cast(T)-*number);
                }
            }
        }
        assert(0, "sema checked the operator against the operand's type");
    }
}
