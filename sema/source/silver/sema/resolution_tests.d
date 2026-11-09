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

/// Asserts that the call whose callee name is at `call` constructs the type declared at `declaration`.
void shouldConstruct(const Analyzed a, At call, At declaration,
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
    auto actual = a.analysis.constructionOf(*callId);
    if (actual is null)
    {
        throw new AssertError(format("%s isn't a construction", call), file, line);
    }
    if (SymbolId(*actual) != *expected)
    {
        throw new AssertError(format("%s constructs %s, expected %s", call, *actual, *expected), file, line);
    }
}

/// Asserts that the call whose callee name is at `call` isn't a construction.
void shouldNotConstruct(const Analyzed a, At call, string file = __FILE__, size_t line = __LINE__)
{
    auto callId = call.offsetIn(a) in a.names[call.moduleName].calls;
    if (callId is null)
    {
        throw new AssertError(format("%s isn't the callee of a call", call), file, line);
    }
    if (auto actual = a.analysis.constructionOf(*callId))
    {
        throw new AssertError(format("%s constructs %s, expected no construction", call, *actual), file, line);
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
            (const TypeDecl t) => indexer.visit(t),
            (const ConstDecl c) => indexer.visit(c),
            (const AliasDecl _) {},
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

    void visit(const TypeDecl t)
    {
        index.declarations[t.nameSpan.start] = SymbolId(t.id);
    }

    void visit(const ConstDecl c)
    {
        index.declarations[c.nameSpan.start] = SymbolId(c.id);
        visit(c.value);
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
            (const PatternDecl p) { visit(p.pattern); visit(p.value); },
            (_) {},
        );
    }

    void visit(const Pattern p)
    {
        p.kind.match!(
            (const VarDecl v) { index.declarations[v.nameSpan.start] = SymbolId(v.id); },
            (const TuplePattern t) {
                foreach (element; t.elements)
                {
                    visit(element);
                }
            },
            (const ConstructorPattern c) {
                foreach (argument; c.arguments)
                {
                    visit(argument);
                }
            },
            (const SomePattern s) => visit(*s.inner),
            (const NonePattern _) {},
            (const LiteralPattern l) => visit(l.value),
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
            (const InterpolatedString s) {
                foreach (part; s.parts)
                {
                    visit(part);
                }
            },
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
            (const ForExpr f) {
                index.declarations[f.binding.nameSpan.start] = SymbolId(f.binding.id);
                visit(f.binding.value);
                visit(f.body);
            },
            (const RangeExpr r) { visit(r.start); visit(r.end); },
            (const MatchExpr m) {
                visit(m.subject);
                foreach (arm; m.arms)
                {
                    visit(arm.pattern);
                    visit(arm.body);
                }
            },
            (const TupleLiteral t) {
                foreach (element; t.elements)
                {
                    visit(element);
                }
            },
            (const WithExpr w) {
                visit(w.object);
                foreach (update; w.updates)
                {
                    visit(update.value);
                }
            },
            (const ArrayLiteral l) {
                foreach (element; l.elements)
                {
                    visit(element);
                }
            },
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

@("name resolution finds a module through a part of its path that isn't imported, below one that is")
unittest
{
    auto files = ["a.ag": "module a\ndef g(): Int => 1", "a/b/c.ag": "module a.b.c\ndef f(): Int => 2"];
    enum imports = "import a\nimport a.b.c\n";

    auto a = analyzed(imports ~ "def main(): Unit => printl(a.b.c.f() + a.g())", files);
    a.shouldResolve(At("f", 1), At("f", 1, "a.b.c"));
    a.shouldResolveToModule(At("c", 2), "a.b.c");
    a.shouldResolve(At("g", 1), At("g", 1, "a"));
    a.shouldHaveNoDiagnostics();

    analyzed(imports ~ "def main(): Unit => printl(a.b)", files)
        .shouldReport(DiagnosticCode.ModuleIsNotAValue, At("a", 3));
    analyzed(imports ~ "def main(): Unit => printl(a.b.nope)", files)
        .shouldReport(DiagnosticCode.UnknownName, At("a", 3));
    analyzed(imports ~ "def main(): Unit => printl(a.x.c.f())", files)
        .shouldReport(DiagnosticCode.UnknownModuleMember, At("a", 3));
}

@("name resolution prefers a module's declaration over a part of an imported module's path")
unittest
{
    auto a = analyzed("import a\nimport a.b.c\ndef main(): Unit => printl(a.b())",
        ["a.ag": "module a\ndef b(): Int => 1", "a/b/c.ag": "module a.b.c\ndef f(): Int => 2"]);
    a.shouldResolve(At("b", 2), At("b", 1, "a"));
    a.shouldHaveNoDiagnostics();
}

@("name resolution passes a type declaration")
unittest
{
    analyzed("type Point(x: Int, y: Int)\ndef main(): Unit => ()")
        .shouldHaveNoDiagnostics();
    analyzed("type Marker\ndef main(): Unit => ()")
        .shouldHaveNoDiagnostics();
}

private enum emptyMain = "\ndef main(): Unit => ()";

@("name resolution reports a type declared twice in a module, at the second name")
unittest
{
    analyzed("type Point(x: Int)\ntype Point(y: Int)" ~ emptyMain)
        .shouldReport(DiagnosticCode.DuplicateDeclaration, At("Point", 2));
    analyzed("type Point(x: Int)\ntype Point" ~ emptyMain)
        .shouldReport(DiagnosticCode.DuplicateDeclaration, At("Point", 2));
}

@("name resolution reports a type declared with empty parens, and still declares it")
unittest
{
    analyzed("type Marker()" ~ emptyMain)
        .shouldReport(DiagnosticCode.TypeEmptyParens, At("Marker", 1));
    analyzed("type Marker()\ndef f(m: Marker): Unit => ()" ~ emptyMain)
        .shouldReport(DiagnosticCode.TypeEmptyParens, At("Marker", 1));
}

@("name resolution reports a repeated field name, at the repeat, but other types may reuse it")
unittest
{
    analyzed("type Point(x: Int, x: String)" ~ emptyMain)
        .shouldReport(DiagnosticCode.DuplicateField, At("x", 2));
    analyzed("type Point(x: Int, y: Int)\ntype Line(x: Int, y: Int)" ~ emptyMain)
        .shouldHaveNoDiagnostics();
}

@("name resolution reports a type that redeclares a built-in")
unittest
{
    static foreach (name; ["Never", "Unit", "Bool", "Int", "Float", "String", "Any"])
    {
        analyzed("type " ~ name ~ "(x: Int)" ~ emptyMain)
            .shouldReport(DiagnosticCode.DuplicateDeclaration, At(name, 1));
    }
}

@("name resolution finds every built-in type")
unittest
{
    analyzed("def takes(a: Never, b: Unit, c: Bool, d: Int, e: Float, f: String, g: Any): Unit => ()" ~ emptyMain)
        .shouldHaveNoDiagnostics();
    analyzed("type All(a: Never, b: Unit, c: Bool, d: Int, e: Float, f: String, g: Any)" ~ emptyMain)
        .shouldHaveNoDiagnostics();
}

@("name resolution finds a declared type wherever a type can be written")
unittest
{
    enum point = "type Point(x: Int)\n";
    static foreach (declaration; [
        "def f(p: Point): Unit => ()",
        "def f(p: Point): Point => p",
        "def f(p: Point): Unit {\n    val q: Point = p\n}",
        "def f(p: Point?): Unit => ()",
        "def f(g: (Point) -> Int): Unit => ()",
        "def f(g: (Int) -> Point): Unit => ()",
        "native def f(p: Point): Unit",
        "type Line(a: Point, b: Point)",
        "type Box(p: Point?, f: (Point) -> Point)",
    ])
    {
        analyzed(point ~ declaration ~ emptyMain).shouldHaveNoDiagnostics();
    }
    analyzed("type Marker\ndef f(m: Marker): Unit => ()" ~ emptyMain).shouldHaveNoDiagnostics();
}

@("name resolution finds a type declared later in the module")
unittest
{
    analyzed("def f(p: Point): Unit => ()\ntype Point(x: Int)" ~ emptyMain).shouldHaveNoDiagnostics();
    analyzed("type Line(a: Point)\ntype Point(x: Int)" ~ emptyMain).shouldHaveNoDiagnostics();
}

@("name resolution reports an unknown type in a field, once, at its name")
unittest
{
    static foreach (field; ["x: Nope", "x: Nope?", "f: (Nope) -> Int", "f: (Int) -> Nope"])
    {
        analyzed("type Box(" ~ field ~ ")" ~ emptyMain)
            .shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    }
}

@("name resolution reports an unknown type in a signature or annotation, once, at its name")
unittest
{
    analyzed("def f(p: Nope): Unit => ()" ~ emptyMain).shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    analyzed("native def f(): Nope" ~ emptyMain).shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    analyzed("def main(): Unit {\n    val x: Nope? = 1\n}").shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
}

@("name resolution finds an imported type, plain or qualified")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)\ntype Origin"];
    analyzed("import geo\ndef f(p: Point): Unit => ()" ~ emptyMain, files).shouldHaveNoDiagnostics();
    analyzed("import geo\ndef f(p: geo.Point): Unit => ()" ~ emptyMain, files).shouldHaveNoDiagnostics();
    analyzed("import geo\ndef f(o: Origin): Unit => ()" ~ emptyMain, files).shouldHaveNoDiagnostics();
    analyzed("import geo\ntype Line(a: geo.Point)" ~ emptyMain, files).shouldHaveNoDiagnostics();

    auto nested = ["a/b.ag": "module a.b\ntype Point(x: Int)"];
    analyzed("import a.b\ndef f(p: a.b.Point): Unit => ()" ~ emptyMain, nested).shouldHaveNoDiagnostics();
}

@("name resolution reports a qualified type that doesn't exist, at the start of its path")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)"];
    analyzed("import geo\ndef f(p: geo.Nope): Unit => ()" ~ emptyMain, files)
        .shouldReport(DiagnosticCode.UnknownType, At("geo", 2));
    analyzed("def f(p: geo.Point): Unit => ()" ~ emptyMain)
        .shouldReport(DiagnosticCode.UnknownType, At("geo", 1));
}

