module silver.interpreter.tests;

import std.path;

import silver.interpreter.evaluator : Evaluator, RuntimeError;
version (unittest) import fluent.asserts;

version (unittest)
{
    import silver.ast : DiagnosticCode, formatDiagnostic, Program, SourceContext;
    import silver.loader : load, standardLibraryPath;

    /// Loads `source` as the module `file`, throwing on a parse error and
    /// failing on any error the loader reports.
    Program loadProgram(string source, string file = "test", string[] importPaths = [])
    {
        import std.algorithm : map;
        import std.array : join;

        auto context = new SourceContext;
        auto program = load(source, file, importPaths, context);
        assert(!context.collector.hasErrors, context.collector.errors
                .map!(d => formatDiagnostic(d, context.sources)).join("
"));
        return program;
    }

    string runProgram(string source)
    {
        auto evaluator = new Evaluator(loadProgram(source, "test", [standardLibraryPath()]), null);
        evaluator.run();
        return evaluator.output;
    }

    /// Runs `source` with `files` (path to text) as modules on an import path,
    /// ahead of the standard library. A file without a `module` line gets one from its path.
    string runWithModules(string source, string[string] files)
    {
        import std.algorithm : startsWith;
        import std.array : replace;
        import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
        import std.path : stripExtension;
        import std.uuid : randomUUID;

        // Unique per call because tests run in parallel.
        auto directory = buildPath(tempDir(), "silver-interpreter-" ~ randomUUID().toString);
        scope (exit) rmdirRecurse(directory);
        foreach (fileName, text; files)
        {
            auto path = buildPath(directory, fileName);
            mkdirRecurse(dirName(path));
            auto header = text.startsWith("module ") ? "" : "module " ~ fileName.stripExtension.replace("/", ".") ~ "\n";
            write(path, header ~ text);
        }
        auto evaluator = new Evaluator(loadProgram(source, "test", [directory, standardLibraryPath()]), null);
        evaluator.run();
        return evaluator.output;
    }

    /// Runs `body` as the body of the entry module's `main`.
    string runMain(string body)
    {
        return runProgram("def main(): Unit {\n" ~ body ~ "\n}");
    }

    /// What printing `expression` from `main` shows.
    string evaluateExpression(string expression)
    {
        import std.format;

        return runMain(`print(%s)`.format(expression));
    }
}

@("Simple program")
unittest
{
    runMain("val a = 1").should.equal("");
}

@("Expressions evaluate to their value")
unittest
{
    evaluateExpression("1").should.equal("1");
}

@("Addition")
unittest
{
    evaluateExpression("1 + 2").should.equal("3");
}

@("Multiplication")
unittest
{
    evaluateExpression("2 * 2").should.equal("4");
}

@("Operator Precedence LTR")
unittest
{
    evaluateExpression("1 + 2 * 2").should.equal("5");
}

@("Operator Precedence RTL")
unittest
{
    runMain("val a = 2 * 2 + 1
     print(a)").should.equal("5");
}

@("Operator Precedence Parenthetical")
unittest
{
    evaluateExpression("(1 + 2) * 2").should.equal("6");
    evaluateExpression("2 * (1 + 2)").should.equal("6");
}

@("If Statements - true")
unittest
{
    runMain("mutable val a = 1
     if true {
        a = 2
     }
     print(a)").should.equal("2");
}

@("If Statements - false")
unittest
{
    runMain("val a = 1
     if false {
        a = 2
     }
     print(a)").should.equal("1");
}

@("If-Else Statements")
unittest
{
    runMain("mutable val a = 1
     if false {
        a = 2
     } else {
        a = 3
     }
     print(a)").should.equal("3");
}

@("Compound assignment applies its operator")
unittest
{
    runMain("mutable val a = 10
     a += 5
     a -= 3
     a *= 2
     print(a)").should.equal("24");
}

@("While loops until the condition is false")
unittest
{
    runMain("mutable val i = 0
     while i < 3 {
        i += 1
     }
     print(i)").should.equal("3");
}

@("While condition must be a boolean")
unittest
{
    runMain("while 1 { }").should.throwException!RuntimeError.withMessage(
        "While condition must be a boolean");
}

@("Block scope - inner declaration does not leak")
unittest
{
    runMain("if true {
        val b = 2
     }
     print(b)").should.throwException!RuntimeError.withMessage("Variable 'b' not found");
}

@("Block scope - assignment updates outer variable")
unittest
{
    runMain("mutable val a = 1
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
    runMain("val a = 1
     if true {
        val a = 2
        print(a)
     }
     print(a)").should.equal("21");
}

@("Block scope - duplicate declaration in same scope")
unittest
{
    runMain("val a = 1
     val a = 2").should.throwException!RuntimeError.withMessage(
        "Duplicate declaration of variable a");
}

@("Call function")
unittest
{
    runProgram("def f() : Int => 1
def main(): Unit {
     print(f())
}").should.equal("1");
}

@("Call function with arguments")
unittest
{
    runProgram("def add(a : Int, b : Int) : Int {
        val c = a + b
        c
     }
def main(): Unit {
     print(add(1, 2))
}").should.equal("3");
}

@("Function sees variables from where it was defined")
unittest
{
    runMain("val x = 1
     def f() : Int => x + 1
     print(f())").should.equal("2");
}

@("Function does not see caller's variables")
unittest
{
    runMain("val x = 1
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
def main(): Unit {
     f()
     print(local)
}").should.throwException!RuntimeError.withMessage("Variable 'local' not found");
}

@("Wrong argument count")
unittest
{
    runProgram("def f(a : Int) : Int => a
def main(): Unit {
     print(f())
}").should.throwException!RuntimeError.withMessage("f expects 1 arguments, got 0");
}

@("val cannot be reassigned")
unittest
{
    runMain("val a = 1
     a = 2").should.throwException!RuntimeError.withMessage("Cannot assign to val 'a'. Declare as 'mutable val' to reassign it.");
}

@("Runtime errors report their Silver source location")
unittest
{
    auto source = "def main(): Unit {\n    val a = 1\n    a = 2\n}";
    auto context = new SourceContext;
    auto program = load(source, "test.ag", [], context);
    auto evaluator = new Evaluator(program, null);
    try
    {
        evaluator.run();
        assert(false, "Expected assignment to val to fail");
    }
    catch (RuntimeError e)
    {
        e.diagnostic.span.file.should.equal("test.ag");
        context.sources.locate(e.diagnostic.span).line.should.equal(3);
        e.diagnostic.code.should.equal(DiagnosticCode.AssignToImmutable);
        e.msg.should.equal("Cannot assign to val 'a'. Declare as 'mutable val' to reassign it.");
    }
}

@("print and printl are native functions from the prelude")
unittest
{
    runMain("print(1)
     printl(2)
     print(true)").should.equal("12\ntrue");
}

@("Native functions are values")
unittest
{
    runMain("val p = printl
     p(3)").should.equal("3\n");
}

@("Prelude names can be shadowed")
unittest
{
    runProgram("def print(value : Int) : Int => value
def main(): Unit {
     printl(print(4))
}").should.equal("4\n");
}

@("Native function without a binding")
unittest
{
    runProgram("native def missing() : Unit
def main(): Unit {}").should.throwException!RuntimeError.withMessage(
        "No native binding for missing");
}

@("Native function argument count is checked")
unittest
{
    runMain("print()").should.throwException!RuntimeError.withMessage(
        "print expects 1 arguments, got 0");
}

@("A module without main is an error")
unittest
{
    runProgram("def f() : Unit => ()").should.throwException!RuntimeError.withMessage(
        "the program must define `def main(): Unit` in one of its modules");
}

@("main must take no parameters")
unittest
{
    runProgram("def main(args : Int) : Unit => ()").should.throwException!RuntimeError.withMessage(
        "`main` must take no parameters");
}

@("Functions can be declared after main")
unittest
{
    runProgram("def main(): Unit {
     print(f())
}
def f() : Int => 1").should.equal("1");
}

@("A dotted import's members are reachable by their full path")
unittest
{
    runWithModules("import a.b
def main(): Unit => printl(a.b.f())", ["a/b.ag": "def f(): Int => 1"]).should.equal("1
");
}

@("An import's members are reachable unqualified")
unittest
{
    runWithModules("import a.b
def main(): Unit => printl(f())", ["a/b.ag": "def f(): Int => 1"]).should.equal("1
");
}

@("The longest imported prefix of a path is the module")
unittest
{
    runWithModules("import a
import a.b
def main(): Unit => printl(a.b.f())",
        ["a.ag": "def g(): Int => 1", "a/b.ag": "def f(): Int => 2"]).should.equal("2
");
}

@("A module's own definition beats an imported one")
unittest
{
    runWithModules("import a
def f(): Int => 2
def main(): Unit => printl(f())", ["a.ag": "def f(): Int => 1"]).should.equal("2
");
}

@("A local variable hides a module path")
unittest
{
    runWithModules("import a
def main(): Unit {
    val a = 3
    printl(a.f())
}", ["a.ag": "def f(): Int => 1"]).should.throwException!RuntimeError.withMessage(
        "3 has no member f");
}

@("An import shadows the prelude")
unittest
{
    runWithModules("import a
def main(): Unit => print(1)", ["a.ag": "def print(value: Int): Unit => printl(value + 1)"])
        .should.equal("2
");
}

@("A name defined by two imports is ambiguous where it's used")
unittest
{
    runWithModules("import a
import b
def main(): Unit => printl(f())", ["a.ag": "def f(): Int => 1", "b.ag": "def f(): Int => 2"])
        .should.throwException!RuntimeError.withMessage("'f' is ambiguous: it's defined in a, b");
}

@("Importing two modules that define the same name is fine if it's only used qualified")
unittest
{
    runWithModules("import a
import b
def main(): Unit => printl(a.f() + b.f())", ["a.ag": "def f(): Int => 1", "b.ag": "def f(): Int => 2"])
        .should.equal("3
");
}

@("Imports aren't visible to the importing module's importers")
unittest
{
    auto files = ["a.ag": "import b
def g(): Int => f()", "b.ag": "def f(): Int => 1"];
    runWithModules("import a
def main(): Unit => printl(g())", files).should.equal("1
");
    runWithModules("import a
def main(): Unit => printl(f())", files).should.throwException!RuntimeError.withMessage(
        "Variable 'f' not found");
    runWithModules("import a
def main(): Unit => printl(b.f())", files).should.throwException!RuntimeError.withMessage(
        "Variable 'b' not found");
}

@("Modules in an import cycle can call each other")
unittest
{
    runWithModules("import a
def main(): Unit => printl(a.f(3))", [
        "a.ag": "import b
def f(n: Int): Int => if n == 0 => 0 else b.g(n - 1) + 1",
        "b.ag": "import a
def g(n: Int): Int => a.f(n)",
    ]).should.equal("3
");
}

@("A module path is not a value")
unittest
{
    auto files = ["a/b.ag": "def f(): Int => 1"];
    runWithModules("import a.b
def main(): Unit => printl(a.b)", files).should.throwException!RuntimeError.withMessage(
        "Module path 'a.b' is not a value");
    runWithModules("import a.b
def main(): Unit => printl(a)", files).should.throwException!RuntimeError.withMessage(
        "Module path 'a' is not a value");
}

@("A path through a module reports the missing part")
unittest
{
    auto files = ["a/b.ag": "def f(): Int => 1"];
    runWithModules("import a.b
def main(): Unit => printl(a.c.f())", files).should.throwException!RuntimeError.withMessage(
        "Module path 'a' has no member 'c'");
    runWithModules("import a.b
def main(): Unit => printl(a.b.g())", files).should.throwException!RuntimeError.withMessage(
        "Module a.b has no member g");
}

@("An imported name can't be assigned")
unittest
{
    runWithModules("import a
def main(): Unit {
    f = 1
}", ["a.ag": "def f(): Int => 1"]).should.throwException!RuntimeError.withMessage(
        "Cannot assign to imported 'f'");
}

@("main can be in a module the starting file imports")
unittest
{
    runWithModules("import app", ["app.ag": "def main(): Unit => printl(1)"]).should.equal("1\n");
}

@("A program with main in two modules is an error")
unittest
{
    runWithModules("import a\ndef main(): Unit => ()", ["a.ag": "def main(): Unit => ()"])
        .should.throwException!RuntimeError.withMessage(
            "`main` is defined in more than one module: a, test");
}

@("A string literal prints without quotes, with escapes decoded")
unittest
{
    evaluateExpression(`"hello"`).should.equal("hello");
    evaluateExpression(`"a\tb\n\"c\" \\"`).should.equal("a\tb\n\"c\" \\");
    evaluateExpression(`""`).should.equal("");
}

@("Strings compare by value")
unittest
{
    runMain(`val a = "silver"
    printl(a == "silver")
    printl(a != "gold")`).should.equal("true\ntrue\n");
}

@("Strings can be passed to and returned from functions")
unittest
{
    runProgram(`def greeting(): String => "hi"
def echo(s: String): String => s
def main(): Unit => print(echo(greeting()))`).should.equal("hi");
}

@("Integer arithmetic is signed")
unittest
{
    evaluateExpression("-7 / 2").should.equal("-3");
    evaluateExpression("-7 % 2").should.equal("-1");
    evaluateExpression("7 / -2").should.equal("-3");
    evaluateExpression("-2 * 3").should.equal("-6");
    evaluateExpression("-1 < 1").should.equal("true");
}

@("Integer division by zero is a runtime error")
unittest
{
    try
    {
        runMain("printl(1 / 0)");
        assert(false, "Expected division by zero to fail");
    }
    catch (RuntimeError e)
    {
        e.diagnostic.code.should.equal(DiagnosticCode.DivisionByZero);
    }
}
