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
    }

    private Array!(Variant[string]) globals;

    const(Variant[string]) getGlobals() const
    {
        return globals[0];
    }

    /// Executes the ast.
    void run()
    {
        globals.insert((Variant[string]).init);
        interpret(program, globals);
    }

    private void declareVariable(Array!(Variant[string]) variables, string name, Variant value)
    {
        foreach_reverse(stack; variables)
        {
            if(name in stack)
            {
                import std.format;
                throw new Exception("Duplicate declaration of variable %s".format(name));
            }
        }
        variables[$-1][name] = value;
    }

    private void interpret(ParseTree ast, Array!(Variant[string]) variables)
    {
        import std.conv : to;
        switch(ast.name)
        {
            case "Silver":
            case "Silver.Statement":
                interpret(ast.children[0], variables);
                break;
            case "Silver.Module":
                foreach (statement; ast.children)
                {
                    interpret(statement, variables);
                }
                break;
            case "Silver.DeclarationStatement":
                auto name = ast.children[0].matches[0];
                auto value = interpretExpression(ast[1], variables);
                declareVariable(variables, name, value);
            break;
            case "Silver.AssignmentStatement":
                auto name = ast.children[0].matches[0];
                auto value = interpretExpression(ast[1], variables);
                variables[$-1][name] = value;
            break;
            case "Silver.PrintStatement":
                auto value = interpretExpression(ast[0], variables);
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

    
    private void interpretIfStatement(ParseTree ast, Array!(Variant[string]) variables)
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
                    foreach (statement; bodyStatements)
                    {
                        interpret(statement, variables);
                    }
                    break; // test successful, skip the rest
                }
            }
            else
            {
                foreach (statement; block.children)
                {
                    interpret(statement, variables);
                }
            }
            
        }
    }

    private Variant interpretExpression(ParseTree ast, Array!(Variant[string]) variables)
    {
        import std.conv : to, ConvException;
        import std.string : strip;
        import std.range : slide, drop;
        switch(ast.name)
        {
            case "Silver.Expression":
                return interpretExpression(ast[0], variables);
            case "Silver.AdditionExpression":
            case "Silver.MultiplyExpression":
            case "Silver.LogicalExpression":
                auto lhs = interpretExpression(ast[0], variables);
                foreach(children;ast.children.drop(1).slide(2))
                {
                    auto operator = children[0].matches[0];
                    auto rhs = interpretExpression(children[1], variables);
                    lhs = operate(operator, lhs, rhs);
                }
                return lhs;
            case "Silver.Eval":
            case "Silver.Literal":
            case "Silver.NumberLiteral":
                return interpretExpression(ast.children[0], variables);
            case "Silver.UnsignedLiteral":
                return Variant(ast.matches[0].to!int);
            case "Silver.HexaLiteral":
                return Variant(ast.matches[0].to!int);
            case "Silver.Variable":
                auto name = ast.matches[0];
                return variables[$-1][name];
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
}