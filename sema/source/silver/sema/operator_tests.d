/// Tests of operator functions: indexing, slicing and assigning elements of anything but an array.
module silver.sema.operator_tests;

version (unittest):

import std.algorithm : canFind;

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType, shouldTypeEveryExpression;
import silver.sema.resolution_tests;

private enum window = "type W<T>(items: [T])
def length<T>(w: W<T>): Int => length(w.items)
def opIndex<T>(w: W<T>, index: Int): T => w.items[index]
def opIndexAssign<T>(w: W<T>, index: Int, value: T): W<T> => W(w.items.opIndexAssign(index, value))
def opIndex<T>(w: W<T>, part: Interval<Int>): W<T> => W(w.items[part])
";

@("x[i], x[a..b] and x[i] = v call opIndex, opIndex with an Interval and opIndexAssign, typed by what they return and take")
unittest
{
    auto a = analyzed(window ~ "def main(): Unit {
    mutable val w = W([1.5])
    val one = w[0]
    val some = w[0..1]
    val rest = w[1..]
    val start = w[..1]
    w[0] = 2.5
    w[0] += 1.0
    mutable val bytes = W<UInt8>([1])
    bytes[0] = 2
}");
    a.shouldHaveNoDiagnostics();
    a.shouldTypeEveryExpression();
    a.shouldDeclareType(At("one", 1), "Float");
    a.shouldDeclareType(At("some", 1), "W<Float>");
    a.shouldDeclareType(At("rest", 1), "W<Float>");
    a.shouldDeclareType(At("start", 1), "W<Float>");
    analyzed(window ~ "def main(): Unit {\n    mutable val w = W([1.5])\n    mutable val bytes = W<UInt8>([1])\n"
        ~ "    (w[0], bytes[0]) = (3.5, 3)\n    (w[0], bytes[0]) = (bytes[0], 4)\n}")
        .shouldReport(DiagnosticCode.NoMatchingOverload, At("w[0]", 2));
}

