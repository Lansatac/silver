module silver.loader;

import std.array : join, split;
import std.file : exists, readText;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName, stripExtension;
import std.sumtype;
import std.typecons : Tuple;

import silver.ast;
import silver.syntax.parse : parse;

/// Parses `source` (read from `file`) and everything it needs: `lang`, the module `prelude` names
/// unless it's null, and every imported module, transitively. `lang`'s modules are read from
/// `standardLibraryPath()` alone, and the others from `importPaths`.
/// Each file's text is added to `context.sources`, so errors can be reported even if loading fails.
/// An import that isn't on any import path is reported to `context.collector` and skipped, and so
/// is a prelude that isn't.
///
/// Every imported file must start with a `module` line matching the path it was imported by.
/// `file` may leave it out, and is then named after the file and can't be imported. If it has
/// one, the line must match the end of `file`'s path, and the rest of that path is searched for
/// imports first.
/// Throws: ParseException.
Program load(string source, string file, string[] importPaths, string prelude, SourceContext context)
{
    context.sources.add(file, source);
    Program program;
    program.sources = context.sources;
    program.prelude = prelude;
    auto start = new Module;
    auto startName = baseName(file).stripExtension;
    *start = parse(source, startName, new NodeIds(ModuleKey.of(startName, source)), file);
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
        else if (isInLang(start.name) && !sameFile(file, findModule(declaration.path, importPaths)))
        {
            context.collector.reportError(DiagnosticCode.ModuleDeclarationMismatch, declaration.span,
                format("Module '%s' belongs to `%s`, which ships with the compiler, so it must be the file at %s",
                    start.name, langPackage, buildPath(standardLibraryPath() ~ declaration.path) ~ ".ag"));
        }
        else
        {
            importPaths = root ~ importPaths;
        }
    }
    program.modules[start.name] = start;
    program.entryModule = start.name;

    // Modules whose imports haven't been followed yet.
    Module*[] unscanned = [start];
    foreach (i, implicit; [langPackage, prelude])
    {
        if (implicit is null || implicit in program.modules) continue;
        auto chain = implicit.split(".");
        auto path = findModule(chain, importPaths);
        if (path !is null)
        {
            program.modules[implicit] = parseModuleFile(path, chain, context);
            unscanned ~= program.modules[implicit];
        }
        else if (i == 1)
        {
            context.collector.reportError(DiagnosticCode.ModuleNotFound, Span(file, 0, 0),
                format("The prelude, '%s', wasn't found: there's no %s.ag\nPaths searched: %s",
                    prelude, chain.join("/"), importPaths.join("\n")));
        }
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
            program.modules[name] = parseModuleFile(modulePath, path, context);
            unscanned ~= program.modules[name];
        }
    }

    return program;
}

/// Directory holding `lang` and the standard library that ships with the compiler.
/// For now it's the repo's stdlib/, found relative to this source file; this is the
/// place to add an environment variable or install-relative lookup later.
string standardLibraryPath()
{
    return buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "stdlib");
}

/// The prelude a build names when it's told of no other: the standard library's. The compiler
/// itself never names it, and only imports the prelude `load` is given.
enum standardPrelude = "std.prelude";

