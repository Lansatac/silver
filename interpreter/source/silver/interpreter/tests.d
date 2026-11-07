module silver.interpreter.tests;

import std.path;

import silver.interpreter.evaluator : Evaluator, RuntimeError;
version (unittest) import fluent.asserts;

version (unittest)
{
    import silver.ast : DiagnosticCode, formatDiagnostic, SourceContext;
    import silver.loader : load, standardLibraryPath;
    import silver.sema : analyze;

    /// Runs `source` as the driver does, failing on anything the loader or sema reports.
    string runChecked(string source, string[] importPaths)
    {
        import std.algorithm : map;
        import std.array : join;

        auto context = new SourceContext;
        auto program = load(source, "test", importPaths, context);
        auto analysis = analyze(program, context.collector);
        assert(!context.collector.hasErrors, context.collector.errors
                .map!(d => formatDiagnostic(d, context.sources)).join("\n"));
        auto evaluator = new Evaluator(program, analysis);
        evaluator.run();
        return evaluator.output;
    }

    string runProgram(string source)
    {
        return runChecked(source, [standardLibraryPath()]);
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
        return runChecked(source, [directory, standardLibraryPath()]);
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
    runMain("mutable val a = 1
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

@("Block scope - sibling blocks can use the same name")
unittest
{
    runMain("if true {
        val a = 1
        print(a)
     }
     if true {
        val a = 2
        print(a)
     }").should.equal("12");
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

@("Runtime errors report their Silver source location")
unittest
{
    auto source = "def main(): Unit {\n    val a = 0\n    printl(1 / a)\n}";
    auto context = new SourceContext;
    auto program = load(source, "test.ag", [standardLibraryPath()], context);
    auto evaluator = new Evaluator(program, analyze(program, context.collector));
    try
    {
        evaluator.run();
        assert(false, "Expected dividing by zero to fail");
    }
    catch (RuntimeError e)
    {
        e.diagnostic.span.file.should.equal("test.ag");
        context.sources.locate(e.diagnostic.span).line.should.equal(3);
        e.diagnostic.code.should.equal(DiagnosticCode.DivisionByZero);
        e.msg.should.equal("Division by zero");
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

@("Importing two modules that define the same name is fine if it's only used qualified")
unittest
{
    runWithModules("import a
import b
def main(): Unit => printl(a.f() + b.f())", ["a.ag": "def f(): Int => 1", "b.ag": "def f(): Int => 2"])
        .should.equal("3
");
}

@("An imported module can use its own imports")
unittest
{
    auto files = ["a.ag": "import b
def g(): Int => f()", "b.ag": "def f(): Int => 1"];
    runWithModules("import a
def main(): Unit => printl(g())", files).should.equal("1
");
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

@("main can be in a module the starting file imports")
unittest
{
    runWithModules("import app", ["app.ag": "def main(): Unit => printl(1)"]).should.equal("1\n");
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

@("Strings keep the bytes after a NUL")
unittest
{
    runMain(`printl("a\0b" == "a\0c")
    print("a\0b")`).should.equal("false\na\0b");
}

@("Strings concatenate with ~")
unittest
{
    evaluateExpression(`"a" ~ "b" ~ "c"`).should.equal("abc");
    evaluateExpression(`"" ~ "x"`).should.equal("x");
    evaluateExpression(`"x" ~ ""`).should.equal("x");
    evaluateExpression(`"caf" ~ "é"`).should.equal("café");
}

@("Strings order by unsigned bytes, then by length")
unittest
{
    evaluateExpression(`"a" < "b"`).should.equal("true");
    evaluateExpression(`"b" <= "a"`).should.equal("false");
    evaluateExpression(`"a" > "b"`).should.equal("false");
    evaluateExpression(`"a" >= "a"`).should.equal("true");
    evaluateExpression(`"app" < "apple"`).should.equal("true");
    evaluateExpression(`"" < "a"`).should.equal("true");
    evaluateExpression(`"z" < "é"`).should.equal("true");
    evaluateExpression(`"a\0" > "a"`).should.equal("true");
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
