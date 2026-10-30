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

    static class Function
    {
        const FunctionDecl declaration;
        Environment closure;
        this(const FunctionDecl declaration, Environment closure)
        {
            this.declaration = declaration;
            this.closure = closure;
        }

        override string toString() const
        {
            return declaration.name;
        }
    }

    private Environment globals;

    const(Variant[string]) getGlobals() const
    {
        return globals.variables;
    }

    /// Executes the ast.
    void run()
    {
        globals = new Environment();
        execute(program, globals);
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
        catch (SilverRuntimeException e)
        {
            throw e;
        }
        catch (ReturnSignal signal)
        {
            throw signal;
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

    private void execute(const PrintStmt ast, Environment variables)
    {
        import std.conv : to;
        import std.stdio;


        auto value = evaluate(ast.expr, variables);
        if (!ast.newline)
        {
            programOutput ~= value.to!string;
            if (useStdOut)
            {
                write(value);
            }
        }
        else
        {
            programOutput ~= value.to!string ~ "\n";
            if (useStdOut)
            {
                writeln(value);
            }
        }
    }

    private void execute(const IfStmt ast, Environment variables)
    {
        import std.conv : to;

        auto condition = evaluate(ast.condition, variables);
        if (condition.get!bool)
        {
            Environment blockEnv = new Environment(variables);
            foreach (statement; ast.body)
            {
                execute(statement, blockEnv);
            }
        }
        else
        {
            Environment blockEnv = new Environment(variables);
            foreach (statement; ast.elseBody)
            {
                execute(statement, blockEnv);
            }
        }
    }

    private void execute(const FunctionDecl ast, Environment variables)
    {
        variables.defineFunction(ast.name, new Function(ast, variables));
    }

    private void execute(const ImportStmt ast, Environment variables)
    {
        import std.array : join;

        auto loadedModule = loadModule(ast.path);
        variables.defineVariable(ast.path.join("."), Variant(loadedModule));
    }

    private Module loadModule(const (string[]) moduleChain)
    {
        import std.file : exists, readText;
        import std.path : buildPath;
        import std.format : format;
        import std.array : join;
        import silver.parse;

        foreach (importPath; importPaths)
        {
            auto modulePath = buildPath(importPath, moduleChain.join("/") ~ ".silver");
            if (exists(modulePath))
            {
                auto moduleSource = readText(modulePath);
                auto moduleName = moduleChain.join(".");
                auto moduleAst = parse(moduleSource, moduleName, modulePath);
                sourceFiles[modulePath] = moduleSource;
                auto moduleEnv = new Environment();
                execute(moduleAst, moduleEnv);

                return new Module(moduleName, moduleEnv);
            }
        }
    
        throw new Exception("Module '%s'.silver not found".format(moduleChain.join("/")));
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
    private class ReturnSignal : Exception
    {
        Variant value;
        this(Variant value)
        {
            super("return outside of a function"); // what you see if it escapes to top level
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

    private Variant evaluate(const IfExpr ast, Environment variables)
    {
        auto condition = evaluate(*ast.condition, variables);
        if (condition.convertsTo!bool)
        {
            if (condition.get!bool)
            {
                return evaluate(*ast.trueBody, variables);
            }
            else
            {
                return evaluate(*ast.falseBody, variables);
            }
        }
        throw new Exception("If condition must be a boolean");
    }

    private Variant evaluate(const BlockExpr ast, Environment variables)
    {
        foreach (statement; ast.statements)
        {
            execute(statement, variables);
        }
        return evaluate(*ast.returnExpr, variables);
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
