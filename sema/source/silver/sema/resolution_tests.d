/// Name resolution tests. Uses and declarations are found by counting whole-word
/// occurrences of a name in a module's source, so tests never depend on ID numbering.
module silver.sema.resolution_tests;

version (unittest):

import core.exception : AssertError;
import std.format : format;
import std.sumtype : match;

import silver.ast;
import silver.loader : load, standardLibraryPath;
import silver.sema.analysis;
import silver.sema.resolve;

/// A program loaded with the real stdlib and analyzed, with every module indexed.
struct Analyzed
{
    Analysis analysis;
    Collector collector;
    string[string] sources;
    NameIndex[string] names;
    Id!Module[string] moduleIds;
}

/// Analyzes `entry` as main.ag. `files` (by file name, e.g. "a/b.ag") are written to a
/// temporary import path, searched before the stdlib.
Analyzed analyzed(string entry, string[string] files = null)
{
    import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
    import std.path : buildPath, dirName;
    import std.uuid : randomUUID;

    auto directory = buildPath(tempDir(), "silver-sema-" ~ randomUUID().toString());
    mkdirRecurse(directory);
    scope (exit) rmdirRecurse(directory);
    foreach (fileName, text; files)
    {
        auto path = buildPath(directory, fileName);
        mkdirRecurse(dirName(path));
        write(path, text);
    }

    auto context = new SourceContext;
    auto program = load(entry, "main.ag", [directory, standardLibraryPath()], context);
    assert(!context.collector.hasErrors, "The test program failed to load");

    Analyzed a;
    a.analysis = analyze(program, context.collector);
    a.collector = context.collector;
    foreach (name, m; program.modules)
    {
        a.sources[name] = name == "main" ? entry : readText(m.span.file);
        a.names[name] = indexNames(*m);
        a.moduleIds[name] = m.id;
    }
    return a;
}

/// The `nth` (from 1) whole-word occurrence of `word` in a module's source, counting
/// uses and declarations alike.
struct At
{
    string word;
    size_t nth;
    string moduleName = "main";

    string toString() const
    {
        return format("'%s' #%s in %s", word, nth, moduleName);
    }
}

/// Asserts that the use at `use` resolves to the declaration at `declaration`.
void shouldResolve(const Analyzed a, At use, At declaration,
    string file = __FILE__, size_t line = __LINE__)
{
    auto expected = declaration.offsetIn(a) in a.names[declaration.moduleName].declarations;
    if (expected is null)
    {
        throw new AssertError(format("%s isn't a declaration", declaration), file, line);
    }
    a.shouldResolveTo(use, *expected, file, line);
}

/// Shorthand for a use and a declaration of `name` in the entry module.
void shouldResolve(const Analyzed a, string name, size_t useNth, size_t declarationNth,
    string file = __FILE__, size_t line = __LINE__)
{
    a.shouldResolve(At(name, useNth), At(name, declarationNth), file, line);
}

/// Asserts that the use at `use` is a module path that resolves to module `moduleName`.
void shouldResolveToModule(const Analyzed a, At use, string moduleName,
    string file = __FILE__, size_t line = __LINE__)
{
    a.shouldResolveTo(use, SymbolId(a.moduleIds[moduleName]), file, line);
}

private void shouldResolveTo(const Analyzed a, At use, SymbolId expected, string file, size_t line)
{
    auto useId = use.offsetIn(a) in a.names[use.moduleName].uses;
    if (useId is null)
    {
        throw new AssertError(format("%s isn't an identifier or member name", use), file, line);
    }
    auto actual = a.analysis.resolutionOf(*useId);
    if (actual is null)
    {
        throw new AssertError(format("%s isn't resolved", use), file, line);
    }
    if (*actual != expected)
    {
        throw new AssertError(format("%s resolves to %s, expected %s", use, *actual, expected), file, line);
    }
}

