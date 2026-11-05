/// Type checking tests. An expression is found by its exact source text (its nth whole-word
/// occurrence), and types are compared as `TypeTable.describe` prints them, e.g. "Int?".
module silver.sema.check_tests;

version (unittest):

import core.exception : AssertError;
import std.format : format;

import silver.ast;
import silver.sema.resolution_tests;

/// Asserts that the expression whose source is exactly the `nth` occurrence of `text` has type `expected`.
void shouldHaveType(const Analyzed a, string text, size_t nth, string expected,
    string moduleName = "main", string file = __FILE__, size_t line = __LINE__)
{
    auto start = occurrence(a.sources[moduleName], text, nth);
    size_t[2] span = [start, start + text.length];
    auto id = span in a.names[moduleName].exprs;
    if (id is null)
    {
        throw new AssertError(format("No expression spans exactly `%s` #%s", text, nth), file, line);
    }
    if (!a.analysis.hasType(*id))
    {
        throw new AssertError(format("`%s` #%s has no type", text, nth), file, line);
    }
    auto actual = a.analysis.types.describe(a.analysis.typeOf(*id));
    if (actual != expected)
    {
        throw new AssertError(format("`%s` #%s has type %s, expected %s", text, nth, actual, expected), file, line);
    }
}

/// Shorthand for the first occurrence.
void shouldHaveType(const Analyzed a, string text, string expected,
    string file = __FILE__, size_t line = __LINE__)
{
    a.shouldHaveType(text, 1, expected, "main", file, line);
}

/// Asserts that the function, param or local declared at `declaration` has type `expected`.
void shouldDeclareType(const Analyzed a, At declaration, string expected,
    string file = __FILE__, size_t line = __LINE__)
{
    auto start = occurrence(a.sources[declaration.moduleName], declaration.word, declaration.nth);
    auto symbol = start in a.names[declaration.moduleName].declarations;
    if (symbol is null)
    {
        throw new AssertError(format("%s isn't a declaration", declaration), file, line);
    }
    if (!a.analysis.hasType(*symbol))
    {
        throw new AssertError(format("%s has no type", declaration), file, line);
    }
    auto actual = a.analysis.types.describe(a.analysis.typeOf(*symbol));
    if (actual != expected)
    {
        throw new AssertError(format("%s has type %s, expected %s", declaration, actual, expected), file, line);
    }
}

/// Asserts that every expression in a module was given a type.
void shouldTypeEveryExpression(const Analyzed a, string moduleName = "main",
    string file = __FILE__, size_t line = __LINE__)
{
    foreach (span, id; a.names[moduleName].exprs)
    {
        if (!a.analysis.hasType(id))
        {
            throw new AssertError(format("`%s` has no type", a.sources[moduleName][span[0] .. span[1]]), file, line);
        }
    }
}

/// `body` as the body of `main`.
private Analyzed analyzedMain(string body)
{
    return analyzed("def main(): Unit {\n" ~ body ~ "\n}");
}

// Literals, locals, and declarations

@("type checking gives each literal its type")
unittest
{
    auto a = analyzedMain(`val i = 1
    val f = 1.5
    val s = "s"
    val b = true
    val u = ()`);
    a.shouldHaveType("1", "Int");
    a.shouldHaveType("1.5", "Float");
    a.shouldHaveType(`"s"`, "String");
    a.shouldHaveType("true", "Bool");
    a.shouldHaveType("()", "Unit");
    a.shouldHaveNoDiagnostics();
}

@("type checking gives an unannotated local its initializer's type, and an annotated one its annotation")
unittest
{
    auto a = analyzedMain(`val plain = 1
    val maybe: Int? = 1
    printl(plain)
    printl(maybe)`);
    a.shouldDeclareType(At("plain", 1), "Int");
    a.shouldDeclareType(At("maybe", 1), "Int?");
    a.shouldHaveType("plain", 2, "Int");
    a.shouldHaveType("maybe", 2, "Int?");
    a.shouldHaveNoDiagnostics();
}

