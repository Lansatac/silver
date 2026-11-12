/// Tests of overloading: which declarations of one name can coexist, and which one a call or a
/// function value chooses.
module silver.sema.overload_tests;

version (unittest):

import std.algorithm : canFind;

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldHaveType;
import silver.sema.resolution_tests;

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

@("mutable alone doesn't make an overload")
unittest
{
    auto a = analyzed("def f(x: Int): Unit => ()\ndef f(mutable x: Int): Unit => ()\ndef main(): Unit => ()");
    a.shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    assert(a.collector.diagnostics[0].message.canFind("`mutable` alone"));
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

@("a call that functions of two imported modules fit equally well is ambiguous")
unittest
{
    auto files = [
        "a.ag": "module a\ndef f(x: Int): Unit => ()\ndef g(x: Int?): Unit => ()\ndef h<T>(x: T): Unit => ()",
        "b.ag": "module b\ndef f(x: Int): Unit => ()\ndef g(x: Int?): Unit => ()\ndef h(x: Int?): Unit => ()",
    ];
    foreach (call; ["f", "g", "h"])
    {
        analyzed("import a\nimport b\ndef main(): Unit {\n    " ~ call ~ "(1)\n}", files)
            .shouldReport(DiagnosticCode.AmbiguousName, At(call, 1));
    }
}

@("a for chooses among imported modules by fit as a call does")
unittest
{
    auto files = [
        "down.ag": "module down\ntype Down(n: Int)\ndef next(d: Down): (Int, Down)? => None",
        "gen.ag": "module gen\ndef next<T>(x: T?): (Int, T?)? => None",
    ];
    analyzed("import down\nimport gen\ndef main(): Unit {\n    for x in Down(3) { print(x) }\n}", files)
        .shouldHaveNoDiagnostics();
}

@("this module's functions come first, and imported ones are tried when none of them fits")
unittest
{
    auto a = analyzed("import a\nimport b\ndef only(x: String): Unit => ()\ndef shared(x: Int?): Unit => ()\ndef main(): Unit {\n"
        ~ "    only(\"a\")\n    only(1)\n    shared(1)\n}", ["a.ag": libraries["a.ag"], "b.ag": "module b"]);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("only", 2), At("only", 1));
    a.shouldCall(At("only", 3), At("only", 1, "a"));
    // This module's `shared(Int?)` fits, so `a.shared(Int)`, which would fit better, isn't tried.
    a.shouldCall(At("shared", 2), At("shared", 1));
}

@("this module's function of a name can call the prelude's")
unittest
{
    auto a = analyzed("type Point(x: Int, y: Int)\ndef printl(p: Point): Unit => printl(\"({p.x}, {p.y})\")\n"
        ~ "def main(): Unit => printl(Point(1, 2))");
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("printl", 2), At("printl", 1, "prelude"));
    a.shouldCall(At("printl", 3), At("printl", 1));
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
