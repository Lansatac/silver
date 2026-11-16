/// Tests of `forward import`: what a module's importers see, and how what it forwards is ranked.
module silver.sema.forward_tests;

version (unittest):

import std.algorithm : canFind;
import std.array : array, replace;

import silver.ast : DiagnosticCode;
import silver.sema.resolution_tests;

private enum string[string] library = [
    "a.ag": "module a
def f(): Int => 1
def pick(x: Int): Int => 1
type P(x: Int)
interface Named { def name(self: Self): String }
alias Count = Int
val limit: Int = 3
private def hidden(): Int => 4",
    "b.ag": "module b
def g(): Int => 2
def pick<T>(x: T): Int => 2
val limit: Int = 5",
    "selected.ag": "module selected\nforward import a : f, pick, P, Named, Count, limit",
    "blanket.ag": "module blanket\nforward import a\ndef own(): Int => 9",
    "outer.ag": "module outer\nforward import blanket",
];

@("a module's importers see what it forwards, unqualified and through it")
unittest
{
    auto a = analyzed("import selected
def name(p: P): String => \"p\"
def show<T: Named>(x: T): String => name(x)
def h(p: P, q: selected.P, n: Count): Int => p.x + q.x + n
def main(): Unit => printl(f() + selected.f() + h(P(limit), selected.P(selected.limit), 1))", library);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("f", 1), At("f", 1, "a"));
    a.shouldResolve(At("f", 2), At("f", 1, "a"));
    a.shouldResolve(At("limit", 2), At("limit", 1, "a"));
}

@("a blanket forward passes on every public name, and what its module forwards")
unittest
{
    auto a = analyzed("import outer\ndef main(): Unit => printl(f() + own() + outer.limit + P(1).x)", library);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("own", 1), At("own", 1, "blanket"));

    analyzed("import outer\ndef main(): Unit => printl(hidden())", library)
        .shouldReport(DiagnosticCode.UnknownName, At("hidden", 1));
    analyzed("import outer\ndef main(): Unit => printl(outer.hidden())", library)
        .shouldReport(DiagnosticCode.UnknownModuleMember, At("outer", 2));
}

@("a selective forward passes on only what it lists, and gives no access to its module's path")
unittest
{
    auto files = library.dup;
    files["some.ag"] = "module some\nforward import a : f";
    analyzed("import some\ndef main(): Unit => printl(limit)", files)
        .shouldReport(DiagnosticCode.UnknownName, At("limit", 1));
    analyzed("import some\ndef main(): Unit => printl(some.limit)", files)
        .shouldReport(DiagnosticCode.UnknownModuleMember, At("some", 2));
    analyzed("import some\ndef main(): Unit => printl(a.f())", files)
        .shouldReport(DiagnosticCode.UnknownName, At("a", 1));
}

@("a forward import is an import for its own module too")
unittest
{
    auto files = library.dup;
    files["user.ag"] = "module user\nforward import a : f\ndef twice(): Int => f() + a.limit";
    analyzed("import user\ndef main(): Unit => printl(twice())", files).shouldHaveNoDiagnostics();
}

@("one declaration reached through two imports isn't ambiguous")
unittest
{
    auto a = analyzed("import a\nimport selected\nimport blanket\nimport outer
def h(p: P, n: Count): Int => p.x + n
def main(): Unit => printl(f() + limit + pick(1) + h(P(1), 2))", library);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("pick", 1), At("pick", 1, "a"));
}

@("different declarations of one name from a forwarding module and another are still ambiguous")
unittest
{
    auto a = analyzed("import selected\nimport b\ndef main(): Unit => printl(limit)", library);
    a.shouldReport(DiagnosticCode.AmbiguousName, At("limit", 1));
    assert(a.collector.errors.front.message.canFind("(selected, b)"));
}

@("what one import brings is ranked as one module")
unittest
{
    auto files = library.dup;
    files["both.ag"] = "module both\nforward import a : pick\nforward import b : pick\ndef pick(x: String): Int => 3";
    auto a = analyzed("import both\ndef main(): Unit => printl(pick(1) + pick(true) + pick(\"s\") + both.pick(2))", files);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("pick", 1), At("pick", 1, "a"));
    a.shouldCall(At("pick", 2), At("pick", 1, "b"));
    a.shouldCall(At("pick", 3), At("pick", 3, "both"));
    a.shouldCall(At("pick", 4), At("pick", 1, "a"));

    // Importing one of the modules beside it changes nothing.
    auto beside = analyzed("import b\nimport both\ndef main(): Unit => printl(pick(1))", files);
    beside.shouldHaveNoDiagnostics();
    beside.shouldCall(At("pick", 1), At("pick", 1, "a"));
}

@("two imports whose functions fit equally well are named by the import")
unittest
{
    auto files = library.dup;
    files["c.ag"] = "module c\ndef pick(x: Int): Int => 7";
    auto a = analyzed("import selected\nimport c\ndef main(): Unit => printl(pick(1))", files);
    a.shouldReport(DiagnosticCode.AmbiguousName, At("pick", 1));
    assert(a.collector.errors.front.message.canFind("(selected, c)"));
    assert(a.collector.errors.front.message.canFind("`selected.pick(...)`"));
}

@("a forwarded function satisfies a bound for the forwarding module's importers")
unittest
{
    auto files = [
        "json.ag": "module json\ninterface Json { def toJson(self: Self): String }\ndef encode<T: Json>(x: T): String => toJson(x)",
        "things.ag": "module things\ntype Thing(n: Int)\ndef toJson(t: Thing): String => \"thing\"",
        "all.ag": "module all\nforward import json\nforward import things",
    ];
    analyzed("import all\ndef main(): Unit => printl(encode(Thing(1)))", files).shouldHaveNoDiagnostics();
    analyzed("import all\nimport things\nimport json\ndef main(): Unit => printl(encode(Thing(1)))", files)
        .shouldHaveNoDiagnostics();
}

