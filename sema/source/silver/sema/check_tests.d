/// Type checking tests. An expression is found by its exact source text (its nth whole-word
/// occurrence), and types are compared as `TypeTable.describe` prints them, e.g. "Int?".
module silver.sema.check_tests;

version (unittest):

import core.exception : AssertError;
import std.format : format;

import silver.ast;
import silver.sema.check : FieldInfo;
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
type Knot(self: Knot)
def push(v: Int, n: Node): Node => Node(v, n)
def tie(k: Knot): Knot => Knot(k)
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
            (const Id!TypeDecl decl) => a.analysis.fieldsOf(decl),
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