@("name resolution doesn't see types from the imports of an imported module")
unittest
{
    auto files = [
        "a.ag": "module a\nimport b",
        "b.ag": "module b\ntype Secret(x: Int)",
    ];
    analyzed("import a\ndef f(s: Secret): Unit => ()" ~ emptyMain, files)
        .shouldReport(DiagnosticCode.UnknownType, At("Secret", 1));
}

@("name resolution reports a type two imports define only where it's used, and accepts it qualified")
unittest
{
    auto files = [
        "a.ag": "module a\ntype Shared(x: Int)",
        "b.ag": "module b\ntype Shared(y: Int)",
    ];
    analyzed("import a\nimport b" ~ emptyMain, files).shouldHaveNoDiagnostics();
    analyzed("import a\nimport b\ndef f(s: Shared): Unit => ()" ~ emptyMain, files)
        .shouldReport(DiagnosticCode.AmbiguousName, At("Shared", 1));
    analyzed("import a\nimport b\ndef f(s: b.Shared): Unit => ()" ~ emptyMain, files)
        .shouldHaveNoDiagnostics();
}

@("name resolution prefers a module's own type over an imported one")
unittest
{
    auto files = ["a.ag": "module a\ntype Shared(x: Int)"];
    analyzed("import a\ntype Shared(y: Int)\ndef f(s: Shared): Unit => ()" ~ emptyMain, files)
        .shouldHaveNoDiagnostics();
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

// Constructors

@("name resolution links a constructor to its type declaration")
unittest
{
    auto a = analyzed(`type Point(x: Int)
type Origin
def main(): Unit {
    val p = Point(1)
    val o = Origin
}`);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve("Point", 2, 1);
    a.shouldResolve("Origin", 2, 1);
}

@("name resolution finds a constructor declared later in the module")
unittest
{
    auto a = analyzed("def main(): Unit {\n    val p = Point(1)\n}\ntype Point(x: Int)");
    a.shouldHaveNoDiagnostics();
    a.shouldResolve("Point", 1, 2);
}

@("name resolution doesn't record a construction as a call to a function")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)"];
    auto a = analyzed("import geo\ndef main(): Unit {\n    val p = Point(1)\n    val q = geo.Point(2)\n}", files);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveNoCallee(At("Point", 1));
    a.shouldHaveNoCallee(At("Point", 2));
}