/// Asserts that the call whose callee name is at `call` directly invokes the function
/// declared at `declaration`.
void shouldCall(const Analyzed a, At call, At declaration,
    string file = __FILE__, size_t line = __LINE__)
{
    auto expected = declaration.offsetIn(a) in a.names[declaration.moduleName].declarations;
    if (expected is null)
    {
        throw new AssertError(format("%s isn't a declaration", declaration), file, line);
    }
    auto callId = call.offsetIn(a) in a.names[call.moduleName].calls;
    if (callId is null)
    {
        throw new AssertError(format("%s isn't the callee of a call", call), file, line);
    }
    auto actual = a.analysis.calleeOf(*callId);
    if (actual is null)
    {
        throw new AssertError(format("%s has no callee", call), file, line);
    }
    if (SymbolId(*actual) != *expected)
    {
        throw new AssertError(format("%s calls %s, expected %s", call, *actual, *expected), file, line);
    }
}

/// Asserts that the call whose callee name is at `call` has no static callee.
void shouldHaveNoCallee(const Analyzed a, At call, string file = __FILE__, size_t line = __LINE__)
{
    auto callId = call.offsetIn(a) in a.names[call.moduleName].calls;
    if (callId is null)
    {
        throw new AssertError(format("%s isn't the callee of a call", call), file, line);
    }
    if (auto actual = a.analysis.calleeOf(*callId))
    {
        throw new AssertError(format("%s calls %s, expected no callee", call, *actual), file, line);
    }
}

/// Asserts that `use` was left unresolved, e.g. a member of a value.
void shouldNotResolve(const Analyzed a, At use, string file = __FILE__, size_t line = __LINE__)
{
    auto useId = use.offsetIn(a) in a.names[use.moduleName].uses;
    if (useId is null)
    {
        throw new AssertError(format("%s isn't an identifier or member name", use), file, line);
    }
    if (auto actual = a.analysis.resolutionOf(*useId))
    {
        throw new AssertError(format("%s resolves to %s, expected nothing", use, *actual), file, line);
    }
}

void shouldHaveNoDiagnostics(const Analyzed a, string file = __FILE__, size_t line = __LINE__)
{
    if (a.collector.diagnostics.length > 0)
    {
        throw new AssertError("Unexpected diagnostics:\n" ~ a.describeDiagnostics, file, line);
    }
}

/// Asserts that the only diagnostic is `code`, starting at `where`.
void shouldReport(const Analyzed a, DiagnosticCode code, At where,
    string file = __FILE__, size_t line = __LINE__)
{
    auto diagnostics = a.collector.diagnostics;
    auto start = where.offsetIn(a);
    if (diagnostics.length != 1 || diagnostics[0].code != code || diagnostics[0].span.start != start)
    {
        throw new AssertError(format("Expected only %s at %s (offset %s), got:\n%s",
            code, where, start, a.describeDiagnostics), file, line);
    }
}

private string describeDiagnostics(const Analyzed a)
{
    import std.algorithm : map;
    import std.array : join;

    return a.collector.diagnostics
        .map!(d => format("%s %s@%s: %s", d.code, d.span.file, d.span.start, d.message))
        .join("\n");
}

private size_t offsetIn(const At at, const Analyzed a)
{
    return occurrence(a.sources[at.moduleName], at.word, at.nth);
}

/// Where the `nth` (from 1) whole-word occurrence of `word` starts.
size_t occurrence(string source, string word, size_t nth)
{
    import std.ascii : isAlphaNum;

    bool isWordChar(char c)
    {
        return isAlphaNum(c) || c == '_';
    }

    size_t seen = 0;
    for (size_t i = 0; i + word.length <= source.length; i++)
    {
        auto end = i + word.length;
        if (source[i .. end] != word
            || (i > 0 && isWordChar(source[i - 1]))
            || (end < source.length && isWordChar(source[end])))
        {
            continue;
        }
        if (++seen == nth)
        {
            return i;
        }
    }
    throw new AssertError(format("'%s' occurs only %s times", word, seen));
}

/// A module's name uses and declarations, by where their names start. A member access is
/// a use of its member name, e.g. `pow` in `std.math.pow`.
struct NameIndex
{
    Id!Expr[size_t] uses;
    SymbolId[size_t] declarations;
    /// Call expressions, by where their callee's name starts.
    Id!Expr[size_t] calls;
    /// Every expression, by its exact [start, end) span. When two share a span, the outer one.
    Id!Expr[size_t[2]] exprs;
}

