/// Tests of overloading: which declarations of one name can coexist, and which one a call or a
/// function value chooses.
module silver.sema.overload_tests;

version (unittest):

import std.algorithm : canFind;

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldHaveType;
import silver.sema.resolution_tests;
import silver.sema.target : Target;

/// `body` in `main`, after `declarations`.
private Analyzed analyzedWith(string declarations, string body)
{
    return analyzed(declarations ~ "\ndef main(): Unit {\n" ~ body ~ "\n}");
}

// Declarations

@("functions of one name can differ in their parameter types or in how many they take")
unittest
{
    analyzed("def f(x: Int): Unit => ()\ndef f(x: String): Unit => ()\ndef f(x: Int, y: Int): Unit => ()\ndef main(): Unit => ()")
        .shouldHaveNoDiagnostics();
}

@("two functions of one name can't take the same parameter types")
unittest
{
    analyzed("def f(x: Int): Unit => ()\ndef f(y: Int): String => \"a\"\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
}

@("functions that differ only in which parameters are mutable are overloads")
unittest
{
    enum decls = "type G(n: Int)\ndef advance(g: G): Int => 1\ndef advance(mutable g: G): String => \"\"";
    analyzed(decls ~ "\ndef main(): Unit => ()").shouldHaveNoDiagnostics();
    auto a = analyzedWith(decls, "mutable val g = G(1)\nval a = advance(g)\nval b = advance(mutable g)\nval c = g.advance()");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("advance(g)", "Int");
    a.shouldHaveType("advance(mutable g)", "String");
    a.shouldHaveType("g.advance()", "Int");
    analyzedWith(decls, "val p: (G) -> Int = advance\nval q: (mutable G) -> String = advance").shouldHaveNoDiagnostics();
}

@("a call without mutable doesn't reach the only mutable function")
unittest
{
    enum decls = "type G(n: Int)\ndef advance(mutable g: G): Int => 1";
    auto a = analyzedWith(decls, "mutable val g = G(1)\nval a = advance(g)");
    a.shouldReport(DiagnosticCode.MutabilityMismatch, At("g", 3));
    assert(a.collector.diagnostics[0].message.canFind("`mutable`"));
    analyzedWith(decls, "mutable val g = G(1)\nval a = g.advance()").shouldReport(DiagnosticCode.MutabilityMismatch, At("g", 3));
}

@("a candidate that fits but for mutable says so in the listing")
unittest
{
    auto a = analyzedWith("def f(x: Int, y: Int): Unit => ()\ndef f(mutable x: Int, y: String): Unit => ()",
        "mutable val v = 1\nf(v, true)");
    a.shouldReport(DiagnosticCode.NoMatchingOverload, At("f", 3));
    assert(a.collector.diagnostics[0].message.canFind("argument 1 has to be passed as `mutable`"));
}

@("two functions with the same mutable parameters are still duplicates")
unittest
{
    auto a = analyzed("def f(mutable x: Int): Unit => ()\ndef f(mutable y: Int): Unit => ()\ndef main(): Unit => ()");
    a.shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    assert(!a.collector.diagnostics[0].message.canFind("`mutable` alone"));
}

@("nested defs that differ only in mutable are overloads")
unittest
{
    analyzedWith("", "def f(x: Int): Int => 1\ndef f(mutable x: Int): String => \"\"\nmutable val v = 1\nval a = f(v)\nval b = f(mutable v)")
        .shouldHaveNoDiagnostics();
    analyzedWith("", "def f(mutable x: Int): Int => 1\ndef f(mutable y: Int): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
}

@("a forwarded and a listed function that differ only in mutable don't clash")
unittest
{
    auto files = [
        "a.ag": "module a\ndef same(x: Int): Int => 1",
        "b.ag": "module b\ndef same(mutable y: Int): Int => 2",
        "two.ag": "module two\nforward import a : same\nforward import b : same",
        "own.ag": "module own\nforward import a : same\ndef same(mutable z: Int): Int => 3",
    ];
    analyzed("import two\nimport own\ndef main(): Unit => ()", files).shouldHaveNoDiagnostics();
}

@("generic overloads are the same when only their type parameters' names differ")
unittest
{
    analyzed("def f<T>(x: T): Unit => ()\ndef f<U>(x: U): Unit => ()\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzed("def f<A, B>(x: A, y: B): Unit => ()\ndef f<B, A>(x: B, y: A): Unit => ()\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzed("def f<A, B>(x: A, y: B): Unit => ()\ndef f<A>(x: A, y: A): Unit => ()\ndef f<T>(x: T): Unit => ()\n"
        ~ "def f(x: Int): Unit => ()\ndef f<T>(x: [T]): Unit => ()\ndef main(): Unit => ()").shouldHaveNoDiagnostics();
}

@("an alias doesn't make an overload")
unittest
{
    analyzed("alias Count = Int\ndef f(x: Int): Unit => ()\ndef f(x: Count): Unit => ()\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
}

@("natives that bind one symbol need signatures C passes alike, wherever they are and whether or not they are called")
unittest
{
    enum main = "\ndef main(): Unit => ()";
    // Int64 and UInt64 cross alike, Int8 and UInt8 don't.
    analyzed(`native("abs") def a(x: Int64): Int64
native("abs") def b(x: UInt64): UInt64` ~ main).shouldHaveNoDiagnostics();
    analyzed(`native("abs") def a(x: Int8): Int8
native("abs") def b(x: UInt8): UInt8` ~ main).shouldReport(DiagnosticCode.NativeSymbolMismatch, At("b", 1));
    auto message = analyzed(`native("abs") def a(x: Int32): Int32
native("abs") def b(x: Float): Float` ~ main).onlyMessage(DiagnosticCode.NativeSymbolMismatch);
    assert(message.canFind("`b` binds the C symbol `abs` as `(Float) -> Float`"));
    assert(message.canFind("`main.a` at "));
    // A different number of parameters, and a result that never returns, differ too.
    analyzed(`native("f") def a(x: Int): Int
native("f") def b(x: Int, y: Int): Int` ~ main).shouldReport(DiagnosticCode.NativeSymbolMismatch, At("b", 1));
    analyzed(`native("f") def a(): Unit
native("f") def b(): Never` ~ main).shouldReport(DiagnosticCode.NativeSymbolMismatch, At("b", 1));
    // A narrow result is extended differently as signed and as unsigned.
    analyzed(`native("abs") def a(x: Int32): Int8
native("abs") def b(x: Int32): UInt8` ~ main).shouldReport(DiagnosticCode.NativeSymbolMismatch, At("b", 1));
    // Structures by value: of different sizes, and one that crosses like a 64-bit integer on Windows
    // but in a float register on System V, so a program can't depend on the platform.
    enum structures = "native type P(a: Int32, b: Int32)\nnative type Q(a: Int32, b: Int32, c: Int32)\n"
        ~ "native type F(a: Float32, b: Float32)\n";
    analyzed(structures ~ `native("s") def sa(x: P): Int
native("s") def sb(x: Q): Int` ~ main).shouldReport(DiagnosticCode.NativeSymbolMismatch, At("sb", 1));
    analyzed(structures ~ `native("s") def sa(x: F): Int
native("s") def sb(x: Int): Int` ~ main).shouldReport(DiagnosticCode.NativeSymbolMismatch, At("sb", 1));
    analyzed(structures ~ `native("s") def sa(x: P): Int
native("s") def sb(x: P): Int` ~ main).shouldHaveNoDiagnostics();
    // Across modules, including the standard library's: `lang.time` binds the runtime's `silver_nowNanos`.
    auto lib = ["lib.ag": "module lib\nnative(\"abs\") def a(x: Int8): Int8"];
    analyzed("import lib\nnative(\"abs\") def b(x: Int32): Int32" ~ main, lib)
        .shouldReport(DiagnosticCode.NativeSymbolMismatch, At("b", 1));
    analyzed("import std.time\nnative(\"silver_nowNanos\") def now(): Int32" ~ main)
        .shouldReport(DiagnosticCode.NativeSymbolMismatch, At("now", 1));
    analyzed("import std.time\nnative(\"silver_nowNanos\") def now(): Int" ~ main).shouldHaveNoDiagnostics();
}

@("a native that binds a symbol the standard library binds differently is reported at the program's own declaration")
unittest
{
    import std.algorithm : endsWith;

    // `aaa` sorts before `lang.time`, but the standard library's declaration isn't the user's to change.
    auto a = analyzed("import std.time
import aaa
def main(): Unit => ()",
        ["aaa.ag": "module aaa
native(\"silver_nowNanos\") def now(): Int32"]);
    a.shouldReport(DiagnosticCode.NativeSymbolMismatch, At("now", 1, "aaa"));
    assert(a.collector.diagnostics[0].span.file.endsWith("aaa.ag"), a.collector.diagnostics[0].span.file);
}

@("a third native that binds a symbol like the first isn't reported against the second, already reported")
unittest
{
    analyzed("native(\"abs\") def a(x: Int32): Int32
native(\"abs\") def b(x: Int8): Int8
"
        ~ "native(\"abs\") def c(x: Int32): Int32
def main(): Unit => ()")
        .shouldReport(DiagnosticCode.NativeSymbolMismatch, At("b", 1));
}

@("two natives of one name need different symbols")
unittest
{
    analyzed("native def f(x: Float): Float\nnative def f(x: Int): Int\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzed("native def f(x: Float): Float\nnative(\"g\") def f(x: Int): Int\ndef f(x: Bool): Bool => x\ndef main(): Unit => ()")
        .shouldHaveNoDiagnostics();
}

@("functions of one name in different modules are never duplicates")
unittest
{
    analyzed("import lib\ndef f(x: Int): Unit => ()\ndef main(): Unit => ()", ["lib.ag": "module lib\ndef f(x: Int): Unit => ()"])
        .shouldHaveNoDiagnostics();
}

// Choosing by the arguments' types

private enum shows = "def show(x: Int): Unit => ()\ndef show(x: String): Unit => ()\ndef show(x: Bool): Unit => ()";

@("a call chooses the overload its argument's type fits")
unittest
{
    auto a = analyzedWith(shows, "    val i = 1\n    val s = \"a\"\n    show(i)\n    show(s)\n    show(true)\n    show(1)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("show", 4), At("show", 1));
    a.shouldCall(At("show", 5), At("show", 2));
    a.shouldCall(At("show", 6), At("show", 3));
    a.shouldCall(At("show", 7), At("show", 1));
    a.shouldHaveType("show(s)", "Unit");
}

@("a call that no overload fits lists each one and why")
unittest
{
    auto a = analyzedWith(shows, "    show(1.5)");
    a.shouldReport(DiagnosticCode.NoMatchingOverload, At("show", 4));
    auto message = a.collector.diagnostics[0].message;
    assert(message.canFind("show(Int) argument 1 is `Float`, not `Int`"), message);
    assert(message.canFind("show(Bool)"), message);
    analyzedWith(shows, "    show(1, 2)").shouldReport(DiagnosticCode.NoMatchingOverload, At("show", 4));
}

@("the number of arguments alone can choose, and then arguments adapt as for a lone function")
unittest
{
    auto a = analyzedWith("def f(x: UInt8): Unit => ()\ndef f(x: Int, y: Int): Unit => ()",
        "    val r = f(if true => 1 else 2)\n    f(3, 4)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 1));
    a.shouldCall(At("f", 4), At("f", 2));
}

@("an exact match beats a promotion")
unittest
{
    auto a = analyzedWith("def f(x: Int): Unit => ()\ndef f(x: Int?): Unit => ()",
        "    val i = 1\n    val o: Int? = 1\n    f(i)\n    f(o)\n    f(None)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 1));
    a.shouldCall(At("f", 4), At("f", 2));
    a.shouldCall(At("f", 5), At("f", 2));
}

@("overload choice binds a function's type parameters as the call of it would, the expected type too")
unittest
{
    // What the expected type binds rules out the generic function, whose argument couldn't be it.
    auto a = analyzedWith("def g<T>(x: T): [T] => [x]\ndef g(x: Int?): [String] => []", "    val xs: [String] = g(1)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("g", 3), At("g", 2));
}

@("fewer promotion steps beat more, counting each layer and each injection")
unittest
{
    enum types = "type Box<T>(value: T)\ntype Held = :Box<Int> | :Box<String>\ntype Oops(code: Int)\ntype Mine = :Int | :String\n";
    auto a = analyzedWith(types ~ "def g(h: Held?): Unit => ()\ndef g(b: Box<Int>?): Unit => ()\n"
        ~ "def n(x: (Int?)?): Unit => ()\ndef n(x: Int ! Oops): Unit => ()\n"
        ~ "def m(x: Mine?): Unit => ()\ndef m(x: Int?): Unit => ()",
        "    g(Box(1))\n    val i = 1\n    n(i)\n    n(1)\n    m(i)\n    m(1)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("g", 3), At("g", 2));
    a.shouldCall(At("n", 3), At("n", 2));
    a.shouldCall(At("n", 4), At("n", 2));
    a.shouldCall(At("m", 3), At("m", 2));
    a.shouldCall(At("m", 4), At("m", 2));

    // An injection and a layer are one step each, so they tie.
    analyzedWith(types ~ "def k(h: Held): Unit => ()\ndef k(b: Box<Int>?): Unit => ()", "    k(Box(1))")
        .shouldReport(DiagnosticCode.AmbiguousOverload, At("k", 3));
}

@("a literal prefers its default type, and two other types tie")
unittest
{
    auto a = analyzedWith("def f(x: Int8): Unit => ()\ndef f(x: Int): Unit => ()\ndef g(x: Int8): Unit => ()\ndef g(x: String): Unit => ()",
        "    f(1)\n    g(1)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 2));
    a.shouldCall(At("g", 3), At("g", 1));
    analyzedWith("def f(x: Int8): Unit => ()\ndef f(x: Int16): Unit => ()", "    f(1)")
        .shouldReport(DiagnosticCode.AmbiguousOverload, At("f", 3));
}

@("an integer literal is an integer first, and a float only where no integer type fits")
unittest
{
    auto a = analyzedWith("def f(x: Int): Unit => ()\ndef f(x: Float): Unit => ()\n"
        ~ "def h(x: Int8): Unit => ()\ndef h(x: Float): Unit => ()\n"
        ~ "def k(x: Float32): Unit => ()\ndef k(x: Float): Unit => ()\n"
        ~ "def p(x: Int8?): Unit => ()\ndef p(x: Float32?): Unit => ()\n"
        ~ "def q(x: [Float32]): Unit => ()\ndef q(x: [UInt16]): Unit => ()",
        "    f(1)\n    h(1)\n    h(-1)\n    k(1)\n    k(-1)\n    p(1)\n    q([1, 2])");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 1));
    a.shouldCall(At("h", 3), At("h", 1));
    a.shouldCall(At("h", 4), At("h", 1));
    a.shouldCall(At("k", 3), At("k", 2));
    a.shouldCall(At("k", 4), At("k", 2));
    a.shouldCall(At("p", 3), At("p", 1));
    a.shouldCall(At("q", 3), At("q", 2));
    a.shouldHaveType("1", 4, "Float");

    // Two integer types still tie, and so do two functions that each read a different argument as a float.
    analyzedWith("def g(x: Int8, y: Float): Unit => ()\ndef g(x: Float, y: Int8): Unit => ()", "    g(1, 2)")
        .shouldReport(DiagnosticCode.AmbiguousOverload, At("g", 3));
}

@("how a literal reads only decides between functions that fit a call alike")
unittest
{
    // Fewer steps first: the option is a step more than the Float.
    auto a = analyzedWith("def m(x: Int8?): Unit => ()\ndef m(x: Float): Unit => ()\n"
        ~ "def n(x: Float): Unit => ()\ndef n<T>(x: T?): Unit => ()\n"
        ~ "def s(x: Int8, y: String?): Unit => ()\ndef s(x: Float, y: String): Unit => ()",
        "    m(1)\n    n(1)\n    s(1, \"a\")");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("m", 3), At("m", 2));
    // A function that isn't generic is chosen over one that is before literals are read.
    a.shouldCall(At("n", 3), At("n", 1));
    a.shouldCall(At("s", 3), At("s", 2));
}

@("nested overloads read an integer literal as an integer first")
unittest
{
    auto a = analyzed("def main(): Unit {\n    def h(x: Int8): Unit => ()\n    def h(x: Float): Unit => ()\n"
        ~ "    def k(x: Float32): Unit => ()\n    def k(x: Float): Unit => ()\n    h(1)\n    k(1)\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("1", 1, "Int8");
    a.shouldHaveType("1", 2, "Float");
}

@("a call is ambiguous when no overload fits every argument at least as well as the others")
unittest
{
    auto a = analyzedWith("def f(x: Int, y: Int?): Unit => ()\ndef f(x: Int?, y: Int): Unit => ()", "    val i = 1\n    f(i, i)");
    a.shouldReport(DiagnosticCode.AmbiguousOverload, At("f", 3));
    auto message = a.collector.diagnostics[0].message;
    assert(message.canFind("`f(Int, Int?)` and `f(Int?, Int)`"), message);
}

@("an argument that's already wrong doesn't make the call ambiguous too")
unittest
{
    analyzedWith("def f(x: Int, y: Int?): Unit => ()\ndef f(x: Int?, y: Int): Unit => ()", "    val i = 1\n    f(nope, i)")
        .shouldReport(DiagnosticCode.UnknownName, At("nope", 1));
}

@("mutable arguments choose an overload with a mutable parameter of exactly their type")
unittest
{
    auto a = analyzedWith("def f(mutable x: Int): Unit => ()\ndef f(mutable x: String): Unit => ()\ndef f(x: Bool): Unit => ()",
        "    mutable val n = 1\n    mutable val s = \"a\"\n    f(mutable n)\n    f(mutable s)\n    f(true)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 4), At("f", 1));
    a.shouldCall(At("f", 5), At("f", 2));
    a.shouldCall(At("f", 6), At("f", 3));
    analyzedWith("def f(mutable x: Int): Unit => ()\ndef f(x: String): Unit => ()", "    val n = 1\n    f(n)")
        .shouldReport(DiagnosticCode.NoMatchingOverload, At("f", 3));
}

@("array, tuple and Some literals are compared by their shape")
unittest
{
    auto a = analyzedWith("def f(x: [UInt8]): Unit => ()\ndef f(x: String): Unit => ()\n"
        ~ "def g(x: (Int8, String)): Unit => ()\ndef g(x: Bool): Unit => ()\n"
        ~ "def h(x: UInt8?): Unit => ()\ndef h(x: [Int]): Unit => ()",
        "    f([1, 2])\n    g((1, \"a\"))\n    h(Some(1))\n    h([])");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 1));
    a.shouldCall(At("g", 3), At("g", 1));
    a.shouldCall(At("h", 3), At("h", 1));
    a.shouldCall(At("h", 4), At("h", 2));
}

// Lambdas

@("a lambda chooses by how many parameters it has, and is then checked against the one chosen")
unittest
{
    auto a = analyzedWith("def apply(f: (Int) -> Unit): Unit => f(1)\ndef apply(f: (Int, Int) -> Unit): Unit => f(1, 2)",
        "    apply(x => ())\n    apply((x, y) => ())");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("apply", 3), At("apply", 1));
    a.shouldCall(At("apply", 4), At("apply", 2));
}

@("a lambda whose parameters say nothing can't choose between parameter types, and an annotated one can")
unittest
{
    enum decls = "def apply(f: (Int) -> Unit): Unit => f(1)\ndef apply(f: (String) -> Unit): Unit => f(\"a\")";
    analyzedWith(decls, "    apply(x => ())").shouldReport(DiagnosticCode.AmbiguousOverload, At("apply", 3));
    auto a = analyzedWith(decls, "    apply((x: String) => ())");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("apply", 3), At("apply", 2));
}

// Generics

@("a function that isn't generic beats a generic one that fits as well")
unittest
{
    auto a = analyzedWith("def f<T>(x: T): Unit => ()\ndef f(x: Int): Unit => ()", "    f(1)\n    f(\"a\")");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 2));
    a.shouldCall(At("f", 4), At("f", 1));
}

@("a generic exact match beats a promotion")
unittest
{
    auto a = analyzedWith("def f<T>(x: T): Unit => ()\ndef f(x: Int?): Unit => ()", "    val i = 1\n    f(i)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 1));
}

@("the more specific generic wins")
unittest
{
    auto a = analyzedWith("def f<T>(x: T): Unit => ()\ndef f<T>(x: [T]): Unit => ()", "    val xs = [1]\n    f(xs)\n    f(1)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 2));
    a.shouldCall(At("f", 4), At("f", 1));
}

@("a generic overload's parameters have to fit together")
unittest
{
    auto a = analyzedWith("def f<T>(x: T, y: T): Unit => ()\ndef f(x: Int, y: String): Unit => ()",
        "    f(1, \"a\")\n    f(\"a\", \"b\")");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 2));
    a.shouldCall(At("f", 4), At("f", 1));
    analyzedWith("def f<T>(x: [T]): Unit => ()\ndef f(x: String): Unit => ()", "    f(1)")
        .shouldReport(DiagnosticCode.NoMatchingOverload, At("f", 3));
}

@("written type arguments only fit a generic overload with that many")
unittest
{
    auto a = analyzedWith("def f<T>(x: T): Unit => ()\ndef f(x: Int): Unit => ()\ndef f<A, B>(x: A, y: B): Unit => ()",
        "    f<Int>(1)\n    f(1)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 4), At("f", 1));
    a.shouldCall(At("f", 5), At("f", 2));
}

// Modules

private enum libraries = [
    "a.ag": "module a\ndef shared(x: Int): Unit => ()\ndef only(x: Int): Unit => ()",
    "b.ag": "module b\ndef shared(x: String): Unit => ()\ndef shared(x: Bool): Unit => ()\ndef only(x: Int?): Unit => ()",
];

@("overloads in different imported modules combine when only one module's fits")
unittest
{
    auto a = analyzed("import a\nimport b\ndef main(): Unit {\n    shared(1)\n    shared(\"a\")\n    b.shared(true)\n}", libraries);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("shared", 1), At("shared", 1, "a"));
    a.shouldCall(At("shared", 2), At("shared", 1, "b"));
    a.shouldCall(At("shared", 3), At("shared", 2, "b"));
}

@("an imported function that fits exactly and isn't generic beats other modules' that convert")
unittest
{
    auto a = analyzed("import a\nimport b\ndef main(): Unit {\n    only(1)\n    val n = 2\n    n.only()\n}", libraries);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("only", 1), At("only", 1, "a"));
    a.shouldCall(At("only", 2), At("only", 1, "a"));
    auto b = analyzed("import a\nimport b\ndef main(): Unit {\n    b.only(1)\n}", libraries);
    b.shouldHaveNoDiagnostics();
    b.shouldCall(At("only", 1), At("only", 1, "b"));
}

@("an imported function that fits exactly and isn't generic beats other modules' generic ones")
unittest
{
    auto files = [
        "foo.ag": "module foo\ntype Foo(x: Int)\ndef toJson(f: Foo): String => \"foo\"",
        "json.ag": "module json\ndef toJson<T>(x: T?): String => \"any\"\ndef toJson<T>(xs: [T]): String => \"array\"",
    ];
    auto a = analyzed("import foo\nimport json\ndef main(): Unit {\n    val f = Foo(1)\n"
        ~ "    val s = toJson(f)\n    val t = f.toJson()\n    val u = toJson([f])\n}", files);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("toJson", 1), At("toJson", 1, "foo"));
    a.shouldCall(At("toJson", 2), At("toJson", 1, "foo"));
    a.shouldCall(At("toJson", 3), At("toJson", 2, "json"));
}

@("a call that functions of two imported modules fit equally well is ambiguous, and one that fits better is chosen")
unittest
{
    auto files = [
        "a.ag": "module a\ndef f(x: Int): Unit => ()\ndef g(x: Int?): Unit => ()\ndef h<T>(x: T): Unit => ()",
        "b.ag": "module b\ndef f(x: Int): Unit => ()\ndef g(x: Int?): Unit => ()\ndef h(x: Int?): Unit => ()",
    ];
    foreach (call; ["f", "g"])
    {
        analyzed("import a\nimport b\ndef main(): Unit {\n    " ~ call ~ "(1)\n}", files)
            .shouldReport(DiagnosticCode.AmbiguousName, At(call, 1));
    }
    auto h = analyzed("import a\nimport b\ndef main(): Unit {\n    h(1)\n}", files);
    h.shouldHaveNoDiagnostics();
    h.shouldCall(At("h", 1), At("h", 1, "a"));
}

@("a conformance chooses among imported modules by fit as a call does")
unittest
{
    auto files = [
        "down.ag": "module down\ntype Down(n: Int)\ndef next(d: Down): (Int, Down)? => None",
        "gen.ag": "module gen\ndef next<T>(x: T?): (Int, T?)? => None",
    ];
    analyzed("import down\nimport gen\nconform Down: Range<Int>\ndef main(): Unit {\n    for x in Down(3) { print(x) }\n}", files)
        .shouldHaveNoDiagnostics();
}

@("this module's functions come first, unless an imported one takes the arguments in fewer steps")
unittest
{
    auto files = ["a.ag": libraries["a.ag"] ~ "\ndef tied(x: Int?): Unit => ()\ndef wide<T>(x: T): Unit => ()\ndef bare<T>(x: T): Unit => ()\ndef boxed<T>(xs: [T]): Unit => ()"
        ~ "\ndef mixed(x: Int, y: Int?): Unit => ()", "b.ag": "module b"];
    auto a = analyzed("import a\nimport b\ndef only(x: String): Unit => ()\ndef shared(x: Int?): Unit => ()\n"
        ~ "def tied<T>(x: T?): Unit => ()\ndef wide(x: Int): Unit => ()\ndef mixed(x: Int?, y: Int): Unit => ()\n"
        ~ "def bare(x: Int?): Unit => ()\ndef boxed(xs: [Int]?): Unit => ()\n"
        ~ "def main(): Unit {\n    val n = 1\n    val o: Int? = n\n"
        ~ "    only(\"a\")\n    only(1)\n    shared(1)\n    shared(n)\n    n.shared()\n    shared(o)\n"
        ~ "    tied(o)\n    wide(n)\n    mixed(n, n)\n    bare(n)\n    boxed([n])\n}", files);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("only", 2), At("only", 1));
    a.shouldCall(At("only", 3), At("only", 1, "a"));
    // `a.shared(Int)` takes an `Int` as it is, and this module's `shared(Int?)` promotes it.
    a.shouldCall(At("shared", 2), At("shared", 1, "a"));
    a.shouldCall(At("shared", 3), At("shared", 1, "a"));
    a.shouldCall(At("shared", 4), At("shared", 1, "a"));
    a.shouldCall(At("shared", 5), At("shared", 1));
    // Fitting alike, this module's is called, though the imported one is the more specific.
    a.shouldCall(At("tied", 2), At("tied", 1));
    a.shouldCall(At("wide", 2), At("wide", 1));
    // Better for one argument and worse for another isn't fewer steps.
    a.shouldCall(At("mixed", 2), At("mixed", 1));
    // A parameter that's only a type parameter takes anything, so it's never the nearer one.
    a.shouldCall(At("bare", 2), At("bare", 1));
    a.shouldCall(At("boxed", 2), At("boxed", 1, "a"));
}

@("a function over a sum leaves a member's own imported function to a call with the member")
unittest
{
    auto files = ["store.ag": "module store\ntype Store(items: [Int])\ndef size(s: Store): Int => 1\n"
        ~ "def opIndex(s: Store, key: String): Int => 2"];
    auto a = analyzed("import store\ntype Value = :Int | :Store\n"
        ~ "def size(v: Value): Int => match v {\n    s: Store => size(s)\n    _ => 0\n}\n"
        ~ "def opIndex(v: Value, key: String): Int => match v {\n    s: Store => s[key]\n    _ => 0\n}\n"
        ~ "def main(): Unit {\n    val v: Value = Store([])\n    print(size(v))\n    print(v[\"a\"])\n}", files);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("size", 2), At("size", 1, "store"));
    a.shouldCall(At("size", 3), At("size", 1));
}

@("this module's function of a name can call the prelude's")
unittest
{
    // The prelude's `show<T>` fits a `Point` too, as the real prelude's `printl<T>` does.
    auto prelude = ["kit/base.ag": "module kit.base\nforward import console",
        "console.ag": "module console\ndef show<T>(value: T): Unit => ()"];
    auto a = analyzed("type Point(x: Int, y: Int)\ndef show(p: Point): Unit => show(\"({p.x}, {p.y})\")\n"
        ~ "def main(): Unit => show(Point(1, 2))", prelude, Target.host, false, "kit.base");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("show", 2), At("show", 1, "console"));
    a.shouldCall(At("show", 3), At("show", 1));
}

@("a private overload isn't visible from another module")
unittest
{
    auto files = ["lib.ag": "module lib\nprivate def f(x: Int): Unit => ()\ndef f(x: String): Unit => ()"];
    analyzed("import lib\ndef main(): Unit {\n    lib.f(\"a\")\n    f(\"a\")\n}", files).shouldHaveNoDiagnostics();
    analyzed("import lib\ndef main(): Unit {\n    f(1)\n}", files).shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
}

// Method calls

@("x.f() chooses among overloads by the receiver's type")
unittest
{
    auto a = analyzedWith(shows, "    val i = 1\n    val r = i.show()\n    val s = \"a\".show()");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("show", 4), At("show", 1));
    a.shouldCall(At("show", 5), At("show", 2));
}

@("a literal receiver adapts to the overload it fits")
unittest
{
    auto a = analyzedWith("def f(x: UInt8): Unit => ()\ndef f(x: String): Unit => ()", "    (200).f()");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("f", 3), At("f", 1));
    a.shouldHaveType("200", "UInt8");
}