@("name resolution finds an imported constructor, plain or qualified")
unittest
{
    auto files = ["a/geo.ag": "module a.geo\ntype Point(x: Int)\ntype Origin"];
    auto a = analyzed(`import a.geo
def main(): Unit {
    val p = Point(1)
    val q = a.geo.Point(2)
    val o = Origin
    val r = a.geo.Origin
}`, files);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("Point", 1), At("Point", 1, "a.geo"));
    a.shouldResolve(At("Point", 2), At("Point", 1, "a.geo"));
    a.shouldResolve(At("Origin", 1), At("Origin", 1, "a.geo"));
    a.shouldResolve(At("Origin", 2), At("Origin", 1, "a.geo"));
}

@("name resolution prefers a module's own constructor over an imported one")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)"];
    auto a = analyzed("import geo\ntype Point(y: Int)\ndef main(): Unit {\n    val p = Point(1)\n}", files);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve("Point", 2, 1);
}

@("name resolution reports a constructor two imports define only where it's used, and accepts it qualified")
unittest
{
    auto files = [
        "a.ag": "module a\ntype Shared(x: Int)",
        "b.ag": "module b\ntype Shared(y: Int)",
    ];
    analyzed("import a\nimport b\ndef main(): Unit {\n    val s = Shared(1)\n}", files)
        .shouldReport(DiagnosticCode.AmbiguousName, At("Shared", 1));
    analyzed("import a\nimport b\ndef main(): Unit {\n    val s = b.Shared(1)\n}", files)
        .shouldHaveNoDiagnostics();
}