@("forwarding a private name, or one the module doesn't have, is reported")
unittest
{
    auto files = library.dup;
    files["bad.ag"] = "module bad\nforward import a : hidden";
    files["worse.ag"] = "module worse\nforward import a : nope";
    analyzed("import bad\ndef main(): Unit => ()", files).shouldReport(DiagnosticCode.PrivateMember, At("hidden", 1, "bad"));
    analyzed("import worse\ndef main(): Unit => ()", files)
        .shouldReport(DiagnosticCode.UnknownModuleMember, At("nope", 1, "worse"));
}

@("a cycle of forward imports ends, and each module gives what all of them have")
unittest
{
    auto files = [
        "x.ag": "module x\nforward import y\ndef fromX(): Int => 1",
        "y.ag": "module y\nforward import z\ndef fromY(): Int => 2",
        "z.ag": "module z\nforward import x\ndef fromZ(): Int => 3\nprivate def fromX(): Int => 0",
    ];
    auto a = analyzed("import z\ndef main(): Unit => printl(fromX() + fromY() + z.fromZ() + z.fromX())", files);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("fromX", 1), At("fromX", 1, "x"));
    a.shouldResolve(At("fromX", 2), At("fromX", 1, "x"));
}

@("a forwarded name that the module also declares as something else is reported")
unittest
{
    auto files = library.dup;
    files["own.ag"] = "module own\nforward import a : limit\nval limit: Int = 9";
    analyzed("import own\ndef main(): Unit => ()", files)
        .shouldReport(DiagnosticCode.DuplicateDeclaration, At("limit", 1, "own"));

    files["hides.ag"] = "module hides\nforward import a : limit\nprivate val limit: Int = 9";
    auto hides = analyzed("import hides\ndef main(): Unit => printl(limit)", files);
    hides.shouldHaveNoDiagnostics();
    hides.shouldResolve(At("limit", 1), At("limit", 1, "a"));
}

@("a name forwarded from two modules that declare different things is reported")
unittest
{
    auto files = library.dup;
    files["two.ag"] = "module two\nforward import a : limit\nforward import b : limit";
    auto a = analyzed("import two\ndef main(): Unit => ()", files);
    a.shouldReport(DiagnosticCode.AmbiguousName, At("limit", 2, "two"));
}

@("forwarded functions that take the same parameters are reported at the forward")
unittest
{
    auto files = [
        "a.ag": "module a\ndef same(x: Int): Int => 1",
        "b.ag": "module b\ndef same(y: Int): Int => 2",
        "two.ag": "module two\nforward import a : same\nforward import b : same",
        "own.ag": "module own\nforward import a\ndef same(z: Int): Int => 3",
    ];
    auto two = analyzed("import two\ndef main(): Unit => ()", files);
    two.shouldReport(DiagnosticCode.DuplicateOverload, At("same", 2, "two"));
    assert(two.collector.errors.front.message.canFind("`b.same(Int)` can't be forwarded: `a.same(Int)`"));

    auto own = analyzed("import own\ndef main(): Unit => ()", files);
    own.shouldReport(DiagnosticCode.DuplicateOverload, At("forward", 1, "own"));
}

@("forwarded functions that differ only in bounds neither includes are reported")
unittest
{
    auto files = [
        "i.ag": "module i\ninterface A { def a(self: Self): Int }\ninterface B { def b(self: Self): Int }",
        "a.ag": "module a\nimport i\ndef get<T: A>(x: T): Int => 1",
        "b.ag": "module b\nimport i\ndef get<T: B>(x: T): Int => 2",
        "more.ag": "module more\nimport i\ndef get<T: A & B>(x: T): Int => 3",
        "two.ag": "module two\nforward import a\nforward import b",
        "ladder.ag": "module ladder\nforward import a\nforward import more",
    ];
    analyzed("import two\ndef main(): Unit => ()", files)
        .shouldReport(DiagnosticCode.DuplicateOverload, At("forward", 2, "two"));
    analyzed("import ladder\ndef main(): Unit => ()", files).shouldHaveNoDiagnostics();
}

@("`forward` is an ordinary name anywhere but before `import`")
unittest
{
    analyzed("def forward(x: Int): Int => x\ndef main(): Unit => printl(forward(1))").shouldHaveNoDiagnostics();
    analyzed("val forward: Int = 1\ndef main(): Unit {\nval import_ = forward\nprintl(import_)\n}").shouldHaveNoDiagnostics();
}

@("a prelude that only forwards supplies everything the prelude does")
unittest
{
    import std.file : readText;
    import std.path : buildPath;
    import silver.loader : standardLibraryPath;

    auto files = [
        "prelude.ag": "module prelude\nforward import std.core",
        "std/core.ag": readText(buildPath(standardLibraryPath(), "prelude.ag")).replace("module prelude", "module std.core"),
    ];
    auto a = analyzed("import std.string
type Stack(items: [Int])
def length(s: Stack): Int => length(s.items)
def opIndex(s: Stack, i: Int): Int => s.items[i]
def next(s: Stack): (Int, Stack)? => None
def main(): Unit {
    mutable val xs = [1, 2]
    xs ~= [3]
    for x in Stack(xs) { printl(x) }
    for i in 0..length(xs) { printl(xs[i]) }
    val first: Int? = if length(xs) > 0 => Some(xs[0]) else None
    printl(prelude.length(xs))
    assert(first == Some(1))
}", files);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("printl", 1), At("printl", 1, "std.core"));
}
