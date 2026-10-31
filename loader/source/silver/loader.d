module silver.loader;

import std.array : join;
import std.file : exists, readText;
import std.format : format;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, stripExtension;
import std.sumtype;

import silver.ast;
import silver.syntax.parse : parse;

/// Parses `source` (the entry module, read from `file`) and everything it needs:
/// prelude.silver if an import path has one, and every imported module, transitively.
/// Each file's text is added to `sources`, so errors can be reported even if loading fails.
/// Throws: ParseException, or DiagnosticException for an import that isn't on any import path.
Program load(string source, string file, string[] importPaths, SourceMap sources)
{
    sources.add(file, source);
    Program program;
    program.sources = sources;
    program.main = parse(source, baseName(file).stripExtension, file);

    // Modules whose imports haven't been followed yet.
    Module[] unscanned = [program.main];
    auto preludePath = findModule(["prelude"], importPaths);
    if (preludePath !is null)
    {
        program.modules["prelude"] = parseModuleFile(preludePath, "prelude", sources);
        unscanned ~= *program.modules["prelude"];
    }

    while (unscanned.length > 0)
    {
        auto current = unscanned[$ - 1];
        unscanned = unscanned[0 .. $ - 1];
        foreach (importNode; importsIn(current.statements))
        {
            auto path = importNode.kind.get!ImportStmt.path;
            auto name = path.join(".");
            // Already loaded, or being loaded further up an import cycle.
            if (name in program.modules)
            {
                continue;
            }
            auto modulePath = findModule(path, importPaths);
            if (modulePath is null)
            {
                throw new DiagnosticException(Diagnostic(importNode.span,
                        format("Module '%s'.silver not found", path.join("/"))));
            }
            program.modules[name] = parseModuleFile(modulePath, name, sources);
            unscanned ~= *program.modules[name];
        }
    }
    return program;
}

/// Directory holding Silver's standard library (prelude.silver, math.silver, ...).
/// For now it's the repo's stdlib/, found relative to this source file; this is the
/// place to add an environment variable or install-relative lookup later.
string standardLibraryPath()
{
    return buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "stdlib");
}

/// The path of the module `chain` on the first import path that has it, or null.
private string findModule(string[] chain, string[] importPaths)
{
    foreach (importPath; importPaths)
    {
        auto path = buildPath(importPath, chain.join("/") ~ ".silver");
        if (exists(path))
        {
            return path;
        }
    }
    return null;
}

/// Reads and parses the module at `path`. The text is recorded in `sources` before
/// parsing, so a parse error can be reported against it.
private Module* parseModuleFile(string path, string name, SourceMap sources)
{
    auto text = readText(path);
    sources.add(path, text);
    auto loaded = new Module;
    *loaded = parse(text, name, path);
    return loaded;
}

/// The import statements in `statements`, including ones nested in function bodies,
/// blocks and other expressions. The grammar only allows imports at top level today.
private Stmt[] importsIn(Stmt[] statements)
{
    Stmt[] imports;
    foreach (statement; statements)
    {
        imports ~= importsIn(statement);
    }
    return imports;
}

private Stmt[] importsIn(Stmt statement)
{
    return statement.kind.match!(
        (VarDecl d) => importsIn(d.value),
        (AssignStmt a) => importsIn(a.target) ~ importsIn(a.value),
        (ExprStmt e) => importsIn(e.expr),
        (ImportStmt i) => [statement],
        (FunctionDecl f) => importsIn(f.body),
        (ReturnStmt r) => importsIn(r.value),
    );
}

private Stmt[] importsIn(Expr expr)
{
    return expr.kind.match!(
        (UnaryExpr u) => importsIn(u.operand),
        (BinaryExpr b) => importsIn(b.left) ~ importsIn(b.right),
        (CallExpr c) => importsIn(c.callee) ~ importsIn(c.args),
        (MemberAccess m) => importsIn(m.object),
        (WhileExpr w) => importsIn(w.condition) ~ importsIn(w.body),
        (IfExpr i) => importsIn(i.condition) ~ importsIn(i.trueBody) ~ importsIn(i.falseBody),
        (BlockExpr b) => importsIn(b.statements) ~ importsIn(b.value),
        (_) => Stmt[].init,
    );
}

private Stmt[] importsIn(Expr[] exprs)
{
    Stmt[] imports;
    foreach (expr; exprs)
    {
        imports ~= importsIn(expr);
    }
    return imports;
}

/// An optional child expression, which is null when absent.
private Stmt[] importsIn(Expr* expr)
{
    if (expr is null)
    {
        return null;
    }
    return importsIn(*expr);
}