@("name resolution doesn't see constructors from the imports of an imported module")
unittest
{
    auto files = [
        "a.ag": "module a\nimport b",
        "b.ag": "module b\ntype Secret(x: Int)",
    ];
    analyzed("import a\ndef main(): Unit {\n    val s = Secret(1)\n}", files)
        .shouldReport(DiagnosticCode.UnknownName, At("Secret", 1));
}

@("name resolution reports a constructor that doesn't exist")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)"];
    analyzed("def main(): Unit {\n    val p = Nope(1)\n}")
        .shouldReport(DiagnosticCode.UnknownName, At("Nope", 1));
    analyzed("import geo\ndef main(): Unit {\n    val p = geo.Nope(1)\n}", files)
        .shouldReport(DiagnosticCode.UnknownModuleMember, At("geo", 2));
}

@("name resolution leaves a field read for the type checker")
unittest
{
    auto a = analyzed("type Point(x: Int)\ndef main(): Unit {\n    val p = Point(1)\n    val v = p.x\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldNotResolve(At("x", 2));
}

@("name resolution records a call to a type's name as a construction of that type")
unittest
{
    auto a = analyzed("type Point(x: Int)\ndef main(): Unit {\n    val p = Point(1)\n}");
    a.shouldConstruct(At("Point", 2), At("Point", 1));
}

@("name resolution records a construction of an imported type, plain or qualified")
unittest
{
    auto files = ["a/geo.ag": "module a.geo\ntype Point(x: Int)"];
    auto a = analyzed("import a.geo\ndef main(): Unit {\n    val p = Point(1)\n    val q = a.geo.Point(2)\n}", files);
    a.shouldConstruct(At("Point", 1), At("Point", 1, "a.geo"));
    a.shouldConstruct(At("Point", 2), At("Point", 1, "a.geo"));
}

@("name resolution records a construction of the module's own type over an imported one")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)"];
    auto a = analyzed("import geo\ntype Point(y: Int)\ndef main(): Unit {\n    val p = Point(1)\n}", files);
    a.shouldConstruct(At("Point", 2), At("Point", 1));
}

