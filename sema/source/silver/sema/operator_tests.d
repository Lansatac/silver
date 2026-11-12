/// Tests of operator functions: indexing, slicing and assigning elements of anything but an array.
module silver.sema.operator_tests;

version (unittest):

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType, shouldTypeEveryExpression;
import silver.sema.resolution_tests;

private enum window = "type W<T>(items: [T])
def length<T>(w: W<T>): Int => length(w.items)
def opIndex<T>(w: W<T>, index: Int): T => w.items[index]
def opIndexAssign<T>(w: W<T>, index: Int, value: T): W<T> => W(w.items.opIndexAssign(index, value))
def opSlice<T>(w: W<T>, from: Int, to: Int): W<T> => W(w.items[from..to])
";

@("x[i], x[a..b] and x[i] = v call opIndex, opSlice and opIndexAssign, typed by what they return and take")
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
    analyzed(point ~ "def main(): Unit => print(P(1)[0..1])").shouldReport(DiagnosticCode.InvalidOperand, At("P(1)", 1));
    analyzed(point ~ "def opSlice(p: P, from: Int, to: Int): P => p\ndef main(): Unit => print(P(1)[0..])")
        .shouldReport(DiagnosticCode.InvalidOperand, At("P(1)", 1));
    analyzed(point ~ "def opIndex(p: P, i: Int): Int => 1\ndef main(): Unit {\n    mutable val p = P(1)\n    p[0] = 2\n}")
        .shouldReport(DiagnosticCode.InvalidOperand, At("p[0]", 1));
}

@("opIndexAssign has to take and return the value assigned back to, and a left-out bound has to fit opSlice exactly")
unittest
{
    enum point = "type P(x: Int)\n";
    enum main = "def main(): Unit {\n    mutable val p = P(1)\n    p[0] = 2\n}";
    analyzed(point ~ "def opIndexAssign(p: P, i: Int, v: Int): Int => v\n" ~ main)
        .shouldReport(DiagnosticCode.TypeMismatch, At("p[0]", 1));
    analyzed(point ~ "def opIndexAssign(p: P?, i: Int, v: Int): P => P(v)\n" ~ main)
        .shouldReport(DiagnosticCode.TypeMismatch, At("p[0]", 1));
    analyzed(point ~ "def opSlice(p: P, from: UInt8, to: UInt8): P => p\ndef main(): Unit => print(P(1)[..2])")
        .shouldReport(DiagnosticCode.NoMatchingOverload, At("P(1)[..2]", 1));
    analyzed(point ~ "def opSlice(p: P, from: Int?, to: Int): P => p\ndef main(): Unit => print(P(1)[..2])")
        .shouldReport(DiagnosticCode.TypeMismatch, At("P(1)[..2]", 1));
    analyzed(point ~ "def length(p: P): Int => 1\ndef opSlice(p: P, from: Int, to: Int?): P => p\n"
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
        ~ "    xs = xs.opIndexAssign(0, 3)\n    print(xs.opSlice(0, 1))\n}").shouldHaveNoDiagnostics();
    analyzed("def main(): Unit {\n    val i: UInt8 = 0\n    print(opIndex([1], i))\n}").shouldReport(DiagnosticCode.TypeMismatch, At("i", 2));
}
