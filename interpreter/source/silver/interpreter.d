module silver.interpreter;

import std.stdio;
import std.path;

import silver.parse : parse, ParseException;
import silver.cstToAst : cstToAst;
import silver.context : Context, SilverRuntimeException;
// Renamed because Context has its own (runtime) Module class.
import silver.ast : AstModule = Module, printModule;
version (unittest) import fluent.asserts;

/// Interprets a string representing silver code.
int interpret(string code, string filename = "<input>")
{
    AstModule program;
    try
    {
        program = parse(code, filename.baseName.stripExtension, filename);
    }
    catch (ParseException e)
    {
        writeln(e.msg);
        return 1;
    }

    auto context = new Context(program, [absolutePath("./stdlib")], true, code);
    try
    {
        context.run();
    }
    catch (SilverRuntimeException e)
    {
        import std.path;
        stderr.writefln("%s:%s: %s", buildNormalizedPath(absolutePath( e.sourceFile)), e.sourceLine, e.msg);
        return 1;
    }
    catch (ParseException e)
    {
        stderr.writeln(e.msg);
        return 1;
    }

    return 0;
}

version (unittest)
{
    import std.variant;

    /// Parses and lowers `program`, throwing on a parse error.
    AstModule toAst(string program)
    {
        return parse(program, "test", "test");
    }

    Variant evaluateExpression(string expression)
    {
        import std.format;

        auto program = toAst(`val variable = %s`.format(expression));
        auto context = new Context(program, []);
        context.run();
        return context.getGlobals()["variable"];
    }

    string runProgram(string program)
    {
        auto context = new Context(toAst(program), [absolutePath("./stdlib")]);
        context.run();
        return context.ProgramOutput;
    }
}

@("Simple program")
unittest
{
    interpret("val a = 1").should.equal(0);
}

@("Global Variable Assignment")
unittest
{
    evaluateExpression("1").get!long.should.equal(1);
}

@("Addition")
unittest
{
    evaluateExpression("1 + 2").get!long.should.equal(3);
}

@("Multiplication")
unittest
{
    evaluateExpression("2 * 2").get!long.should.equal(4);
}

@("Operator Precedence LTR")
unittest
{
    evaluateExpression("1 + 2 * 2").get!long.should.equal(5);
}

@("Operator Precedence RTL")
unittest
{
    auto program = toAst("val a = 2 * 2 + 1");
    evaluateExpression("2 * 2 + 1").get!long.should.equal(5).because(printModule(program));
}

@("Operator Precedence Parenthetical")
unittest
{
    evaluateExpression("(1 + 2) * 2").get!long.should.equal(6);
    evaluateExpression("2 * (1 + 2)").get!long.should.equal(6);
}

@("If Statements - true")
unittest
{
    runProgram("mutable val a = 1
     if true {
        a = 2
     }
     print a").should.equal("2");
}

@("If Statements - false")
unittest
{
    auto context = new Context(toAst(
        r"val a = 1
          if false {
            a = 2
          }
          "), []);
    context.run();
    context.getGlobals()["a"].get!long.should.equal(1);
}

@("If-Else Statements")
unittest
{
    auto context = new Context(toAst(
        r"mutable val a = 1
          if false {
            a = 2
          } else {
            a = 3
          }
          "), []);
    context.run();
    context.getGlobals()["a"].get!long.should.equal(3);
}

@("Block scope - inner declaration does not leak")
unittest
{
    runProgram("if true {
        val b = 2
     }
     print b").should.throwException!SilverRuntimeException.withMessage("Variable b not found");
}

@("Block scope - assignment updates outer variable")
unittest
{
    runProgram("mutable val a = 1
     if false {
        a = 2
     } else {
        a = 3
     }
     print a").should.equal("3");
}

@("Block scope - shadowing")
unittest
{
    runProgram("val a = 1
     if true {
        val a = 2
        print a
     }
     print a").should.equal("21");
}

@("Block scope - duplicate declaration in same scope")
unittest
{
    runProgram("val a = 1
     val a = 2").should.throwException!SilverRuntimeException.withMessage(
        "Duplicate declaration of variable a");
}

@("Call function")
unittest
{
    runProgram("def f() : Int => 1
     print f()").should.equal("1");
}

@("Call function with arguments")
unittest
{
    runProgram("def add(a : Int, b : Int) : Int {
        val c = a + b
        c
     }
     print add(1, 2)").should.equal("3");
}

@("Function sees variables from where it was defined")
unittest
{
    runProgram("val x = 1
     def f() : Int => x + 1
     print f()").should.equal("2");
}

@("Function does not see caller's variables")
unittest
{
    runProgram("val x = 1
     def show() : Int => x
     def caller() : Int {
        val x = 2
        show()
     }
     print caller()").should.equal("1");
}

@("Function locals do not leak")
unittest
{
    runProgram("def f() : Int {
        val local = 1
        local
     }
     f()
     print local").should.throwException!SilverRuntimeException.withMessage("Variable local not found");
}

@("Wrong argument count")
unittest
{
    runProgram("def f(a : Int) : Int => a
     print f()").should.throwException!SilverRuntimeException.withMessage("f expects 1 arguments, got 0");
}

@("val cannot be reassigned")
unittest
{
    runProgram("val a = 1
     a = 2").should.throwException!SilverRuntimeException.withMessage("Cannot assign to val 'a'. Declare as 'mutable val' to reassign it.");
}

@("Runtime errors report their Silver source location")
unittest
{
    auto source = "val a = 1\n    a = 2";
    auto program = parse(source, "test", "test.silver");
    auto context = new Context(program, [], false, source);
    try
    {
        context.run();
        assert(false, "Expected assignment to val to fail");
    }
    catch (SilverRuntimeException e)
    {
        e.sourceFile.should.equal("test.silver");
        e.sourceLine.should.equal(2);
        e.msg.should.equal("Cannot assign to val 'a'. Declare as 'mutable val' to reassign it.");
    }
}