@("name resolution records nested constructions separately")
unittest
{
    auto a = analyzed("type Point(x: Int)\ntype Line(start: Point)\ndef main(): Unit {\n    val l = Line(Point(1))\n}");
    a.shouldConstruct(At("Line", 2), At("Line", 1));
    a.shouldConstruct(At("Point", 3), At("Point", 1));
}

@("name resolution doesn't record a call to a function as a construction")
unittest
{
    auto a = analyzed("def f(): Int => 1\ndef main(): Unit {\n    val x = f()\n}");
    a.shouldNotConstruct(At("f", 2));
    a.shouldCall(At("f", 2), At("f", 1));
}

@("name resolution doesn't record a call through a local as a construction")
unittest
{
    auto a = analyzed("type Point(x: Int)\ndef main(): Unit {\n    val make = Point\n    val p = make(1)\n}");
    a.shouldNotConstruct(At("make", 2));
    a.shouldHaveNoCallee(At("make", 2));
}

// The declarations table

/// Asserts that the declaration at `where` has a table entry naming it, which also shows that
/// the entry still points at the AST rather than at a copy that's gone.
void shouldHaveDeclaration(const Analyzed a, At where, string file = __FILE__, size_t line = __LINE__)
{
    auto symbol = where.offsetIn(a) in a.names[where.moduleName].declarations;
    if (symbol is null)
    {
        throw new AssertError(format("%s isn't a declaration", where), file, line);
    }
    auto name = (*symbol).match!(
        (const Id!FunctionDecl id) => a.analysis.declarationOf(id).name,
        (const Id!TypeDecl id) => a.analysis.declarationOf(id).name,
        (const Id!ConstDecl id) => a.analysis.declarationOf(id).name,
        (const Id!VarDecl id) => a.analysis.declarationOf(id).name,
        (const Id!Param id) => a.analysis.declarationOf(id).name,
        (const Id!Module _) => cast(string) null,
        (const Id!AliasDecl _) => cast(string) null,
    );
    if (name != where.word)
    {
        throw new AssertError(format("%s has the table entry '%s'", where, name), file, line);
    }
}

@("name resolution records every kind of declaration, however deeply nested")
unittest
{
    auto a = analyzed(`type Point(x: Int)
native def external(raw: Int): Int
def helper(given: Int): Int {
    val outer = given
    if outer > 0 {
        val inner = outer
        while false {
            mutable val deepest = inner
        }
    }
    outer
}
def main(): Unit => ()`);
    a.shouldHaveNoDiagnostics();
    foreach (name; ["Point", "external", "raw", "helper", "given", "outer", "inner", "deepest", "main"])
    {
        a.shouldHaveDeclaration(At(name, 1));
    }
}

@("name resolution records the declarations of imported modules")
unittest
{
    auto files = ["geo.ag": "module geo\ntype Point(x: Int)\ndef f(given: Int): Int {\n    val local = given\n    local\n}"];
    auto a = analyzed("import geo\ndef main(): Unit => ()", files);
    a.shouldHaveNoDiagnostics();
    foreach (name; ["Point", "f", "given", "local"])
    {
        a.shouldHaveDeclaration(At(name, 1, "geo"));
    }
}

@("name resolution records declarations that clash, since each still has an ID")
unittest
{
    auto a = analyzed("def main(): Unit {\n    val x = 1\n    val x = 2\n}");
    a.shouldHaveDeclaration(At("x", 1));
    a.shouldHaveDeclaration(At("x", 2));
}

// Top-level constants

@("name resolution finds a constant wherever it's declared in the module")
unittest
{
    auto a = analyzed("def f(): Int => late\nval early: Int = late\nval late: Int = 1\ndef main(): Unit => ()");
    a.shouldHaveNoDiagnostics();
    a.shouldResolve("late", 1, 3);
    a.shouldResolve("late", 2, 3);
    a.shouldHaveDeclaration(At("late", 3));
}