NameIndex indexNames(const Module m)
{
    auto indexer = new Indexer;
    foreach (d; m.declarations)
    {
        d.kind.match!(
            (const FunctionDecl f) => indexer.visit(f),
            (const ImportStmt _) {},
        );
    }
    return indexer.index;
}

private final class Indexer
{
    NameIndex index;

    void visit(const FunctionDecl f)
    {
        index.declarations[f.nameSpan.start] = SymbolId(f.id);
        foreach (p; f.params)
        {
            index.declarations[p.nameSpan.start] = SymbolId(p.id);
        }
        visit(f.body);
    }

    void visit(const Stmt s)
    {
        s.kind.match!(
            (const VarDecl v) {
                index.declarations[v.nameSpan.start] = SymbolId(v.id);
                visit(v.value);
            },
            (const AssignStmt a) { visit(a.target); visit(a.value); },
            (const ExprStmt e) => visit(e.expr),
            (const ReturnStmt r) => visit(r.value),
            (const FunctionDecl f) => visit(f),
        );
    }

    void visit(const(Expr)* e)
    {
        if (e !is null)
        {
            visit(*e);
        }
    }

    void visit(const Expr e)
    {
        size_t[2] span = [e.span.start, e.span.end];
        if (span !in index.exprs)
        {
            index.exprs[span] = e.id;
        }
        e.kind.match!(
            (const Identifier _) { index.uses[e.span.start] = e.id; },
            (const UnaryExpr u) => visit(u.operand),
            (const BinaryExpr b) { visit(b.left); visit(b.right); },
            (const CallExpr c) {
                c.callee.kind.match!(
                    (const Identifier _) { index.calls[c.callee.span.start] = e.id; },
                    (const MemberAccess ma) { index.calls[c.callee.span.end - ma.member.length] = e.id; },
                    (_) {},
                );
                visit(c.callee);
                foreach (arg; c.args)
                {
                    visit(arg);
                }
            },
            (const MemberAccess ma) {
                index.uses[e.span.end - ma.member.length] = e.id;
                visit(ma.object);
            },
            (const WhileExpr w) { visit(w.condition); visit(w.body); },
            (const IfExpr i) { visit(i.condition); visit(i.trueBody); visit(i.falseBody); },
            (const BlockExpr b) {
                foreach (s; b.statements)
                {
                    visit(s);
                }
                visit(b.value);
            },
            (_) {},
        );
    }
}

@("name resolution links uses in a function to its params, its locals, and itself")
unittest
{
    auto a = analyzed("def factorial(n: Int): Int {
    mutable val result = 1
    if !(n == 0) {
        result = n * factorial(n - 1)
    }
    result
}

def main(): Unit => ()");

    a.shouldResolve("n", 2, 1);
    a.shouldResolve("n", 3, 1);
    a.shouldResolve("n", 4, 1);
    a.shouldResolve("result", 2, 1);
    a.shouldResolve("result", 3, 1);
    a.shouldResolve("factorial", 2, 1);
    a.shouldHaveNoDiagnostics();
}

