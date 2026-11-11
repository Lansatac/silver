/// Type checking tests. An expression is found by its exact source text (its nth whole-word
/// occurrence), and types are compared as `TypeTable.describe` prints them, e.g. "Int?".
module silver.sema.check_tests;

version (unittest):

import core.exception : AssertError;
import std.format : format;
import std.sumtype : get, has, match;

import silver.ast;
import silver.sema.check : FieldInfo;
import silver.sema.constant : ConstInt, ConstUInt, ConstUnit;
import silver.sema.resolution_tests;
import silver.sema.target : Target;

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
    auto a = analyzed(`def f(x: Int, g: (Int) -> Bool): String? => None
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

@("type checking gives `~` on Strings the type String, and comparing Strings the type Bool")
unittest
{
    auto a = analyzedMain(`val joined = "a" ~ "b"
    val lt = "a" < "b"
    val le = "a" <= "b"
    val gt = "a" > "b"
    val ge = "a" >= "b"`);
    a.shouldHaveType(`"a" ~ "b"`, "String");
    a.shouldHaveType(`"a" < "b"`, "Bool");
    a.shouldHaveType(`"a" <= "b"`, "Bool");
    a.shouldHaveType(`"a" > "b"`, "Bool");
    a.shouldHaveType(`"a" >= "b"`, "Bool");
    a.shouldHaveNoDiagnostics();
}

@("type checking reports `~` on anything but Strings, blaming the wrong operand")
unittest
{
    analyzedMain(`printl(1 ~ 2)`).shouldReport(DiagnosticCode.InvalidOperand, At("1", 1));
    analyzedMain(`printl("a" ~ 1)`).shouldReport(DiagnosticCode.InvalidOperand, At("1", 1));
    analyzedMain(`printl(1 ~ "a")`).shouldReport(DiagnosticCode.InvalidOperand, At("1", 1));
    analyzedMain(`printl(true ~ "a")`).shouldReport(DiagnosticCode.InvalidOperand, At("true", 1));
    analyzedMain(`printl("a" ~ ())`).shouldReport(DiagnosticCode.InvalidOperand, At("()", 1));
}

@("type checking only orders two numbers or two Strings")
unittest
{
    analyzedMain(`printl("a" < 1)`).shouldReport(DiagnosticCode.InvalidOperand, At(`"a"`, 1));
    analyzedMain(`printl(1 >= "a")`).shouldReport(DiagnosticCode.InvalidOperand, At("1", 1));
    analyzedMain(`printl("a" < true)`).shouldReport(DiagnosticCode.InvalidOperand, At("true", 1));
    analyzedMain(`printl(true < "a")`).shouldReport(DiagnosticCode.InvalidOperand, At("true", 1));
}

@("operator diagnostics on Strings name the operator as it's written")
unittest
{
    static string messageOf(const Analyzed a) => a.collector.diagnostics[0].message;
    assert(messageOf(analyzedMain(`printl(1 ~ 2)`)) == "`~` needs a String or an array, got `Int`");
    assert(messageOf(analyzedMain(`printl("a" <= true)`)) == "`<=` needs a number or a String, got `Bool`");
    assert(messageOf(analyzedMain(`printl("a" < 1.5)`)) == "`<` can't compare `String` and `Float`");
}

@("type checking reports equality between different types, and logic on non-Bools")
unittest
{
    analyzedMain(`printl("a" == 1)`).shouldReport(DiagnosticCode.InvalidOperand, At(`"a"`, 1));
    analyzedMain(`printl(!1)`).shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
    analyzedMain(`printl(1 || true)`).shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
}

// Options

@("type checking gives Some and None the option they're used as")
unittest
{
    auto a = analyzedMain(`val m: UInt8? = 1
    val joined = if true => Some(1) else None
    val promoted = if true => 1 else None
    val nested: (Int?)? = Some(None)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("if true => Some(1) else None", "Int?");
    a.shouldHaveType("if true => 1 else None", "Int?");
}

@("type checking reports a None with no option to take its type from")
unittest
{
    analyzedMain("val x = None").shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain("val x = if true => None else None").shouldReport(DiagnosticCode.UntypedNone, At("if", 1));
    analyzedMain("printl(None)").shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain(`val s = "{None}"`).shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain("val s = String(None)").shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain("val s = Some(None)").shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain("printl(None == None)").shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain("printl(None ?? 1)").shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain("if val x = None { }").shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain("val x: Int = None").shouldReport(DiagnosticCode.TypeMismatch, At("None", 1));
}