@("indexing is chosen by its arguments, as any call is")
unittest
{
    auto a = analyzed("type M(keys: [String])
def opIndex(m: M, index: Int): String => m.keys[index]
def opIndex(m: M, key: String): Int? => None
def main(): Unit {
    val m = M([])
    val byPosition = m[0]
    val byKey = m[\"a\"]
}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("byPosition", 1), "String");
    a.shouldDeclareType(At("byKey", 1), "Int?");
    analyzed("type M(keys: [String])\ndef opIndex(m: M, key: String): Int => 1\ndef main(): Unit => print(M([])[1.0])")
        .shouldReport(DiagnosticCode.NoMatchingOverload, At("M([])[1.0]", 1));
}

@("indexing, slicing or assigning what no function takes is an error")
unittest
{
    enum point = "type P(x: Int)\n";
    analyzed(point ~ "def main(): Unit => print(P(1)[0])").shouldReport(DiagnosticCode.InvalidOperand, At("P(1)", 1));
    analyzed(point ~ "def main(): Unit => print(P(1)[0..1])").shouldReport(DiagnosticCode.InvalidOperand, At("P(1)[0..1]", 1));
    analyzed(point ~ "def opIndex(p: P, r: Interval<Int>): P => p\ndef main(): Unit => print(P(1)[0..])")
        .shouldReport(DiagnosticCode.InvalidOperand, At("P(1)", 1));
    analyzed(point ~ "def opIndex(p: P, i: Int): Int => 1\ndef main(): Unit {\n    mutable val p = P(1)\n    p[0] = 2\n}")
        .shouldReport(DiagnosticCode.InvalidOperand, At("p[0]", 1));
}

@("opIndexAssign has to take and return the value assigned back to, and a slice with a left-out bound has to fit opIndex exactly")
unittest
{
    enum point = "type P(x: Int)\n";
    enum main = "def main(): Unit {\n    mutable val p = P(1)\n    p[0] = 2\n}";
    analyzed(point ~ "def opIndexAssign(p: P, i: Int, v: Int): Int => v\n" ~ main)
        .shouldReport(DiagnosticCode.TypeMismatch, At("p[0]", 1));
    analyzed(point ~ "def opIndexAssign(p: P?, i: Int, v: Int): P => P(v)\n" ~ main)
        .shouldReport(DiagnosticCode.TypeMismatch, At("p[0]", 1));
    analyzed(point ~ "def opIndex(p: P, r: Interval<UInt8>): P => p\ndef main(): Unit => print(P(1)[..2])")
        .shouldReport(DiagnosticCode.InvalidOperand, At("P(1)[..2]", 1));
    analyzed(point ~ "def opIndex(p: P, r: Interval<Int>?): P => p\ndef main(): Unit => print(P(1)[..2])")
        .shouldReport(DiagnosticCode.TypeMismatch, At("P(1)[..2]", 1));
    analyzed(point ~ "def length(p: P): Int => 1\ndef opIndex(p: P, r: Interval<Int>?): P => p\n"
        ~ "def main(): Unit => print(P(1)[0..])").shouldReport(DiagnosticCode.TypeMismatch, At("P(1)[0..]", 1));
}

@("an element is written back into each element it's inside, which has to be read and written with one index type")
unittest
{
    enum grid = "type G(rows: [[Int]])\n";
    enum read = "def opIndex(g: G, row: Int): [Int] => g.rows[row]\n";
    enum write = "def opIndexAssign(g: G, row: Int, value: [Int]): G => g\n";
    enum main = "def main(): Unit {\n    mutable val g = G([[1]])\n    g[0][0] = 2\n}";
    analyzed(grid ~ read ~ write ~ main).shouldHaveNoDiagnostics();
    analyzed(grid ~ read ~ main).shouldReport(DiagnosticCode.InvalidOperand, At("g[0]", 1));
    analyzed(grid ~ write ~ main).shouldReport(DiagnosticCode.InvalidOperand, At("g[0][0]", 1));
    analyzed(grid ~ read ~ "def opIndexAssign(g: G, row: UInt8, value: [Int]): G => g\n" ~ main)
        .shouldReport(DiagnosticCode.NoMatchingOverload, At("g[0]", 1));
    analyzed(grid ~ read ~ "def opIndexAssign(g: G, row: Int, value: [Int]?): G => g\n" ~ main)
        .shouldReport(DiagnosticCode.TypeMismatch, At("g[0]", 1));
}

@("a compound assignment reads and writes with the index it evaluates once")
unittest
{
    enum source = "type P(x: Int)
def opIndex(p: P, i: Int): Int => 1
def opIndexAssign(p: P, i: UInt8, v: Int): P => p
def main(): Unit {
    mutable val p = P(1)
    p[0] += 1
}";
    analyzed(source).shouldReport(DiagnosticCode.TypeMismatch, At("0", 1));
}

@("indexing uses an imported opIndex, but only one imported module's may fit")
unittest
{
    auto files = [
        "a.ag": "module a\ntype P(x: Int)\ndef opIndex(p: P, i: Int): Int => 1",
        "b.ag": "module b\nimport a\ndef opIndex(p: a.P, i: Int): Int => 2",
    ];
    analyzed("import a\ndef main(): Unit => print(P(1)[0])", files).shouldHaveNoDiagnostics();
    analyzed("import a\nimport b\ndef main(): Unit => print(P(1)[0])", files)
        .shouldReport(DiagnosticCode.AmbiguousName, At("P(1)[0]", 1));
    analyzed("import a\nimport b\ndef opIndex(p: P, i: Int): Int => 3\ndef main(): Unit => print(P(1)[0])", files)
        .shouldHaveNoDiagnostics();
}

@("an array's operator functions can be called by name, and take an Int")
unittest
{
    analyzed("def main(): Unit {\n    mutable val xs = [1, 2]\n    print(opIndex(xs, 0) + xs.opIndex(1))\n"
        ~ "    xs = xs.opIndexAssign(0, 3)\n    print(xs.opIndex(0..1))\n}").shouldHaveNoDiagnostics();
    analyzed("def main(): Unit {\n    val i: UInt8 = 0\n    print(opIndex([1], i))\n}").shouldReport(DiagnosticCode.NoMatchingOverload, At("opIndex", 1));
}

@("opEquals, opHash and opString are for a declared type, with the shape each has, for every instance, and opEquals and opHash come together")
unittest
{
    enum types = "interface Named { def name(value: Self): String }
type Point(x: Int, y: Int)
type Box<T>(value: T)
type Pair<A, B>(first: A, second: B)
";
    void rejects(string functions)
    {
        auto a = analyzed(types ~ functions ~ "\ndef main(): Unit {}");
        assert(a.collector.diagnostics.length == 1, functions);
        assert(a.collector.diagnostics[0].code == DiagnosticCode.InvalidTypeFunction, functions);
    }

    analyzed(types ~ "def opEquals(a: Point, b: Point): Bool => a.x == b.x
def opHash(p: Point): UInt => 0
def opString(p: Point): String => \"point\"
def opEquals<T>(a: Box<T>, b: Box<T>): Bool => true
def opHash<T>(b: Box<T>): UInt => 0
def opString<B, A>(p: Pair<A, B>): String => \"pair\"
def hash(p: Point): Int => p.x
def main(): Unit {}").shouldHaveNoDiagnostics();

    rejects("def opEquals(a: Point, b: Int): Bool => true");
    rejects("def opEquals(a: Point): Bool => true");
    rejects("def opEquals(a: Int, b: Int): Bool => true");
    rejects("def opString(p: Point): Int => p.x");
    rejects("def opString(text: String): String => text");
    rejects("def opString(mutable p: Point): String => \"point\"");
    rejects("def opHash(p: Point): Int => p.x");
    rejects("def opHash(n: Int): UInt => 0");
    rejects("def opString(b: Box<Int>): String => \"box\"");
    rejects("def opString<T>(p: Pair<T, T>): String => \"pair\"");
    rejects("def opString<T: Named>(b: Box<T>): String => name(b.value)");
    rejects("def opString<T, U>(b: Box<T>): String => \"box\"");
    rejects("def opEquals(a: Point, b: Point): Bool => true");
    rejects("def opHash(p: Point): UInt => 0");
}

@("arithmetic on anything but two numbers calls opAdd, opSub, opMul, opDiv, opRem or opNeg, typed by what the function returns")
unittest
{
    enum vec = "type V(x: Float)
def opAdd(a: V, b: V): V => a
def opSub(a: V, b: V): V => a
def opMul(a: V, k: Float): V => a
def opMul(k: Float, a: V): V => a
def opMul(a: V, b: V): Float => 1.0
def opDiv(a: V, k: Float): V => a
def opRem(a: V, k: Float): V => a
def opNeg(a: V): V => a
";
    auto a = analyzed(vec ~ "def main(): Unit {
    val p = V(1.0)
    val sum = p + p
    val scaled = 2 * p
    val literal = p * 2
    val dot = p * p
    val negated = -p
    val rest = p / 2.0 % 3.0
    mutable val q = p
    q += p
    q -= p
}");
    a.shouldHaveNoDiagnostics();
    a.shouldTypeEveryExpression();
    a.shouldDeclareType(At("sum", 1), "V");
    a.shouldDeclareType(At("scaled", 1), "V");
    a.shouldDeclareType(At("literal", 1), "V");
    a.shouldDeclareType(At("dot", 1), "Float");
    a.shouldDeclareType(At("negated", 1), "V");
    a.shouldDeclareType(At("rest", 1), "V");
}

@("an operator with no function that takes its operands is an error naming the operator, the function and the operands, at the first operand that isn't a number")
unittest
{
    enum point = "type P(x: Int)\ndef opMul(p: P, k: Int): P => p\n";
    analyzed(point ~ "def main(): Unit => print(P(1) / 2)").shouldReport(DiagnosticCode.InvalidOperand, At("P(1)", 1));
    analyzed(point ~ "def main(): Unit => print(2 * P(1))").shouldReport(DiagnosticCode.InvalidOperand, At("P(1)", 1));
    analyzed(point ~ "def main(): Unit => print(-P(1))").shouldReport(DiagnosticCode.InvalidOperand, At("P(1)", 1));
    analyzed(point ~ "def main(): Unit => print(P(1) * 1.5)").shouldReport(DiagnosticCode.NoMatchingOverload, At("P(1) * 1.5", 1));
    // The wrapping operators have no function, and are as they were.
    analyzed(point ~ "def main(): Unit => print(P(1) +% P(1))").shouldReport(DiagnosticCode.InvalidOperand, At("P(1)", 1));
    // Two numbers are built in, whatever functions are in scope.
    analyzed("def opAdd<T>(a: T, b: T): T => a\ndef main(): Unit {\n    val i = 1\n    val f = 1.5\n    print(i + f)\n}")
        .shouldReport(DiagnosticCode.InvalidOperand, At("i + f", 1));
}

@("an arithmetic operator function that takes only built-in numbers is an error, and a generic one isn't")
unittest
{
    analyzed("def opAdd(a: Int, b: Int): Int => a\ndef main(): Unit {}").shouldReport(DiagnosticCode.InvalidOperatorFunction, At("opAdd", 1));
    analyzed("def opMul(a: Int, b: Float): Float => b\ndef main(): Unit {}").shouldReport(DiagnosticCode.InvalidOperatorFunction, At("opMul", 1));
    analyzed("def opNeg(a: UInt8): UInt8 => a\ndef main(): Unit {}").shouldReport(DiagnosticCode.InvalidOperatorFunction, At("opNeg", 1));
    analyzed("def opAdd(a: Float32, b: Float32): Float32 => a\ndef main(): Unit {}").shouldReport(DiagnosticCode.InvalidOperatorFunction, At("opAdd", 1));
    analyzed("def opDiv(a: Float32, b: Int): Float32 => a\ndef main(): Unit {}").shouldReport(DiagnosticCode.InvalidOperatorFunction, At("opDiv", 1));
    analyzed("def opAdd<T>(a: T, b: T): T => a
def opMul(a: String, k: Int): String => a
def opAdd(a: Int, b: String, c: Int): Int => a
type V(x: Float)
def opNeg(a: V): V => a
def main(): Unit => print(1 + 2)").shouldHaveNoDiagnostics();
}

@("a function of the operator's name with no parameters is not a candidate, for arithmetic or indexing")
unittest
{
    analyzed("type V(x: Int)\ndef opAdd(): Int => 1\ndef main(): Unit => print(V(1) + V(2))")
        .shouldReport(DiagnosticCode.InvalidOperand, At("V(1)", 1));
    analyzed("type V(x: Int)\ndef opNeg(): Int => 1\ndef main(): Unit => print(-V(1))")
        .shouldReport(DiagnosticCode.InvalidOperand, At("V(1)", 1));
    analyzed("type V(x: Int)\ndef opIndex(): Int => 1\ndef opIndex(v: V, i: Int): Int => i\ndef main(): Unit => print(V(1)[2])")
        .shouldHaveNoDiagnostics();
    analyzed("type V(x: Int)\ndef opIndex(): Int => 1\ndef main(): Unit => print(V(1)[2])")
        .shouldReport(DiagnosticCode.InvalidOperand, At("V(1)", 1));
}

@("an operand fitted by its shape is typed as the call's argument is, and reported once")
unittest
{
    enum v = "type V(x: Int)\n";
    analyzed(v ~ "def opSub(a: V, b: [Float]): V => a\ndef main(): Unit => print(V(1) - [1, 2.5])").shouldHaveNoDiagnostics();
    analyzed(v ~ "def opMul(a: V, b: (Int, [Float])): V => a\ndef main(): Unit => print(V(1) * (1, [1, 2.5]))").shouldHaveNoDiagnostics();
    analyzed(v ~ "def opDiv(a: V, b: (Int8?)?): V => a\ndef main(): Unit => print(V(1) / Some(None))").shouldHaveNoDiagnostics();
    analyzed(v ~ "def opDiv(a: V, f: (Int) -> Int): V => a\ndef main(): Unit => print(V(1) / (x => x + 1))").shouldHaveNoDiagnostics();
    analyzed(v ~ "def opSub(a: V, b: Int8): V => a\ndef main(): Unit => print(V(1) - 100)").shouldHaveNoDiagnostics();
    analyzed(v ~ "def opSub(a: V, b: Int8): V => a\ndef main(): Unit => print(V(1) - 200)")
        .shouldReport(DiagnosticCode.LiteralOutOfRange, At("200", 1));
    analyzed(v ~ "def opNeg(a: [Float]): V => V(1)\ndef main(): Unit => print(-[1, 2.5])").shouldHaveNoDiagnostics();
    analyzed(v ~ "def opAdd(a: String, b: V): V => b\ndef main(): Unit => print(\"s\" + V(1))").shouldHaveNoDiagnostics();
}

@("an operand that never returns fits any parameter, as it does in a call")
unittest
{
    analyzed("type V(x: Int)\ndef opAdd(a: V, b: V): V => a\ndef main(): Unit => print(V(1) + panic(\"y\"))")
        .shouldHaveNoDiagnostics();
    analyzed("type V(x: Int)\ndef opAdd(a: V, b: V): V => a\ndef main(): Unit => print(panic(\"y\") + V(1))")
        .shouldHaveNoDiagnostics();
}

@("a + with no opAdd for a String or an array operand says that ~ joins them, and only then")
unittest
{
    void hints(string source, string text)
    {
        auto a = analyzed(source);
        assert(a.collector.diagnostics.length == 1, source);
        auto message = a.collector.diagnostics[0].message;
        assert(a.collector.diagnostics[0].code == DiagnosticCode.InvalidOperand, message);
        assert(text is null ? !message.canFind("joins") : message.canFind(text), message);
    }
    hints("def main(): Unit => print(\"a\" + \"b\")", "`~` joins strings");
    hints("def main(): Unit {\n    val s = \"a\"\n    print(s + 1)\n}", "`~` joins strings");
    hints("def main(): Unit => print([1] + [2])", "`~` joins arrays");
    hints("def main(): Unit {\n    val xs = [1]\n    print(xs + 2)\n}", "`~` joins arrays");
    hints("def main(): Unit => print(\"a\" - \"b\")", null);
    hints("def main(): Unit {\n    val o: Int? = None\n    print(o + 1)\n}", null);
    analyzed("def opAdd(a: String, b: String): String => a\ndef main(): Unit => print(\"a\" + \"b\")").shouldHaveNoDiagnostics();
}

@("an operator that calls a function can't be in a top-level constant")
unittest
{
    analyzed("def opAdd(a: String, b: String): String => a\nval c: String = \"a\" + \"b\"\ndef main(): Unit => print(c)")
        .shouldReport(DiagnosticCode.NonConstantInitializer, At("\"a\" + \"b\"", 1));
    analyzed("val c: Int = 1 + 2 * 3\ndef main(): Unit => print(c)").shouldHaveNoDiagnostics();
}
