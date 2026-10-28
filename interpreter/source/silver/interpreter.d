module silver.interpreter;

import std.stdio;
import std.path;

import silver.grammar;
import silver.parse;
import silver.context;
import pegged.grammar : ParseTree;

version (unittest) import fluent.asserts;

/// Interprets a string representing silver code.
int interpret(string code, string filename = "<input>")
{
    ParseTree parseTree;
    try
    {
        parseTree = parse(code, filename);
    }
    catch (ParseException e)
    {
        writeln(e.msg);
        return 1;
    }

    auto context = new Context(parseTree, [absolutePath("./stdlib")], true);

    context.run();

    return 0;
}

version (unittest)
{
    import std.variant;

    Variant evaluateExpression(string expression)
    {
        import std.format;

        auto program = `var variable = %s`.format(expression);
        auto parseTree = Silver(program);
        if (!parseTree.successful)
        {
            throw new Exception(parseTree.failMsg);
        }
        auto context = new Context(parseTree, []);
        context.run();
        return context.getGlobals()["variable"];
    }

    string runProgram(string program)
    {
        auto parseTree = Silver(program);
        if (!parseTree.successful)
        {
            throw new Exception(parseTree.failMsg);
        }
        auto context = new Context(parseTree, [absolutePath("./stdlib")]);
        context.run();
        return context.ProgramOutput;
    }
}

@("Simple program")
unittest
{
    interpret("var a = 1").should.equal(0);
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

    auto tree = Silver("var a = 2 * 2 + 1");
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
    runProgram("var a = 1
     if true then
        a = 2
     end
     print a").should.equal("2");
}

@("If Statements - false")
unittest
{
    auto parseTree = Silver(
        r"var a = 1
          if false then
            a = 2
          end
          ");
    if (!parseTree.successful)
    {
        throw new Exception(parseTree.failMsg);
    }
    auto context = new Context(parseTree, []);
    context.run();
    context.getGlobals()["a"].get!int.should.equal(1);
}

@("If-Else Statements")
unittest
{
    auto parseTree = Silver(
        r"var a = 1
          if false then
            a = 2
          else
            a = 3
          end
          ");
    if (!parseTree.successful)
    {
        throw new Exception(parseTree.failMsg);
    }
    auto context = new Context(parseTree, []);
    context.run();
    context.getGlobals()["a"].get!int.should.equal(3);
}

@("Block scope - inner declaration does not leak")
unittest
{
    runProgram("if true then
        var b = 2
     end
     print b").should.throwException!Exception.withMessage("Variable b not found");
}

@("Block scope - assignment updates outer variable")
unittest
{
    runProgram("var a = 1
     if false then
        a = 2
     else
        a = 3
     end
     print a").should.equal("3");
}

@("Block scope - shadowing")
unittest
{
    runProgram("var a = 1
     if true then
        var a = 2
        print a
     end
     print a").should.equal("21");
}

@("Block scope - duplicate declaration in same scope")
unittest
{
    runProgram("var a = 1
     var a = 2").should.throwException!Exception.withMessage(
        "Duplicate declaration of variable a");
}

@("Call function")
unittest
{
    runProgram("def f()
        return 1
     end
     print f()").should.equal("1");
}

@("Call function with arguments")
unittest
{
    runProgram("def add(a, b)
        var c = a + b
        return c
     end
     print add(1, 2)").should.equal("3");
}

@("Function sees variables from where it was defined")
unittest
{
    runProgram("var x = 1
     def f()
        return x + 1
     end
     print f()").should.equal("2");
}

@("Function does not see caller's variables")
unittest
{
    runProgram("var x = 1
     def show()
        return x
     end
     def caller()
        var x = 2
        return show()
     end
     print caller()").should.equal("1");
}

@("Function locals do not leak")
unittest
{
    runProgram("def f()
        var local = 1
        return local
     end
     f()
     print local").should.throwException!Exception.withMessage("Variable local not found");
}

@("Wrong argument count")
unittest
{
    runProgram("def f(a)
        return a
     end
     print f()").should.throwException!Exception.withMessage("f expects 1 arguments, got 0");
}

@("Import stdlib")
unittest
{
    runProgram("import math
    print math.square(4)").should.equal("16");
}
