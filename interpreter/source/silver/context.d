module silver.context;

import pegged.grammar : ParseTree;

debug import std.stdio;

class Context
{
    import std.variant;
    import std.container.array;
    import silver.grammar_tests;

    private ParseTree program;

    private bool useStdOut;
    private string programOutput;
    private string[] importPaths;
    public const(string) ProgramOutput()
    {
        return programOutput;
    }

    nothrow this(ParseTree program, string[] importPaths, bool useStdOut = false)
    {
        this.program = program;
        this.useStdOut = useStdOut;
        this.importPaths = importPaths;
    }

    static class Environment
    {
        Variant[string] variables;
        Environment parent;
        this(Environment parent = null)
        {
            this.parent = parent;
        }

        public void defineVariable(string name, Variant value)
        {
            if (name in variables)
            {
                import std.format;

                throw new Exception("Duplicate declaration of variable %s".format(name));
            }
            variables[name] = value;
        }

        public void setVariable(string name, Variant value)
        {
            if (name in variables)
            {
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
        ParseTree declaration;
        Environment closure;
        this(ParseTree declaration, Environment closure)
        {
            this.declaration = declaration;
            this.closure = closure;
        }

        override string toString() const
        {
            return declaration.matches[0];
        }
    }

    private static ParseTree[] childrenNamed(ParseTree tree, string name)
    {
        import std.algorithm : filter;
        import std.array : array;

        return tree.children.filter!(child => child.name == name).array;
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
        interpret(program, globals);
    }

    private void interpret(ParseTree ast, Environment variables)
    {
        import std.conv : to;

        switch (ast.name)
        {
        case "Silver":
        case "Silver.Statement":
            interpret(ast.children[0], variables);
            break;
        case "Silver.Module":
        case "Silver.StatementBlock":
            foreach (statement; ast.children)
            {
                interpret(statement, variables);
            }
            break;
        case "Silver.VariableDeclaration":
            auto name = ast.children[0].matches[0];
            auto value = interpretExpression(ast[1], variables);
            variables.defineVariable(name, value);
            break;
        case "Silver.AssignmentStatement":
            auto name = ast.children[0].matches[0];
            auto value = interpretExpression(ast[1], variables);
            variables.setVariable(name, value);
            break;
        case "Silver.PrintStatement":
            auto value = interpretExpression(ast[1], variables);
            if (ast.matches[0] == "print")
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
            break;
        case "Silver.IfStatement":
            interpretIfStatement(ast, variables);
            break;
        case "Silver.FunctionDeclaration":
            interpretFunctionDeclaration(ast, variables);
            break;
        case "Silver.CallStatement":
            interpretExpression(ast[0], variables);
            break;
        case "Silver.ImportStatement":
            interpretImportStatement(ast, variables);
            break;
        default:
            {
                writefln("Unhandled ast: %s", ast.name);
            }
        }
    }

    private void interpretIfStatement(ParseTree ast, Environment variables)
    {
        foreach (block; ast.children)
        {
            if (block.name == "Silver.IfBlock" || block.name == "Silver.ElseIfBlock")
            {
                ParseTree testExpression = block[0];
                auto bodyStatements = block.children[1 .. $];
                auto testValue = interpretExpression(testExpression, variables);

                if (!testValue.convertsTo!bool)
                {
                    import std.format : format;

                    throw new Exception("'%s' is not a boolean value".format(
                            testExpression.input[testExpression.begin .. testExpression.end]));
                }

                if (testValue.get!bool)
                {
                    Environment blockEnv = new Environment(variables);
                    foreach (statement; bodyStatements)
                    {
                        interpret(statement, blockEnv);
                    }
                    break; // test successful, skip the rest
                }
            }
            else
            {
                Environment blockEnv = new Environment(variables);
                foreach (statement; block.children)
                {
                    interpret(statement, blockEnv);
                }
            }

        }
    }

    private void interpretImportStatement(ParseTree ast, Environment variables)
    {
        auto moduleName = ast.matches[0];
        auto loadedModule = loadModule(moduleName);
        variables.defineVariable(moduleName, Variant(loadedModule));
    }

    private Module loadModule(string moduleName)
    {
        import std.file : exists, readText;
        import std.path : buildPath;
        import std.format : format;
        import silver.parse;

        foreach (importPath; importPaths)
        {
            auto modulePath = buildPath(importPath, moduleName ~ ".silver");
            if (exists(modulePath))
            {
                auto moduleSource = readText(modulePath);
                auto moduleAst = parse(moduleSource, modulePath);
                auto moduleEnv = new Environment();
                interpret(moduleAst, moduleEnv);

                return new Module(moduleName, moduleEnv);
            }
        }

        throw new Exception("Module '%s' not found".format(moduleName));
    }

    private Variant interpretExpression(ParseTree ast, Environment variables)
    {
        import std.conv : to, ConvException;
        import std.string : strip;
        import std.range : chunks, drop;

        switch (ast.name)
        {
        case "Silver.Expression":
            return interpretExpression(ast[0], variables);
        case "Silver.AdditionExpression":
        case "Silver.MultiplyExpression":
        case "Silver.OrExpression":
        case "Silver.AndExpression":
        case "Silver.EqExpression":
            auto lhs = interpretExpression(ast[0], variables);
            foreach (children; ast.children.drop(1).chunks(2))
            {
                auto operator = children[0].matches[0];
                auto rhs = interpretExpression(children[1], variables);
                lhs = operate(operator, lhs, rhs);
            }
            return lhs;
        case "Silver.Unary":
            if (ast.children.length == 2)
            {
                auto value = interpretExpression(ast[1], variables);
                if (ast.children.length == 2)
                {
                    auto operator = ast[0].matches[0];
                    return unaryOperate(operator, value);
                }
                return value;
            }
            return interpretExpression(ast[0], variables);
        case "Silver.PowerExpression":
            if (ast.children.length == 3)
            {
                auto base = interpretExpression(ast[0], variables);
                auto exponent = interpretExpression(ast[2], variables);
                return operate(ast[1].matches[0], base, exponent);
            }
            return interpretExpression(ast[0], variables);
        case "Silver.Eval":
        case "Silver.Literal":
        case "Silver.NumberLiteral":
        case "Silver.FunctionParam":
            return interpretExpression(ast.children[0], variables);
        case "Silver.UnsignedLiteral":
            return Variant(ast.matches[0].to!int);
        case "Silver.HexaLiteral":
            return Variant(ast.matches[0].to!int);
        case "Silver.Variable":
            auto name = ast.matches[0];
            return variables.resolveVariable(name);
        case "Silver.BooleanLiteral":
            return Variant(ast.matches[0].to!bool);
        case "Silver.ReadExpression":
            {
                auto input = readln().strip;
                try
                {
                    return Variant(input.to!int);
                }
                catch (ConvException)
                {
                    return Variant(input.to!bool);
                }
            }
        case "Silver.Postfix":
            return interpretPostfix(ast, variables);
        default:
            {
                import std.format : format;

                throw new Exception("Unhandled expression ast: %s".format(ast.name));
            }
        }
    }

    private void interpretFunctionDeclaration(ParseTree ast, Environment variables)
    {
        auto name = ast.children[0].matches[0];
        variables.defineFunction(name, new Function(ast, variables));
    }

    private Variant interpretPostfix(ParseTree ast, Environment variables)
    {
        import std.range : drop;

        auto eval = ast.children[0];
        auto lhs = interpretExpression(eval, variables);
        foreach (postFixOp; ast.children.drop(1))
        {
            switch (postFixOp[0].name)
            {
            case "Silver.CallArgs":
                lhs = interpretCall(lhs.get!Function, postFixOp, variables);
                break;
            case "Silver.MemberAccess":
                auto memberName = postFixOp[0].matches[0]; // the identifier after the '.'
                lhs = memberOf(lhs, memberName);
                break;
            default:
                break;
            }
        }
        return lhs;
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

    private Variant interpretCall(Function fn, ParseTree callArgsAst, Environment variables)
    {
        import std.format : format;

        string[] params;
        foreach (paramDefs; childrenNamed(fn.declaration, "Silver.FunctionParamDefs"))
        {
            foreach (param; paramDefs.children)
            {
                params ~= param.matches[0];
            }
        }

        auto callArgs = callArgsAst.children;
        ParseTree[] args = callArgsAst.children.length == 1 ? callArgs[0].children : [
        ];
        if (args.length != params.length)
        {
            throw new Exception("%s expects %s arguments, got %s".format(fn, params.length, args
                    .length));
        }

        // The parent is the environment the function was defined in, not the caller's.
        Environment functionEnv = new Environment(fn.closure);
        foreach (i, arg; args)
        {
            // Arguments are evaluated in the caller's environment.
            functionEnv.defineVariable(params[i], interpretExpression(arg, variables));
        }

        foreach (block; childrenNamed(fn.declaration, "Silver.StatementBlock"))
        {
            interpret(block, functionEnv);
        }

        auto returnStatement = childrenNamed(fn.declaration, "Silver.ReturnStatement")[0];
        return interpretExpression(returnStatement[0], functionEnv);
    }

    private Variant operate(string operator, Variant lhs, Variant rhs)
    {
        //writefln("%s %s %s", lhs, operator, rhs);
        switch (operator)
        {
        case "+":
            return lhs + rhs;
        case "-":
            return lhs - rhs;
        case "*":
            return lhs * rhs;
        case "/":
            return lhs / rhs;
        case "^":
            return lhs ^^ rhs;
        case "==":
            return Variant(lhs == rhs);
        case "&&":
            return Variant(lhs.get!bool && rhs.get!bool);
        case "||":
            return Variant(lhs.get!bool || rhs.get!bool);
        default:
            throw new Exception("Unsupported operator " ~ operator);
        }
    }

    private Variant unaryOperate(string operator, Variant value)
    {
        //writefln("%s %s %s", lhs, operator, rhs);
        switch (operator)
        {
        case "-":
            if (value.convertsTo!double)
            {
                return Variant(-value.get!double);
            }
            else if (value.convertsTo!int)
            {
                return Variant(-value.get!int);
            }
            else
            {
                import std.conv : to;

                throw new Exception(
                    "Unsupported unary operator " ~ operator ~ " for type " ~ value.type.to!string);
            }
        case "!":
            return Variant(!value.get!bool);
        default:
            throw new Exception("Unsupported unary operator " ~ operator);
        }
    }
}