version (unittest)
{
    import fluent.asserts;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.string : indexOf;
    import silver.syntax.parse : ParseException;

    /// Makes a fresh directory under the temp dir holding `files` (path to text),
    /// and returns its path. The caller removes it.
    string makeModuleDirectory(string name, string[string] files)
    {
        auto directory = buildPath(tempDir(), "silver-loader-" ~ name);
        if (exists(directory))
        {
            rmdirRecurse(directory);
        }
        mkdirRecurse(directory);
        foreach (fileName, text; files)
        {
            auto path = buildPath(directory, fileName);
            mkdirRecurse(dirName(path));
            write(path, text);
        }
        return directory;
    }
}

@("load includes transitive imports")
unittest
{
    auto directory = makeModuleDirectory("transitive",
        ["a.silver": "import b", "b.silver": "val b = 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.silver", [directory], new SourceMap);
    assert("a" in program.modules);
    assert("b" in program.modules);
    program.modules.length.should.equal(2);
}

@("load maps a dotted import to a directory")
unittest
{
    auto directory = makeModuleDirectory("dotted", ["a/b.silver": "val b = 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a.b", "main.silver", [directory], new SourceMap);
    assert("a.b" in program.modules);
    program.modules["a.b"].name.should.equal("a.b");
}

@("load terminates on an import cycle")
unittest
{
    auto directory = makeModuleDirectory("cycle",
        ["a.silver": "import b", "b.silver": "import a"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.silver", [directory], new SourceMap);
    program.modules.length.should.equal(2);
}

@("imports nested in function bodies, blocks and if branches are found")
unittest
{
    Span span;
    auto importA = Stmt(span, StmtKind(ImportStmt(["a"])));
    auto importB = Stmt(span, StmtKind(ImportStmt(["b"])));

    auto functionBody = new Expr(span, ExprKind(BlockExpr([importA], null)));
    auto functionDecl = Stmt(span, StmtKind(FunctionDecl("f", [], functionBody, "Unit", false)));

    auto condition = new Expr(span, ExprKind(BoolLiteral(true)));
    auto branch = new Expr(span, ExprKind(BlockExpr([importB], null)));
    auto ifStatement = Stmt(span, StmtKind(ExprStmt(Expr(span,
            ExprKind(IfExpr(condition, branch, null))))));

    auto found = importsIn([functionDecl, ifStatement]);
    found.length.should.equal(2);
    found[0].kind.get!ImportStmt.path.join(".").should.equal("a");
    found[1].kind.get!ImportStmt.path.join(".").should.equal("b");
}

@("load throws for an import that isn't on any import path")
unittest
{
    auto directory = makeModuleDirectory("missing", ["a.silver": "val a = 1"]);
    scope (exit) rmdirRecurse(directory);

    auto source = "val x = 1\nimport nope";
    try
    {
        load(source, "main.silver", [directory], new SourceMap);
        assert(false, "Expected a missing module error");
    }
    catch (DiagnosticException e)
    {
        e.diagnostic.message.should.equal("Module 'nope'.silver not found");
        e.diagnostic.span.file.should.equal("main.silver");
        e.diagnostic.span.start.should.equal(source.indexOf("import nope"));
    }
}

@("standardLibraryPath holds prelude.silver")
unittest
{
    assert(exists(buildPath(standardLibraryPath(), "prelude.silver")));
}

@("load includes the prelude when an import path has one")
unittest
{
    auto directory = makeModuleDirectory("prelude", ["prelude.silver": "val p = 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("val x = 1", "main.silver", [directory], new SourceMap);
    assert("prelude" in program.modules);
}

@("load works without a prelude")
unittest
{
    auto directory = makeModuleDirectory("no-prelude", ["a.silver": "val a = 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("val x = 1", "main.silver", [directory], new SourceMap);
    assert("prelude" !in program.modules);
    program.modules.length.should.equal(0);
}

@("load records an imported module's text and throws its parse error")
unittest
{
    auto directory = makeModuleDirectory("parse-error", ["bad.silver": "val = 1"]);
    scope (exit) rmdirRecurse(directory);

    auto sources = new SourceMap;
    auto badPath = buildPath(directory, "bad.silver");
    try
    {
        load("import bad", "main.silver", [directory], sources);
        assert(false, "Expected a parse error");
    }
    catch (ParseException e)
    {
        e.diagnostic.span.file.should.equal(badPath);
        sources.has(badPath).should.equal(true);
    }
}