@("type checking records function and parameter types from their annotations")
unittest
{
    auto a = analyzed(`native def f(x: Int, g: (Int) -> Bool): String?
def main(): Unit => ()`);
    a.shouldDeclareType(At("f", 1), "(Int, (Int) -> Bool) -> String?");
    a.shouldDeclareType(At("x", 1), "Int");
    a.shouldDeclareType(At("g", 1), "(Int) -> Bool");
    a.shouldHaveNoDiagnostics();
}

@("type checking finds a function declared after its caller")
unittest
{
    auto a = analyzed(`def main(): Unit => printl(later(1))
def later(x: Int): Bool => true`);
    a.shouldHaveType("later(1)", "Bool");
    a.shouldHaveNoDiagnostics();
}

@("type checking reports an unknown type once, at its name")
unittest
{
    analyzed("def f(x: Nope): Int => 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    analyzed("def f(): Nope => 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    analyzedMain("val x: Nope = 1\n    printl(x + 1)")
        .shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
}

// Assignability

@("type checking accepts any type where Any is expected")
unittest
{
    analyzedMain(`printl(1)
    printl("s")
    printl(true)`).shouldHaveNoDiagnostics();
}

@("type checking promotes T to T?, but not T? to T")
unittest
{
    analyzedMain("val maybe: Int? = 1").shouldHaveNoDiagnostics();
    analyzedMain("val maybe: Int? = 1\n    val sure: Int = maybe")
        .shouldReport(DiagnosticCode.TypeMismatch, At("maybe", 2));
}

@("type checking reports an argument of the wrong type, at the argument")
unittest
{
    analyzed(`def f(x: Int): Int => x
def main(): Unit => printl(f("a"))`)
        .shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
}

@("type checking reports a body that doesn't match the return type")
unittest
{
    analyzed(`def f(): Int => "a"
def main(): Unit => ()`)
        .shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
}

@("type checking checks a return statement against the function's return type")
unittest
{
    analyzed(`def f(): Int {
    return "a"
}
def main(): Unit => ()`)
        .shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
}

@("type checking reports an assignment of the wrong type")
unittest
{
    analyzedMain(`mutable val x = 1
    x = "a"`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
}

@("type checking reports a call with the wrong number of arguments, or of something that isn't a function")
unittest
{
    analyzed("def f(x: Int): Int => x\ndef main(): Unit => printl(f(1, 2))")
        .shouldReport(DiagnosticCode.WrongArgumentCount, At("f", 2));
    analyzedMain("val x = 1\n    x()")
        .shouldReport(DiagnosticCode.NotCallable, At("x", 2));
}

@("type checking gives a call its function's return type, even when an argument is wrong")
unittest
{
    auto a = analyzed(`def f(x: Int): Bool => true
def main(): Unit => printl(f("a"))`);
    a.shouldHaveType(`f("a")`, "Bool");
    a.shouldHaveType(`"a"`, "String");
}

// Int and Float

@("type checking lets an integer literal be a Float where one is expected")
unittest
{
    auto a = analyzedMain(`val f: Float = 1
    val g: Float = -2`);
    a.shouldHaveType("1", "Float");
    a.shouldHaveType("-2", "Float");
    a.shouldHaveType("2", "Float");
    a.shouldHaveNoDiagnostics();
}

@("type checking lets an integer literal argument be a Float")
unittest
{
    auto a = analyzed(`native def g(x: Float): Unit
def main(): Unit => g(2)`);
    a.shouldHaveType("2", "Float");
    a.shouldHaveNoDiagnostics();
}

@("type checking lets an integer literal beside a Float operand be a Float")
unittest
{
    auto a = analyzedMain(`val x = 1.5
    val y = x * 2
    val z = 0 == x`);
    a.shouldHaveType("x * 2", "Float");
    a.shouldHaveType("2", "Float");
    a.shouldHaveType("0", "Float");
    a.shouldHaveType("0 == x", "Bool");
    a.shouldHaveNoDiagnostics();
}

@("type checking never converts an Int value to Float")
unittest
{
    analyzedMain("val i = 1\n    val f: Float = i")
        .shouldReport(DiagnosticCode.TypeMismatch, At("i", 2));
    analyzedMain("val i = 1\n    printl(i + 1.5)")
        .shouldReport(DiagnosticCode.InvalidOperand, At("i", 2));
    analyzedMain("val i = 1\n    val f = 1.5\n    printl(i < f)")
        .shouldReport(DiagnosticCode.InvalidOperand, At("i", 2));
}

// Operators

@("type checking gives arithmetic its operands' numeric type")
unittest
{
    auto a = analyzedMain(`val i = 1 + 2 * 3
    val f = 1.5 / 2.5
    val n = -i`);
    a.shouldHaveType("1 + 2 * 3", "Int");
    a.shouldHaveType("1.5 / 2.5", "Float");
    a.shouldHaveType("-i", "Int");
    a.shouldHaveNoDiagnostics();
}

@("type checking reports arithmetic on something that isn't a number, at that operand")
unittest
{
    analyzedMain(`printl("a" + 1)`).shouldReport(DiagnosticCode.InvalidOperand, At(`"a"`, 1));
    analyzedMain(`printl(1 * true)`).shouldReport(DiagnosticCode.InvalidOperand, At("true", 1));
    analyzedMain(`printl(-true)`).shouldReport(DiagnosticCode.InvalidOperand, At("true", 1));
}

@("type checking gives comparisons, equality and logic the type Bool")
unittest
{
    auto a = analyzedMain(`val lt = 1 < 2
    val eq = "a" == "b"
    val both = true && !false`);
    a.shouldHaveType("1 < 2", "Bool");
    a.shouldHaveType(`"a" == "b"`, "Bool");
    a.shouldHaveType("true && !false", "Bool");
    a.shouldHaveNoDiagnostics();
}

@("type checking reports equality between different types, and logic on non-Bools")
unittest
{
    analyzedMain(`printl("a" == 1)`).shouldReport(DiagnosticCode.InvalidOperand, At(`"a"`, 1));
    analyzedMain(`printl(!1)`).shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
    analyzedMain(`printl(1 || true)`).shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
}

@("type checking reports ?? as unsupported for now")
unittest
{
    analyzedMain("val maybe: Int? = 1\n    printl(maybe ?? 0)")
        .shouldReport(DiagnosticCode.InternalError, At("maybe", 2));
}

// If, while, blocks, and Never

@("type checking gives an if with an else the type its branches share")
unittest
{
    auto a = analyzed(`def f(c: Bool): Int => if c => 1 else 2
def main(): Unit => ()`);
    a.shouldHaveType("if c => 1 else 2", "Int");
    a.shouldHaveNoDiagnostics();
}

@("type checking gives an if without an else the type Unit")
unittest
{
    auto a = analyzedMain("if true => printl(1)");
    a.shouldHaveType("if true => printl(1)", "Unit");
    a.shouldHaveNoDiagnostics();
}

@("type checking reports an if whose branches have different types, at the if")
unittest
{
    analyzedMain(`printl(if true => 1 else "a")`).shouldReport(DiagnosticCode.TypeMismatch, At("if", 1));
}

@("type checking reports a condition that isn't a Bool")
unittest
{
    analyzedMain("printl(if 1 => 2 else 3)").shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
    analyzedMain("while 1 { }").shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
}

@("type checking gives a block ending in return the type Never, so the other branch decides the if")
unittest
{
    auto a = analyzed(`def f(c: Bool): Int {
    val v = if c { return 1 } else { 2 }
    v
}
def main(): Unit => ()`);
    a.shouldHaveType("{ return 1 }", "Never");
    a.shouldHaveType("if c { return 1 } else { 2 }", "Int");
    a.shouldDeclareType(At("v", 1), "Int");
    a.shouldHaveNoDiagnostics();
}

@("type checking accepts a function body that ends in a return statement")
unittest
{
    analyzed(`def f(c: Bool): Int {
    if c {
        return 1
    }
    return 2
}
def main(): Unit => ()`).shouldHaveNoDiagnostics();
}

@("type checking gives a block its last expression's type, or Unit")
unittest
{
    auto a = analyzedMain(`val n = { 1 }
    val u = { val x = 1 }`);
    a.shouldHaveType("{ 1 }", "Int");
    a.shouldHaveType("{ val x = 1 }", "Unit");
    a.shouldHaveNoDiagnostics();
}

// Names, modules, and cascades

@("type checking gives a module-qualified function its declared type")
unittest
{
    auto a = analyzed("import std.math\ndef main(): Unit => printl(std.math.pow(2, 3))");
    a.shouldHaveType("std.math.pow", "(Float, Float) -> Float");
    a.shouldHaveType("std.math.pow(2, 3)", "Float");
    a.shouldHaveNoDiagnostics();
}

@("type checking reports a member of a value, since no type has members yet")
unittest
{
    analyzedMain("val x = 1\n    printl(x.size)").shouldReport(DiagnosticCode.UnknownMember, At("x", 2));
}

@("type checking doesn't report again where name resolution already did")
unittest
{
    analyzedMain("printl(nope + 1)").shouldReport(DiagnosticCode.UnknownName, At("nope", 1));
    analyzedMain("printl(nope(1))").shouldReport(DiagnosticCode.UnknownName, At("nope", 1));
    analyzedMain("printl(-nope)").shouldReport(DiagnosticCode.UnknownName, At("nope", 1));
    analyzed("import std.math\ndef main(): Unit => printl(std.math.nope(1))")
        .shouldReport(DiagnosticCode.UnknownModuleMember, At("std", 2));
    analyzed("import std.math\ndef main(): Unit => printl(std.math + 1)")
        .shouldReport(DiagnosticCode.ModuleIsNotAValue, At("std", 2));
}

@("type checking gives every expression in a program a type")
unittest
{
    auto a = analyzed(`def f(x: Int, y: Float): Float {
    mutable val total = y
    while total < 10.0 {
        total = total + 1
    }
    if x > 2 => total * 2 else -total
}
def main(): Unit {
    printl(f(1, 2))
    printl(if true { "a" } else { "b" })
}`);
    a.shouldHaveNoDiagnostics();
    a.shouldTypeEveryExpression();
}

// Declared types

@("type checking gives a param, local or function its declared type")
unittest
{
    auto a = analyzed(`type Point(x: Int)
type Marker
def f(p: Point, m: Marker, maybe: Point?): Point {
    val q = p
    q
}
def main(): Unit => ()`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("p", 1), "Point");
    a.shouldDeclareType(At("m", 1), "Marker");
    a.shouldDeclareType(At("maybe", 1), "Point?");
    a.shouldDeclareType(At("q", 1), "Point");
    a.shouldDeclareType(At("f", 1), "(Point, Marker, Point?) -> Point");
}

@("type checking treats a declared type by name, so the same fields don't make the same type")
unittest
{
    analyzed(`type Meters(value: Int)
type Feet(value: Int)
def f(m: Meters): Unit => ()
def g(x: Feet): Unit => f(x)
def main(): Unit => ()`)
        .shouldReport(DiagnosticCode.TypeMismatch, At("x", 2));
}

@("type checking keeps same-named types in different modules apart")
unittest
{
    auto files = ["lib.ag": "module lib\ntype Point(x: Int)"];
    analyzed(`import lib
type Point(x: Int)
def f(p: Point): Unit => ()
def g(q: lib.Point): Unit => f(q)
def main(): Unit => ()`, files)
        .shouldReport(DiagnosticCode.TypeMismatch, At("q", 2));
}

@("type checking treats plain and qualified names for a type as the same type")
unittest
{
    auto files = ["lib.ag": "module lib\ntype Point(x: Int)"];
    analyzed(`import lib
def f(p: Point): Unit => ()
def g(q: lib.Point): Unit => f(q)
def main(): Unit => ()`, files)
        .shouldHaveNoDiagnostics();
}
