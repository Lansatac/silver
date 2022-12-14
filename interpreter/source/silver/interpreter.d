module silver.interpreter;

import std.stdio;

import silver.grammar;
import silver.context;
import pegged.grammar : ParseTree;

version(unittest) import fluent.asserts;

/// Interprets a string representing silver code.
int interpret(string code)
{
    auto parseTree = Silver(code);

    //writeln(parseTree);

    if(!parseTree.successful)
    {
        writeln(parseTree.errorMessage);
        return 1;
    }

    auto context = new Context(parseTree, true);

    context.run();

    return 0;
}


version(unittest)
{
    import std.variant;

    Variant evaluateExpression(string expression)
    {
        import std.format;

        auto program = `var variable = %s;`.format(expression);
        auto parseTree = Silver(program);
        if(!parseTree.successful)
        {
            throw new Exception(parseTree.failMsg);
        }
        auto context = new Context(parseTree);
        context.run();
        return context.getGlobals()["variable"];
    }

    
    string runProgram(string program)
    {
        auto parseTree = Silver(program);
        if(!parseTree.successful)
        {
            throw new Exception(parseTree.failMsg);
        }
        auto context = new Context(parseTree);
        context.run();
        return context.ProgramOutput;
    }
}

@("Simple program")
unittest
{
    interpret("var a = 1;").should.equal(0);
}


@("Global Variable Assignment")
unittest
{
    evaluateExpression("1").get!int.should.equal(1);
}


@("Addition")
unittest
{
    evaluateExpression("1 + 2").get!int.should.equal(3);
}

@("Multiplication")
unittest
{
    evaluateExpression("2 * 2").get!int.should.equal(4);
}

@("Operator Precedence LTR")
unittest
{
    evaluateExpression("1 + 2 * 2").get!int.should.equal(5);
}

@("Operator Precedence RTL")
unittest
{
    import std.conv;
    auto tree = Silver("var a = 2 * 2 + 1;");
    tree.successful.should.equal(true);
    evaluateExpression("2 * 2 + 1").get!int.should.equal(5).because(tree.to!string);
}

@("Operator Precedence Parenthetical")
unittest
{
    evaluateExpression("(1 + 2) * 2").get!int.should.equal(6);
    evaluateExpression("2 * (1 + 2)").get!int.should.equal(6);
}


@("If Statements - true")
unittest
{
    runProgram("var a = 1; if true then a = 2; end print a;").should.equal("2");
}

@("If Statements - false")
unittest
{
    auto parseTree = Silver(
        r"var a = 1;
          if false then
            a = 2;
          end
          ");
    if(!parseTree.successful)
    {
        throw new Exception(parseTree.failMsg);
    }
    auto context = new Context(parseTree);
    context.run();
    context.getGlobals()["a"].get!int.should.equal(1);
}


@("If-Else Statements")
unittest
{
    auto parseTree = Silver(
        r"var a = 1;
          if false then
            a = 2;
          else
            a = 3;
          end
          ");
    if(!parseTree.successful)
    {
        throw new Exception(parseTree.failMsg);
    }
    auto context = new Context(parseTree);
    context.run();
    context.getGlobals()["a"].get!int.should.equal(3);
}

private string errorMessage(ParseTree tree)
{
    ParseTree terminal = tree;

    while(terminal.children.length > 0)
    {
        foreach (child; terminal.children)
        {
            if(!child.successful)
            {
                terminal = child;
                break;
            }
        }
    }

    return terminal.failMsg;
}

