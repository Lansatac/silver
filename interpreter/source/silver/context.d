module silver.context;

import pegged.grammar : ParseTree;

debug import std.stdio;

class Context
{
    import std.variant;
    import std.container.array;

    private ParseTree program;

    private bool useStdOut;
    private string programOutput;
    public const(string) ProgramOutput(){return programOutput;}

    nothrow this(ParseTree program, bool useStdOut = false)
    {
        this.program = program;
        this.useStdOut = useStdOut;
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
            if(name in variables)
            {
                import std.format;
                throw new Exception("Duplicate declaration of variable %s".format(name));
            }
            variables[name] = value;
        }

        public void setVariable(string name, Variant value)
        {
            if(name in variables)
            {
                variables[name] = value;
            }
            else if(parent !is null)
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
            if(name in variables)
            {
                return variables[name];
            }
            else if(parent !is null)
            {
                return parent.resolveVariable(name);
            }
            else
            {
                import std.format : format;
                throw new Exception("Variable %s not found".format(name));
            }
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
        interpret(program, globals);
    }

    private void interpret(ParseTree ast, Environment variables)
    {
        import std.conv : to;
        switch(ast.name)
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
                if(ast.matches[0] == "print")
                {
                    programOutput ~= value.to!string;
                    if(useStdOut)
                    {
                        write(value);
                    }
                }
                else
                {
                    programOutput ~= value.to!string ~ "\n";
                    if(useStdOut)
                    {
                        writeln(value);
                    }
                }
                break;
            case "Silver.IfStatement":
                interpretIfStatement(ast, variables);
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
            if(block.name == "Silver.IfBlock" || block.name == "Silver.ElseIfBlock")
            {
                ParseTree testExpression = block[0];
                auto bodyStatements = block.children[1 .. $];
                auto testValue = interpretExpression(testExpression, variables);
                
                if(!testValue.convertsTo!bool)
                {
                    import std.format : format;
                    throw new Exception("'%s' is not a boolean value".format(testExpression.input[testExpression.begin .. testExpression.end]));
                }

                if(testValue.get!bool)
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

    private Variant interpretExpression(ParseTree ast, Environment variables)
    {
        import std.conv : to, ConvException;
        import std.string : strip;
        import std.range : chunks, drop;
        switch(ast.name)
        {
            case "Silver.Expression":
                return interpretExpression(ast[0], variables);
            case "Silver.AdditionExpression":
            case "Silver.MultiplyExpression":
            case "Silver.OrExpression":
            case "Silver.AndExpression":
            case "Silver.EqExpression":
                auto lhs = interpretExpression(ast[0], variables);
                foreach(children;ast.children.drop(1).chunks(2))
                {
                    auto operator = children[0].matches[0];
                    auto rhs = interpretExpression(children[1], variables);
                    lhs = operate(operator, lhs, rhs);
                }
                return lhs;
            case "Silver.Unary":
            if(ast.children.length == 2)
            {
                auto value = interpretExpression(ast[1], variables);
                if(ast.children.length == 2)
                {
                    auto operator = ast[0].matches[0];
                    return unaryOperate(operator, value);
                }
                return value;
            }
            return interpretExpression(ast[0], variables);
            case "Silver.Eval":
            case "Silver.Literal":
            case "Silver.NumberLiteral":
            case "Silver.Postfix":
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
                try{
                    return Variant(input.to!int);
                }
                catch(ConvException) {
                    return Variant(input.to!bool);
                }
            }
            default:
            {
                import std.format : format;
                throw new Exception("Unhandled expression ast: %s".format(ast.name));
            }
        }
    }

    private Variant operate(string operator, Variant lhs, Variant rhs)
    {
        //writefln("%s %s %s", lhs, operator, rhs);
        switch(operator)
        {
        case "+":
            return lhs + rhs;
        case "-":
            return lhs - rhs;
        case "*":
            return lhs * rhs;
        case "/":
            return lhs / rhs;
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
        switch(operator)
        {
        case "-":
            if(value.convertsTo!double)
            {
                return Variant(-value.get!double);
            }
            else if(value.convertsTo!int)
            {
                return Variant(-value.get!int);
            }
            else
            {
                import std.conv : to;
                throw new Exception("Unsupported unary operator " ~ operator ~ " for type " ~ value.type.to!string);
            }
        case "!":
            return Variant(!value.get!bool);
        default:
            throw new Exception("Unsupported unary operator " ~ operator);
        }
    }
}