@("x.f() finds imported overloads as a plain name does")
unittest
{
    auto a = analyzed("import a\nimport b\ndef main(): Unit {\n    val r = true.shared()\n}", libraries);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("shared", 1), At("shared", 2, "b"));
}

// Function values

@("an overloaded function used as a value is chosen by its expected type")
unittest
{
    auto a = analyzedWith(shows ~ "\ndef call(f: (Bool) -> Unit): Unit => f(true)",
        "    val f: (String) -> Unit = show\n    val r = call(show)");
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("show", 4), At("show", 2));
    a.shouldResolve(At("show", 5), At("show", 3));
}

@("an overloaded function used as a value needs a type to choose by")
unittest
{
    analyzedWith(shows, "    val f = show").shouldReport(DiagnosticCode.AmbiguousOverload, At("show", 4));
    analyzedWith(shows, "    val f: (Float) -> Unit = show").shouldReport(DiagnosticCode.NoMatchingOverload, At("show", 4));
}

@("an overloaded function passed to an overloaded function chooses by the parameter's arity")
unittest
{
    auto a = analyzedWith(shows ~ "\ndef call(f: (Int) -> Unit): Unit => f(1)\ndef call(f: () -> Unit): Unit => f()",
        "    val r = call(show)");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("call", 3), At("call", 1));
    a.shouldResolve(At("show", 4), At("show", 1));
}

