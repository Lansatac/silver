module silver.loader;

import std.array : join;
import std.file : exists, readText;
import std.format : format;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, stripExtension;
import std.sumtype;

import silver.ast;
import silver.syntax.parse : parse;

/// Parses `source` (the entry module, read from `file`) and everything it needs:
/// prelude.ag if an import path has one, and every imported module, transitively.
/// Each file's text is added to `context.sources`, so errors can be reported even if loading fails.
/// An import that isn't on any import path is reported to `context.collector` and skipped.
/// Throws: ParseException.
Program load(string source, string file, string[] importPaths, SourceContext context)
{
    context.sources.add(file, source);
    Program program;
    program.sources = context.sources;
    program.main = parse(source, baseName(file).stripExtension, file);

    // Modules whose imports haven't been followed yet.
    Module[] unscanned = [program.main];
    auto preludePath = findModule(["prelude"], importPaths);
    if (preludePath !is null)
    {
        program.modules["prelude"] = parseModuleFile(preludePath, "prelude", context);
        unscanned ~= *program.modules["prelude"];
    }

    while (unscanned.length > 0)
    {
        auto current = unscanned[$ - 1];
        unscanned = unscanned[0 .. $ - 1];
        foreach (importNode; current.declarations)
        {
            if (!importNode.kind.has!ImportStmt)
            {
                continue;
            }
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
                context.collector.reportError(importNode.span, format("Module '%s.ag' not found", path.join("/")));
                continue;
            }
            program.modules[name] = parseModuleFile(modulePath, name, context);
            unscanned ~= *program.modules[name];
        }
    }

    return program;
}

/// Directory holding Silver's standard library (prelude.ag, math.ag, ...).
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
        auto path = buildPath(importPath, chain.join("/") ~ ".ag");
        if (exists(path))
        {
            return path;
        }
    }
    return null;
}

/// Reads and parses the module at `path`. The text is recorded in `context.sources` before
/// parsing, so a parse error can be reported against it.
private Module* parseModuleFile(string path, string name, SourceContext context)
{
    auto text = readText(path);
    context.sources.add(path, text);
    auto loaded = new Module;
    *loaded = parse(text, name, path);
    return loaded;
}

version (unittest)
{
    import fluent.asserts;
    import std.algorithm : map, sort;
    import std.array : array;
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
        ["a.ag": "import b", "b.ag": "def b(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.ag", [directory], new SourceContext);
    assert("a" in program.modules);
    assert("b" in program.modules);
    program.modules.length.should.equal(2);
}

@("load maps a dotted import to a directory")
unittest
{
    auto directory = makeModuleDirectory("dotted", ["a/b.ag": "def b(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a.b", "main.ag", [directory], new SourceContext);
    assert("a.b" in program.modules);
    program.modules["a.b"].name.should.equal("a.b");
}

@("load terminates on an import cycle")
unittest
{
    auto directory = makeModuleDirectory("cycle",
        ["a.ag": "import b", "b.ag": "import a"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.ag", [directory], new SourceContext);
    program.modules.length.should.equal(2);
}

@("load reports an import that isn't on any import path and keeps going")
unittest
{
    auto directory = makeModuleDirectory("missing", ["a.ag": "def a(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto source = "def x(): Int => 1
import nope
import a";
    auto context = new SourceContext;
    auto program = load(source, "main.ag", [directory], context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].message.should.equal("Module 'nope.ag' not found");
    errors[0].span.file.should.equal("main.ag");
    errors[0].span.start.should.equal(source.indexOf("import nope"));
    assert("a" in program.modules);
}

@("load reports every missing import")
unittest
{
    auto directory = makeModuleDirectory("missing-several", ["a.ag": "import gone"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    load("import nope
import a", "main.ag", [directory], context);

    context.collector.errors.map!(d => d.message.idup).array.sort.array.should.equal(
        ["Module 'gone.ag' not found", "Module 'nope.ag' not found"]);
}

@("standardLibraryPath holds prelude.ag")
unittest
{
    assert(exists(buildPath(standardLibraryPath(), "prelude.ag")));
}

@("load includes the prelude when an import path has one")
unittest
{
    auto directory = makeModuleDirectory("prelude", ["prelude.ag": "def p(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("def x(): Int => 1", "main.ag", [directory], new SourceContext);
    assert("prelude" in program.modules);
}

@("load works without a prelude")
unittest
{
    auto directory = makeModuleDirectory("no-prelude", ["a.ag": "def a(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("def x(): Int => 1", "main.ag", [directory], new SourceContext);
    assert("prelude" !in program.modules);
    program.modules.length.should.equal(0);
}

@("load records an imported module's text and throws its parse error")
unittest
{
    auto directory = makeModuleDirectory("parse-error", ["bad.ag": "val = 1"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto badPath = buildPath(directory, "bad.ag");
    try
    {
        load("import bad", "main.ag", [directory], context);
        assert(false, "Expected a parse error");
    }
    catch (ParseException e)
    {
        e.diagnostic.span.file.should.equal(badPath);
        context.sources.has(badPath).should.equal(true);
    }
}
