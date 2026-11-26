/// Tests of expressions with no type of their own: what they take from where they go, in
/// inference, overload choice and method calls (docs/language/types.md, "A type of its own").
module silver.sema.untyped_tests;

version (unittest):

import std.algorithm : canFind, count;
import std.array : replicate;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.format : format;

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType, shouldHaveType;
import silver.sema.resolution_tests;

private enum declarations = `
type Box<T>(items: [T])
type Other(n: Int)
def id<T>(x: T): T => x
def opt<T>(x: T, y: T?): T? => y
def none<T>(): T? => None
def same<T>(a: T, b: T): T => a
def two<T>(a: T, b: T): [T] => [a, b]
def mp<T, U>(xs: [T], f: (T) -> U): [U] => []
def dbl(x: Int): Int => x * 2
def dbl(x: Float): Float => x * 2.0
`;

/// `body` in `main`, after the declarations above and `more`.
private Analyzed analyzedUntyped(string body, string more = "")
{
    return analyzed(declarations ~ more ~ "def main(): Unit {\n" ~ body ~ "\n}");
}

@("the expected type reaches a literal through nested generic calls, and each call is an instance of it")
unittest
{
    auto a = analyzedUntyped(`    val v: UInt8 = id(id(1))
    val w: [UInt8]? = id(id([7, 8]))`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("1", "UInt8");
    a.shouldHaveType("id(1)", "UInt8");
    a.shouldHaveType("7", "UInt8");
    a.shouldHaveType("id([7, 8])", "[UInt8]?");
}

@("with nothing expected a generic call of literals binds what they are by themselves")
unittest
{
    auto a = analyzedUntyped(`    val one = id(id(1))
    val maybe = opt(1, None)
    val pair = two(opt(1, None), 2)
    val mapped = mp([1], x => x + 1)`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("one", 1), "Int");
    a.shouldDeclareType(At("maybe", 1), "Int?");
    a.shouldDeclareType(At("pair", 1), "[Int?]");
    a.shouldDeclareType(At("mapped", 1), "[Int]");
}

@("an argument with a type of its own decides before one without, whichever is written first")
unittest
{
    auto a = analyzedUntyped(`    val small: UInt8 = 3
    val n = 5
    val first = same(id(1), small)
    val array = same([1, 2], [small])
    val block = same({ 1 }, small)
    val branch = same(if n > 1 => 1 else 2, small)
    val both = two(opt(n, None), n)`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("first", 1), "UInt8");
    a.shouldDeclareType(At("array", 1), "[UInt8]");
    a.shouldDeclareType(At("block", 1), "UInt8");
    a.shouldDeclareType(At("branch", 1), "UInt8");
    a.shouldDeclareType(At("both", 1), "[Int?]");

    analyzedUntyped(`    val n = 5
    val both = two(opt(1, None), n)`).shouldReport(DiagnosticCode.TypeMismatch, At("opt(1, None)", 1));
    analyzedUntyped(`    val n = 5
    val first = same(Some(1), n)`).shouldReport(DiagnosticCode.TypeMismatch, At("Some(1)", 1));
}

@("arguments with no type of their own take their turns left to right, a literal as its default type")
unittest
{
    auto a = analyzedUntyped(`    val after = same(Some(2), 1)
    val wrapped = two(opt(1, None), 2)`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("after", 1), "Int?");
    a.shouldDeclareType(At("wrapped", 1), "[Int?]");
    // The literal comes first and is an `Int`, which an option isn't.
    analyzedUntyped("    val before = same(1, Some(2))").shouldReport(DiagnosticCode.TypeMismatch, At("Some(2)", 1));
    analyzedUntyped("    val before = two(2, opt(1, None))").shouldReport(DiagnosticCode.TypeMismatch, At("opt(1, None)", 1));
}

@("an argument that can't be typed at its turn is tried again after the ones that follow it")
unittest
{
    auto a = analyzedUntyped(`    val boxes = two(Box([]), Box([1]))
    val tuples = two((1, []), (2, [3]))
    val nested = two([[]], [[1]])`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("boxes", 1), "[Box<Int>]");
    a.shouldDeclareType(At("tuples", 1), "[(Int, [Int])]");
    a.shouldDeclareType(At("nested", 1), "[[[Int]]]");
}

@("a bare Error takes its error union from where it goes, and never makes a type argument of its own")
unittest
{
    auto a = analyzedUntyped(`    val t: Int ! String = Ok(1)
    val direct: Int ! String = id(Error("a"))
    val twice: Int ! String = id(id(Error("b")))
    val beside = same(Error("c"), t)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType(`id(Error("a"))`, "Int ! String");
    a.shouldHaveType(`id(Error("b"))`, "Int ! String");
    a.shouldDeclareType(At("beside", 1), "Int ! String");
    analyzedUntyped(`    val e = id(Error("x"))`).shouldReport(DiagnosticCode.UntypedErrorUnion, At("Error", 1));
}

@("an expression with nothing to make it anything is reported where it needs a type, however it's wrapped")
unittest
{
    analyzedUntyped("    val v = id(id(None))").shouldReport(DiagnosticCode.UntypedNone, At("None", 2));
    analyzedUntyped("    val v = id(id([]))").shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 2));
    analyzedUntyped("    val v = id(Box([]))").shouldReport(DiagnosticCode.UntypedEmptyArray, At("[]", 2));
    analyzedUntyped("    val v = id((1, None))").shouldReport(DiagnosticCode.UntypedNone, At("None", 2));
    analyzedUntyped("    val v = id(none())").shouldReport(DiagnosticCode.CannotInferTypeArgument, At("none", 2));
    analyzedUntyped("    val v = same(none(), none())").collector.diagnostics.length.shouldEqual(2);
}

@("a generic or overloaded function's name needs the whole function type, and is reported once")
unittest
{
    analyzedUntyped("    val v = mp([1], id)").shouldReport(DiagnosticCode.CannotInferTypeArgument, At("id", 2));
    analyzedUntyped("    val v = mp([1], dbl)").shouldReport(DiagnosticCode.AmbiguousOverload, At("dbl", 3));
    auto a = analyzedUntyped(`    val f: (Int) -> Int = id(dbl)
    val g: (Float) -> Float = id(id(dbl))
    val h = same(dbl, f)`);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("dbl", 3), At("dbl", 1));
    a.shouldResolve(At("dbl", 4), At("dbl", 2));
    a.shouldResolve(At("dbl", 5), At("dbl", 1));
}

@("overload choice tries an argument with no type of its own by the check each function would give it")
unittest
{
    enum overloads = `def ov(x: UInt8): String => "u8"
def ov(o: Other): String => "other"
def ob(b: Box<Int>): String => "box"
def ob(o: Other): String => "other"
def h(xs: [Int]): String => "array"
def h(xs: [Int]?): String => "option"
def lists(xs: [Int]): String => "ints"
def lists(s: String): String => "string"
def show(x: Float): String => "float"
def show(x: String): String => "string"
`;
    auto a = analyzedUntyped(`    val c = true
    val r1 = ov(id(1))
    val r2 = ov(if c => 1 else 2)
    val r3 = ob(Box([]))
    val r4 = h([])
    val r5 = lists(mp([1], x => x + 1))
    val r6 = show(dbl(1.0))`, overloads);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("ov", 3), At("ov", 1));
    a.shouldHaveType("id(1)", "UInt8");
    a.shouldCall(At("ov", 4), At("ov", 1));
    a.shouldCall(At("ob", 3), At("ob", 1));
    a.shouldCall(At("h", 3), At("h", 1));
    a.shouldCall(At("lists", 3), At("lists", 1));
    a.shouldCall(At("show", 3), At("show", 1));

    // An inner call of an overloaded function is chosen by its own arguments, whatever it's passed to.
    analyzedUntyped("    val r = show(dbl(1))", overloads).shouldReport(DiagnosticCode.NoMatchingOverload, At("show", 3));
    // A lambda's body isn't looked at to choose, so what's wrong in it is reported once, by the check.
    analyzedUntyped(`    val r = lists(mp([1], x => x + "a"))`, overloads).collector.diagnostics.length.shouldEqual(1);
}

@("a receiver with no type of its own is a first argument, unless what it is by itself has the field")
unittest
{
    enum methods = `def m8(d: [String: Int8]): Int => 1
def u(x: UInt8): Int => 2
def ob(b: Box<Int>): Int => 3
def k(x: Int?): Int => 4
def ap(f: (Int) -> Int, x: Int): Int => f(x)
def from(r: Interval<Int>): String => "a function"
def bytes(xs: [UInt8]): Int => 5
`;
    auto a = analyzedUntyped(`    val c = true
    val r1 = ["a": 77].m8()
    val r2 = (if c => 55 else 66).u()
    val r3 = Box([]).ob()
    val r4 = none().k()
    val r5 = dbl.ap(4)
    val r6 = id(1).u()
    val r7 = [56, 57].bytes()`, methods);
    a.shouldHaveNoDiagnostics();
    // What the receiver was by itself, an `[Int]` with no field `bytes`, is taken back.
    a.shouldHaveType("56", "UInt8");
    a.shouldHaveType("[56, 57]", "[UInt8]");
    a.shouldHaveType("55", "UInt8");
    a.shouldHaveType("id(1)", "UInt8");

    // An `Interval` has a field `from`, so that's what a range literal's `.from` is.
    analyzedUntyped("    val r = (1..5).from()", methods).shouldReport(DiagnosticCode.NotCallable, At("1..5", 1));
    // And a field of what a call is by itself.
    auto b = analyzedUntyped("    val held = id(Box([1])).items", methods);
    b.shouldHaveNoDiagnostics();
    b.shouldDeclareType(At("held", 1), "[Int]");
}

@("with nothing expected, the parts of an array, if or match that have a type decide what the literals are")
unittest
{
    auto a = analyzedUntyped(`    val small: UInt8 = 3
    val c = true
    val branch = if c => 1 else small
    val elements = [1, small, 2]
    val optional = [small, None]
    val entries = ["a": small, "b": 4]
    val arm = match c {
        true => 5
        false => small
    }`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("branch", 1), "UInt8");
    a.shouldDeclareType(At("elements", 1), "[UInt8]");
    a.shouldDeclareType(At("optional", 1), "[UInt8?]");
    a.shouldDeclareType(At("entries", 1), "[String: UInt8]");
    a.shouldDeclareType(At("arm", 1), "UInt8");
    // A float literal isn't an integer, so it's joined as before, and that's the error.
    analyzedUntyped(`    val small: UInt8 = 3
    val elements = [small, 1.5]`).collector.diagnostics.length.shouldEqual(1);
}

@("a function whose result is worked out from its body is checked once when a trial reaches it first")
unittest
{
    auto a = analyzed(`def ov(x: [Int]): String => "ints"
def ov(x: String): String => "string"
def pick<T>(a: T, b: T): T => a
def main(): Unit {
    val r = ov(pick([], later().array()))
}
def later(): Range<Int> {
    val wrong: Int = "s"
    [1, 2].iterate()
}`);
    a.shouldReport(DiagnosticCode.TypeMismatch, At(`"s"`, 1));
}

@("checking stays linear in how deep calls with no type of their own nest")
unittest
{
    enum depth = 200;
    string nested(string open, string innermost, string close)
    {
        return open.replicate(depth) ~ innermost ~ close.replicate(depth);
    }
    auto timer = StopWatch(AutoStart.yes);
    auto a = analyzed(format(`def q<T>(x: T, y: T?): T? => y
def id<T>(x: T): T => x
def ov(x: UInt8): String => "u8"
def ov(x: String): String => "string"
type Tree<K, V>(keys: [K], values: [V])
def empty<K, V>(): Tree<K, V> => Tree([], [])
def insert<K, V>(t: Tree<K, V>, k: K, v: V): Tree<K, V> => t
def main(): Unit {
    val alone = %s
    val t: Tree<String, Int> = %s
    val chosen = ov(%s)
    val chain = [1, 2]%s.array()
}`, nested("q(", "1", ", None)"), nested("insert(", "empty()", `, "a", 1)`), nested("id(", "1", ")"),
        ".map(x => x + 1).filter(x => x > 1)".replicate(depth / 2)));
    a.shouldHaveNoDiagnostics();
    // Three times the work at each level, as a trial per level was, wouldn't finish at this depth.
    assert(timer.peek.total!"seconds" < 20, format("took %s", timer.peek));
}

@("the steps a literal takes count through a generic call, so wrapping an argument doesn't change the function chosen")
unittest
{
    auto a = analyzedUntyped(`    val bare = wide(1)
    val wrapped = wide(id(1))
    val twice = wide(id(id(1)))
    val array = wide(id([1]))
    val pair = wide(two(1, 2))`, `def wide(x: Int): Int => 0
def wide(x: UInt8): String => ""
def wide(x: [Int]): Int => 0
def wide(x: [UInt8]): String => ""
`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("bare", 1), "Int");
    a.shouldDeclareType(At("wrapped", 1), "Int");
    a.shouldDeclareType(At("twice", 1), "Int");
    a.shouldDeclareType(At("array", 1), "Int");
    a.shouldDeclareType(At("pair", 1), "Int");
}

@("checking stays linear in how deep blocks nest in an arm that is tried against the other arm's type")
unittest
{
    enum depth = 19;
    string value = "None";
    foreach (i; 0 .. depth) value = format("{ val q%s = if c => small else %s\n None }", i, value);
    auto timer = StopWatch(AutoStart.yes);
    auto a = analyzed(format(`def main(): Unit {
    val c = true
    val small: UInt8 = 3
    val r = if c => small else %s
}`, value));
    a.shouldHaveNoDiagnostics();
    // Twice the work at each level, as a failed try and then typing it again is, takes minutes at this depth.
    assert(timer.peek.total!"seconds" < 5, format("took %s", timer.peek));
}

@("checking stays linear in how deep blocks nest in an argument that is tried against several functions")
unittest
{
    enum depth = 11;
    string value = "[1]";
    foreach (i; 0 .. depth) value = format("{ val q%s = ov(%s)\n [1] }", i, value);
    auto timer = StopWatch(AutoStart.yes);
    auto a = analyzed(format(`def ov(xs: [Int]): String => "ints"
def ov(s: String): String => "string"
def main(): Unit {
    val r = ov(%s)
}`, value));
    a.shouldHaveNoDiagnostics();
    // A trial for each function and then the check, at each level, takes minutes at this depth.
    assert(timer.peek.total!"seconds" < 5, format("took %s", timer.peek));
}

private void shouldEqual(size_t actual, size_t expected, string file = __FILE__, size_t line = __LINE__)
{
    import core.exception : AssertError;

    if (actual != expected) throw new AssertError(format("Expected %s, got %s", expected, actual), file, line);
}