@("review: injection binds nothing during choice either, so a generic sum parameter doesn't fit a member")
unittest
{
    // `Box<Int>` against `W<T>` binds nothing, so the generic doesn't fit; `Box<Int>?` does in one step.
    auto a = analyzedWith("type Box<T>(value: T)\ntype W<T> = :Box<T> | :String\n"
        ~ "def g<T>(w: W<T>): Int => 1\ndef g(b: Box<Int>?): String => \"s\"", "    val r = g(Box(1))");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("g(Box(1))", "String");
}

// Nested defs

@("nested defs of one name are overloads when their parameter types differ")
unittest
{
    auto a = analyzedWith("", "    def f(x: Int): Int => x\n    def f(x: String): String => x\n    def f(x: Int, y: Int): Int => x + y\n"
        ~ "    val a = f(1)\n    val b = f(\"s\")\n    val c = f(1, 2)");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("f(1)", "Int");
    a.shouldHaveType("f(\"s\")", "String");
}

@("two nested defs of one name can't take the same parameter types, and a def can't join a val")
unittest
{
    analyzedWith("", "    def f(x: Int): Int => x\n    def f(y: Int): String => \"a\"").shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedWith("", "    val f = 1\n    def f(y: Int): Int => y").shouldReport(DiagnosticCode.DuplicateDeclaration, At("f", 2));
}

