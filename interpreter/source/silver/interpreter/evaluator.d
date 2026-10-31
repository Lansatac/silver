module silver.interpreter.evaluator;

import std.sumtype;
import std.variant : Variant;
import silver.ast;
import silver.interpreter.environment : Environment;
import silver.interpreter.values;

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

    private bool useStdOut;
    private string outputText;

    /// Everything the program has printed so far.
    string output() const
    {
        return outputText;
    }

    nothrow this(Program program, bool useStdOut = false)
    {
        this.program = program;
        this.useStdOut = useStdOut;
    }

    private Environment globalEnvironment;
    /// Names every module can see without importing them, loaded from
    /// prelude.silver. Module environments are its children, so they can shadow it.
    private Environment prelude;
    /// Implementations for `native def`s, by function name.
    private NativeFunction[string] nativeBindings;

    const(Variant[string]) globals() const
    {
        return globalEnvironment.variables;
    }

    void run()
    {
        bindNatives();
        try
        {
            prelude = new Environment();
            auto preludeModule = program.modules.get("prelude", null);
            if (preludeModule !is null)
            {
                execute(*preludeModule, prelude);
            }
            globalEnvironment = new Environment(prelude);
            execute(program.main, globalEnvironment);
        }
        catch (ReturnSignal signal)
        {
            throw runtimeError(signal.span, new Exception("return outside of a function"));
        }
    }

    private void execute(const Module ast, Environment variables)
    {
        foreach (child; ast.statements)
        {
            execute(child, variables);
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
        auto value = ast.value.kind.match!(s => evaluate(s, variables));
        variables.defineVariable(ast.name, value, ast.mutable);
    }

    private void execute(const AssignStmt ast, Environment variables)
    {
        // ast is const, so the target's kind holds const types; matching on
        // `const Identifier` avoids has!/get! failing on the qualifier.
        auto name = ast.target.kind.match!(
            (const Identifier i) => i.name,
            (_) => throw new Exception("PH: Can only assign to a variable"));
        auto value = evaluate(ast.value, variables);
        variables.setVariable(name, value);
    }

    private void bindNatives()
    {
        import std.stdio : readln;

        nativeBindings["print"] = (Variant[] args) => print(args[0], false);
        nativeBindings["printl"] = (Variant[] args) => print(args[0], true);
        nativeBindings["read"] = (Variant[] args) => Variant(readln());
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

            throw new Exception("No native binding for %s".format(ast.name));
        }
        variables.defineVariable(ast.name, Variant(new Function(ast, variables, *binding)));
    }

    /// Executes the imported module, which the loader has already parsed, into a
    /// fresh environment, and binds it to the import's dotted name.
    private void execute(const ImportStmt ast, Environment variables)
    {
        import std.array : join;
        import std.format : format;

        auto name = ast.path.join(".");
        auto loaded = program.modules.get(name, null);
        if (loaded is null)
        {
            throw new Exception("Module %s was not loaded".format(name));
        }
        auto moduleEnv = new Environment(prelude);
        execute(*loaded, moduleEnv);
        variables.defineVariable(name, Variant(new ModuleValue(name, moduleEnv)));
    }

    private void execute(const ExprStmt ast, Environment variables)
    {
        evaluate(ast.expr, variables);
    }

    private Variant evaluate(const Expr ast, Environment variables)
    {
        try
        {
            return ast.kind.match!(s => evaluate(s, variables));
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

    private RuntimeError runtimeError(Span span, Exception error)
    {
        return new RuntimeError(Diagnostic(span, error.msg));
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

    private Variant evaluate(const IntLiteral ast, Environment variables)
    {
        return makeValue(ast.value);
    }

    private Variant evaluate(const FloatLiteral ast, Environment variables)
    {
        return makeValue(ast.value);
    }

    private Variant evaluate(const Identifier ast, Environment variables)
    {
        return variables.resolveVariable(ast.name);
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

        if (!callee.convertsTo!Function)
        {
            throw new Exception("%s is not a function".format(callee));
        }
        auto fn = callee.get!Function;
        if (args.length != fn.declaration.params.length)
        {
            throw new Exception("%s expects %s arguments, got %s".format(
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
        import std.format : format;

        auto object = evaluate(*ast.object, variables);
        if (object.convertsTo!ModuleValue)
        {
            return object.get!ModuleValue.member(ast.member);
        }
        throw new Exception("%s has no member %s".format(object, ast.member));
    }

    private Variant evaluate(const WhileExpr ast, Environment variables)
    {
        auto condition = evaluate(*ast.condition, variables);
        while(condition.convertsTo!bool && condition.get!bool)
        {
            evaluate(*ast.body, variables);
            condition = evaluate(*ast.condition, variables);
        }

        return Variant(Unit());
    }

    private Variant evaluate(const IfExpr ast, Environment variables)
    {
        auto condition = evaluate(*ast.condition, variables);
        if (condition.convertsTo!bool)
        {
            if (condition.get!bool)
            {
                return evaluate(*ast.trueBody, variables);
            }
            else if (ast.falseBody !is null)
            {
                return evaluate(*ast.falseBody, variables);
            }
            return Variant(Unit());
        }
        throw new Exception("If condition must be a boolean");
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

    private Variant operate(BinaryOp operator, Variant lhs, Variant rhs)
    {
        final switch (operator)
        {
        case BinaryOp.Add:
            return lhs + rhs;
        case BinaryOp.Subtract:
            return lhs - rhs;
        case BinaryOp.Multiply:
            return lhs * rhs;
        case BinaryOp.Divide:
            return lhs / rhs;
        case BinaryOp.Modulo:
            return lhs % rhs;
        case BinaryOp.Power:
            return lhs ^^ rhs;
        case BinaryOp.Equal:
            return Variant(lhs == rhs);
        case BinaryOp.NotEqual:
            return Variant(lhs != rhs);
        case BinaryOp.And:
        case BinaryOp.Or:
            assert(0, "and/or short-circuit in evaluate(BinaryExpr)");
        case BinaryOp.Less:
            return Variant(lhs < rhs);
        case BinaryOp.LessEqual:
            return Variant(lhs <= rhs);
        case BinaryOp.Greater:
            return Variant(lhs > rhs);
        case BinaryOp.GreaterEqual:
            return Variant(lhs >= rhs);
        case BinaryOp.Coalesce:
            throw new Exception("Coalesce operator not implemented");
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

                throw new Exception(
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