@("type checking checks a literal against the option's payload")
unittest
{
    analyzedMain("val x: UInt8? = 300").shouldReport(DiagnosticCode.LiteralOutOfRange, At("300", 1));
    analyzedMain("val x: UInt8? = Some(300)").shouldReport(DiagnosticCode.LiteralOutOfRange, At("300", 1));
    analyzedMain("val x: UInt8? = -1").shouldReport(DiagnosticCode.LiteralOutOfRange, At("1", 1));
    analyzedMain("val x: (UInt8?)? = 300").shouldReport(DiagnosticCode.LiteralOutOfRange, At("300", 1));
    analyzedMain(`val x: String? = 1`).shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
    analyzedMain(`val x: Int? = Some("a")`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
    analyzedMain(`val x: Int? = Some(Some(1))`).shouldReport(DiagnosticCode.TypeMismatch, At("Some(1)", 1));
}

@("name resolution reserves Some and None")
unittest
{
    analyzed("type None\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("None", 1));
    analyzed("type Some(x: Int)\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Some", 1));
    analyzedMain("val f = Some").shouldReport(DiagnosticCode.UnknownName, At("Some", 1));
    analyzedMain("val x = Some(1, 2)").shouldReport(DiagnosticCode.UnknownName, At("Some", 1));
}

@("type checking rejects an option of Any")
unittest
{
    analyzed("def f(x: Any?): Unit => ()\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidOptionPayload, At("Any?", 1));
}

@("type checking needs an option on the left of ?? and a fitting value on the right")
unittest
{
    analyzedMain("printl(1 ?? 2)").shouldReport(DiagnosticCode.InvalidOperand, At("1", 1));
    analyzedMain(`val x: Int? = 1
    printl(x ?? "a")`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
    analyzedMain(`val x: Int? = 1
    val y: String? = "a"
    printl(x ?? y)`).shouldReport(DiagnosticCode.TypeMismatch, At("y", 2));
    analyzedMain("val x: UInt8? = 1\n    printl(x ?? 300)").shouldReport(DiagnosticCode.LiteralOutOfRange, At("300", 1));
}

@("type checking gives ?? the payload's type unless the right side is an option")
unittest
{
    auto a = analyzedMain(`val x: Int? = 1
    val nested: (Int?)? = 1
    val y = x ?? 0
    val z = x ?? None
    val w = x ?? x
    val u = nested ?? x`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("x ?? 0", "Int");
    a.shouldHaveType("x ?? None", "Int?");
    a.shouldHaveType("x ?? x", "Int?");
    a.shouldHaveType("nested ?? x", "Int?");
}

@("if val binds the payload in the true branch only, and needs an option")
unittest
{
    auto a = analyzedMain(`val x: Int? = 1
    if val y = x {
        val z = y
        printl(z + 1)
    }`);
    a.shouldHaveNoDiagnostics();
    analyzedMain(`if val y = 1 { }`).shouldReport(DiagnosticCode.InvalidOperand, At("1", 1));
    analyzedMain(`val x: Int? = 1
    if val y = x { } else { printl(y) }`).shouldReport(DiagnosticCode.UnknownName, At("y", 2));
    analyzedMain(`val x: Int? = 1
    if val y = x { }
    printl(y)`).shouldReport(DiagnosticCode.UnknownName, At("y", 2));
    analyzedMain(`val x: Int? = 1
    if val x = x { }`).shouldReport(DiagnosticCode.ShadowedDeclaration, At("x", 2));
    analyzedMain(`val x: Int? = 1
    if val y = x {
        y = 2
    }`).shouldReport(DiagnosticCode.AssignToImmutable, At("y", 2));
}

@("type checking compares an option with its payload, but doesn't order it")
unittest
{
    analyzedMain(`val x: UInt8? = 1
    printl(x == 2)
    printl(2 == x)
    printl(x == None)
    printl(None == x)
    printl(x == Some(2))
    printl(Some(2) == x)
    printl(Some(1) == None)`).shouldHaveNoDiagnostics();

    analyzedMain(`val x: Int? = 1
    printl(x == "a")`).shouldReport(DiagnosticCode.InvalidOperand, At(`x == "a"`, 1));
    analyzedMain(`val x: Int? = 1
    printl(x < 2)`).shouldReport(DiagnosticCode.InvalidOperand, At("x", 2));
    analyzedMain(`val x: UInt8? = 1
    printl(x == 300)`).shouldReport(DiagnosticCode.LiteralOutOfRange, At("300", 1));
    analyzedMain("printl(3 == None)").shouldReport(DiagnosticCode.InvalidOperand, At("3 == None", 1));
    analyzed("def f(a: () -> Int, b: (() -> Int)?): Bool => b == a\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidOperand, At("b == a", 1));
}

@("postfix ? needs an option, in a function that returns one")
unittest
{
    analyzed("def f(x: Int?): Int? => Some(x? + 1)\ndef main(): Unit => ()").shouldHaveNoDiagnostics();
    analyzed("def f(x: Int?): Int => x?\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidPropagation, At("x?", 1));
    analyzed("def f(x: Int): Int? => x?\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidOperand, At("x", 2));
}

@("?. reads a field of an option, staying one option deep")
unittest
{
    enum types = "type Inner(n: Int)\ntype Outer(i: Inner?, plain: Inner)\n";
    auto a = analyzed(types ~ `def main(): Unit {
    val o: Outer? = None
    val p = o?.plain
    val i = o?.i
    val n = o?.i?.n
}`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("o?.plain", "Inner?");
    a.shouldHaveType("o?.i", "Inner?");
    a.shouldHaveType("o?.i?.n", "Int?");

    analyzed(types ~ "def f(o: Outer): Inner => o?.plain\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidOperand, At("o", 2));
    analyzed(types ~ "def f(o: Outer?): Int? => o?.nope\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.UnknownMember, At("o?.nope", 1));
    analyzed(types ~ "def f(o: Outer?): Inner => o.plain\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.UnknownMember, At("o.plain", 1));
    analyzed(types ~ "def main(): Unit {\n    mutable val o: Outer?\n    o?.plain = Inner(1)\n}")
        .shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("o?.plain", 1));
}

@("options can't be top-level constants or built from them")
unittest
{
    analyzed("val x: Int = None ?? 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.NonConstantInitializer, At("None", 1));
    analyzed("val x: Int = Some(1) ?? 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.NonConstantInitializer, At("Some(1)", 1));
    analyzed("val y: Int = 1\nval x: Int = y ?? 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidOperand, At("y", 2));
}

// Values dropped where Unit is expected

@("type checking drops a block's value where Unit is expected")
unittest
{
    analyzed(`def number(): Int => 1
def a(): Unit { number() }
def b(): Unit => number()
def c(x: Bool): Unit {
    if x { 1 } else { "text" }
}
def d(x: Bool): Unit {
    if x => number()
    while x { number() }
}
def main(): Unit => ()`).shouldHaveNoDiagnostics();
}

@("type checking still needs Unit where nothing's a block's value")
unittest
{
    analyzed("def number(): Int => 1\ndef main(): Unit {\n    val x: Unit = number()\n}")
        .shouldReport(DiagnosticCode.TypeMismatch, At("number()", 2));
    analyzed("def main(): Unit {\n    return 1\n}").shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
    analyzed(`def main(): Unit {
    val x: Unit = { 1 }
}`).shouldReport(DiagnosticCode.TypeMismatch, At("{ 1 }", 1));
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

// Constructing declared types

/// `body` as the body of `main`, with `Point` and `Origin` declared.
private Analyzed analyzedWithTypes(string body)
{
    return analyzed("type Point(x: Int, y: Int)\ntype Origin\ndef main(): Unit {\n" ~ body ~ "\n}");
}

@("type checking gives a constructor a function type, and a construction the declared type")
unittest
{
    auto a = analyzedWithTypes(`val p = Point(1, 2)
    val make = Point`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("Point", 2, "(Int, Int) -> Point");
    a.shouldHaveType("Point(1, 2)", "Point");
    a.shouldDeclareType(At("p", 1), "Point");
    a.shouldDeclareType(At("make", 1), "(Int, Int) -> Point");
    a.shouldTypeEveryExpression();
}

@("type checking gives a marker's name the marker type, since it's already a value")
unittest
{
    auto a = analyzedWithTypes(`val o = Origin`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("Origin", 2, "Origin");
    a.shouldDeclareType(At("o", 1), "Origin");
}

@("type checking reports a marker called like a function")
unittest
{
    analyzedWithTypes(`val o = Origin()`).shouldReport(DiagnosticCode.NotCallable, At("Origin", 2));
}

@("type checking reports a construction with the wrong number of arguments")
unittest
{
    analyzedWithTypes(`val p = Point(1)`).shouldReport(DiagnosticCode.WrongArgumentCount, At("Point", 2));
    analyzedWithTypes(`val p = Point(1, 2, 3)`).shouldReport(DiagnosticCode.WrongArgumentCount, At("Point", 2));
    analyzedWithTypes(`val p = Point()`).shouldReport(DiagnosticCode.WrongArgumentCount, At("Point", 2));
}

@("type checking checks each constructor argument against its field")
unittest
{
    analyzedWithTypes(`val p = Point(1, "a")`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
    analyzed(`type Meters(value: Int)
type Feet(value: Int)
def main(): Unit {
    val feet = Feet(1)
    val meters = Meters(feet)
}`).shouldReport(DiagnosticCode.TypeMismatch, At("feet", 2));
}

@("type checking adapts an integer literal to a Float field, but not an Int value")
unittest
{
    enum box = "type Box(value: Float)\ndef main(): Unit {\n";
    analyzed(box ~ "    val b = Box(1)\n}").shouldHaveNoDiagnostics();
    analyzed(box ~ "    val i = 1\n    val b = Box(i)\n}")
        .shouldReport(DiagnosticCode.TypeMismatch, At("i", 2));
}

@("type checking promotes a constructor argument to an option field")
unittest
{
    analyzed("type Box(value: Int?)\ndef main(): Unit {\n    val b = Box(1)\n}").shouldHaveNoDiagnostics();
}

@("type checking finds constructors and fields of types declared later")
unittest
{
    auto a = analyzed(`def main(): Unit {
    val line = Line(Point(1))
    val v = line.start.x
}
type Line(start: Point)
type Point(x: Int)`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("line", 1), "Line");
    a.shouldDeclareType(At("v", 1), "Int");
}

@("type checking accepts a type whose fields refer back to it")
unittest
{
    auto a = analyzed(`type Node(value: Int, next: Node?)
def push(v: Int, n: Node): Node => Node(v, n)
def rest(n: Node): Node? => n.next
def main(): Unit => ()`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("Node", 5, "(Int, Node?) -> Node");
    a.shouldHaveType("n.next", "Node?");
}

@("type checking treats plain and qualified constructors as the same type")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)\ntype Origin"];
    auto a = analyzed(`import geo
def same(p: geo.Point, o: geo.Origin): Unit => ()
def main(): Unit {
    same(Point(1), Origin)
    same(geo.Point(2), geo.Origin)
}`, files);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("Point(1)", "Point");
    a.shouldHaveType("geo.Point(2)", "Point");
    a.shouldHaveType("geo.Origin", 2, "Origin");
}

@("type checking keeps same-named imported and local constructions apart")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)"];
    analyzed(`import geo
type Point(y: Int)
def own(p: Point): Unit => ()
def main(): Unit {
    own(geo.Point(1))
}`, files).shouldReport(DiagnosticCode.TypeMismatch, At("geo", 2));
}

// Reading fields

@("type checking gives a field read the field's declared type")
unittest
{
    auto a = analyzed(`type Mixed(count: Int, ratio: Float, name: String, maybe: Int?, f: (Int) -> Bool)
def read(m: Mixed): Unit {
    val a = m.count
    val b = m.ratio
    val c = m.name
    val d = m.maybe
    val e = m.f
    val g = m.f(1)
}
def main(): Unit => ()`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("a", 1), "Int");
    a.shouldDeclareType(At("b", 1), "Float");
    a.shouldDeclareType(At("c", 1), "String");
    a.shouldDeclareType(At("d", 1), "Int?");
    a.shouldDeclareType(At("e", 1), "(Int) -> Bool");
    a.shouldDeclareType(At("g", 1), "Bool");
}

@("type checking reads fields through other fields and from any expression")
unittest
{
    auto a = analyzed(`type Point(x: Int)
type Line(start: Point)
def make(): Line => Line(Point(1))
def main(): Unit {
    val line = make()
    val fromChain = line.start.x
    val fromCall = make().start
    val fromConstruction = Point(2).x
}`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("fromChain", 1), "Int");
    a.shouldDeclareType(At("fromCall", 1), "Point");
    a.shouldDeclareType(At("fromConstruction", 1), "Int");
    a.shouldTypeEveryExpression();
}

@("type checking finds a field by the object's type, so types can reuse a field name")
unittest
{
    auto a = analyzed(`type Count(value: Int)
type Label(value: String)
def main(): Unit {
    val n = Count(1).value
    val s = Label("a").value
}`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("n", 1), "Int");
    a.shouldDeclareType(At("s", 1), "String");
}

@("type checking keeps field names apart from locals and functions")
unittest
{
    analyzed(`type Point(x: Int, main: Int)
def main(): Unit {
    val x = Point(1, 2).x
    val y = Point(1, 2).main
}`).shouldHaveNoDiagnostics();
}

@("type checking reads the fields of an imported type")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)"];
    auto a = analyzed("import geo\ndef main(): Unit {\n    val v = geo.Point(1).x\n}", files);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("v", 1), "Int");
}

@("type checking reports a field the type doesn't have, at the start of the read")
unittest
{
    analyzedWithTypes(`val p = Point(1, 2)
    val v = p.nope`).shouldReport(DiagnosticCode.UnknownMember, At("p", 2));
    analyzedWithTypes(`val v = Origin.x`).shouldReport(DiagnosticCode.UnknownMember, At("Origin", 2));
    // The constructor is a function, not an instance.
    analyzedWithTypes(`val v = Point.x`).shouldReport(DiagnosticCode.UnknownMember, At("Point", 2));
}

@("type checking doesn't read a field through an option")
unittest
{
    analyzed(`type Point(x: Int)
def f(maybe: Point?): Int => maybe.x
def main(): Unit => ()`).shouldReport(DiagnosticCode.UnknownMember, At("maybe", 2));
}

// Assigning to bindings and fields: the binding decides, not the type

private enum lineTypes = "type Point(x: Int)\ntype Line(start: Point)\n";

@("type checking accepts an assignment to a field through a mutable binding")
unittest
{
    analyzedWithTypes(`mutable val p = Point(1, 2)
    p.x = 3`).shouldHaveNoDiagnostics();
    analyzed(lineTypes ~ "def main(): Unit {\n    mutable val line = Line(Point(1))\n    line.start.x = 2\n}")
        .shouldHaveNoDiagnostics();
}

@("type checking reports an assignment to a field through an immutable binding")
unittest
{
    analyzedWithTypes(`val p = Point(1, 2)
    p.x = 3`).shouldReport(DiagnosticCode.AssignToImmutable, At("p", 2));
    analyzed(lineTypes ~ "def main(): Unit {\n    val line = Line(Point(1))\n    line.start.x = 2\n}")
        .shouldReport(DiagnosticCode.AssignToImmutable, At("line", 2));
    analyzed(lineTypes ~ "def f(p: Point): Unit {\n    p.x = 2\n}\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.AssignToImmutable, At("p", 2));
}

@("type checking reports an assignment to an immutable binding")
unittest
{
    analyzedWithTypes(`val x = 1
    x = 2`).shouldReport(DiagnosticCode.AssignToImmutable, At("x", 3));
    analyzed("def f(n: Int): Unit {\n    n = 2\n}\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.AssignToImmutable, At("n", 2));
}

@("type checking reports an assignment to a field of something that isn't a binding")
unittest
{
    analyzedWithTypes(`Point(1, 2).x = 3`).shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("Point", 2));
    analyzed(lineTypes ~ "def make(): Point => Point(1)\ndef main(): Unit {\n    make().x = 2\n}")
        .shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("make", 2));
}

@("type checking checks the value assigned to a field against the field's type")
unittest
{
    analyzedWithTypes(`mutable val p = Point(1, 2)
    p.x = "a"`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
}

@("type checking reports an assignment to a field the type doesn't have")
unittest
{
    analyzedWithTypes(`mutable val p = Point(1, 2)
    p.nope = 3`).shouldReport(DiagnosticCode.UnknownMember, At("p", 2));
}

@("type checking accepts rebinding a mutable binding to a new value")
unittest
{
    analyzedWithTypes(`mutable val p = Point(1, 2)
    p = Point(3, 4)`).shouldHaveNoDiagnostics();
}

@("type checking reports an assignment to something that isn't a binding at all")
unittest
{
    auto files = ["geo.ag": "module geo\ndef f(): Int => 1"];
    analyzed("def f(): Int => 1\ndef g(): Int => 2\ndef main(): Unit {\n    f = g\n}")
        .shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("f", 2));
    analyzed("import geo\ndef main(): Unit {\n    geo.f = geo.f\n}", files)
        .shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("geo", 2));
}

private Analyzed analyzedEquality(string declarations, string operands = "a: T, b: T")
{
    return analyzed(declarations ~ "\ndef same(" ~ operands ~ "): Bool => a == b\ndef main(): Unit => ()");
}

@("type checking accepts == on a type whose fields can all be compared")
unittest
{
    analyzedEquality("type T(i: Int, f: Float, s: String, b: Bool, u: Unit)").shouldHaveNoDiagnostics();
    analyzedEquality("type Inner(i: Int)\ntype T(inner: Inner, marker: Marker)\ntype Marker").shouldHaveNoDiagnostics();
    analyzedEquality("type T(maybe: Int?)").shouldHaveNoDiagnostics();
    analyzedEquality("type T", "a: T, b: T").shouldHaveNoDiagnostics();
}

@("type checking accepts == on a type that contains itself")
unittest
{
    analyzedEquality("type T(next: T?)").shouldHaveNoDiagnostics();
    analyzedEquality("type T(other: U?)\ntype U(back: T?)").shouldHaveNoDiagnostics();
}

@("type checking gives == on a declared type the type Bool")
unittest
{
    auto a = analyzed("type T(i: Int)\ndef main(): Unit {\n    val same = T(1) == T(1)\n    val differs = T(1) != T(2)\n}");
    a.shouldHaveType("T(1) == T(1)", "Bool");
    a.shouldHaveType("T(1) != T(2)", "Bool");
    a.shouldHaveNoDiagnostics();
}

@("type checking reports == on functions, at the comparison")
unittest
{
    analyzed("def f(): Int => 1\ndef main(): Unit {\n    printl(f == f)\n}")
        .shouldReport(DiagnosticCode.InvalidOperand, At("f", 2));
    analyzed("def f(): Int => 1\ndef main(): Unit {\n    printl(f != f)\n}")
        .shouldReport(DiagnosticCode.InvalidOperand, At("f", 2));
    analyzed("type T(i: Int)\ndef main(): Unit {\n    printl(T == T)\n}")
        .shouldReport(DiagnosticCode.InvalidOperand, At("T", 2));
}

@("type checking reports == on a type with a function anywhere inside it")
unittest
{
    analyzedEquality("type T(f: (Int) -> Int)").shouldReport(DiagnosticCode.InvalidOperand, At("a", 2));
    analyzedEquality("type T(f: ((Int) -> Int)?)").shouldReport(DiagnosticCode.InvalidOperand, At("a", 2));
    analyzedEquality("type Inner(f: () -> Int)\ntype T(inner: Inner)").shouldReport(DiagnosticCode.InvalidOperand, At("a", 2));
    analyzedEquality("type T(next: T?, f: () -> Int)").shouldReport(DiagnosticCode.InvalidOperand, At("a", 2));
}

@("type checking reports == between different declared types with the same fields")
unittest
{
    analyzedEquality("type T(i: Int)\ntype U(i: Int)", "a: T, b: U").shouldReport(DiagnosticCode.InvalidOperand, At("a", 2));
}

@("type checking reports ordering comparisons on a declared type")
unittest
{
    analyzed("type T(i: Int)\ndef f(a: T, b: T): Bool => a < b\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidOperand, At("a", 2));
}

private void shouldHaveFieldIndex(const Analyzed a, string text, size_t nth, size_t expected,
    string file = __FILE__, size_t line = __LINE__)
{
    auto start = occurrence(a.sources["main"], text, nth);
    size_t[2] span = [start, start + text.length];
    auto id = span in a.names["main"].exprs;
    if (id is null)
    {
        throw new AssertError(format("No expression spans exactly `%s` #%s", text, nth), file, line);
    }
    auto actual = a.analysis.fieldIndexOf(*id);
    if (actual != expected)
    {
        throw new AssertError(format("`%s` #%s is field %s, expected %s", text, nth, actual, expected), file, line);
    }
}

@("type checking records which field a member access reads")
unittest
{
    auto a = analyzed(`type Point(x: Int, y: Int)
type Line(start: Point, end: Point)
def main(): Unit {
    val p = Point(1, 2)
    val line = Line(p, p)
    printl(p.x)
    printl(p.y)
    printl(line.end)
    printl(line.end.y)
    printl(Point(3, 4).y)
}`);
    a.shouldHaveFieldIndex("p.x", 1, 0);
    a.shouldHaveFieldIndex("p.y", 1, 1);
    a.shouldHaveFieldIndex("line.end", 1, 1);
    a.shouldHaveFieldIndex("line.end.y", 1, 1);
    a.shouldHaveFieldIndex("Point(3, 4).y", 1, 1);
}

@("type checking records which field an assignment target writes, at each step of the chain")
unittest
{
    auto a = analyzed(`type Point(x: Int, y: Int)
type Line(start: Point, end: Point)
def main(): Unit {
    mutable val line = Line(Point(1, 2), Point(3, 4))
    line.end.y = 5
}`);
    a.shouldHaveFieldIndex("line.end.y", 1, 1);
    a.shouldHaveFieldIndex("line.end", 1, 1);
}

@("type checking records a type's fields in declaration order, with their types")
unittest
{
    import std.algorithm : map;
    import std.array : array;
    import std.sumtype : match;

    auto a = analyzed(`type Later(n: Int)
type Mixed(name: String, later: Later, maybe: Int?, f: (Int) -> Int, nothing: Unit)
type Origin
def main(): Unit => ()`);

    const(FieldInfo)[] fieldsAt(string name)
    {
        auto symbol = occurrence(a.sources["main"], name, 1) in a.names["main"].declarations;
        return (*symbol).match!(
            (const Id!TypeDecl decl) => a.analysis.fieldsOf(a.analysis.typeOf(decl)),
            (_) => assert(0, name ~ " isn't a type"),
        );
    }

    auto mixed = fieldsAt("Mixed");
    mixed.map!(f => f.name).array.shouldEqual(["name", "later", "maybe", "f", "nothing"]);
    mixed.map!(f => a.analysis.types.describe(f.type)).array
        .shouldEqual(["String", "Later", "Int?", "(Int) -> Int", "Unit"]);
    assert(fieldsAt("Origin").length == 0);
}

private void shouldEqual(const(string)[] actual, const(string)[] expected, string file = __FILE__, size_t line = __LINE__)
{
    if (actual != expected)
    {
        throw new AssertError(format("Got %s, expected %s", actual, expected), file, line);
    }
}

// Integer types

@("type checking treats Int64 and UInt64 as Int and UInt")
unittest
{
    auto a = analyzed("def f(a: Int64, b: UInt64): Int => a\ndef g(b: UInt): UInt64 => b\ndef main(): Unit => ()");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("a", 1), "Int");
    a.shouldDeclareType(At("b", 1), "UInt");
}

@("an integer literal takes the type expected of it, and is otherwise an Int")
unittest
{
    auto a = analyzedMain(`val x: UInt8 = 200
    val y = x + 1
    val z = 2 * x
    val w = 7
    mutable val v: Int16 = 0
    v = 9
    printl(y)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("200", "UInt8");
    a.shouldHaveType("1", "UInt8");
    a.shouldHaveType("2", "UInt8");
    a.shouldHaveType("7", "Int");
    a.shouldHaveType("9", "Int16");
}

@("an integer literal adapts through if arms and block values")
unittest
{
    auto a = analyzed(`def f(c: Bool): UInt8 {
    if c { return 1 }
    if c => 2 else 3
}
def g(): Int8 {
    val unused = 0
    -4
}
def main(): Unit => ()`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("2", "UInt8");
    a.shouldHaveType("3", "UInt8");
    a.shouldHaveType("-4", "Int8");
}

@("type checking reports a literal that doesn't fit its type")
unittest
{
    analyzedMain("val x: UInt8 = 256").shouldReport(DiagnosticCode.LiteralOutOfRange, At("256", 1));
    analyzedMain("val x: Int8 = 128").shouldReport(DiagnosticCode.LiteralOutOfRange, At("128", 1));
    analyzedMain("val x: Int8 = -129").shouldReport(DiagnosticCode.LiteralOutOfRange, At("129", 1));
    analyzedMain("val x: UInt8 = -1").shouldReport(DiagnosticCode.LiteralOutOfRange, At("1", 1));
    analyzedMain("val x: UInt8 = -0").shouldReport(DiagnosticCode.LiteralOutOfRange, At("0", 1));
    analyzedMain("val x = 9223372036854775808").shouldReport(DiagnosticCode.LiteralOutOfRange, At("9223372036854775808", 1));
    analyzedMain("val x = 0x8000000000000000").shouldReport(DiagnosticCode.LiteralOutOfRange, At("0x8000000000000000", 1));
    analyzedMain("val x: UInt = 18446744073709551616").shouldReport(DiagnosticCode.LiteralOutOfRange, At("18446744073709551616", 1));
    analyzedMain("val x: UInt8 = 200\nval y = x + 300").shouldReport(DiagnosticCode.LiteralOutOfRange, At("300", 1));
    analyzedMain("printl(UInt8(256))").shouldReport(DiagnosticCode.LiteralOutOfRange, At("256", 1));
    analyzedMain("printl(UInt8(-1))").shouldReport(DiagnosticCode.LiteralOutOfRange, At("1", 1));
}

@("the boundary literals of each type are accepted")
unittest
{
    analyzedMain(`val a: Int8 = -128
    val b: Int8 = 127
    val c: UInt8 = 255
    val d: Int = -9223372036854775808
    val e = 9223372036854775807
    val f: UInt = 18446744073709551615
    val g: Float = 18446744073709551615`).shouldHaveNoDiagnostics();
}

@("integers of different types don't mix without a conversion")
unittest
{
    analyzedMain("val a: UInt8 = 1\nval b: Int = 2\nprintl(a + b)").shouldReport(DiagnosticCode.InvalidOperand, At("a + b", 1));
    analyzedMain("val a: UInt8 = 1\nval b: Int16 = 2\nprintl(a < b)").shouldReport(DiagnosticCode.InvalidOperand, At("a < b", 1));
    analyzedMain("val a: UInt8 = 1\nval b: Int = 2\nprintl(a == b)").shouldReport(DiagnosticCode.InvalidOperand, At("a == b", 1));
    analyzedMain("val a: UInt8 = 1\nval b: Int = a").shouldReport(DiagnosticCode.TypeMismatch, At("a", 2));
    analyzed("def f(x: UInt8): Unit => ()\ndef main(): Unit {\n    val n = 1\n    f(n)\n}")
        .shouldReport(DiagnosticCode.TypeMismatch, At("n", 2));
    analyzedMain("val a: UInt8 = 1\nval b: Float = a").shouldReport(DiagnosticCode.TypeMismatch, At("a", 2));
}

@("bit and wrapping operators need integers of one type")
unittest
{
    analyzedMain("printl(1.5 & 1)").shouldReport(DiagnosticCode.InvalidOperand, At("1.5", 1));
    analyzedMain("printl(1 | 1.5)").shouldReport(DiagnosticCode.InvalidOperand, At("1.5", 1));
    analyzedMain("printl(1.5 ^ 2.5)").shouldReport(DiagnosticCode.InvalidOperand, At("1.5", 1));
    analyzedMain("printl(1.5 << 1)").shouldReport(DiagnosticCode.InvalidOperand, At("1.5", 1));
    analyzedMain("printl(1.5 +% 1)").shouldReport(DiagnosticCode.InvalidOperand, At("1.5", 1));
    analyzedMain("printl(true *% 1)").shouldReport(DiagnosticCode.InvalidOperand, At("true", 1));
    analyzedMain("printl(~1.5)").shouldReport(DiagnosticCode.InvalidOperand, At("1.5", 1));
    analyzedMain("printl(~true)").shouldReport(DiagnosticCode.InvalidOperand, At("true", 1));
    analyzedMain("val a: UInt8 = 1\nval b = 1\nprintl(a & b)").shouldReport(DiagnosticCode.InvalidOperand, At("a & b", 1));
}

@("an unsigned value can't be negated")
unittest
{
    analyzedMain("val a: UInt8 = 1\nprintl(-a)").shouldReport(DiagnosticCode.InvalidOperand, At("a", 2));
}

@("a conversion names any numeric type, and takes one number")
unittest
{
    auto a = analyzedMain(`val n = 1
    val b = UInt8(n)
    val c = Float(n)
    val d = Int(2.5)
    val e = UInt64(b)
    printl(e)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("UInt8(n)", "UInt8");
    a.shouldHaveType("Float(n)", "Float");
    a.shouldHaveType("Int(2.5)", "Int");
    a.shouldHaveType("UInt64(b)", "UInt");

    analyzedMain(`printl(Int("a"))`).shouldReport(DiagnosticCode.InvalidOperand, At(`"a"`, 1));
    analyzedMain("printl(Int(true))").shouldReport(DiagnosticCode.InvalidOperand, At("true", 1));
    analyzedMain("printl(Int(1, 2))").shouldReport(DiagnosticCode.WrongArgumentCount, At("Int(1, 2)", 1));
    analyzedMain("printl(Int())").shouldReport(DiagnosticCode.WrongArgumentCount, At("Int()", 1));
}

@("a conversion can't be used as a value, or built-in numeric types redeclared")
unittest
{
    analyzedMain("val f = Int").shouldReport(DiagnosticCode.UnknownName, At("Int", 1));
    analyzed("type UInt8(x: Int)\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("UInt8", 1));
}

// Top-level constants

/// The value and type sema gave the constant declared as the first occurrence of `name`.
private void shouldEvaluateTo(T)(const Analyzed a, string name, T expected, string type,
    string file = __FILE__, size_t line = __LINE__)
{
    auto symbol = occurrence(a.sources["main"], name, 1) in a.names["main"].declarations;
    if (symbol is null)
    {
        throw new AssertError(format("`%s` #1 isn't a declaration", name), file, line);
    }
    auto id = (*symbol).match!(
        (const Id!ConstDecl c) => c,
        (_) => Id!ConstDecl.init,
    );
    if (!id.isValid)
    {
        throw new AssertError(format("`%s` #1 isn't a constant", name), file, line);
    }
    auto actualType = a.analysis.types.describe(a.analysis.typeOf(id));
    if (actualType != type)
    {
        throw new AssertError(format("`%s` has type %s, expected %s", name, actualType, type), file, line);
    }
    auto value = a.analysis.valueOf(id);
    if (!value.has!(const T) || value.get!(const T) != expected)
    {
        throw new AssertError(format("`%s` is %s, expected %s", name, value, expected), file, line);
    }
}

private Analyzed analyzedConstants(string declarations)
{
    return analyzed(declarations ~ "\ndef main(): Unit => ()");
}

@("type checking gives a constant its annotated type, wherever it's used")
unittest
{
    auto a = analyzed("val limit: UInt8 = 255\ndef main(): Unit {\n    val x = limit\n    printl(x)\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("limit", 2, "UInt8");
    a.shouldEvaluateTo("limit", ConstUInt(255), "UInt8");
}

@("a constant evaluates to the value of each primitive type")
unittest
{
    auto a = analyzedConstants(`val b: Bool = true
val i: Int = 1
val u: UInt = 18446744073709551615
val f: Float = 1.5
val s: String = "text"
val n: Unit = ()`);
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("b", true, "Bool");
    a.shouldEvaluateTo("i", ConstInt(1), "Int");
    a.shouldEvaluateTo("u", ConstUInt(ulong.max), "UInt");
    a.shouldEvaluateTo("f", 1.5, "Float");
    a.shouldEvaluateTo("s", "text", "String");
    a.shouldEvaluateTo("n", ConstUnit(), "Unit");
}

@("a String constant can be built with `~`, keeping every byte")
unittest
{
    auto a = analyzedConstants(`val first: String = "sil"
val whole: String = first ~ "ver" ~ ""
val nul: String = "a\0" ~ "b"
val empty: String = "" ~ ""`);
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("whole", "silver", "String");
    a.shouldEvaluateTo("nul", "a\0b", "String");
    a.shouldEvaluateTo("empty", "", "String");
}

@("String constants compare by unsigned bytes, then length")
unittest
{
    auto a = analyzedConstants(`val less: Bool = "a" < "b"
val notLess: Bool = "b" < "a"
val prefix: Bool = "app" < "apple"
val atMost: Bool = "a" <= "a"
val atLeast: Bool = "a" >= "b"
val greater: Bool = "é" > "z"
val nul: Bool = "a\0b" == "a\0c"`);
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("less", true, "Bool");
    a.shouldEvaluateTo("notLess", false, "Bool");
    a.shouldEvaluateTo("prefix", true, "Bool");
    a.shouldEvaluateTo("atMost", true, "Bool");
    a.shouldEvaluateTo("atLeast", false, "Bool");
    a.shouldEvaluateTo("greater", true, "Bool");
    a.shouldEvaluateTo("nul", false, "Bool");
}

@("a literal initializer adapts to the constant's type, and is range-checked against it")
unittest
{
    auto a = analyzedConstants("val limit: UInt8 = 255\nval low: Int8 = -128\nval min: Int = -9223372036854775808\nval whole: Float = 3\nval signed: Float = -3");
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("limit", ConstUInt(255), "UInt8");
    a.shouldEvaluateTo("low", ConstInt(-128), "Int8");
    a.shouldEvaluateTo("min", ConstInt(long.min), "Int");
    a.shouldEvaluateTo("whole", 3.0, "Float");
    a.shouldEvaluateTo("signed", -3.0, "Float");

    analyzedConstants("val x: UInt8 = 256").shouldReport(DiagnosticCode.LiteralOutOfRange, At("256", 1));
    analyzedConstants("val x: Int8 = 128").shouldReport(DiagnosticCode.LiteralOutOfRange, At("128", 1));
    analyzedConstants("val x: Int8 = -129").shouldReport(DiagnosticCode.LiteralOutOfRange, At("129", 1));
    analyzedConstants("val x: UInt8 = -1").shouldReport(DiagnosticCode.LiteralOutOfRange, At("1", 1));
    analyzedConstants("val x: Int = 99999999999999999999").shouldReport(DiagnosticCode.LiteralOutOfRange, At("99999999999999999999", 1));
}

@("literal arithmetic doesn't adapt to a constant's type, and values never convert")
unittest
{
    analyzedConstants("val x: UInt8 = 1 + 2").shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
    analyzedConstants("val x: Float = 7 / 2").shouldReport(DiagnosticCode.TypeMismatch, At("7", 1));
    analyzedConstants("val a: Int = 1\nval b: UInt8 = a").shouldReport(DiagnosticCode.TypeMismatch, At("a", 2));
    analyzedConstants(`val x: Int = "text"`).shouldReport(DiagnosticCode.TypeMismatch, At(`"text"`, 1));
    analyzedConstants("val x: Bool = !1").shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
}

@("a literal beside a constant takes its type")
unittest
{
    auto a = analyzedConstants("val m: UInt8 = 200\nval sum: UInt8 = m + 55\nval d: Float = 1.0 / 4");
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("sum", ConstUInt(255), "UInt8");
    a.shouldEvaluateTo("d", 0.25, "Float");
}

@("a constant may name another, in any order, and across modules")
unittest
{
    auto a = analyzed("import lib.values\nval total: Int = doubled + lib.values.base\nval doubled: Int = base * 2\ndef main(): Unit => ()",
        ["lib/values.ag": "module lib.values\nval base: Int = 21"]);
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("total", ConstInt(63), "Int");
}

@("an initializer must be a constant expression")
unittest
{
    void shouldBeNonConstant(string initializer, At at, string file = __FILE__, size_t line = __LINE__)
    {
        analyzed("type Point(x: Int)\ntype Marker\ndef f(): Int => 1\nval k: Int = 1\nval x: Int = "
                ~ initializer ~ "\ndef main(): Unit => ()")
            .shouldReport(DiagnosticCode.NonConstantInitializer, at, file, line);
    }

    shouldBeNonConstant("f()", At("f", 2));
    shouldBeNonConstant("f", At("f", 2));
    shouldBeNonConstant("Int8(1)", At("Int8", 1));
    shouldBeNonConstant("Point(1)", At("Point", 2));
    shouldBeNonConstant("Marker", At("Marker", 2));
    shouldBeNonConstant("if true => 1 else 2", At("if", 1));
    shouldBeNonConstant("{ 1 }", At("{", 1));
    shouldBeNonConstant("{ val y = 1\ny }", At("{", 1));
    shouldBeNonConstant("{ return 1 }", At("{", 1));
    shouldBeNonConstant("while false { }", At("while", 1));
    shouldBeNonConstant("k.field", At("k", 2));
    shouldBeNonConstant("Point(1).x", At("Point", 2));
    shouldBeNonConstant("1 + f()", At("f", 2));
    shouldBeNonConstant("-f()", At("f", 2));
}

@("a constant that names itself is a cycle, reported once at the use")
unittest
{
    analyzedConstants("val a: Int = a").shouldReport(DiagnosticCode.ConstantCycle, At("a", 2));
    analyzedConstants("val a: Int = a + a").shouldReport(DiagnosticCode.ConstantCycle, At("a", 2));
}

@("two constants naming each other are a cycle, reported once at the use that closes it")
unittest
{
    analyzedConstants("val a: Int = b\nval b: Int = a").shouldReport(DiagnosticCode.ConstantCycle, At("a", 2));
    analyzedConstants("val a: Int = b + 1\nval b: Int = c\nval c: Int = a")
        .shouldReport(DiagnosticCode.ConstantCycle, At("a", 2));

    // `c` closes two different cycles here, each of which needs fixing.
    assert(analyzedConstants("val a: Int = b\nval b: Int = c\nval c: Int = a + b").collector.diagnostics.length == 2);
}

@("a cycle can run through modules")
unittest
{
    analyzed("import a\ndef main(): Unit => ()", [
        "a.ag": "module a\nimport b\nval y: Int = b.z",
        "b.ag": "module b\nimport a\nval z: Int = a.y",
    ]).shouldReport(DiagnosticCode.ConstantCycle, At("a", 2, "b"));
}

@("a short-circuited operand can't hide a cycle, or a failure in a constant it names")
unittest
{
    analyzedConstants("val a: Bool = false && a").shouldReport(DiagnosticCode.ConstantCycle, At("a", 2));
    analyzedConstants("val a: Bool = true || b\nval b: Bool = 1 / 0 == 0")
        .shouldReport(DiagnosticCode.ConstantEvaluationFailed, At("1", 1));
}

@("a short-circuited operand isn't evaluated, as at runtime")
unittest
{
    auto a = analyzedConstants("val p: Bool = false && 1 / 0 == 0\nval q: Bool = true || 1 / 0 == 0\nval r: Bool = true && false\nval s: Bool = false || true");
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("p", false, "Bool");
    a.shouldEvaluateTo("q", true, "Bool");
    a.shouldEvaluateTo("r", false, "Bool");
    a.shouldEvaluateTo("s", true, "Bool");
}

@("arithmetic in an initializer that would panic at runtime is a compile-time error")
unittest
{
    void shouldFail(string declarations, At at, string file = __FILE__, size_t line = __LINE__)
    {
        analyzedConstants(declarations).shouldReport(DiagnosticCode.ConstantEvaluationFailed, at, file, line);
    }

    shouldFail("val x: Int = 9223372036854775807 + 1", At("9223372036854775807", 1));
    shouldFail("val x: Int = 4611686018427387904 * 2", At("4611686018427387904", 1));
    shouldFail("val m: Int8 = 127\nval x: Int8 = m + 1", At("m", 2));
    shouldFail("val m: Int8 = 127\nval x: Int8 = m * 2", At("m", 2));
    shouldFail("val m: UInt8 = 0\nval x: UInt8 = m - 1", At("m", 2));
    shouldFail("val m: UInt = 18446744073709551615\nval x: UInt = m + 1", At("m", 2));
    shouldFail("val x: Int = 1 / 0", At("1", 1));
    shouldFail("val x: Int = 1 % 0", At("1", 1));
    shouldFail("val m: Int8 = -128\nval x: Int8 = m / -1", At("m", 2));
    shouldFail("val m: Int8 = -128\nval x: Int8 = m % -1", At("m", 2));
    shouldFail("val m: Int = -9223372036854775808\nval x: Int = m / -1", At("m", 2));
    shouldFail("val m: Int8 = -128\nval x: Int8 = -m", At("-m", 1));
    shouldFail("val x: Int = 1 << 64", At("1", 1));
    shouldFail("val x: Int = 1 >> 64", At("1", 1));
    shouldFail("val x: Int = 1 << -1", At("1", 1));
    shouldFail("val m: UInt8 = 1\nval x: UInt8 = m << 8", At("m", 2));
}

@("a constant that failed only reports where it failed, not where it's used")
unittest
{
    analyzedConstants("val a: Int = 1 / 0\nval b: Int = a + 1\nval c: Int = b").shouldReport(
        DiagnosticCode.ConstantEvaluationFailed, At("1", 1));
    analyzedConstants("val a: Int = nope\nval b: Int = a + 1").shouldReport(DiagnosticCode.UnknownName, At("nope", 1));
}

@("a lambda's parameter types come from the annotation or the context")
unittest
{
    auto a = analyzedMain(`val f = (x: Int) => x + 1
    val g: (Int) -> Int = x => x + 1
    val h: ((Int) -> Int)? = x => x`);
    a.shouldHaveNoDiagnostics();
    a.shouldTypeEveryExpression();
    a.shouldDeclareType(At("f", 1), "(Int) -> Int");

    analyzedMain(`val f = x => x`).shouldReport(DiagnosticCode.UntypedLambdaParameter, At("x", 1));
    analyzedMain(`val f = (x, y: Int) => y`).shouldReport(DiagnosticCode.UntypedLambdaParameter, At("x", 1));
    analyzedMain(`val f: (Int) -> Int = (x, y) => x`).shouldReport(DiagnosticCode.TypeMismatch, At("(x, y) => x", 1));
    analyzedMain(`val f: (Int) -> Int = (x: String) => 1`).shouldReport(DiagnosticCode.TypeMismatch, At("(x: String) => 1", 1));
    analyzedMain(`val f: (mutable Int) -> Int = x => x`).shouldReport(DiagnosticCode.TypeMismatch, At("x => x", 1));
}

@("a lambda's return type is the common type of what it returns")
unittest
{
    auto a = analyzedMain(`val f = (x: Int) => {
        if x > 0 { return None }
        x
    }
    val g = (x: Int?) => x?`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("f", 1), "(Int) -> Int?");
    a.shouldDeclareType(At("g", 1), "(Int?) -> Int?");

    analyzedMain(`val f = (x: Int) => {
        if x > 0 { return "a" }
        x
    }`).shouldReport(DiagnosticCode.TypeMismatch, At("{\n        if", 1));
    analyzedMain(`val f = () => None`).shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain(`val f = (x: Int): String => x`).shouldReport(DiagnosticCode.TypeMismatch, At("x", 2));
    analyzedMain(`val f = (x: Int?): Int => x?`).shouldReport(DiagnosticCode.InvalidPropagation, At("x?", 1));
}

@("a lambda can't jump out to a loop around it")
unittest
{
    analyzedMain(`while true {
        val f = () => { break }
    }`).shouldReport(DiagnosticCode.JumpOutsideLoop, At("break", 1));
}

@("a lambda can capture what's immutable and nothing else")
unittest
{
    analyzedMain(`val a = 1
    val f = () => a`).shouldHaveNoDiagnostics();
    analyzedMain(`mutable val a = 1
    val f = () => a`).shouldReport(DiagnosticCode.CapturedMutable, At("a", 2));
    analyzedMain(`mutable val a = 1
    val f = () => () => a`).shouldReport(DiagnosticCode.CapturedMutable, At("a", 2));
    analyzedMain(`mutable val a = 1
    def f(): Int => a`).shouldReport(DiagnosticCode.CapturedMutable, At("a", 2));
    analyzedMain(`val f = (mutable x: Int) => () => x`).shouldReport(DiagnosticCode.CapturedMutable, At("x", 2));
    analyzedMain(`val f = () => {
        mutable val own = 1
        own += 1
        own
    }`).shouldHaveNoDiagnostics();
}

@("a nested function sees itself and what's before it, follows the shadowing rules, and can't be native")
unittest
{
    analyzedMain(`def f(n: Int): Int => if n == 0 => 0 else f(n - 1)
    print(f(1))`).shouldHaveNoDiagnostics();
    analyzedMain(`print(g())
    def g(): Int => 1`).shouldReport(DiagnosticCode.UnknownName, At("g", 1));
    analyzedMain(`val x = 1
    val f = (x: Int) => x`).shouldReport(DiagnosticCode.ShadowedDeclaration, At("x", 2));
    analyzedMain(`val f = () => f()`).shouldReport(DiagnosticCode.UnknownName, At("f", 2));
    analyzedMain(`def f(): Int => 1
    def f(): Int => 2`).shouldReport(DiagnosticCode.DuplicateDeclaration, At("f", 2));
    analyzedMain(`native def f(): Int`).shouldReport(DiagnosticCode.InternalError, At("f", 1));
}

@("a shift amount can be any integer type, and the result has the type of the value shifted")
unittest
{
    auto a = analyzedMain(`val n: UInt8 = 2
    val byte: UInt8 = 1
    val wide: Int64 = 1
    val literal = 1 << n
    val narrow = byte << wide
    val adapted = byte << 3`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("literal", 1), "Int");
    a.shouldDeclareType(At("narrow", 1), "UInt8");
    a.shouldDeclareType(At("adapted", 1), "UInt8");

    analyzedMain(`print(1 << 1.0)`).shouldReport(DiagnosticCode.InvalidOperand, At("1.0", 1));

    auto c = analyzedConstants(`val amount: UInt8 = 4
val shifted: Int = 1 << amount
val narrow: UInt8 = 0xF0
val back: UInt8 = narrow >> amount`);
    c.shouldHaveNoDiagnostics();
    c.shouldEvaluateTo("shifted", ConstInt(16), "Int");
    c.shouldEvaluateTo("back", ConstUInt(15), "UInt8");
}

@("wrapping operators and shifts in an initializer use the checked type's width and signedness")
unittest
{
    auto a = analyzedConstants(`val umax: UInt8 = 255
val imax: Int8 = 127
val imin: Int8 = -128
val addedU: UInt8 = umax +% 1
val addedI: Int8 = imax +% 1
val subbedU: UInt8 = 0 -% umax
val subbedI: Int8 = imin -% 1
val timesU: UInt8 = umax *% umax
val timesI: Int8 = imax *% 2
val leftU: UInt8 = umax << 4
val leftI: Int8 = imax << 1
val rightU: UInt8 = umax >> 4
val rightI: Int8 = imin >> 2
val notU: UInt8 = ~umax
val notI: Int8 = ~imax
val wide: Int = 9223372036854775807 +% 1`);
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("addedU", ConstUInt(0), "UInt8");
    a.shouldEvaluateTo("addedI", ConstInt(-128), "Int8");
    a.shouldEvaluateTo("subbedU", ConstUInt(1), "UInt8");
    a.shouldEvaluateTo("subbedI", ConstInt(127), "Int8");
    a.shouldEvaluateTo("timesU", ConstUInt(1), "UInt8");
    a.shouldEvaluateTo("timesI", ConstInt(-2), "Int8");
    a.shouldEvaluateTo("leftU", ConstUInt(240), "UInt8");
    a.shouldEvaluateTo("leftI", ConstInt(-2), "Int8");
    a.shouldEvaluateTo("rightU", ConstUInt(15), "UInt8");
    a.shouldEvaluateTo("rightI", ConstInt(-32), "Int8");
    a.shouldEvaluateTo("notU", ConstUInt(0), "UInt8");
    a.shouldEvaluateTo("notI", ConstInt(-128), "Int8");
    a.shouldEvaluateTo("wide", ConstInt(long.min), "Int");
}

@("Float and comparison operators evaluate as they do at runtime")
unittest
{
    auto a = analyzedConstants(`val rest: Float = 5.5 % 2
val low: Bool = 1 < 2
val eq: Bool = "a" == "b"
val ne: Bool = "a" != "b"
val units: Bool = () == ()
val flags: Bool = true != false
val negated: Bool = !true
val nanEq: Bool = 0.0 / 0.0 == 0.0 / 0.0
val trunc: Int = -7 / 2
val rem: Int = -7 % 2`);
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("rest", 1.5, "Float");
    a.shouldEvaluateTo("low", true, "Bool");
    a.shouldEvaluateTo("eq", false, "Bool");
    a.shouldEvaluateTo("ne", true, "Bool");
    a.shouldEvaluateTo("units", true, "Bool");
    a.shouldEvaluateTo("flags", true, "Bool");
    a.shouldEvaluateTo("negated", false, "Bool");
    a.shouldEvaluateTo("nanEq", false, "Bool");
    a.shouldEvaluateTo("trunc", ConstInt(-3), "Int");
    a.shouldEvaluateTo("rem", ConstInt(-1), "Int");

    // Dividing Floats by zero doesn't panic, and -0 keeps its sign.
    auto b = analyzed(`val up: Float = 1.0 / 0.0
val zero: Float = -0
def main(): Unit => ()`);
    b.shouldHaveNoDiagnostics();
    b.shouldEvaluateTo("zero", -0.0, "Float");
    b.shouldEvaluateTo("up", double.infinity, "Float");
}

@("a constant can't be assigned to")
unittest
{
    analyzed("val x: Int = 1\ndef main(): Unit {\n    x = 2\n}")
        .shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("x", 2));
    analyzed("import a\ndef main(): Unit {\n    a.x = 2\n}", ["a.ag": "module a\nval x: Int = 1"])
        .shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("a", 2));
}

// String interpolation and `String(x)`

@("an interpolated string is a String, whatever its holes hold")
unittest
{
    auto a = analyzedMain(`val n: UInt8 = 1
    val s = "a{n}b{"c"}{()}{1.5}{n > 0}"
    val t: String = "{s}"
    printl(t)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType(`"{s}"`, "String");
    a.shouldHaveType("n > 0", "Bool");
}

@("a hole's expression is resolved and checked like any other")
unittest
{
    analyzedMain(`printl("a{nope}")`).shouldReport(DiagnosticCode.UnknownName, At("nope", 1));
    analyzedMain(`printl("{1 + true}")`).shouldReport(DiagnosticCode.InvalidOperand, At("true", 1));
    analyzedMain(`val x: Int = "{1}"`).shouldReport(DiagnosticCode.TypeMismatch, At(`"{1}"`, 1));
    analyzedMain(`printl("{99999999999999999999}")`)
        .shouldReport(DiagnosticCode.LiteralOutOfRange, At("99999999999999999999", 1));
}

@("String(x) takes one value of any type")
unittest
{
    auto a = analyzedMain(`val n: UInt8 = 1
    val b = String(n)
    val c = String(1)
    val d = String("s")
    val e = String(())
    printl(b ~ c ~ d ~ e)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("String(n)", "String");
    a.shouldHaveType("String(1)", "String");

    analyzedMain("printl(String())").shouldReport(DiagnosticCode.WrongArgumentCount, At("String()", 1));
    analyzedMain("printl(String(1, 2))").shouldReport(DiagnosticCode.WrongArgumentCount, At("String(1, 2)", 1));
    analyzedMain("val f = String").shouldReport(DiagnosticCode.UnknownName, At("String", 1));
}

@("a constant can interpolate other constants, formatted as the backends format them")
unittest
{
    auto a = analyzedConstants(`val major: UInt8 = 2
val ratio: Float = 1.5
val ok: Bool = true
val nothing: Unit = ()
val name: String = "silver"
val text: String = "{name} v{major}.{1 + 1} {ratio} {ok} {nothing} {-1}"`);
    a.shouldHaveNoDiagnostics();
    a.shouldEvaluateTo("text", "silver v2.2 1.5 true () -1", "String");

    analyzedConstants(`val a: String = "{b}"` ~ "\n" ~ `val b: String = "{a}"`)
        .shouldReport(DiagnosticCode.ConstantCycle, At("a", 2));
    analyzedConstants(`val a: String = "{1 / 0}"`).shouldReport(DiagnosticCode.ConstantEvaluationFailed, At("1 / 0", 1));
    analyzed("def f(): Int => 1\n" ~ `val a: String = "{f()}"` ~ "\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.NonConstantInitializer, At("f", 2));
    analyzedConstants(`val a: String = String(1)`).shouldReport(DiagnosticCode.NonConstantInitializer, At("String", 2));
}

@("an array literal takes its element type from what it's checked against, or joins its elements")
unittest
{
    auto a = analyzedMain(`val bytes: [UInt8] = [1, 2]
    val some = [Some(1), None]
    val nested = [[], [1]]
    val wrapped: [UInt8]? = [1]
    val branch: [UInt8] = if true => [1] else []`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("bytes", 1), "[UInt8]");
    a.shouldDeclareType(At("some", 1), "[Int?]");
    a.shouldDeclareType(At("nested", 1), "[[Int]]");
    a.shouldDeclareType(At("wrapped", 1), "[UInt8]?");

    analyzedMain(`val x = [1, 2.0]`).shouldReport(DiagnosticCode.TypeMismatch, At("2.0", 1));
    analyzedMain(`val x: [UInt8] = [256]`).shouldReport(DiagnosticCode.LiteralOutOfRange, At("256", 1));
}

@("a [] or [None] with nothing to take a type from says to annotate")
unittest
{
    analyzedMain(`val x = []`).shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 1));
    analyzedMain(`print([])`).shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 1));
    analyzedMain(`print("{[]}")`).shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 1));
    analyzedMain(`print([] == [])`).shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 1));
    analyzedMain(`print([] ~ [])`).shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 1));
    analyzedMain(`print(length([]))`).shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 1));
    analyzedMain(`val x = [None]`).shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
}

@("an array can't hold Any")
unittest
{
    analyzed("def f(x: [Any]): Unit => ()\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidArrayElement, At("[Any]", 1));
}

@("indexing takes any integer and only applies to arrays, and a slice keeps the array's type")
unittest
{
    auto a = analyzedMain(`val xs = ["a"]
    val one = xs[0]
    val some = xs[0..1]`);
    a.shouldHaveNoDiagnostics();
    a.shouldTypeEveryExpression();
    a.shouldDeclareType(At("one", 1), "String");
    a.shouldDeclareType(At("some", 1), "[String]");

    analyzedMain(`val i: UInt8 = 0
    val j: Int16 = 1
    print([1][i])
    print([1][i..j])`).shouldHaveNoDiagnostics();
    analyzedMain(`val f = 1.0
    print([1][f])`).shouldReport(DiagnosticCode.TypeMismatch, At("f", 2));
    analyzedMain(`print([1][0.."a"])`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
    analyzedMain(`print("abc"[0])`).shouldReport(DiagnosticCode.InvalidOperand, At(`"abc"`, 1));
    analyzedMain(`print(length("abc"))`).shouldReport(DiagnosticCode.TypeMismatch, At(`"abc"`, 1));
}

@("an array's elements can't be assigned, even on a mutable val")
unittest
{
    analyzedMain(`mutable val xs = [1]
    xs[0] = 2`).shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("xs[0]", 1));
    analyzedMain(`mutable val xs = [1]
    xs[0] += 2`).shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("xs[0]", 1));
}

@("~ joins two of the same array or String, and never takes a bare element")
unittest
{
    auto a = analyzedMain(`val bytes: [UInt8] = [1]
    val left = bytes ~ [2]
    val right = [2] ~ bytes
    val chain = [1] ~ [2] ~ bytes
    val empty = bytes ~ []`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("left", 1), "[UInt8]");
    a.shouldDeclareType(At("right", 1), "[UInt8]");
    a.shouldDeclareType(At("chain", 1), "[UInt8]");
    a.shouldDeclareType(At("empty", 1), "[UInt8]");

    analyzedMain(`print([1] ~ 2)`).shouldReport(DiagnosticCode.InvalidOperand, At("2", 1));
    analyzedMain(`print([[1]] ~ [1])`).shouldReport(DiagnosticCode.TypeMismatch, At("1", 2));
    analyzedMain(`val a = [1]
    val b = ["a"]
    print(a ~ b)`).shouldReport(DiagnosticCode.InvalidOperand, At("a ~ b", 1));
    analyzedMain(`print("a" ~ [1])`).shouldReport(DiagnosticCode.InvalidOperand, At(`"a" ~ [1]`, 1));
}

@("~= needs a mutable array or String, and the same type on the right")
unittest
{
    analyzedMain(`mutable val xs: [UInt8] = []
    xs ~= [255]
    mutable val s = "a"
    s ~= "b"`).shouldHaveNoDiagnostics();

    analyzedMain(`val xs = [1]
    xs ~= [2]`).shouldReport(DiagnosticCode.AssignToImmutable, At("xs", 2));
    analyzedMain(`mutable val xs = [1]
    xs ~= 2`).shouldReport(DiagnosticCode.InvalidOperand, At("2", 1));
    analyzedMain(`mutable val x = 1
    x ~= [2]`).shouldReport(DiagnosticCode.InvalidOperand, At("x", 2));
}

@("arrays compare when their elements do, and have no order")
unittest
{
    analyzedMain(`val xs = [1]
    print(xs == [1])
    print([1] != xs)
    print(xs == [])`).shouldHaveNoDiagnostics();
    analyzedMain(`print([1] < [2])`).shouldReport(DiagnosticCode.InvalidOperand, At("[1]", 1));
    analyzed("def f(): Unit => ()\ndef main(): Unit => print([f] == [f])")
        .shouldReport(DiagnosticCode.InvalidOperand, At("[f] == [f]", 1));
}

@("while val needs an option, and its binding is only in scope in the body")
unittest
{
    auto a = analyzedMain(`val opt: String? = None
    while val line = opt {
        print(line)
    }
    while val line = opt { }`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("line", 2, "String");

    analyzedMain(`while val x = 1 { }`).shouldReport(DiagnosticCode.InvalidOperand, At("1", 1));
    analyzedMain(`while val x = None { }`).shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain(`val o: Int? = None
    while val x = o { }
    print(x)`).shouldReport(DiagnosticCode.UnknownName, At("x", 2));
    analyzedMain(`val x: Int? = None
    while val x = x { }`).shouldReport(DiagnosticCode.ShadowedDeclaration, At("x", 2));
}

@("for takes an array, binding its elements, and its binding is only in scope in the body")
unittest
{
    auto a = analyzedMain(`val xs: [Int?] = [1, None]
    for x in xs {
        print(x)
    }
    for x in ["a"] {
        print(x)
    }
    for y in [[1]] {
        print(y)
    }
    val u = for z in xs { z }
    print(u)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("x", 2, "Int?");
    a.shouldHaveType("x", 4, "String");
    a.shouldHaveType("y", 2, "[Int]");
    a.shouldHaveType("u", 2, "Unit");

    analyzedMain(`for x in 1 { }`).shouldReport(DiagnosticCode.InvalidOperand, At("1", 1));
    analyzedMain(`for c in "abc" { }`).shouldReport(DiagnosticCode.InvalidOperand, At(`"abc"`, 1));
    analyzedMain(`val o: [Int]? = None
    for x in o { }`).shouldReport(DiagnosticCode.InvalidOperand, At("o", 2));
    analyzedMain(`for x in [] { }`).shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 1));
    analyzedMain(`for x in [1] { }
    print(x)`).shouldReport(DiagnosticCode.UnknownName, At("x", 2));
    analyzedMain(`val x = [1]
    for x in x { }`).shouldReport(DiagnosticCode.ShadowedDeclaration, At("x", 2));
    analyzedMain(`for x in [1] {
        val x = 2
    }`).shouldReport(DiagnosticCode.ShadowedDeclaration, At("x", 2));
    analyzedMain(`for x in [1] {
        x = 2
    }`).shouldReport(DiagnosticCode.AssignToImmutable, At("x", 2));
    analyzedMain(`for _ in [1] { }
    for _ in [2] { }`).shouldHaveNoDiagnostics();
}

@("a for range takes integers of one type, and a literal adapts to the number beside it")
unittest
{
    auto a = analyzedMain(`val small: UInt8 = 3
    for i in 0..small {
        print(i)
    }
    for j in small..10 {
        print(j)
    }
    for k in 0..3 {
        print(k)
    }`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("i", 2, "UInt8");
    a.shouldHaveType("j", 2, "UInt8");
    a.shouldHaveType("k", 2, "Int");
    a.shouldHaveType("0", 1, "UInt8");

    analyzedMain(`for i in 0.0..1.0 { }`).shouldReport(DiagnosticCode.InvalidOperand, At("0.0..1.0", 1));
    analyzedMain(`for i in "a".."b" { }`).shouldReport(DiagnosticCode.InvalidOperand, At(`"a".."b"`, 1));
    analyzedMain(`val a: Int8 = 1
    val b: Int16 = 2
    for i in a..b { }`).shouldReport(DiagnosticCode.TypeMismatch, At("a..b", 1));
    analyzedMain(`val a: UInt8 = 1
    for i in a..300 { }`).shouldReport(DiagnosticCode.LiteralOutOfRange, At("300", 1));
    analyzedMain(`val r = 0..3`).shouldReport(DiagnosticCode.NotSupportedYet, At("0..3", 1));
    analyzedMain(`for i in { 0..3 } { }`).shouldReport(DiagnosticCode.NotSupportedYet, At("0..3", 1));
}

@("break and continue need the body of a loop, and have type Never")
unittest
{
    analyzedMain(`while true {
        break
        continue
    }
    for x in [1] {
        if x == 1 { continue }
        val y: Int = if x == 2 { 1 } else { break }
        print(y)
    }`).shouldHaveNoDiagnostics();

    analyzedMain(`break`).shouldReport(DiagnosticCode.JumpOutsideLoop, At("break", 1));
    analyzedMain(`continue`).shouldReport(DiagnosticCode.JumpOutsideLoop, At("continue", 1));
    analyzedMain(`if true { break }`).shouldReport(DiagnosticCode.JumpOutsideLoop, At("break", 1));

    // A condition and what a `for` loops over are outside the loop's body.
    analyzedMain(`while { break
        true } { }`).shouldReport(DiagnosticCode.JumpOutsideLoop, At("break", 1));
    analyzedMain(`for x in { continue
        [1] } { }`).shouldReport(DiagnosticCode.JumpOutsideLoop, At("continue", 1));
    analyzedMain(`for i in 0..{ break
        3 } { }`).shouldReport(DiagnosticCode.JumpOutsideLoop, At("break", 1));
    analyzedMain(`while true {
        while { break
            true } { }
    }`).shouldHaveNoDiagnostics();
}

@("a non-final expression statement that isn't Unit is an error")
unittest
{
    analyzedMain(`1
    print(2)`).shouldReport(DiagnosticCode.UnusedValue, At("1", 1));
    analyzed("def f(): Int => 1\ndef main(): Unit {\n    f()\n    print(2)\n}")
        .shouldReport(DiagnosticCode.UnusedValue, At("f()", 2));
    analyzedMain(`None
    print(2)`).shouldReport(DiagnosticCode.UnusedValue, At("None", 1));
    analyzedMain(`if true => 1 else 2
    print(2)`).shouldReport(DiagnosticCode.UnusedValue, At("if true => 1 else 2", 1));
    analyzedMain(`val x = 2
    val y = x
    - 1
    print(y)`).shouldReport(DiagnosticCode.UnusedValue, At("- 1", 1));
}

@("a block's last expression is its value, and a Unit position still drops one")
unittest
{
    analyzed(`def f(): Int => 1
def g(): Unit { f() }
def h(): Unit => f()
def main(): Unit {
    print(1)
    if true { f() }
    if true => print(1) else print(2)
    while false { f() }
    val a = { print(1); 1 }
    f()
}`).shouldHaveNoDiagnostics();
    analyzed(`def f(): Int {
    return 1
}
def g(x: Int?): Unit? {
    { return None }
    ()
}
def main(): Unit => ()`).shouldHaveNoDiagnostics();
}

@("a discard evaluates its value and declares nothing")
unittest
{
    analyzedMain(`_ = 1
    _ = 2
    val _ = 3
    val _ = None
    _ = []
    val _: UInt8 = 255`).shouldHaveNoDiagnostics();

    // It still checks what's there.
    analyzedMain(`val _: UInt8 = 256`).shouldReport(DiagnosticCode.LiteralOutOfRange, At("256", 1));
    analyzedMain(`_ = nope`).shouldReport(DiagnosticCode.UnknownName, At("nope", 1));
    analyzedMain(`_ = [None]`).shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain(`while val _ = 1 { }`).shouldReport(DiagnosticCode.InvalidOperand, At("1", 1));
}

@("a tuple literal synthesizes each element, and its type is the element types in order")
unittest
{
    auto a = analyzedMain(`val t = (1, "a")
    val n = ((1, 2.0), true, ())
    val s = (Some(1), [1])`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("t", 1), "(Int, String)");
    a.shouldDeclareType(At("n", 1), "((Int, Float), Bool, Unit)");
    a.shouldDeclareType(At("s", 1), "(Int?, [Int])");
}

@("a tuple literal takes its element types from what it's checked against")
unittest
{
    auto a = analyzed(`def pair(): (UInt8, Int?) => (1, None)
def main(): Unit {
    val t: (UInt8, Int?) = (2, 3)
    val o: (Int, Int)? = (4, 5)
    val ts: [(UInt8, Bool)] = [(6, true)]
    val c: (UInt8, Int?) = if true => (7, None) else { (8, 9) }
}`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("1", "UInt8");
    a.shouldHaveType("None", "None");
    a.shouldHaveType("(2, 3)", "(UInt8, Int?)");
    a.shouldHaveType("3", "Int");
    a.shouldHaveType("(4, 5)", "(Int, Int)");
    a.shouldHaveType("6", "UInt8");
    a.shouldHaveType("8", "UInt8");
}

@("a tuple of one type is the same type wherever it's written")
unittest
{
    analyzed(`def pair(): (Int, String) => (1, "a")
def first(p: (Int, String)): Int {
    val (n, _) = p
    n
}
def main(): Unit {
    val p: (Int, String) = pair()
    _ = first(p) + first((2, "b"))
}`).shouldHaveNoDiagnostics();
    analyzedMain(`val p: (Int, String) = (1, 2)`).shouldReport(DiagnosticCode.TypeMismatch, At("2", 1));
    analyzedMain(`val p: (Int, Int) = (1, 2, 3)`).shouldReport(DiagnosticCode.TypeMismatch, At("(1, 2, 3)", 1));
}

@("a tuple value never converts, though a literal's elements adapt and promote")
unittest
{
    analyzedMain(`val a = (1, 2)
    val b: (Int, Int?) = a`).shouldReport(DiagnosticCode.TypeMismatch, At("a", 2));
    analyzedMain(`val b: (Int, Int?) = (1, 2)`).shouldHaveNoDiagnostics();
}

@("a tuple element with nothing to take a type from says to annotate, and Any isn't one")
unittest
{
    analyzedMain(`val t = (1, None)`).shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedMain(`val t = ([], 1)`).shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 1));
    analyzed(`def f(t: (Any, Int)): Unit => ()
def main(): Unit => ()`).shouldReport(DiagnosticCode.InvalidTupleElement, At("Any", 1));
}

@("tuples compare elementwise when every element can, and have no order")
unittest
{
    auto a = analyzedMain(`val t: (UInt8, Int?) = (1, None)
    _ = t == (2, Some(3))
    _ = (2, 3) != t`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("2", 1, "UInt8");
    a.shouldHaveType("2", 2, "UInt8");
    analyzed(`def f(): Unit => ()
def main(): Unit {
    _ = (f, 1) == (f, 1)
}`).shouldReport(DiagnosticCode.InvalidOperand, At("(f, 1) == (f, 1)", 1));
    analyzedMain(`_ = (1, 2) < (1, 3)`).shouldReport(DiagnosticCode.InvalidOperand, At("(1, 2)", 1));
}

@("a tuple literal against an option is checked against its payload and promoted")
unittest
{
    auto a = analyzedMain(`val t: (UInt8, Bool)? = (1, true)
    val u: (UInt8, Bool)? = None
    val v = u ?? (2, false)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("(1, true)", "(UInt8, Bool)");
    a.shouldDeclareType(At("v", 1), "(UInt8, Bool)");
}

@("destructuring binds each part of a tuple, element by element for a literal")
unittest
{
    auto a = analyzed(`def pair(): (Int, String) => (1, "a")
def main(): Unit {
    val (x, y) = pair()
    val (b: UInt8, c, _) = (2, Some(3), None)
    val ((d, e), f) = ((true, 1.5), pair())
    mutable val (g, h: Int?) = (4, 5)
    g = 6
    h = None
}`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("x", 1), "Int");
    a.shouldDeclareType(At("y", 1), "String");
    a.shouldDeclareType(At("b", 1), "UInt8");
    a.shouldHaveType("2", "UInt8");
    a.shouldDeclareType(At("c", 1), "Int?");
    a.shouldDeclareType(At("d", 1), "Bool");
    a.shouldDeclareType(At("e", 1), "Float");
    a.shouldDeclareType(At("f", 1), "(Int, String)");
    a.shouldDeclareType(At("h", 1), "Int?");
}

@("a fully annotated pattern checks its value against the pattern's type")
unittest
{
    auto a = analyzedMain(`val (x: UInt8, y: Int?) = if true => (1, 2) else (3, None)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("1", "UInt8");
    a.shouldHaveType("(1, 2)", "(UInt8, Int?)");
    analyzedMain(`val (x: Int, y: Int) = ("a", 1)`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
}

@("a part of a value that isn't a literal can only be annotated with its own type")
unittest
{
    analyzed(`def pair(): (Int, String) => (1, "a")
def main(): Unit {
    val (x: Int, y) = pair()
}`).shouldHaveNoDiagnostics();
    analyzed(`def pair(): (Int, String) => (1, "a")
def main(): Unit {
    val (x: Int?, y) = pair()
}`).shouldReport(DiagnosticCode.TypeMismatch, At("Int", 2));
}

@("a pattern has to fit the tuple it takes apart")
unittest
{
    analyzed(`def triple(): (Int, Int, Int) => (1, 2, 3)
def main(): Unit {
    val (x, y) = triple()
}`).shouldReport(DiagnosticCode.PatternMismatch, At("(x, y)", 1));
    analyzedMain(`val (x, y) = 1`).shouldReport(DiagnosticCode.PatternMismatch, At("(x, y)", 1));
    analyzedMain(`val ((x, y), z) = (1, 2)`).shouldReport(DiagnosticCode.PatternMismatch, At("(x, y)", 1));
    analyzedMain(`val (x, y) = (1, 2, 3)`).shouldReport(DiagnosticCode.PatternMismatch, At("(x, y)", 1));
}

@("a pattern's bindings follow the rules for locals")
unittest
{
    analyzedMain(`val (x, x) = (1, 2)`).shouldReport(DiagnosticCode.DuplicateDeclaration, At("x", 2));
    analyzedMain(`val x = 1
    val (x, y) = (1, 2)`).shouldReport(DiagnosticCode.DuplicateDeclaration, At("x", 2));
    analyzedMain(`val (x, y) = (1, x)`).shouldReport(DiagnosticCode.UnknownName, At("x", 2));
    analyzedMain(`val (x, y) = (1, 2)
    x = 3`).shouldReport(DiagnosticCode.AssignToImmutable, At("x", 2));
    analyzedMain(`val (_, _) = (None, [])`).shouldHaveNoDiagnostics();
}

@("a tuple isn't a constant")
unittest
{
    analyzed(`val t: (Int, Int) = (1, 2)
def main(): Unit => ()`).shouldReport(DiagnosticCode.InvalidConstantType, At("(Int, Int)", 1));
}

private enum stepper = `type Rng(state: Int)
type Game(rng: Rng, score: Int)
def step(mutable rng: Rng): Int {
    rng.state += 1
    rng.state
}
def add(mutable a: Int, mutable b: Int): Unit { a += b }
`;

@("a mutable parameter can be assigned, and its fields too")
unittest
{
    analyzed(stepper ~ "def main(): Unit { }").shouldHaveNoDiagnostics();
    analyzed("def f(mutable x: Int): Unit { x = 2 }\ndef main(): Unit { }").shouldHaveNoDiagnostics();
    analyzed("def f(x: Int): Unit { x = 2 }\ndef main(): Unit { }")
        .shouldReport(DiagnosticCode.AssignToImmutable, At("x", 2));
}

@("a mutable argument is a place")
unittest
{
    analyzed(stepper ~ `def main(): Unit {
    mutable val r = Rng(1)
    mutable val g = Game(r, 1)
    _ = step(mutable r)
    _ = step(mutable g.rng)
}`).shouldHaveNoDiagnostics();
    analyzed(stepper ~ "def pass(mutable r: Rng): Int => step(mutable r)\ndef main(): Unit { }").shouldHaveNoDiagnostics();
    analyzed(stepper ~ "def main(): Unit {\n    val r = Rng(1)\n    _ = step(mutable r)\n}")
        .shouldReport(DiagnosticCode.AssignToImmutable, At("r", 2));
    analyzed(stepper ~ "def pass(r: Rng): Int => step(mutable r)\ndef main(): Unit { }")
        .shouldReport(DiagnosticCode.AssignToImmutable, At("r", 2));
    analyzed(stepper ~ "def main(): Unit {\n    _ = step(mutable Rng(1))\n}")
        .shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("Rng(1)", 1));
    analyzed(stepper ~ "def main(): Unit {\n    mutable val rs = [Rng(1)]\n    _ = step(mutable rs[0])\n}")
        .shouldReport(DiagnosticCode.InvalidAssignmentTarget, At("rs[0]", 1));
}

@("a call says which arguments are mutable, as the function does")
unittest
{
    analyzed(stepper ~ "def main(): Unit {\n    mutable val r = Rng(1)\n    _ = step(r)\n}")
        .shouldReport(DiagnosticCode.MutabilityMismatch, At("r", 2));
    analyzed("def f(x: Int): Int => x\ndef main(): Unit {\n    mutable val r = 1\n    _ = f(mutable r)\n}")
        .shouldReport(DiagnosticCode.MutabilityMismatch, At("r", 2));
    analyzedMain("mutable val r = 1\n    _ = Int8(mutable r)").shouldReport(DiagnosticCode.MutabilityMismatch, At("r", 2));
    analyzedMain("mutable val r = [1]\n    _ = length(mutable r)").shouldReport(DiagnosticCode.MutabilityMismatch, At("r", 2));
    analyzedWithTypes("mutable val r = 1\n    _ = Point(mutable r, 2)").shouldReport(DiagnosticCode.MutabilityMismatch, At("r", 2));
}

@("a mutable argument has exactly the parameter's type")
unittest
{
    analyzed("def f(mutable x: Int?): Unit { }\ndef main(): Unit {\n    mutable val r = 1\n    f(mutable r)\n}")
        .shouldReport(DiagnosticCode.TypeMismatch, At("r", 2));
    analyzed("def f(mutable x: UInt8): Unit { }\ndef main(): Unit {\n    mutable val r = 1\n    f(mutable r)\n}")
        .shouldReport(DiagnosticCode.TypeMismatch, At("r", 2));
}

@("two mutable arguments of a call can't overlap")
unittest
{
    analyzed(stepper ~ "def main(): Unit {\n    mutable val a = 1\n    add(mutable a, mutable a)\n}")
        .shouldReport(DiagnosticCode.OverlappingWrites, At("a", 5));
    analyzed(stepper ~ `def both(mutable g: Game, mutable r: Rng): Unit { }
def main(): Unit {
    mutable val g = Game(Rng(1), 2)
    both(mutable g, mutable g.rng)
}`).shouldReport(DiagnosticCode.OverlappingWrites, At("g.rng", 1));
    analyzed(stepper ~ `def main(): Unit {
    mutable val g = Game(Rng(1), 2)
    add(mutable g.score, mutable g.rng.state)
}`).shouldHaveNoDiagnostics();
    analyzed(stepper ~ `def keep(snapshot: Int, mutable x: Int): Unit { }
def main(): Unit {
    mutable val a = 1
    keep(a, mutable a)
}`).shouldHaveNoDiagnostics();
}

@("mutability is part of a function's type")
unittest
{
    analyzed(stepper ~ `def main(): Unit {
    val f: (mutable Rng) -> Int = step
    mutable val r = Rng(1)
    _ = f(mutable r)
}`).shouldHaveNoDiagnostics();
    analyzed(stepper ~ "def main(): Unit {\n    val f: (Rng) -> Int = step\n}")
        .shouldReport(DiagnosticCode.TypeMismatch, At("step", 2));
}

@("a native or an intrinsic can't take a mutable parameter")
unittest
{
    analyzed("native def f(mutable x: Int): Unit\ndef main(): Unit { }")
        .shouldReport(DiagnosticCode.MutableNativeParameter, At("x", 1));
    analyzed("import std.extra\ndef main(): Unit { }", ["std/extra.ag": "module std.extra\nintrinsic def print(mutable x: Int): Unit"])
        .shouldReport(DiagnosticCode.MutableNativeParameter, At("x", 1, "std.extra"));
}

@("a native's signature has only types with a C equivalent")
unittest
{
    enum point = "type Point(x: Int)\n";
    foreach (type; ["Int8", "Int16", "Int32", "Int", "UInt8", "UInt16", "UInt32", "UInt", "Float", "Bool"])
    {
        analyzed("native def f(x: " ~ type ~ "): " ~ type ~ "\ndef main(): Unit { }").shouldHaveNoDiagnostics();
    }
    analyzed("native def f(): Unit\nnative def g(): Never\ndef main(): Unit { }").shouldHaveNoDiagnostics();
    analyzed("import std.c\nnative def f(x: CInt, y: CLong, z: CSize): CUChar\ndef main(): Unit { }").shouldHaveNoDiagnostics();

    foreach (type; ["String", "Any", "Int?", "[Int]", "(Int, Bool)", "Point", "(Int) -> Int", "()", "Unit", "Never"])
    {
        analyzed(point ~ "native def f(x: " ~ type ~ "): Int\ndef main(): Unit { }")
            .shouldReport(DiagnosticCode.InvalidNativeType, At(type, type == "Point" ? 2 : 1));
    }
    foreach (type; ["String", "Float?", "[UInt8]", "Point"])
    {
        analyzed(point ~ "native def f(): " ~ type ~ "\ndef main(): Unit { }")
            .shouldReport(DiagnosticCode.InvalidNativeType, At(type, type == "Point" ? 2 : 1));
    }
}

@("an intrinsic is declared only in the standard library, and only for one the compiler implements")
unittest
{
    analyzed("intrinsic def print(value: Any): Unit\ndef main(): Unit { }")
        .shouldReport(DiagnosticCode.IntrinsicOutsideStandardLibrary, At("print", 1));
    analyzed("intrinsic alias CLong\ndef main(): Unit { }")
        .shouldReport(DiagnosticCode.IntrinsicOutsideStandardLibrary, At("CLong", 1));
    analyzed("import stdx\ndef main(): Unit { }", ["stdx.ag": "module stdx\nintrinsic def printl(value: Any): Unit"])
        .shouldReport(DiagnosticCode.IntrinsicOutsideStandardLibrary, At("printl", 1, "stdx"));

    analyzed("import std.extra\ndef main(): Unit { }", ["std/extra.ag": "module std.extra\nintrinsic def sqrt(x: Float): Float"])
        .shouldReport(DiagnosticCode.UnknownIntrinsic, At("sqrt", 1, "std.extra"));
    analyzed("import std.extra\ndef main(): Unit { }", ["std/extra.ag": "module std.extra\nintrinsic alias CWord"])
        .shouldReport(DiagnosticCode.UnknownIntrinsic, At("CWord", 1, "std.extra"));
    analyzed("import std.extra\ndef main(): Unit { }", ["std/extra.ag": "module std.extra\nintrinsic def panic(message: String): Never"])
        .shouldHaveNoDiagnostics();
}

@("std.c's long is as wide as the target says, and its other types are the same everywhere")
unittest
{
    enum source = "import std.c\ndef f(x: CLong): Int64 => x\ndef g(x: CULong): UInt32 => x\ndef h(x: CInt, y: CSize): (Int32, UInt64) => (x, y)\ndef main(): Unit { }";
    analyzed(source, null, Target(64)).shouldReport(DiagnosticCode.TypeMismatch, At("x", 4));
    analyzed(source, null, Target(32)).shouldReport(DiagnosticCode.TypeMismatch, At("x", 2));
}

@("a native can't be called while a constant is evaluated")
unittest
{
    analyzed("native def f(): Int\nval c: Int = f()\ndef main(): Unit { }")
        .shouldReport(DiagnosticCode.NonConstantInitializer, At("f", 2));
}


@("with checks each value against its field, and has the object's type")
unittest
{
    analyzed(stepper ~ `type Limited(limit: UInt8?, game: Game)
def main(): Unit {
    val l = Limited(None, Game(Rng(1), 2))
    val m: Limited = l with (limit = 200, game.rng.state = 3)
}`).shouldHaveNoDiagnostics();
    analyzedWithTypes(`val p = Point(1, 2)
    val q = p with (x = "a")`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
}

@("with only reaches declared fields")
unittest
{
    analyzedWithTypes(`val p = Point(1, 2)
    val q = p with (z = 1)`).shouldReport(DiagnosticCode.UnknownMember, At("z", 1));
    analyzedWithTypes(`val p = Point(1, 2)
    val q = p with (x.y = 1)`).shouldReport(DiagnosticCode.UnknownMember, At("x.y", 1));
    analyzedMain(`val q = (1, 2) with (x = 1)`).shouldReport(DiagnosticCode.UnknownMember, At("x", 1));
}

@("two updates of one with can't overlap")
unittest
{
    analyzedWithTypes(`val p = Point(1, 2)
    val q = p with (x = 1, x = 2)`).shouldReport(DiagnosticCode.OverlappingWrites, At("x", 3));
    analyzed(stepper ~ `def main(): Unit {
    val g = Game(Rng(1), 2)
    val h = g with (rng = Rng(2), rng.state = 3)
}`).shouldReport(DiagnosticCode.OverlappingWrites, At("rng.state", 3));
}

@("with works on an immutable binding")
unittest
{
    analyzedWithTypes(`val p = Point(1, 2)
    val q = p with (x = 3)
    p.x = 1`).shouldReport(DiagnosticCode.AssignToImmutable, At("p", 3));
}

@("x.f() is f(x)")
unittest
{
    auto a = analyzed("def twice(n: Int): Int => n * 2\ndef main(): Unit {\n    val qq = 1\n    val r = qq.twice()\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("r", 1), "Int");
}

@("x.f() can't hide a write to x")
unittest
{
    analyzed("def next(mutable n: Int): Int => n\ndef main(): Unit {\n    mutable val qq = 1\n    val r = qq.next()\n}")
        .shouldReport(DiagnosticCode.MutabilityMismatch, At("qq", 2));
}

@("a later mutable argument of x.f(...) is fine, and still has to be marked")
unittest
{
    enum f = "def f(a: Int, mutable b: Int): Int => a\ndef main(): Unit {\n    val qq = 1\n    mutable val zz = 2\n";
    analyzed(f ~ "    val r = qq.f(mutable zz)\n}").shouldHaveNoDiagnostics();
    analyzed(f ~ "    val r = qq.f(zz)\n}").shouldReport(DiagnosticCode.MutabilityMismatch, At("zz", 2));
}

@("a receiver has to be exactly the first parameter's type")
unittest
{
    analyzed("def f(x: UInt8): Int => 1\ndef main(): Unit {\n    val qq = 1\n    val r = qq.f()\n}")
        .shouldReport(DiagnosticCode.TypeMismatch, At("qq", 2));
    analyzed("def f(x: Int?): Int => 1\ndef main(): Unit {\n    val qq = 1\n    val r = qq.f()\n}")
        .shouldReport(DiagnosticCode.TypeMismatch, At("qq", 2));
}

@("a function with no parameters can't be called on a value")
unittest
{
    analyzed("def f(): Int => 1\ndef main(): Unit {\n    val qq = 1\n    val r = qq.f()\n}")
        .shouldReport(DiagnosticCode.WrongArgumentCount, At("qq.f", 1));
}

@("x.f() counts the receiver as an argument")
unittest
{
    analyzed("def f(a: Int, b: Int): Int => 1\ndef main(): Unit {\n    val qq = 1\n    val r = qq.f()\n}")
        .shouldReport(DiagnosticCode.WrongArgumentCount, At("qq.f()", 1));
}

@("only a function can be called on a value")
unittest
{
    analyzed("val k: Int = 1\ndef main(): Unit {\n    val qq = 1\n    val r = qq.k()\n}")
        .shouldReport(DiagnosticCode.UnknownMember, At("qq.k", 1));
    analyzed("type K(n: Int)\ndef main(): Unit {\n    val qq = 1\n    val r = qq.K()\n}")
        .shouldReport(DiagnosticCode.UnknownMember, At("qq.K", 1));
}

@("a field comes before a function of the same name, even one that can't be called")
unittest
{
    analyzed("type T(n: Int)\ndef n(t: T): Int => 1\ndef main(): Unit {\n    val qq = T(1)\n    val r = qq.n()\n}")
        .shouldReport(DiagnosticCode.NotCallable, At("qq.n()", 1));
}

@("a receiver needs a type of its own")
unittest
{
    analyzed("def f(x: Int?): Int => 1\ndef main(): Unit {\n    val r = None.f()\n}")
        .shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
}

@("x.length() is the array length, and needs an array")
unittest
{
    analyzedMain("    val r = [1].length()").shouldHaveNoDiagnostics();
    analyzedMain("    val qq = 1\n    val r = qq.length()").shouldReport(DiagnosticCode.TypeMismatch, At("qq", 2));
}

private enum sums = "type Peg = Literal(text: String) | Sequence(parts: [Peg]) | Empty\n"
    ~ "type Color = Red | Green | Blue\n"
    ~ "type P2(x: Int)\ntype P3(x: Int, z: Int)\ntype Point = P2 | P3\n";

private Analyzed sumMain(string body)
{
    return analyzed(sums ~ "def main(): Unit {\n" ~ body ~ "\n}");
}

@("a constructor of an owned member is the sum, and of a referenced one is itself")
unittest
{
    auto a = sumMain("    val qa = Literal(\"a\")\n    val qr = Red\n    val qp = P2(1)\n    val qs = [Red, Green]");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType(`Literal("a")`, 1, "Peg");
    a.shouldHaveType("Red", 2, "Color");
    a.shouldHaveType("P2(1)", 1, "P2");
    a.shouldHaveType("[Red, Green]", 1, "[Color]");
}

@("a constructor checked against its member builds the member")
unittest
{
    auto a = sumMain("    val l: Literal = Literal(\"a\")\n    val t = l.text\n    val o: Literal? = Literal(\"b\")");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType(`Literal("a")`, 1, "Literal");
    sumMain("    val t = Literal(\"a\").text").shouldReport(DiagnosticCode.UnknownMember, At(`Literal("a").text`, 1));
}

@("join takes a member to its sum and never invents one")
unittest
{
    sumMain("    val l: Literal = Literal(\"a\")\n    val q = if true => l else Empty").shouldHaveNoDiagnostics();
    sumMain("    val q = if true => P2(1) else P3(1, 2)").shouldReport(DiagnosticCode.TypeMismatch, At("if true => P2(1) else P3(1, 2)", 1));
    analyzed("type P2\ntype P3\ntype A = P2 | P3\ndef f(): A => if true => P2 else P3\ndef main(): Unit => ()").shouldHaveNoDiagnostics();
}

@("a literal adapts to the sum's only integer member")
unittest
{
    analyzed("type V = Int8 | String\ndef main(): Unit {\n    val v: V = 1\n}").shouldHaveNoDiagnostics();
    analyzed("type V = Int8 | Int\ndef main(): Unit {\n    val v: V = 1\n}").shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
    analyzed("type V = Int? | String\ndef main(): Unit {\n    val v: V = 1\n}").shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
    analyzed("type V = Int8 | String\ndef main(): Unit {\n    val v: V = 300\n}").shouldReport(DiagnosticCode.LiteralOutOfRange, At("300", 1));
}

@("promotion into a sum is one step")
unittest
{
    analyzed("type V = Int? | String\ndef f(x: Int): V => x\ndef main(): Unit => ()").shouldReport(DiagnosticCode.TypeMismatch, At("x", 2));
    analyzed("type A\ntype B = A | Int\ndef f(a: A): B? => a\ndef main(): Unit => ()").shouldReport(DiagnosticCode.TypeMismatch, At("a", 2));
}

@("a sum's name isn't a value, and it has no fields")
unittest
{
    sumMain("    val q = Peg").shouldReport(DiagnosticCode.InvalidOperand, At("Peg", 3));
    sumMain("    val q = Peg(1)").shouldReport(DiagnosticCode.InvalidOperand, At("Peg", 3));
    sumMain("    mutable val p = Empty\n    p.text = \"a\"").shouldReport(DiagnosticCode.UnknownMember, At("p.text", 1));
}

@("sums are comparable when every member is, and aren't ordered")
unittest
{
    analyzed("type F(f: () -> Int)\ntype S = F | Int\ndef main(): Unit {\n    val a: S = 1\n    val q = a == a\n}")
        .shouldReport(DiagnosticCode.InvalidOperand, At("a == a", 1));
    sumMain("    val q = Red < Green").shouldReport(DiagnosticCode.InvalidOperand, At("Red", 2));
}

@("sum members have to make sense")
unittest
{
    analyzed("type A = Int | Any\ndef main(): Unit => ()").shouldReport(DiagnosticCode.InvalidSumMember, At("Any", 1));
    analyzed("type A = Int | Never\ndef main(): Unit => ()").shouldReport(DiagnosticCode.InvalidSumMember, At("Never", 1));
    analyzed("type A = A | Int\ndef main(): Unit => ()").shouldReport(DiagnosticCode.InvalidSumMember, At("A", 2));
    analyzed("type A = Int | Int64\ndef main(): Unit => ()").shouldReport(DiagnosticCode.InvalidSumMember, At("Int64", 1));
    analyzed("type A = B | B\ndef main(): Unit => ()").shouldReport(DiagnosticCode.InvalidSumMember, At("B", 2));
}

@("a bare name in a sum is declared once")
unittest
{
    analyzed("type A = X | Y\ntype B = X | Z\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("X", 2));
    analyzed("type X\ntype A = X | Y\ntype B = X | Z\ndef main(): Unit => ()").shouldHaveNoDiagnostics();
    analyzed("type A = None | Y\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("None", 1));
    analyzed("type A = Some(x: Int) | Y\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Some", 1));
}

@("a match has to cover its subject, naming what's missing")
unittest
{
    auto a = sumMain("    val q = match Red {\n        Red => 1\n    }");
    a.shouldReport(DiagnosticCode.NonExhaustiveMatch, At("match Red {\n        Red => 1\n    }", 1));
    sumMain("    val q = match Red {\n        Red => 1\n        _ => 2\n    }").shouldHaveNoDiagnostics();
    sumMain("    val q = match 1 {\n        1 => 1\n    }").shouldReport(DiagnosticCode.NonExhaustiveMatch, At("match 1 {\n        1 => 1\n    }", 1));
    sumMain("    val q = match true {\n        true => 1\n    }").shouldReport(DiagnosticCode.NonExhaustiveMatch, At("match true {\n        true => 1\n    }", 1));
    sumMain("    val q = match true {\n        true => 1\n        false => 2\n    }").shouldHaveNoDiagnostics();
    sumMain("    val o: Int? = 1\n    val q = match o {\n        Some(1) => 1\n        None => 2\n    }")
        .shouldReport(DiagnosticCode.NonExhaustiveMatch, At("match o {\n        Some(1) => 1\n        None => 2\n    }", 1));
    sumMain("    val p: Point = P2(1)\n    val q = match (p, true) {\n        (P2(_), true) => 1\n        (P3(_, _), _) => 2\n        (_, false) => 3\n    }").shouldHaveNoDiagnostics();
}

@("an arm that can't run is an error")
unittest
{
    sumMain("    val q = match Red {\n        _ => 1\n        Red => 2\n    }").shouldReport(DiagnosticCode.UnreachableArm, At("Red", 3));
    sumMain("    val q = match 1 {\n        1 => 1\n        1 => 2\n        _ => 3\n    }").shouldReport(DiagnosticCode.UnreachableArm, At("1", 4));
    sumMain("    val q = match Red {\n        Red => 1\n        Green => 2\n        Blue => 3\n        _ => 4\n    }").shouldReport(DiagnosticCode.UnreachableArm, At("_", 1));
}

@("patterns have to fit their subject")
unittest
{
    sumMain("    val q = match Red {\n        Literal(a) => 1\n        _ => 2\n    }").shouldReport(DiagnosticCode.PatternMismatch, At("Literal(a)", 1));
    sumMain("    val q = match Empty {\n        Literal(a, b) => 1\n        _ => 2\n    }").shouldReport(DiagnosticCode.PatternMismatch, At("Literal(a, b)", 1));
    sumMain("    val q = match Red {\n        Some(a) => 1\n        _ => 2\n    }").shouldReport(DiagnosticCode.PatternMismatch, At("Some(a)", 1));
    sumMain("    val q = match Red {\n        1 => 1\n        _ => 2\n    }").shouldReport(DiagnosticCode.PatternMismatch, At("1", 1));
    sumMain("    val q = match Red {\n        Color(a) => 1\n        _ => 2\n    }").shouldReport(DiagnosticCode.PatternMismatch, At("Color(a)", 1));
    sumMain("    val q = match Red {\n        x: Int => 1\n        _ => 2\n    }").shouldReport(DiagnosticCode.PatternMismatch, At("x: Int", 3));
}

@("pattern bindings follow the rules for locals and last for their arm")
unittest
{
    sumMain("    val p = Red\n    val q = match Red {\n        p => 1\n    }").shouldReport(DiagnosticCode.ShadowedDeclaration, At("p", 2));
    sumMain("    val q = match (1, 2) {\n        (a, a) => 1\n    }").shouldReport(DiagnosticCode.DuplicateDeclaration, At("a", 2));
    sumMain("    val q = match 1 {\n        a => a\n    }\n    val r = a").shouldReport(DiagnosticCode.UnknownName, At("a", 3));
    sumMain("    val q = match (1, 2) {\n        (_, _) => 1\n    }").shouldHaveNoDiagnostics();
}

@("panic never returns")
unittest
{
    analyzed("def f(): Int => panic(\"no\")\ndef main(): Unit => ()").shouldHaveNoDiagnostics();
    analyzed("def f(): Int => panic(1)\ndef main(): Unit => ()").shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
}

unittest
{
    // Interchangeable with the type it names.
    auto a = analyzed(`alias Meters = Float
    alias Pair = (Int, Int)
    alias Later = Pair
    alias Fn = (Later) -> Meters
    type Node(next: Link)
    alias Link = Node?
    val limit: Meters = 1.5
    def add(a: Meters, b: Float): Float => a + b
    def first(p: Later): Int { val (a, _) = p; a }
    def main(): Unit {
        val f: Fn = p => Float(first(p))
        val m: Meters = Meters(1)
        val n = Node(None)
        val l: Link = Some(n)
        _ = add(m, f((1, 2))) + limit
        _ = l
    }`);
    assert(!a.collector.hasErrors);
}

unittest
{
    analyzed("alias A = A\ndef main(): Unit => ()").shouldReport(DiagnosticCode.RecursiveAlias, At("A", 1));
    analyzed("alias A = [A]\ndef main(): Unit => ()").shouldReport(DiagnosticCode.RecursiveAlias, At("A", 1));
    analyzed("alias A = B?\nalias B = (A, Int)\ndef main(): Unit => ()").shouldReport(DiagnosticCode.RecursiveAlias, At("A", 1));
    analyzed("alias A = Int\ntype A\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("A", 2));
    analyzed("alias Int = Float\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Int", 1));
    analyzed("alias None = Int\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("None", 1));
    analyzed("alias A = Missing\ndef main(): Unit => ()").shouldReport(DiagnosticCode.UnknownType, At("Missing", 1));
    analyzed("alias A = [Any]\ndef main(): Unit => ()").shouldReport(DiagnosticCode.InvalidArrayElement, At("[Any]", 1));
    analyzed("private type P\nalias A = [P]\ndef main(): Unit => ()").shouldReport(DiagnosticCode.PrivateTypeExposed, At("P", 2));
    analyzed("private alias A = Int\ndef f(a: A): Int => 1\ndef main(): Unit => ()").shouldReport(DiagnosticCode.PrivateTypeExposed, At("A", 2));
    analyzed("alias A = (Int, Int)\nval a: A = 1\ndef main(): Unit => ()").shouldReport(DiagnosticCode.InvalidConstantType, At("A", 2));
    analyzed("alias A = [Int]\ndef main(): Unit { _ = A(1) }").shouldReport(DiagnosticCode.AliasIsNotAValue, At("A", 2));
    analyzed("alias A = Float\ndef main(): Unit { _ = A }").shouldReport(DiagnosticCode.AliasIsNotAValue, At("A", 2));
    analyzed("alias A = Bool\ndef main(): Unit { _ = A(1) }").shouldReport(DiagnosticCode.AliasIsNotAValue, At("A", 2));
    analyzed("alias M = Float\ndef main(): Unit { val s: String = M(1) }").shouldReport(DiagnosticCode.TypeMismatch, At("M", 2));
}

unittest
{
    auto library = ["lib.ag": "module lib\nprivate alias Hidden = Int\nalias Shown = Int\n"];
    analyzed("import lib\ndef main(): Unit { val x: lib.Hidden = 1 }", library)
        .shouldReport(DiagnosticCode.PrivateMember, At("lib", 2));
    analyzed("import lib\ndef main(): Unit { val x: Hidden = 1 }", library)
        .shouldReport(DiagnosticCode.UnknownType, At("Hidden", 1));
    analyzed("import lib\ndef main(): Unit { _ = lib.Hidden(1) }", library)
        .shouldReport(DiagnosticCode.PrivateMember, At("lib", 2));
}
