module silver.interpreter.tests;

import std.path;

import silver.interpreter.evaluator : Evaluator, RuntimeError;
import silver.ast : printModule;
version (unittest) import fluent.asserts;

version (unittest)
{
    import std.variant;
    import silver.ast : Program, SourceMap;
    import silver.loader : load, standardLibraryPath;

    /// Loads `source` as the module `file`, throwing on a parse error.
    Program loadProgram(string source, string file = "test", string[] importPaths = [])
    {
        return load(source, file, importPaths, new SourceMap);
    }

    Variant evaluateExpression(string expression)
    {
        import std.format;

        auto program = loadProgram(`val variable = %s`.format(expression));
        auto evaluator = new Evaluator(program);
        evaluator.run();
        return evaluator.globals["variable"];
    }

    string runProgram(string source)
    {
        auto evaluator = new Evaluator(loadProgram(source, "test", [standardLibraryPath()]));
        evaluator.run();
        return evaluator.output;
    }
}

@("Simple program")
unittest
{
    runProgram("val a = 1").should.equal("");
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
    auto program = loadProgram("val a = 2 * 2 + 1");
    evaluateExpression("2 * 2 + 1").get!long.should.equal(5).because(printModule(program.main));
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
     print(a)").should.equal("2");
}

@("If Statements - false")
unittest
{
    auto evaluator = new Evaluator(loadProgram(
        r"val a = 1
          if false {
            a = 2
          }
          "));
    evaluator.run();
    evaluator.globals["a"].get!long.should.equal(1);
}

@("If-Else Statements")
unittest
{
    auto evaluator = new Evaluator(loadProgram(
        r"mutable val a = 1
          if false {
            a = 2
          } else {
            a = 3
          }
          "));
    evaluator.run();
    evaluator.globals["a"].get!long.should.equal(3);
}

@("Compound assignment applies its operator")
unittest
{
    runProgram("mutable val a = 10
     a += 5
     a -= 3
     a *= 2
     print(a)").should.equal("24");
}

@("While loops until the condition is false")
unittest
{
    runProgram("mutable val i = 0
     while i < 3 {
        i += 1
     }
     print(i)").should.equal("3");
}

@("While condition must be a boolean")
unittest
{
    runProgram("while 1 { }").should.throwException!RuntimeError.withMessage(
        "While condition must be a boolean");
}

@("Block scope - inner declaration does not leak")
unittest
{
    runProgram("if true {
        val b = 2
     }
     print(b)").should.throwException!RuntimeError.withMessage("Variable b not found");
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
     print(a)").should.equal("3");
}

@("Block scope - shadowing")
unittest
{
    runProgram("val a = 1
     if true {
        val a = 2
        print(a)
     }
     print(a)").should.equal("21");
}

@("Block scope - duplicate declaration in same scope")
unittest
{
    runProgram("val a = 1
     val a = 2").should.throwException!RuntimeError.withMessage(
        "Duplicate declaration of variable a");
}

@("Call function")
unittest
{
    runProgram("def f() : Int => 1
     print(f())").should.equal("1");
}

@("Call function with arguments")
unittest
{
    runProgram("def add(a : Int, b : Int) : Int {
        val c = a + b
        c
     }
     print(add(1, 2))").should.equal("3");
}

@("Function sees variables from where it was defined")
unittest
{
    runProgram("val x = 1
     def f() : Int => x + 1
     print(f())").should.equal("2");
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
     print(caller())").should.equal("1");
}

@("Function locals do not leak")
unittest
{
    runProgram("def f() : Int {
        val local = 1
        local
     }
     f()
     print(local)").should.throwException!RuntimeError.withMessage("Variable local not found");
}

@("Wrong argument count")
unittest
{
    runProgram("def f(a : Int) : Int => a
     print(f())").should.throwException!RuntimeError.withMessage("f expects 1 arguments, got 0");
}

@("val cannot be reassigned")
unittest
{
    runProgram("val a = 1
     a = 2").should.throwException!RuntimeError.withMessage("Cannot assign to val 'a'. Declare as 'mutable val' to reassign it.");
}

@("Runtime errors report their Silver source location")
unittest
{
    auto source = "val a = 1\n    a = 2";
    auto sources = new SourceMap;
    auto program = load(source, "test.ag", [], sources);
    auto evaluator = new Evaluator(program);
    try
    {
        evaluator.run();
        assert(false, "Expected assignment to val to fail");
    }
    catch (RuntimeError e)
    {
        e.diagnostic.span.file.should.equal("test.ag");
        sources.locate(e.diagnostic.span).line.should.equal(2);
        e.msg.should.equal("Cannot assign to val 'a'. Declare as 'mutable val' to reassign it.");
    }
}

@("print and printl are native functions from the prelude")
unittest
{
    runProgram("print(1)
     printl(2)
     print(true)").should.equal("12\ntrue");
}

@("Native functions are values")
unittest
{
    runProgram("val p = printl
     p(3)").should.equal("3\n");
}

@("Prelude names can be shadowed")
unittest
{
    runProgram("def print(value : Int) : Int => value
     printl(print(4))").should.equal("4\n");
}

@("Native function without a binding")
unittest
{
    runProgram("native def missing() : Unit").should.throwException!RuntimeError.withMessage(
        "No native binding for missing");
}

@("Native function argument count is checked")
unittest
{
    runProgram("print()").should.throwException!RuntimeError.withMessage(
        "print expects 1 arguments, got 0");
}