/// The path of the module `chain` on the first import path that has it, or null. A module of
/// `lang` is looked for only where the compiler's own is.
private string findModule(string[] chain, string[] importPaths)
{
    if (isInLang(chain.join("."))) importPaths = [standardLibraryPath()];
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
private Module* parseModuleFile(string path, string[] chain, SourceContext context)
{
    auto name = chain.join(".");
    auto text = readText(path);
    context.sources.add(path, text);
    auto loaded = parsed(name, text, path);
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

/// The module `name` parsed from `text`, read from `path`. Each is parsed once per thread and shared
/// by every program that loads it, since nothing changes an AST after loading and its IDs depend
/// only on its name and text. The starting file isn't kept: it's named after parsing, from its
/// `module` line, and is rarely loaded twice.
private Module* parsed(string name, string text, string path)
{
    auto key = Tuple!(string, string, string)(name, path, text);
    if (auto known = key in parsedModules) return *known;
    auto loaded = new Module;
    *loaded = parse(text, name, new NodeIds(ModuleKey.of(name, text)), path);
    parsedModules[key] = loaded;
    return loaded;
}

private Module*[Tuple!(string, string, string)] parsedModules;

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

/// Whether `a` and `b` name the same file, and false when `b` is null.
private bool sameFile(string a, string b)
{
    import std.path : filenameCmp;
    return b !is null && filenameCmp(buildNormalizedPath(absolutePath(a)), buildNormalizedPath(absolutePath(b))) == 0;
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

    /// The names of `program`'s modules outside `lang`, sorted.
    string[] ownModules(const Program program)
    {
        import std.algorithm : filter;
        return program.modules.keys.filter!(name => !isInLang(name)).array.sort.array;
    }
}

@("load includes transitive imports")
unittest
{
    auto directory = makeModuleDirectory("transitive",
        ["a.ag": "module a\nimport b", "b.ag": "module b\ndef b(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.ag", [directory], null, new SourceContext);
    assert("a" in program.modules);
    assert("b" in program.modules);
    ownModules(program).length.should.equal(3);
}

@("load follows forward imports, and a cycle of them ends")
unittest
{
    auto directory = makeModuleDirectory("forward",
        ["a.ag": "module a\nforward import b", "b.ag": "module b\nforward import c : c\nforward import a",
            "c.ag": "module c\ndef c(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.ag", [directory], null, new SourceContext);
    ownModules(program).should.equal(["a", "b", "c", "main"]);
}

@("load maps a dotted import to a directory")
unittest
{
    auto directory = makeModuleDirectory("dotted", ["a/b.ag": "module a.b\ndef b(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a.b", "main.ag", [directory], null, new SourceContext);
    assert("a.b" in program.modules);
    program.modules["a.b"].name.should.equal("a.b");
}

@("load terminates on an import cycle")
unittest
{
    auto directory = makeModuleDirectory("cycle",
        ["a.ag": "module a\nimport b", "b.ag": "module b\nimport a"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.ag", [directory], null, new SourceContext);
    ownModules(program).length.should.equal(3);
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
    auto program = load(source, "main.ag", [directory], null, context);

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
import a", "main.ag", [directory], null, context);

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
        ["base.ag": "module base\ndef p(): Int => 1", "a.ag": "module a\ndef a(): Int => 2"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a
def main(): Unit => ()", "main.ag", [directory], "base", new SourceContext);
    ownModules(program).should.equal(["a", "base", "main"]);
    assert(idProblems(program.modules.byValue.map!(m => *m).array) == []);
}

@("load shares an imported module between programs until its file changes")
unittest
{
    import std.file : write;

    auto directory = makeModuleDirectory("shared", ["a.ag": "module a\ndef a(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto first = load("import a", "main.ag", [directory], null, new SourceContext);
    auto second = load("import a\ndef main(): Unit => ()", "main.ag", [directory], null, new SourceContext);
    assert(first.modules["a"] is second.modules["a"]);
    assert(first.modules["main"] !is second.modules["main"]);

    write(buildPath(directory, "a.ag"), "module a\ndef a(): Int => 2");
    auto changed = load("import a", "main.ag", [directory], null, new SourceContext);
    assert(changed.modules["a"] !is first.modules["a"]);
    assert(changed.modules["a"].id != first.modules["a"].id);
}

@("standardLibraryPath holds lang and the standard prelude")
unittest
{
    assert(exists(buildPath(standardLibraryPath(), langPackage ~ ".ag")));
    assert(exists(buildPath(standardLibraryPath() ~ standardPrelude.split(".")) ~ ".ag"));
}

@("load includes the prelude it's given, whatever its name")
unittest
{
    auto directory = makeModuleDirectory("prelude", ["kit/base.ag": "module kit.base\ndef p(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("def x(): Int => 1", "main.ag", [directory], "kit.base", new SourceContext);
    ownModules(program).should.equal(["kit.base", "main"]);
    program.prelude.should.equal("kit.base");
}

@("load includes no prelude when it's given none, and a module named prelude is ordinary")
unittest
{
    auto directory = makeModuleDirectory("no-prelude", ["prelude.ag": "module prelude\ndef p(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("def x(): Int => 1", "main.ag", [directory], null, new SourceContext);
    ownModules(program).should.equal(["main"]);
}

@("load reports a prelude that isn't on any import path")
unittest
{
    auto context = new SourceContext;
    load("def x(): Int => 1", "main.ag", [], "kit.base", context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.ModuleNotFound);
    errors[0].message.should.contain("The prelude, 'kit.base', wasn't found");
    errors[0].span.should.equal(Span("main.ag", 0, 0));
}

@("load always brings lang, and only from the compiler's own directory")
unittest
{
    auto directory = makeModuleDirectory("lang-replaced",
        ["lang.ag": "module lang\ndef fake(): Int => 1", "lang/io.ag": "module lang.io\ndef fake(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import lang.io", "main.ag", [directory], null, new SourceContext);
    program.modules[langPackage].span.file.should.equal(buildPath(standardLibraryPath(), "lang.ag"));
    program.modules["lang.io"].span.file.should.equal(buildPath(standardLibraryPath(), "lang", "io.ag"));
}

@("load refuses a starting module that claims to be in lang from somewhere else")
unittest
{
    auto directory = makeModuleDirectory("lang-claimed", ["lang/evil.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    load("module lang.evil", buildPath(directory, "lang", "evil.ag"), [], null, context);
    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.ModuleDeclarationMismatch);
    errors[0].message.should.contain("ships with the compiler");
}

@("load accepts lang's own modules as the starting file, as `silver test` runs them")
unittest
{
    auto path = buildPath(standardLibraryPath(), "lang", "char.ag");
    auto context = new SourceContext;
    load(readText(path), path, [], null, context);
    context.collector.diagnostics.length.should.equal(0);
}

@("nothing in lang imports another package")
unittest
{
    import std.file : dirEntries, SpanMode;
    import std.regex : matchFirst, regex;

    auto lang = buildPath(standardLibraryPath(), langPackage);
    auto files = dirEntries(lang, "*.ag", SpanMode.depth).map!(e => e.name).array ~ [lang ~ ".ag"];
    auto anImport = regex(`^\s*(forward\s+)?import\s+([A-Za-z0-9_.]+)`, "m");
    foreach (file; files)
    {
        foreach (line; readText(file).split("\n"))
        {
            auto found = line.matchFirst(anImport);
            if (!found.empty) assert(isInLang(found[2]), file ~ " imports " ~ found[2]);
        }
    }
}

@("the compiler names no module outside lang")
unittest
{
    import std.algorithm : canFind, endsWith, filter, startsWith;
    import std.string : strip;
    import std.file : dirEntries, SpanMode;
    import std.regex : matchFirst, regex;

    // The standard library's prelude is named only where a build picks it, as `standardPrelude`.
    // Tests may name what they like, so only what comes before a `version (unittest)` is read.
    auto root = buildNormalizedPath(standardLibraryPath(), "..");
    auto named = regex(`"(std|prelude|intrinsics)(\.[A-Za-z0-9_.]*)?"`);
    foreach (package_; ["ast", "syntax", "loader", "sema", "core", "interpreter", "codegen"])
    {
        foreach (file; dirEntries(buildPath(root, package_, "source"), "*.d", SpanMode.depth)
            .map!(e => e.name).filter!(f => !f.endsWith("_tests.d") && !f.canFind("cases")))
        {
            auto text = readText(file);
            auto end = text.indexOf("version (unittest)");
            foreach (line; (end < 0 ? text : text[0 .. end]).split("\n"))
            {
                if (line.canFind("enum standardPrelude") || line.strip.startsWith("//")) continue;
                auto found = line.matchFirst(named);
                assert(found.empty, file ~ " names " ~ found.hit);
            }
        }
    }
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
        load("import bad", "main.ag", [directory], null, context);
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
    auto program = load("import a.b", "main.ag", [directory], null, context);

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
    load("import a.b", "main.ag", [directory], null, context);

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
    auto program = load("module app.tool", buildPath(directory, "app", "tool.ag"), [], null, context);
    context.collector.diagnostics.length.should.equal(0);
    assert("app.tool" in program.modules);
    program.modules["app.tool"].name.should.equal("app.tool");
}

@("load names an undeclared entry module by its file name")
unittest
{
    auto program = load("def main(): Unit => ()", "script.ag", [], null, new SourceContext);
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
        [], null, context);
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
    load("module " ~ package_ ~ ".tool", "tool.ag", [], null, context);
    context.collector.diagnostics.length.should.equal(0);
}

@("load reports a declared entry module whose module line doesn't match its path")
unittest
{
    auto source = "module std.maths";
    auto context = new SourceContext;
    load(source, buildPath("lib", "std", "math.ag"), [], null, context);

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
        [], null, context);

    context.collector.diagnostics.length.should.equal(0);
    ownModules(program).should.equal(["app.helper", "app.main"]);
}

@("load reports an import of an undeclared starting module, at the import")
unittest
{
    auto directory = makeModuleDirectory("undeclared-entry-imported",
        ["helper.ag": "module helper\nimport script"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    load("import helper", buildPath(directory, "script.ag"), [directory], null, context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.MissingModuleDeclaration);
    errors[0].span.file.should.equal(buildPath(directory, "helper.ag"));
    errors[0].message.should.contain("`module script`");
}

@("the check that the compiler names no module outside lang reads all of each file's non-test code")
unittest
{
    // That check stops at a file's first `version (unittest)`. analysis.d has a one-line
    // `version (unittest) import ...;` near its top, so `analyze` and the rest of the file go unread.
    auto text = readText(buildPath(standardLibraryPath(), "..", "sema", "source", "silver", "sema", "analysis.d"));
    auto cut = text.indexOf("version (unittest)");
    assert(cut < 0 || cut > text.indexOf("Analysis analyze("),
        "analysis.d is read only up to its first version (unittest), before analyze");
}
