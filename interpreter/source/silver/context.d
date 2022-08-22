module silver.context;

import std.stdio;
import std.variant;
import std.container.array;

import pegged.grammar : ParseTree;

class Context
{
    private ParseTree program;

    this(ParseTree program)
    {
        this.program = program;
    }

    /// Executes the ast.
    void run()
    {
        Array!(Variant[string]) globals;
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
            case "Silver.Declaration":
                auto name = ast.children[0].matches[0];
                auto value = interpretExpression(ast.children[1], variables);
                declareVariable(variables, name, value);
            break;
            case "Silver.Print":
                auto value = interpretExpression(ast.children[0], variables);
                writeln(value);
                break;
            default:
            {
                writefln("Unhandled ast: %s", ast.name);
            }
        }
    }

    private Variant interpretExpression(ParseTree ast, Array!(Variant[string]) variables)
    {
        import std.conv : to;
        switch(ast.name)
        {
            case "Silver.Expression":
                if(ast.children.length == 1)
                {
                    return interpretExpression(ast.children[0], variables);
                }
                auto lhs = interpretExpression(ast.children[0], variables);
                auto operator = ast.children[1].matches[0];
                auto rhs = interpretExpression(ast.children[1], variables);

                return operate(operator, lhs, rhs);
            case "Silver.Eval":
            case "Silver.Literal":
            case "Silver.NumberLiteral":
                return interpretExpression(ast.children[0], variables);
            case "Silver.UnsignedLiteral":
                return Variant(ast.matches[0].to!int);
            case "Silver.Variable":
                auto name = ast.matches[0];
                return variables[$-1][name];
            default:
            {
                import std.format : format;
                throw new Exception("Unhandled expression ast: %s".format(ast.name));
            }
        }
    }

    private Variant operate(string operator, Variant lhs, Variant rhs)
    {
        throw new Exception("not yet :'(");
    }
}