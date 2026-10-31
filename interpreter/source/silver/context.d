module silver.context;

import std.sumtype;
import silver.ast;
import silver.ast : AstModule = Module, AstStatement = Stmt;
import silver.parse : ParseException;

class SilverRuntimeException : Exception
{
    string sourceFile;
    size_t sourceLine;

    this(string message, string sourceFile, size_t sourceLine)
    {
        super(message);
        this.sourceFile = sourceFile;
        this.sourceLine = sourceLine;
    }
}

/// The runtime value of `()`, e.g. a block that doesn't end in an expression.
struct Unit
{
    string toString() const
    {
        return "()";
    }
}

class Context
{
    import std.variant;
    import std.container.array;
    //import std.regex;

    private AstModule program;

    private bool useStdOut;
    private string programOutput;
    private string[] importPaths;
    private string[string] sourceFiles;
    public const(string) ProgramOutput()
    {
        return programOutput;
    }

    nothrow this(AstModule program, string[] importPaths, bool useStdOut = false,
        string source = null)
    {
        this.program = program;
        this.useStdOut = useStdOut;
        this.importPaths = importPaths;
        if (source !is null)
        {
            sourceFiles[program.span.file] = source;
        }
    }

    static class Environment
    {
        Variant[string] variables;
        /// Names declared with `val`, which can't be reassigned.
        bool[string] immutables;
        Environment parent;
        this(Environment parent = null)
        {
            this.parent = parent;
        }

        public void defineVariable(string name, Variant value, bool mutable = true)
        {
            if (name in variables)
            {
                import std.format;

                throw new Exception("Duplicate declaration of variable %s".format(name));
            }
            variables[name] = value;
            if (!mutable)
            {
                immutables[name] = true;
            }
        }

        public void setVariable(string name, Variant value)
        {
            if (name in variables)
            {
                if (name in immutables)
                {
                    import std.format : format;

                    throw new Exception("Cannot assign to val '%s'. Declare as 'mutable val' to reassign it.".format(name));
                }
                variables[name] = value;
            }
            else if (parent !is null)
            {
                parent.setVariable(name, value);
            }
            else
            {
                import std.format : format;

                throw new Exception("Variable %s not found".format(name));
            }
        }

        public Variant resolveVariable(string name)
        {
            if (name in variables)
            {
                return variables[name];
            }
            else if (parent !is null)
            {
                return parent.resolveVariable(name);
            }
            else
            {
                import std.format : format;

                throw new Exception("Variable %s not found".format(name));
            }
        }

        public void defineFunction(string name, Function fn)
        {
            defineVariable(name, Variant(fn));
        }

        public Function resolveFunction(string name)
        {
            auto value = resolveVariable(name);
            if (!value.convertsTo!Function)
            {
                import std.format : format;

                throw new Exception("Variable %s is not a function".format(name));
            }
            return value.get!Function;
        }
    }

    static class Module
    {
        string name;
        Environment environment;
        this(string name, Environment environment)
        {
            this.name = name;
            this.environment = environment;
        }

        /// Looks up a name defined at the module's top level.
        /// Deliberately does not search parent environments.
        Variant member(string memberName)
        {
            if (auto value = memberName in environment.variables)
            {
                return *value;
            }
            import std.format : format;

            throw new Exception("Module %s has no member %s".format(name, memberName));
        }

        override string toString() const
        {
            return name;
        }
    }

    /// The D implementation behind a `native def`. Arguments are already
    /// evaluated and their count checked against the declaration.
    alias NativeFunction = Variant delegate(Variant[] args);

    static class Function
    {
        const FunctionDecl declaration;
        Environment closure;
        /// Set when the declaration is `native`; the body is null then.
        NativeFunction native;
        this(const FunctionDecl declaration, Environment closure, NativeFunction native = null)
        {
            this.declaration = declaration;
            this.closure = closure;
            this.native = native;
        }

        override string toString() const
        {
            return declaration.name;
        }
    }

    private Environment globals;
    /// Names every module can see without importing them, loaded from
    /// prelude.silver. Module environments are its children, so they can shadow it.
    private Environment prelude;
    /// Implementations for `native def`s, by function name.
    private NativeFunction[string] nativeBindings;

    const(Variant[string]) getGlobals() const
    {
        return globals.variables;
    }

    /// Executes the ast.
    void run()
    {
        bindNatives();
        try
        {
            prelude = loadPrelude();
            globals = new Environment(prelude);
            execute(program, globals);
        }
        catch (ReturnSignal signal)
        {
            throw runtimeError(signal.span, new Exception("return outside of a function"));
        }
    }

    private void execute(AstModule ast, Environment variables)
    {
        foreach (child; ast.statements)
        {
            execute(child, variables);
        }
    }