@("a call that ties only with an overload reported as a duplicate reports just the duplicate, even from the duplicate's own body")
unittest
{
    // The duplicate is reported on entering the block, before the body of either def is checked.
    analyzedWith("", "    def f(x: Int): String => \"a\"\n    def f(y: Int): String => f(1)\n    printl(f(2))")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedWith("def f(x: Int): String => \"a\"\ndef f(y: Int): String => f(1)", "    printl(f(2))")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    // Parameter types that name the enclosing function's type parameter are compared too.
    analyzedWith("def g<T>(x: T): Int {\n    def h(a: T): Int => 1\n    def h(b: T): Int => 2\n    h(x)\n}", "    printl(g(1))")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("h", 2));
    analyzedWith("def g<T>(x: T): Int {\n    def h(a: T): Int => 1\n    def h(b: [T]): Int => 2\n    h(x)\n}", "    printl(g(1))")
        .shouldHaveNoDiagnostics();
}

@("an overloaded name used as a value that matches only an overload and its reported duplicate reports just the duplicate")
unittest
{
    analyzedWith("", "    def f(x: Int): Int => 1
    def f(y: Int): Int => 2
    val g: (Int) -> Int = f
    printl(g(1))")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedWith("def f(x: Int): Int => 1
def f(y: Int): Int => 2", "    val g: (Int) -> Int = f
    printl(g(1))")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
}

@("a conformance that finds only a function and its reported duplicate reports just the duplicate")
unittest
{
    analyzedWith("interface A { def a(x: Self): Int }\ndef a(x: Int): Int => 1\ndef a(y: Int): Int => 2\nconform Int: A\n"
        ~ "def use<T: A>(x: T): Int => a(x)", "    printl(use(1))")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("a", 3));
}

