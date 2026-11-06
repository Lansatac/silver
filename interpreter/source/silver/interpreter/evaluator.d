module silver.interpreter.evaluator;

import std.sumtype;
import std.variant : Variant;
import silver.ast;
import silver.interpreter.environment : Environment, ImportScope;
import silver.interpreter.errors : CodedException;
import silver.interpreter.values;
import silver.sema : Analysis;

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
        nativeBindings["read"] = (Variant[] args) => Variant(readln());
        bindNumericNatives();
    }

    /// Each is the same D expression as the compiled backend's, in the runtime's numeric module.
    private void bindNumericNatives()
    {
        import libm = core.stdc.math;

        static NativeFunction floatFunction(alias f)()
        {
            return (Variant[] args) => Variant(f(args[0].get!double));
        }

        nativeBindings["toInt"] = (Variant[] args) {
            auto value = args[0].get!double;
            if (!(value >= -0x1p63 && value < 0x1p63))
            {
                throw new CodedException(DiagnosticCode.InvalidConversion,
                    "toInt: the value is NaN or outside Int's range");
            }
            return Variant(cast(long) value);
        };
        nativeBindings["toFloat"] = (Variant[] args) => Variant(cast(double) args[0].get!long);

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
            return ast.kind.match!(
                (const IntLiteral literal) => intLiteralValue(literal, ast.id),
                s => evaluate(s, variables));
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

    /// Sema types an integer literal as Float where one is expected, as in `half(3)`.
    private Variant intLiteralValue(const IntLiteral literal, Id!Expr id)
    {
        if (analysis !is null && analysis.typeOf(id) == analysis.types.float_)
        {
            return Variant(cast(double) literal.value);
        }
        return makeValue(literal.value);
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
        return unaryOperate(ast.op, value);
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
            return evaluate(*fn.declaration.body, functionEnv);
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
        if (evaluateCondition(*ast.condition, variables, "If"))
        {
            return evaluate(*ast.trueBody, variables);
        }
        else if (ast.falseBody !is null)
        {
            return evaluate(*ast.falseBody, variables);
        }
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
        if (auto left = lhs.peek!long)
        {
            return operate(operator, *left, rhs.get!long);
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
        return lhs == rhs;
    }

    private Variant operate(T)(BinaryOp operator, T lhs, T rhs)
    {
        import std.traits : isIntegral;

        final switch (operator)
        {
        case BinaryOp.Add:
            return Variant(lhs + rhs);
        case BinaryOp.Subtract:
            return Variant(lhs - rhs);
        case BinaryOp.Multiply:
            return Variant(lhs * rhs);
        case BinaryOp.Divide:
        case BinaryOp.Modulo:
            static if (isIntegral!T)
            {
                if (rhs == 0)
                {
                    throw new CodedException(DiagnosticCode.DivisionByZero, "Division by zero");
                }
            }
            return Variant(operator == BinaryOp.Divide ? lhs / rhs : lhs % rhs);
        case BinaryOp.Power:
            return Variant(lhs ^^ rhs);
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
        case BinaryOp.Coalesce:
            throw new CodedException(DiagnosticCode.InternalError, "Coalesce operator not implemented");
        }
    }

    private Variant unaryOperate(UnaryOp operator, Variant value)
    {
        final switch (operator)
        {
        case UnaryOp.Minus:
            // Check long first: long implicitly converts to double, so the
            // other order would turn every negated integer into a float.
            if (value.convertsTo!long)
            {
                return Variant(-value.get!long);
            }
            else if (value.convertsTo!double)
            {
                return Variant(-value.get!double);
            }
            else
            {
                import std.conv : to;

                throw new CodedException(DiagnosticCode.InvalidOperand,
                    "Unsupported unary operator " ~ operator.to!string ~ " for type " ~ value
                        .type.to!string);
            }
        case UnaryOp.Plus:
            return value;
        case UnaryOp.Not:
            return Variant(!value.get!bool);
        }
    }
}