    private void execute(AstStatement ast, Environment variables)
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
        catch (SilverRuntimeException e)
        {
            throw e;
        }
        catch (ParseException e)
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
        // `const VariableRef` avoids has!/get! failing on the qualifier.
        auto name = ast.target.kind.match!(
            (const VariableRef v) => v.name,
            (_) => throw new Exception("PH: Can only assign to a variable"));
        auto value = evaluate(ast.value, variables);
        variables.setVariable(name, value);
    }

    private void bindNatives()
    {
        nativeBindings["print"] = (Variant[] args) => output(args[0], false);
        nativeBindings["printl"] = (Variant[] args) => output(args[0], true);
    }

    private Variant output(Variant value, bool newline)
    {
        import std.conv : to;
        import std.stdio : write, writeln;

        programOutput ~= value.to!string ~ (newline ? "\n" : "");
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
            variables.defineFunction(ast.name, new Function(ast, variables));
            return;
        }
        auto binding = ast.name in nativeBindings;
        if (binding is null)
        {
            import std.format : format;

            throw new Exception("No native binding for %s".format(ast.name));
        }
        variables.defineFunction(ast.name, new Function(ast, variables, *binding));
    }

    private void execute(const ImportStmt ast, Environment variables)
    {
        import std.array : join;

        auto loadedModule = loadModule(ast.path);
        variables.defineVariable(ast.path.join("."), Variant(loadedModule));
    }

    private Module loadModule(const (string[]) moduleChain)
    {
        import std.format : format;
        import std.array : join;

        auto moduleEnv = new Environment(prelude);
        if (!tryLoadModule(moduleChain, moduleEnv))
        {
            throw new Exception("Module '%s'.silver not found".format(moduleChain.join("/")));
        }
        return new Module(moduleChain.join("."), moduleEnv);
    }

    /// Loads prelude.silver if an import path has one. Contexts without a
    /// standard library (e.g. in tests) get an empty prelude.
    private Environment loadPrelude()
    {
        auto preludeEnv = new Environment();
        tryLoadModule(["prelude"], preludeEnv);
        return preludeEnv;
    }

    /// Finds the module on the import paths and executes it into `moduleEnv`.
    /// Returns false if no import path has it.
    private bool tryLoadModule(const (string[]) moduleChain, Environment moduleEnv)
    {
        import std.file : exists, readText;
        import std.path : buildPath;
        import std.array : join;
        import silver.parse;

        foreach (importPath; importPaths)
        {
            auto modulePath = buildPath(importPath, moduleChain.join("/") ~ ".silver");
            if (exists(modulePath))
            {
                auto moduleSource = readText(modulePath);
                auto moduleAst = parse(moduleSource, moduleChain.join("."), modulePath);
                sourceFiles[modulePath] = moduleSource;
                execute(moduleAst, moduleEnv);
                return true;
            }
        }
        return false;
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
        catch (SilverRuntimeException e)
        {
            throw e;
        }
        catch (Exception e)
        {
            throw runtimeError(ast.span, e);
        }
    }

    private SilverRuntimeException runtimeError(Span span, Exception error)
    {
        size_t line = 1;
        if (auto source = span.file in sourceFiles)
        {
            auto offset = span.start < source.length ? span.start : source.length;
            foreach (character; (*source)[0 .. offset])
            {
                if (character == '\n')
                {
                    line++;
                }
            }
        }
        return new SilverRuntimeException(error.msg, span.file, line);
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

    private Variant evaluate(const VariableRef ast, Environment variables)
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
    /// handlers that turn errors into SilverRuntimeExceptions don't swallow it.
    private class ReturnSignal : Throwable
    {
        Variant value;
        /// Where the `return` is, for the error if it escapes to top level.
        /// Filled in by the enclosing execute(AstStatement).
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
            functionEnv.defineVariable(fn.declaration.params[i], arg);
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
        if (object.convertsTo!Module)
        {
            return object.get!Module.member(ast.member);
        }
        throw new Exception("%s has no member %s".format(object, ast.member));
    }

    private Variant evaluate(const ReadExpr ast, Environment variables)
    {
        import std.stdio : readln;

        return Variant(readln());
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

    private Variant memberOf(Variant value, string memberName)
    {
        if (value.convertsTo!Module)
        {
            return value.get!Module.member(memberName);
        }

        import std.format : format;

        throw new Exception("%s has no member %s".format(value, memberName));
    }

    private Variant operate(BinaryOp operator, Variant lhs, Variant rhs)
    {
        //writefln("%s %s %s", lhs, operator, rhs);
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
        //writefln("%s %s %s", lhs, operator, rhs);
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