@("name resolution finds an imported constant, plain or qualified")
unittest
{
    auto a = analyzed("import lib.values\nval mine: Int = limit\nval theirs: Int = lib.values.limit\ndef main(): Unit => ()",
        ["lib/values.ag": "module lib.values\nval limit: Int = 1"]);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("limit", 1), At("limit", 1, "lib.values"));
    a.shouldResolve(At("limit", 2), At("limit", 1, "lib.values"));
}

@("name resolution reports a constant two imports define only where it's used, and accepts it qualified")
unittest
{
    auto files = [
        "a.ag": "module a\nval limit: Int = 1",
        "b.ag": "module b\nval limit: Int = 2",
    ];
    analyzed("import a\nimport b\ndef main(): Unit => ()", files).shouldHaveNoDiagnostics();
    analyzed("import a\nimport b\nval x: Int = a.limit + b.limit\ndef main(): Unit => ()", files)
        .shouldHaveNoDiagnostics();
    analyzed("import a\nimport b\nval x: Int = limit\ndef main(): Unit => ()", files)
        .shouldReport(DiagnosticCode.AmbiguousName, At("limit", 1));
}

@("name resolution prefers a module's own constant over an imported one")
unittest
{
    auto a = analyzed("import a\nval limit: Int = 2\nval x: Int = limit\ndef main(): Unit => ()",
        ["a.ag": "module a\nval limit: Int = 1"]);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve("limit", 2, 1);
}

@("name resolution doesn't see constants from the imports of an imported module")
unittest
{
    analyzed("import a\nval x: Int = hidden\ndef main(): Unit => ()", [
        "a.ag": "module a\nimport b",
        "b.ag": "module b\nval hidden: Int = 1",
    ]).shouldReport(DiagnosticCode.UnknownName, At("hidden", 1));
}