@("name resolution finds a function declared later in the module")
unittest
{
    auto a = analyzed("def main(): Unit => helper()
def helper(): Unit => ()");
    a.shouldResolve("helper", 1, 2);
    a.shouldHaveNoDiagnostics();
}

@("name resolution resolves a local's initializer before declaring it")
unittest
{
    auto a = analyzed("def f(n: Int): Int {
    val m = n + 1
    m
}
def main(): Unit => ()");
    a.shouldResolve("n", 2, 1);
    a.shouldResolve("m", 2, 1);
    a.shouldHaveNoDiagnostics();
}

@("name resolution finds prelude functions without an import")
unittest
{
    auto a = analyzed("def main(): Unit => printl(1)");
    a.shouldResolve(At("printl", 1), At("printl", 1, "prelude"));
    a.shouldHaveNoDiagnostics();
}

@("name resolution resolves a module-qualified call and the module path in it")
unittest
{
    auto a = analyzed("import std.math
def main(): Unit => printl(std.math.pow(2, 3))");
    a.shouldResolve(At("pow", 1), At("pow", 1, "std.math"));
    a.shouldResolveToModule(At("math", 2), "std.math");
    a.shouldHaveNoDiagnostics();
}

@("name resolution leaves a member of a value for the type checker")
unittest
{
    auto a = analyzed("def main(): Unit {
    val x = 1
    printl(x.size)
}");
    a.shouldResolve("x", 2, 1);
    a.shouldNotResolve(At("size", 1));
    // Reported by the type checker, not name resolution: Int has no members.
    a.shouldReport(DiagnosticCode.UnknownMember, At("x", 2));
}

@("name resolution reports an unknown name")
unittest
{
    auto a = analyzed("def main(): Unit => printl(nope)");
    a.shouldReport(DiagnosticCode.UnknownName, At("nope", 1));
}

@("name resolution doesn't let a block's locals leak out of it")
unittest
{
    auto a = analyzed("def main(): Unit {
    val a = if true {
        val inner = 1
        inner
    } else 0
    printl(inner)
}");
    a.shouldReport(DiagnosticCode.UnknownName, At("inner", 3));
}

@("name resolution allows the same name in sibling blocks")
unittest
{
    auto a = analyzed("def main(): Unit {
    val a = if true {
        val t = 1
        t
    } else 0
    val b = if true {
        val t = 2
        t
    } else 0
}");
    a.shouldResolve("t", 2, 1);
    a.shouldResolve("t", 4, 3);
    a.shouldHaveNoDiagnostics();
}

@("name resolution reports a function declared twice in a module, at the second name")
unittest
{
    auto a = analyzed("def twice(): Int => 1
def twice(): Int => 2
def main(): Unit => ()");
    a.shouldReport(DiagnosticCode.DuplicateDeclaration, At("twice", 2));
    import std.algorithm : canFind;

    assert(a.collector.diagnostics[0].message.canFind("'twice'"));
}

@("name resolution reports a local declared twice in one block")
unittest
{
    auto a = analyzed("def main(): Unit {
    val t = 1
    val t = 2
}");
    a.shouldReport(DiagnosticCode.DuplicateDeclaration, At("t", 2));
}

@("name resolution reports a local that shadows one in an enclosing block, and uses resolve to it")
unittest
{
    auto a = analyzed("def main(): Unit {
    val t = 0
    val a = if true {
        val t = 1
        t
    } else 0
}");
    a.shouldReport(DiagnosticCode.ShadowedDeclaration, At("t", 2));
    a.shouldResolve("t", 3, 2);
}

@("name resolution reports a local that shadows a parameter")
unittest
{
    auto a = analyzed("def f(n: Int): Int {
    val n = 2
    n
}
def main(): Unit => ()");
    a.shouldReport(DiagnosticCode.ShadowedDeclaration, At("n", 2));
}

@("name resolution reports a parameter declared twice")
unittest
{
    auto a = analyzed("def f(n: Int, n: Int): Int => n
def main(): Unit => ()");
    a.shouldReport(DiagnosticCode.DuplicateParameter, At("n", 2));
}

@("name resolution reports a local or parameter with the same name as a function in its module")
unittest
{
    auto local = analyzed("def count(): Int => 1
def main(): Unit {
    val count = 2
}");
    local.shouldReport(DiagnosticCode.ShadowedDeclaration, At("count", 2));

    auto param = analyzed("def count(): Int => 1
def f(count: Int): Int => count
def main(): Unit => ()");
    param.shouldReport(DiagnosticCode.ShadowedDeclaration, At("count", 2));
}

@("name resolution lets a local hide an imported name")
unittest
{
    auto a = analyzed("def main(): Unit {
    val read = 1
    printl(read)
}");
    a.shouldResolve("read", 2, 1);
    a.shouldHaveNoDiagnostics();
}

@("name resolution reports a local with the same name as an imported module's root")
unittest
{
    auto a = analyzed("import std.math
def main(): Unit {
    val std = 1
}");
    a.shouldReport(DiagnosticCode.ShadowedDeclaration, At("std", 2));
}

@("name resolution doesn't see the imports of an imported module")
unittest
{
    auto a = analyzed("import a
def main(): Unit => printl(secret())", [
        "a.ag": "module a\nimport b\ndef fromA(): Int => 1",
        "b.ag": "module b\ndef secret(): Int => 7",
    ]);
    a.shouldReport(DiagnosticCode.UnknownName, At("secret", 1));
}

@("name resolution keeps same-named functions in different modules apart")
unittest
{
    auto a = analyzed("import lib
def helper(): Int => 2
def main(): Unit => printl(helper())", [
        "lib.ag": "module lib\ndef helper(): Int => 1\ndef viaLib(): Int => helper()",
    ]);
    a.shouldResolve("helper", 2, 1);
    a.shouldResolve(At("helper", 2, "lib"), At("helper", 1, "lib"));
    a.shouldHaveNoDiagnostics();
}

@("name resolution reports a name two imports define, and accepts it qualified")
unittest
{
    auto files = [
        "a.ag": "module a\ndef shared(): Int => 1",
        "b.ag": "module b\ndef shared(): Int => 2",
    ];
    auto bare = analyzed("import a\nimport b\ndef main(): Unit => printl(shared())", files);
    bare.shouldReport(DiagnosticCode.AmbiguousName, At("shared", 1));

    auto qualified = analyzed("import a\nimport b\ndef main(): Unit => printl(b.shared())", files);
    qualified.shouldResolve(At("shared", 1), At("shared", 1, "b"));
    qualified.shouldHaveNoDiagnostics();
}

@("name resolution treats the prelude like any other import when names clash")
unittest
{
    auto files = ["lib.ag": "module lib\ndef printl(value: Int): Unit => ()"];
    auto bare = analyzed("import lib\ndef main(): Unit => printl(1)", files);
    bare.shouldReport(DiagnosticCode.AmbiguousName, At("printl", 1));

    auto qualified = analyzed("import lib\ndef main(): Unit => prelude.printl(1)", files);
    qualified.shouldResolve(At("printl", 1), At("printl", 1, "prelude"));
    qualified.shouldHaveNoDiagnostics();
}

@("name resolution accepts an explicit import of the prelude")
unittest
{
    auto a = analyzed("import prelude\ndef main(): Unit => printl(1)");
    a.shouldResolve(At("printl", 1), At("printl", 1, "prelude"));
    a.shouldHaveNoDiagnostics();
}

@("name resolution reports a module or package used as a value")
unittest
{
    auto mod = analyzed("import std.math\ndef main(): Unit => printl(std.math)");
    mod.shouldReport(DiagnosticCode.ModuleIsNotAValue, At("std", 2));

    auto package_ = analyzed("import std.math\ndef main(): Unit => printl(std)");
    package_.shouldReport(DiagnosticCode.ModuleIsNotAValue, At("std", 2));
}

@("name resolution reports a member a module doesn't have")
unittest
{
    auto a = analyzed("import std.math\ndef main(): Unit => printl(std.math.nope)");
    a.shouldReport(DiagnosticCode.UnknownModuleMember, At("std", 2));
}

@("name resolution reports a nested function as unsupported")
unittest
{
    auto a = analyzed("def main(): Unit {\n    def inner(): Unit => ()\n}");
    a.shouldReport(DiagnosticCode.InternalError, At("inner", 1));
}

@("name resolution records the function a direct call invokes, plain or qualified")
unittest
{
    auto a = analyzed("import std.math
def twice(x: Float): Float => x * 2
def main(): Unit {
    printl(twice(std.math.pow(2, 3)))
}");
    a.shouldCall(At("twice", 2), At("twice", 1));
    a.shouldCall(At("pow", 1), At("pow", 1, "std.math"));
    a.shouldCall(At("printl", 1), At("printl", 1, "prelude"));
    a.shouldHaveNoDiagnostics();
}

@("name resolution records no callee for a call through a function-typed param")
unittest
{
    auto a = analyzed("def apply(f: (Int) -> Int, x: Int): Int => f(x)
def main(): Unit => ()");
    a.shouldHaveNoCallee(At("f", 2));
    a.shouldHaveNoDiagnostics();
}
