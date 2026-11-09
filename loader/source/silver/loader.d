module silver.loader;

import std.array : join;
import std.file : exists, readText;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName, stripExtension;
import std.sumtype;

import silver.ast;
import silver.syntax.parse : parse;

/// Parses `source` (read from `file`) and everything it needs: prelude.ag if an import
/// path has one, and every imported module, transitively.
/// Each file's text is added to `context.sources`, so errors can be reported even if loading fails.
/// An import that isn't on any import path is reported to `context.collector` and skipped.
///
/// Every imported file must start with a `module` line matching the path it was imported by.
/// `file` may leave it out, and is then named after the file and can't be imported. If it has
/// one, the line must match the end of `file`'s path, and the rest of that path is searched for
/// imports first.
/// Throws: ParseException.
Program load(string source, string file, string[] importPaths, SourceContext context)
{
    context.sources.add(file, source);
    Program program;
    program.sources = context.sources;
    program.ids = new NodeIds;
    auto start = new Module;
    *start = parse(source, baseName(file).stripExtension, program.ids, file);
    if (auto declaration = start.declaration)
    {
        start.name = declaration.path.join(".");
        auto root = rootOf(file, declaration.path);
        if (root is null)
        {
            context.collector.reportError(DiagnosticCode.ModuleDeclarationMismatch, declaration.span,
                format("Module '%s' must be in a file at %s.ag",
                    start.name, declaration.path.join("/")));
        }
        else
        {
            importPaths = root ~ importPaths;
        }
    }
    program.modules[start.name] = start;

    // Modules whose imports haven't been followed yet.
    Module*[] unscanned = [start];
    auto preludePath = findModule(["prelude"], importPaths);
    if (preludePath !is null && "prelude" !in program.modules)
    {
        program.modules["prelude"] = parseModuleFile(preludePath, ["prelude"], program.ids, context);
        unscanned ~= program.modules["prelude"];
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
            if (auto loaded = name in program.modules)
            {
                // Only the starting file can be in the map without a `module` line.
                if ((*loaded).declaration is null)
                {
                    context.collector.reportError(DiagnosticCode.MissingModuleDeclaration, importNode.span,
                        format("'%s' has no module declaration, so it can't be imported\nAdd `module %s` as the first line of %s",
                            name, name, (*loaded).span.file));
                }
                continue;
            }
            auto modulePath = findModule(path, importPaths);
            if (modulePath is null)
            {
                context.collector.reportError(
                    DiagnosticCode.ModuleNotFound,
                    importNode.span,
                    format("Module '%s.ag' not found\nPaths searched: %s",
                        path.join("/"),
                        importPaths.join("\n")));
                continue;
            }
            program.modules[name] = parseModuleFile(modulePath, path, program.ids, context);
            unscanned ~= program.modules[name];
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
        auto path = buildPath(importPath ~ chain) ~ ".ag";
        if (exists(path))
        {
            return path;
        }
    }
    return null;
}

/// Reads and parses the module at `path`, which was found by looking up the module `chain`.
/// The text is recorded in `context.sources` before parsing, so a parse error can be reported
/// against it. A missing or mismatched `module` line is reported, and the module is still loaded.
private Module* parseModuleFile(string path, string[] chain, NodeIds ids, SourceContext context)
{
    auto name = chain.join(".");
    auto text = readText(path);
    context.sources.add(path, text);
    auto loaded = new Module;
    *loaded = parse(text, name, ids, path);
    if (loaded.declaration is null)
    {
        context.collector.reportError(DiagnosticCode.MissingModuleDeclaration, Span(path, 0, 0),
            format("Imported as '%s' but has no module declaration\nAdd `module %s` as its first line",
                name, name));
    }
    else if (loaded.declaration.path != chain)
    {
        context.collector.reportError(DiagnosticCode.ModuleDeclarationMismatch, loaded.declaration.span,
            format("Module '%s' must be in a file at %s.ag, but it's imported as '%s'",
                loaded.declaration.path.join("."), loaded.declaration.path.join("/"), name));
    }
    return loaded;
}