@("name resolution reports a constant declared twice, or sharing a function's name, at the second name")
unittest
{
    analyzed("val x: Int = 1\nval x: Int = 2\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.DuplicateDeclaration, At("x", 2));
    analyzed("def x(): Int => 1\nval x: Int = 2\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.DuplicateDeclaration, At("x", 2));
    analyzed("val x: Int = 2\ndef x(): Int => 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.DuplicateDeclaration, At("x", 2));
}

// Case keeps a type and a constant apart in source, so this builds the declarations directly.
@("name resolution reports a constant and a type sharing a name, whichever comes second")
unittest
{
    import silver.syntax.parse : parse;

    DiagnosticCode[] codesWith(Decl delegate(NodeIds, Span)[] makers...)
    {
        auto context = new SourceContext;
        auto ids = new NodeIds;
        auto m = new Module;
        *m = parse("def main(): Unit => ()", "main", ids, "main.ag");
        foreach (make; makers)
        {
            m.declarations ~= make(ids, Span("main.ag", 0, 0));
        }
        Program program;
        program.sources = context.sources;
        program.ids = ids;
        program.modules["main"] = m;
        analyze(program, context.collector);

        DiagnosticCode[] codes;
        foreach (diagnostic; context.collector.diagnostics)
        {
            codes ~= diagnostic.code;
        }
        return codes;
    }

    Decl type(NodeIds ids, Span span)
    {
        return Decl(span, DeclKind(TypeDecl(ids.next!TypeDecl, "Clash", span)));
    }

    Decl constant(NodeIds ids, Span span)
    {
        auto one = Expr(ids.next!Expr, span, ExprKind(IntLiteral(1)));
        auto annotation = new TypeExpr(ids.next!TypeExpr, span, TypeExprKind(NamedType(["Int"])));
        return Decl(span, DeclKind(ConstDecl(ids.next!ConstDecl, "Clash", span, annotation, one)));
    }

    assert(codesWith(&type, &constant) == [DiagnosticCode.DuplicateDeclaration]);
    assert(codesWith(&constant, &type) == [DiagnosticCode.DuplicateDeclaration]);
}

@("name resolution reports a local or parameter with the same name as a constant in its module")
unittest
{
    analyzed("val x: Int = 1\ndef main(): Unit {\n    val x = 2\n}")
        .shouldReport(DiagnosticCode.ShadowedDeclaration, At("x", 2));
    analyzed("val x: Int = 1\ndef f(x: Int): Int => x\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.ShadowedDeclaration, At("x", 2));
}

@("name resolution lets a local hide an imported constant")
unittest
{
    auto a = analyzed("import a\ndef main(): Unit {\n    val limit = 2\n    printl(limit)\n}",
        ["a.ag": "module a\nval limit: Int = 1"]);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve("limit", 2, 1);
}

@("name resolution reports a constant with the same name as an imported module's root")
unittest
{
    analyzed("import std.math\nval std: Int = 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.ShadowedDeclaration, At("std", 2));
}

@("name resolution reports an unknown constant, plain or qualified, once")
unittest
{
    analyzed("val x: Int = nope\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.UnknownName, At("nope", 1));
    analyzed("import std.math\nval x: Float = std.math.nope\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.UnknownModuleMember, At("std", 2));
    analyzed("import std.math\nval x: Float = std.nope\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.UnknownName, At("std", 2));
}

@("name resolution reports a module used as a constant's value, once")
unittest
{
    analyzed("import std.math\nval x: Int = std.math\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.ModuleIsNotAValue, At("std", 2));
}

@("name resolution reports a constant with no type, at its name, and nothing else")
unittest
{
    analyzed("val x = 1\ndef main(): Unit => ()").shouldReport(DiagnosticCode.MissingConstantType, At("x", 1));
    // It has no type to compare a use with, and evaluating it can't add anything.
    analyzed("val x = 1\nval y: String = x\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.MissingConstantType, At("x", 1));
}

@("name resolution accepts a constant of every primitive type")
unittest
{
    analyzed(`val a: Bool = true
val b: Int = 1
val c: Int8 = 1
val d: Int16 = 1
val e: Int32 = 1
val f: Int64 = 1
val g: UInt = 1
val h: UInt8 = 1
val i: UInt16 = 1
val j: UInt32 = 1
val k: UInt64 = 1
val l: Float = 1.5
val m: String = "s"
val n: Unit = ()
val o: () = ()
def main(): Unit => ()`).shouldHaveNoDiagnostics();
}

@("name resolution reports a constant whose type isn't a primitive, at the type, and nothing else")
unittest
{
    void check(string annotation, string initializer, string file = __FILE__, size_t line = __LINE__)
    {
        analyzed("type Marker\ndef f(): Int => 1\nval x: " ~ annotation ~ " = " ~ initializer
                ~ "\nval y: String = x\ndef main(): Unit => ()")
            .shouldReport(DiagnosticCode.InvalidConstantType, At(annotation, annotation == "Marker" ? 2 : 1), file, line);
    }

    check("Any", "1");
    check("Never", "1");
    check("Marker", "Marker");
    analyzed("val x: Int? = 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidConstantType, At("Int", 1));
    analyzed("def f(): Int => 1\nval x: () -> Int = f\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidConstantType, At("()", 1));
}

@("name resolution reports an unknown type on a constant, once")
unittest
{
    analyzed("val x: Nope = 1\ndef main(): Unit => ()").shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
}

@("x.f() finds f as a plain name would, and an ambiguity only matters if no field wins")
unittest
{
    auto files = [
        "a.ag": "module a\ndef shared(x: Int): Int => 1",
        "b.ag": "module b\ndef shared(x: Int): Int => 2",
    ];
    analyzed("import a\nimport b\ndef main(): Unit {\n    val qq = 1\n    printl(qq.shared())\n}", files)
        .shouldReport(DiagnosticCode.AmbiguousName, At("qq.shared", 1));
    analyzed("import a\nimport b\ntype T(shared: (Int) -> Int)\ndef f(x: Int): Int => x\ndef main(): Unit {\n    val qq = T(f)\n    printl(qq.shared(1))\n}", files)
        .shouldHaveNoDiagnostics();
    analyzed("import a\nimport b\ndef shared(x: Int): Int => 3\ndef main(): Unit {\n    val qq = 1\n    printl(qq.shared())\n}", files)
        .shouldHaveNoDiagnostics();
}

private enum privateLibrary = [
    "lib.ag": "module lib
private def helper(): Int => 1
private val limit: Int = 2
private type Detail(value: Int)
private type Hidden = Inner(n: Int) | Bare
def open(): Int => helper() + limit",
];

@("a private declaration is usable in its own module")
unittest
{
    analyzed("import lib\ndef main(): Unit => printl(open())", privateLibrary).shouldHaveNoDiagnostics();
}

@("a private declaration can't be used unqualified from another module")
unittest
{
    analyzed("import lib\ndef main(): Unit => printl(helper())", privateLibrary)
        .shouldReport(DiagnosticCode.UnknownName, At("helper", 1));
    analyzed("import lib\ndef main(): Unit => printl(limit)", privateLibrary)
        .shouldReport(DiagnosticCode.UnknownName, At("limit", 1));
    analyzed("import lib\ndef f(d: Detail): Int => 1\ndef main(): Unit => ()", privateLibrary)
        .shouldReport(DiagnosticCode.UnknownType, At("Detail", 1));
    analyzed("import lib\ndef main(): Unit => printl(Detail(1))", privateLibrary)
        .shouldReport(DiagnosticCode.UnknownName, At("Detail", 1));
    analyzed("import lib\ndef main(): Unit => printl(Inner(1))", privateLibrary)
        .shouldReport(DiagnosticCode.UnknownName, At("Inner", 1));
    analyzed("import lib\ndef main(): Unit => printl(Bare)", privateLibrary)
        .shouldReport(DiagnosticCode.UnknownName, At("Bare", 1));
}

@("a private declaration can't be reached qualified, and the error says whose it is")
unittest
{
    auto value = analyzed("import lib\ndef main(): Unit => printl(lib.helper())", privateLibrary);
    value.shouldReport(DiagnosticCode.PrivateMember, At("lib", 2));
    import std.algorithm : canFind;
    assert(value.collector.errors.front.message.canFind("private to 'lib'"));

    analyzed("import lib\ndef f(d: lib.Detail): Int => 1\ndef main(): Unit => ()", privateLibrary)
        .shouldReport(DiagnosticCode.PrivateMember, At("lib", 2));
}

@("a private declaration doesn't take part in ambiguity between imports")
unittest
{
    auto files = [
        "a.ag": "module a\nprivate def shared(): Int => 1\nprivate type T",
        "b.ag": "module b\ndef shared(): Int => 2\ntype T",
    ];
    auto a = analyzed("import a\nimport b\ndef f(t: T): Int => shared()\ndef main(): Unit => ()", files);
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("shared", 1), At("shared", 1, "b"));
}

@("a private function isn't a method candidate from another module")
unittest
{
    auto files = ["a.ag": "module a\nprivate def twice(x: Int): Int => x * 2"];
    analyzed("import a\ndef main(): Unit {\nval n = 1\nprintl(n.twice())\n}", files)
        .shouldReport(DiagnosticCode.UnknownMember, At("n", 2));
}

@("a public signature can't mention a private type")
unittest
{
    void rejected(string declaration)
    {
        auto a = analyzed("module main\nprivate type Detail(value: Int)\n" ~ declaration ~ "\ndef main(): Unit => ()");
        a.shouldReport(DiagnosticCode.PrivateTypeExposed, At("Detail", 2));
    }

    rejected("def f(d: Detail): Int => 1");
    rejected("def f(): Detail? => None");
    rejected("def f(g: ([Detail]) -> Int): Int => 1");
    rejected("def f(p: (Int, Detail)): Int => 1");
    rejected("native def f(d: Detail): Int");
    rejected("type Holder(d: Detail)");
    rejected("type Sum = Detail | Other");
    rejected("type Sum = Inline(d: Detail) | Other");
}

@("a private signature or field can mention a private type")
unittest
{
    analyzed("private type Detail(value: Int)
private def f(d: Detail): Detail => d
private type Inner(d: Detail)
private type Sum = Detail | Other
def main(): Unit => ()").shouldHaveNoDiagnostics();
}

@("main can't be private")
unittest
{
    analyzed("private def main(): Unit => ()").shouldReport(DiagnosticCode.MainInvalidDefinition, At("main", 1));
}
