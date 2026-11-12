/// Tests of selective and static imports: which names each form makes visible, and how.
module silver.sema.import_tests;

version (unittest):

import std.algorithm : canFind;

import silver.ast : DiagnosticCode;
import silver.sema.resolution_tests;

private enum string[string] library = [
    "lib.ag": "module lib
def f(): Int => 1
def g(): Int => 2
def twice(x: Int): Int => x * 2
type P(x: Int)
val limit: Int = 3
private def hidden(): Int => 4",
];

@("a selective import gives unqualified access to the names it lists")
unittest
{
    auto a = analyzed("import lib : f, P, limit
def h(p: P): Int => p.x
def main(): Unit => printl(f() + h(P(limit)))", library);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("f", 2), At("f", 1, "lib"));
    a.shouldResolve(At("limit", 2), At("limit", 1, "lib"));
}

@("a selective import gives no access to names it doesn't list")
unittest
{
    analyzed("import lib : f\ndef main(): Unit => printl(g())", library)
        .shouldReport(DiagnosticCode.UnknownName, At("g", 1));
    analyzed("import lib : f\ndef h(p: P): Int => 1\ndef main(): Unit => ()", library)
        .shouldReport(DiagnosticCode.UnknownType, At("P", 1));
}

@("a selective import gives no qualified access")
unittest
{
    analyzed("import lib : f\ndef main(): Unit => printl(lib.f())", library)
        .shouldReport(DiagnosticCode.UnknownName, At("lib", 2));
    analyzed("import lib : P\ndef h(p: lib.P): Int => 1\ndef main(): Unit => ()", library)
        .shouldReport(DiagnosticCode.UnknownType, At("lib", 2));
}

@("a selective import reports a name its module doesn't have or keeps private")
unittest
{
    auto missing = analyzed("import lib : f, nope\ndef main(): Unit => ()", library);
    missing.shouldReport(DiagnosticCode.UnknownModuleMember, At("nope", 1));

    auto hidden = analyzed("import lib : hidden\ndef main(): Unit => ()", library);
    hidden.shouldReport(DiagnosticCode.PrivateMember, At("hidden", 1));
    assert(hidden.collector.errors.front.message.canFind("private to 'lib'"));
}

@("a static import gives qualified access only")
unittest
{
    auto a = analyzed("static import lib
def h(p: lib.P): Int => p.x
def main(): Unit => printl(lib.f() + h(lib.P(lib.limit)))", library);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("f", 1), At("f", 1, "lib"));

    analyzed("static import lib\ndef main(): Unit => printl(f())", library)
        .shouldReport(DiagnosticCode.UnknownName, At("f", 1));
    analyzed("static import lib\ndef h(p: P): Int => 1\ndef main(): Unit => ()", library)
        .shouldReport(DiagnosticCode.UnknownType, At("P", 1));
}

@("a static import gives no method calls")
unittest
{
    analyzed("static import lib\ndef main(): Unit {\nval n = 1\nprintl(n.twice())\n}", library)
        .shouldReport(DiagnosticCode.UnknownMember, At("n", 2));
    analyzed("import lib : twice\ndef main(): Unit {\nval n = 1\nprintl(n.twice())\n}", library)
        .shouldHaveNoDiagnostics();
}

@("imports of one module combine")
unittest
{
    auto a = analyzed("static import lib\nimport lib : f\ndef main(): Unit => printl(f() + lib.g())", library);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("f", 2), At("f", 1, "lib"));
    a.shouldResolve(At("g", 1), At("g", 1, "lib"));

    analyzed("import lib : f\nimport lib : g\ndef main(): Unit => printl(f() + g())", library)
        .shouldHaveNoDiagnostics();
    analyzed("import lib : f\nimport lib\ndef main(): Unit => printl(lib.g() + g())", library)
        .shouldHaveNoDiagnostics();
}

@("only a module's qualified imports reserve its path from locals")
unittest
{
    analyzed("import lib : f\ndef main(): Unit {\nval lib = f()\n}", library).shouldHaveNoDiagnostics();
    analyzed("static import lib\ndef main(): Unit {\nval lib = 1\n}", library)
        .shouldReport(DiagnosticCode.ShadowedDeclaration, At("lib", 2));
}

@("a name two imports provide is ambiguous only if both provide it unqualified")
unittest
{
    auto files = [
        "a.ag": "module a\ndef shared(): Int => 1\ntype T",
        "b.ag": "module b\ndef shared(): Int => 2\ndef other(): Int => 3\ntype T",
    ];
    auto selected = analyzed("import a\nimport b : other\ndef f(t: T): Int => shared() + other()\ndef main(): Unit => ()",
        files);
    selected.shouldHaveNoDiagnostics();
    selected.shouldResolve(At("shared", 1), At("shared", 1, "a"));

    auto qualifiedOnly = analyzed("import a\nstatic import b\ndef main(): Unit => printl(shared() + b.shared())", files);
    qualifiedOnly.shouldHaveNoDiagnostics();
    qualifiedOnly.shouldResolve(At("shared", 1), At("shared", 1, "a"));

    auto both = analyzed("import a : T\nimport b : T\ndef f(t: T): Int => 1\ndef main(): Unit => ()", files);
    both.shouldReport(DiagnosticCode.AmbiguousName, At("T", 3));
    assert(both.collector.errors.front.message.canFind("only one of the imports"));
}

@("selected functions of one name from two modules overload")
unittest
{
    auto files = [
        "a.ag": "module a\ndef show(x: Int): Int => 1",
        "b.ag": "module b\ndef show(x: String): Int => 2",
    ];
    auto a = analyzed("import a : show\nimport b : show\ndef main(): Unit => printl(show(1) + show(\"x\"))", files);
    a.shouldHaveNoDiagnostics();
    a.shouldCall(At("show", 3), At("show", 1, "a"));
    a.shouldCall(At("show", 4), At("show", 1, "b"));
}

@("a module's own declaration beats a selectively imported one")
unittest
{
    auto a = analyzed("import lib : limit\nval limit: Int = 9\ndef main(): Unit => printl(limit)", library);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve("limit", 3, 2);
}

@("an ambiguous call says to qualify it only if an import allows that")
unittest
{
    auto files = [
        "a.ag": "module a\ndef show(x: Int): Int => 1",
        "b.ag": "module b\ndef show(x: Int): Int => 2",
    ];
    auto selected = analyzed("import a : show\nimport b : show\ndef main(): Unit => printl(show(1))", files);
    selected.shouldReport(DiagnosticCode.AmbiguousName, At("show", 3));
    assert(selected.collector.errors.front.message.canFind("only one of the imports"));

    auto qualifiable = analyzed("import a : show\nimport b\ndef main(): Unit => printl(show(1))", files);
    qualifiable.shouldReport(DiagnosticCode.AmbiguousName, At("show", 2));
    assert(qualifiable.collector.errors.front.message.canFind("`b.show(...)`"));
}
