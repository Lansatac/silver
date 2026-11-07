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

    /// `analysis` is null only for programs that skip sema, like the interpreter's own tests.
    /// Integer literals in those programs stay Int, even where a Float is expected.
    nothrow this(Program program, const Analysis analysis, bool useStdOut = false)
    {
        this.program = program;
        this.analysis = analysis;
        this.useStdOut = useStdOut;
    }

    /// Names every module can see without importing them, loaded from prelude.ag.
    /// Every module's ImportScope searches it last.
    private Environment prelude;
    /// Every module run so far, by dotted name, so each runs once however often it's imported.
    private ModuleValue[string] modules;
    /// Implementations for `native def`s, by function name.
    private NativeFunction[string] nativeBindings;

    void run()
    {
        bindNatives();
        prelude = new Environment(new ImportScope(null));
        modules["prelude"] = new ModuleValue("prelude", prelude);
        auto preludeModule = program.modules.get("prelude", null);
        if (preludeModule !is null)
        {
            execute(*preludeModule, prelude);
        }
        callMain();
    }

    /// Runs the module that defines `main`, which runs everything it imports, then calls `main`.
    /// Sema reports a program without exactly one `main`; this repeats the check for programs
    /// that skip sema, like the interpreter's own tests.
    private void callMain()
    {
        import std.algorithm : map;
        import std.array : join;

        auto mains = mainFunctions(program);
        if (mains.length == 0)
        {
            throw runtimeError(Span.init, new CodedException(DiagnosticCode.MissingMain,
                "the program must define `def main(): Unit` in one of its modules"));
        }
        if (mains.length > 1)
        {
            throw runtimeError(mains[1].nameSpan, new CodedException(DiagnosticCode.MultipleMains,
                "`main` is defined in more than one module: " ~ mains.map!(m => m.moduleName).join(", ")));
        }
        auto environment = moduleValue(mains[0].moduleName).environment;
        auto entry = environment.variables["main"];
        auto main = entry.get!Function;
        if (main.declaration.params.length > 0)
        {
            throw runtimeError(main.declaration.nameSpan, new CodedException(DiagnosticCode.MainInvalidDefinition, "`main` must take no parameters"));
        }
        call(entry, [], environment);
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
        catch (ReturnSignal signal)
        {
            if (!signal.located)
            {
                signal.span = ast.span;
                signal.located = true;
            }
            throw signal;
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
        variables.defineVariable(ast.name, evaluate(ast.value, variables), ast.mutable);
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
            (_) {
                throw new CodedException(DiagnosticCode.InvalidAssignmentTarget, "PH: Can only assign to a variable or field");
            });
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
        if (analysis is null)
        {
            throw new CodedException(DiagnosticCode.InternalError, "A top-level constant needs sema to evaluate it");
        }
        auto type = analysis.typeOf(ast.id);
        auto value = analysis.valueOf(ast.id).match!(
            (const ConstInt v) => integerValue(v.value, type),
            (const ConstUInt v) => integerValue(v.value, type),
            (const bool v) => makeValue(v),
            (const double v) => makeValue(v),
            (string v) => Variant(v),
            (const ConstUnit _) => Variant(Unit()),
        );
        variables.defineVariable(ast.name, value, false);
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
        auto value = new ModuleValue(name, new Environment(new ImportScope(prelude)));
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
            if (analysis !is null)
            {
                if (auto option = analysis.promotionOf(ast.id))
                {
                    return promote(value, analysis.typeOf(ast.id), *option);
                }
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
    /// `to` is, and anything else gets one `Some` for each level between the types.
    private Variant promote(Variant value, Type from, Type to)
    {
        if (from == to || from == analysis.types.none) return value;
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
        return evaluate(ast, variables);
    }

    /// `if`, not `?:`: with dmd 2.113, an exception thrown from a `?:` that produces a Variant
    /// could vanish, so the statement was skipped without any error.
    private Variant evaluateCall(const CallExpr call, Id!Expr id, Environment variables)
    {
        if (analysis !is null && analysis.isConversion(id))
        {
            return convert(evaluate(call.args[0], variables), analysis.typeOf(id));
        }
        return evaluate(call, variables);
    }

    /// Sema gives an integer literal the type expected of it, as in `half(3)`.
    private Variant intLiteralValue(const IntLiteral literal, Id!Expr id)
    {
        if (analysis is null) return Variant(cast(long) literal.value);

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
        if (auto value = variables.find(ast.name))
        {
            return *value;
        }
        return resolveModulePath([ast.name], variables);
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
        /// Where the `return` is, for the error if it escapes to top level.
        /// Filled in by the enclosing execute(Stmt).
        Span span;
        bool located;

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

    private Variant call(Variant callee, Variant[] args, Environment variables)
    {
        import std.format : format;

        if (auto constructor = callee.peek!Constructor)
        {
            auto declaration = (*constructor).declaration;
            if (args.length != declaration.fields.length)
            {
                throw new CodedException(DiagnosticCode.WrongArgumentCount, "%s expects %s arguments, got %s".format(
                        declaration.name, declaration.fields.length, args.length));
            }
            return Variant(new Instance(*constructor, args));
        }
        if (!callee.convertsTo!Function)
        {
            throw new CodedException(DiagnosticCode.NotCallable, "%s is not a function".format(callee));
        }
        auto fn = callee.get!Function;
        if (args.length != fn.declaration.params.length)
        {
            throw new CodedException(DiagnosticCode.WrongArgumentCount, "%s expects %s arguments, got %s".format(
                    fn.declaration.name, fn.declaration.params.length, args.length));
        }

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
            if (analysis !is null && analysis.signatureOf(fn.declaration.id).ret == analysis.types.unit)
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
        // Variables win, so a local `std` hides every module under std.
        auto base = dottedPath(*ast.object);
        if (base !is null && variables.find(base[0]) is null)
        {
            return resolveModulePath(base ~ ast.member, variables);
        }
        return member(evaluate(*ast.object, variables), ast.member);
    }

    private static Variant member(Variant object, string name)
    {
        return instanceWithMember(object, name).field(name);
    }

    private static Variant withField(Variant object, string name, Variant value)
    {
        return Variant(instanceWithMember(object, name).withField(name, value));
    }

    private static Instance instanceWithMember(Variant object, string name)
    {
        import std.format : format;

        if (auto instance = object.peek!Instance)
        {
            return *instance;
        }
        throw new CodedException(DiagnosticCode.UnknownMember, "%s has no member %s".format(object, name));
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
    /// module, then members within it. A path that names only a module, or part of one, is an error.
    private Variant resolveModulePath(string[] path, Environment variables)
    {
        import std.algorithm : any, startsWith;
        import std.array : join;
        import std.format : format;

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

        foreach_reverse (length; 1 .. path.length + 1)
        {
            auto prefix = path[0 .. length].join(".");
            if (imports.modules.byKey.any!(m => m == prefix || m.startsWith(prefix ~ ".")))
            {
                if (length == path.length)
                {
                    throw new CodedException(DiagnosticCode.ModuleIsNotAValue, "Module path '%s' is not a value".format(prefix));
                }
                throw new CodedException(DiagnosticCode.UnknownModuleMember, "Module path '%s' has no member '%s'".format(prefix, path[length]));
            }
        }
        throw new CodedException(DiagnosticCode.UnknownName, "Variable '%s' not found".format(path[0]));
    }

    private Variant evaluate(const WhileExpr ast, Environment variables)
    {
        while (evaluateCondition(*ast.condition, variables, "While"))
        {
            evaluate(*ast.body, variables);
        }
        return Variant(Unit());
    }

    private Variant evaluate(const IfExpr ast, Environment variables)
    {
        auto trueScope = variables;
        bool taken;
        if (ast.binding is null)
        {
            taken = evaluateCondition(*ast.condition, variables, "If");
        }
        else
        {
            auto option = evaluate(ast.binding.value, variables).get!OptionValue;
            taken = option.present;
            if (taken)
            {
                trueScope = new Environment(variables);
                trueScope.defineVariable(ast.binding.name, option.payload, false);
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

    private bool evaluateCondition(const Expr condition, Environment variables, string construct)
    {
        auto value = evaluate(condition, variables);
        if (!value.convertsTo!bool)
        {
            throw new CodedException(DiagnosticCode.ConditionNotBool, construct ~ " condition must be a boolean");
        }
        return value.get!bool;
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
    /// Int and Float only meet in programs that skipped sema, where an integer literal beside
    /// a Float hasn't been adapted, so a mixed pair is Float arithmetic.
    private Variant operate(BinaryOp operator, Variant lhs, Variant rhs)
    {
        if (lhs.peek!double || rhs.peek!double)
        {
            return operate(operator, lhs.get!double, rhs.get!double);
        }
        foreach (T; IntegerTypes)
        {
            if (auto left = lhs.peek!T)
            {
                return operateInteger(operator, *left, rhs.get!T);
            }
        }
        auto leftString = lhs.peek!string;
        auto rightString = rhs.peek!string;
        if (leftString && rightString)
        {
            if (operator == BinaryOp.Concat) return Variant(*leftString ~ *rightString);
            return compare(operator, *leftString, *rightString);
        }
        switch (operator)
        {
        case BinaryOp.Equal:
            return Variant(valuesEqual(lhs, rhs));
        case BinaryOp.NotEqual:
            return Variant(!valuesEqual(lhs, rhs));
        default:
            import std.format : format;

            throw new CodedException(DiagnosticCode.InvalidOperand,
                "Unsupported operator %s for type %s".format(operator, lhs.type));
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
        case BinaryOp.And:
        case BinaryOp.Or:
            assert(0, "and/or short-circuit in evaluate(BinaryExpr)");
        default:
            import std.format : format;

            throw new CodedException(DiagnosticCode.InvalidOperand,
                "Unsupported operator %s for %s".format(operator, T.stringof));
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

        import std.conv : to;

        throw new CodedException(DiagnosticCode.InvalidOperand,
            "Unsupported unary operator " ~ operator.to!string ~ " for type " ~ value.type.to!string);
    }
}