/// The directory that `file` is in once the directories and file name that `chain` names are
/// taken off the end, e.g. "lib" for "lib/std/math.ag" and ["std", "math"]. Null if `file`
/// doesn't end in `chain`'s path.
private string rootOf(string file, const string[] chain)
{
    import std.algorithm : equal;
    import std.array : array;
    import std.path : buildPath, extension, pathSplitter;

    if (extension(file) != ".ag")
    {
        return null;
    }
    // Absolute, since a file named from inside its package has a path shorter than its module name.
    auto parts = pathSplitter(buildNormalizedPath(absolutePath(file.stripExtension))).array;
    if (parts.length <= chain.length || !parts[$ - chain.length .. $].equal(chain))
    {
        return null;
    }
    return buildPath(parts[0 .. $ - chain.length]);
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
        ["a.ag": "module a\nimport b", "b.ag": "module b\ndef b(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.ag", [directory], new SourceContext);
    assert("a" in program.modules);
    assert("b" in program.modules);
    program.modules.length.should.equal(3);
}

@("load maps a dotted import to a directory")
unittest
{
    auto directory = makeModuleDirectory("dotted", ["a/b.ag": "module a.b\ndef b(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a.b", "main.ag", [directory], new SourceContext);
    assert("a.b" in program.modules);
    program.modules["a.b"].name.should.equal("a.b");
}

@("load terminates on an import cycle")
unittest
{
    auto directory = makeModuleDirectory("cycle",
        ["a.ag": "module a\nimport b", "b.ag": "module b\nimport a"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.ag", [directory], new SourceContext);
    program.modules.length.should.equal(3);
}

@("load reports an import that isn't on any import path and keeps going")
unittest
{
    auto directory = makeModuleDirectory("missing", ["a.ag": "module a\ndef a(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto source = "def x(): Int => 1
import nope
import a";
    auto context = new SourceContext;
    auto program = load(source, "main.ag", [directory], context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.ModuleNotFound);
    errors[0].message.should.contain("Module 'nope.ag' not found");
    errors[0].span.file.should.equal("main.ag");
    errors[0].span.start.should.equal(source.indexOf("import nope"));
    assert("a" in program.modules);
}

@("load reports every missing import")
unittest
{
    auto directory = makeModuleDirectory("missing-several", ["a.ag": "module a\nimport gone"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    load("import nope
import a", "main.ag", [directory], context);

    context.collector.errors.array.length.should.equal(2);
    foreach (diagnostic; context.collector.errors)
    {
        diagnostic.code.should.equal(DiagnosticCode.ModuleNotFound);
    }
}

@("load gives every node in the program its own ID")
unittest
{
    import std.array : array;

    auto directory = makeModuleDirectory("ids",
        ["prelude.ag": "module prelude\ndef p(): Int => 1", "a.ag": "module a\ndef a(): Int => 2"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a
def main(): Unit => ()", "main.ag", [directory], new SourceContext);
    auto modules = program.modules.byValue.map!(m => *m).array;
    modules.length.should.equal(3);
    assert(idProblems(modules) == []);
}

@("standardLibraryPath holds prelude.ag")
unittest
{
    assert(exists(buildPath(standardLibraryPath(), "prelude.ag")));
}

@("load includes the prelude when an import path has one")
unittest
{
    auto directory = makeModuleDirectory("prelude", ["prelude.ag": "module prelude\ndef p(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("def x(): Int => 1", "main.ag", [directory], new SourceContext);
    assert("prelude" in program.modules);
}

@("load works without a prelude")
unittest
{
    auto directory = makeModuleDirectory("no-prelude", ["a.ag": "module a\ndef a(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("def x(): Int => 1", "main.ag", [directory], new SourceContext);
    program.modules.keys.should.equal(["main"]);
}

@("load records an imported module's text and throws its parse error")
unittest
{
    auto directory = makeModuleDirectory("parse-error", ["bad.ag": "module bad\nval = 1"]);
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

@("load reports an imported module without a module line, at its start, and still loads it")
unittest
{
    auto directory = makeModuleDirectory("undeclared", ["a/b.ag": "def f(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto program = load("import a.b", "main.ag", [directory], context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.MissingModuleDeclaration);
    errors[0].message.should.contain("`module a.b`");
    errors[0].span.should.equal(Span(buildPath(directory, "a", "b.ag"), 0, 0));
    assert("a.b" in program.modules);
}

@("load reports an imported module whose module line doesn't match its import, at the line")
unittest
{
    auto source = "// The b module\nmodule a.c\ndef f(): Int => 1";
    auto directory = makeModuleDirectory("mismatched", ["a/b.ag": source]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    load("import a.b", "main.ag", [directory], context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.ModuleDeclarationMismatch);
    errors[0].span.file.should.equal(buildPath(directory, "a", "b.ag"));
    errors[0].span.start.should.equal(source.indexOf("module a.c"));
}

@("load names a declared entry module by its module line, not its file name")
unittest
{
    auto directory = makeModuleDirectory("entry-name", ["app/tool.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto program = load("module app.tool", buildPath(directory, "app", "tool.ag"), [], context);
    context.collector.diagnostics.length.should.equal(0);
    assert("app.tool" in program.modules);
    program.modules["app.tool"].name.should.equal("app.tool");
}

@("load names an undeclared entry module by its file name")
unittest
{
    auto program = load("def main(): Unit => ()", "script.ag", [], new SourceContext);
    assert("script" in program.modules);
}

@("load resolves a declared entry module's imports from the root its module line implies")
unittest
{
    // Running std/math.ag directly: std.common is next to it, though no import path says so.
    auto directory = makeModuleDirectory("entry-root",
        ["std/math.ag": "", "std/common.ag": "module std.common\ndef c(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto program = load("module std.math\nimport std.common", buildPath(directory, "std", "math.ag"),
        [], context);
    context.collector.diagnostics.length.should.equal(0);
    assert("std.common" in program.modules);
}

@("load accepts a declared entry module named by a path shorter than its module name")
unittest
{
    import std.ascii : isLower;
    import std.algorithm : all;
    import std.file : getcwd;

    // The working directory's name stands in for the package, so it has to be a valid module name.
    auto package_ = baseName(getcwd());
    if (!package_.all!isLower) return;

    auto context = new SourceContext;
    load("module " ~ package_ ~ ".tool", "tool.ag", [], context);
    context.collector.diagnostics.length.should.equal(0);
}

@("load reports a declared entry module whose module line doesn't match its path")
unittest
{
    auto source = "module std.maths";
    auto context = new SourceContext;
    load(source, buildPath("lib", "std", "math.ag"), [], context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.ModuleDeclarationMismatch);
    errors[0].message.should.contain("std/maths.ag");
}

@("load gives an import of the declared starting module the module already loaded")
unittest
{
    auto directory = makeModuleDirectory("entry-imported",
        ["app/main.ag": "", "app/helper.ag": "module app.helper\nimport app.main"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto program = load("module app.main\nimport app.helper", buildPath(directory, "app", "main.ag"),
        [], context);

    context.collector.diagnostics.length.should.equal(0);
    program.modules.keys.sort.array.should.equal(["app.helper", "app.main"]);
}

@("load reports an import of an undeclared starting module, at the import")
unittest
{
    auto directory = makeModuleDirectory("undeclared-entry-imported",
        ["helper.ag": "module helper\nimport script"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    load("import helper", buildPath(directory, "script.ag"), [directory], context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.MissingModuleDeclaration);
    errors[0].span.file.should.equal(buildPath(directory, "helper.ag"));
    errors[0].message.should.contain("`module script`");
}