@("a nested def of a name an enclosing block has already declared is shadowing, not an overload")
unittest
{
    analyzedWith("", "    def f(x: Int): Int => x\n    {\n        def f(x: String): String => x\n    }")
        .shouldReport(DiagnosticCode.ShadowedDeclaration, At("f", 2));
}

@("a call of nested overloads that fits none is reported, and a literal adapts to the one it can")
unittest
{
    analyzedWith("", "    def f(x: Int): Int => x\n    def f(x: String): String => x\n    val a = f(true)")
        .shouldReport(DiagnosticCode.NoMatchingOverload, At("f", 3));
    analyzedWith("", "    def f(x: UInt8): Int => 1\n    def f(x: Bool): Int => 2\n    val a = f(1)").shouldHaveNoDiagnostics();
}

@("nested overloads see themselves and what's before them, and the later ones aren't there yet")
unittest
{
    analyzedWith("", "    def f(x: Int): Int => x\n    def f(x: String): Int => f(1)\n    val a = f(\"s\")").shouldHaveNoDiagnostics();
    analyzedWith("", "    def f(x: Int): Int => f(\"s\")\n    def f(x: String): Int => 1")
        .shouldReport(DiagnosticCode.TypeMismatch, At("\"s\"", 1));
}

@("an overloaded nested def used as a value is chosen by its expected type")
unittest
{
    analyzedWith("", "    def f(x: Int): Int => x\n    def f(x: String): String => x\n    val g: (String) -> String = f")
        .shouldHaveNoDiagnostics();
    analyzedWith("", "    def f(x: Int): Int => x\n    def f(x: String): String => x\n    val g = f")
        .shouldReport(DiagnosticCode.AmbiguousOverload, At("f", 3));
    analyzedWith("", "    def f(x: Int): Int => x\n    def f(x: String): String => x\n    val g: (Bool) -> Bool = f")
        .shouldReport(DiagnosticCode.NoMatchingOverload, At("f", 3));
}
