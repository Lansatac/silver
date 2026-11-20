module silver.loader;

import std.array : join, split;
import std.file : exists, readText;
import std.format : format;
import std.algorithm : endsWith;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName, extension, stripExtension;
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
///
/// `companion`, when testing, is the starting file's companion test file, which is loaded as part
/// of it. A companion can't be the starting file.
/// Throws: ParseException.
Program load(string source, string file, string[] importPaths, string prelude, SourceContext context,
    const(Companion)* companion = null)
{
    context.sources.add(file, source);
    Program program;
    program.sources = context.sources;
    program.prelude = prelude;
    // Before parsing, since what's wrong with it is where it was started from.
    if (isCompanionFile(file))
    {
        auto moduleFile = companionModuleFile(file);
        context.collector.reportError(DiagnosticCode.CompanionStarted, Span(file, 0, 0), exists(moduleFile)
            ? format("'%s' holds tests of %s, and is loaded with it only by `silver test`", file, moduleFile)
            : format("'%s' is named as the tests of %s, which doesn't exist\nRename it, or add %s",
                file, moduleFile, baseName(moduleFile)));
        return program;
    }
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
        else
        {
            importPaths = root ~ importPaths;
        }
    }
    // A file with no module line is named after itself, so `lang.ag` would be `lang` too.
    if (isInLang(start.name) && !sameFile(file, findModule(start.name.split("."), importPaths)))
    {
        context.collector.reportError(DiagnosticCode.NotInLang,
            start.declaration is null ? Span(file, 0, 0) : start.declaration.span,
            format("'%s' would be a module of `%s`, which ships with the compiler, and only the compiler's own %s can be\n%s",
                start.name, langPackage, buildPath(standardLibraryPath() ~ start.name.split(".")) ~ ".ag",
                start.declaration is null ? "Rename the file, or give it a `module` line outside `lang`"
                    : "Name the module outside `lang`"));
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

    // The companion's imports are followed last, so what's loaded then is in the program only for it.
    bool[string] built;
    foreach (forCompanion; [false, true])
    {
        if (forCompanion)
        {
            if (companion is null) break;
            foreach (name; program.modules.byKey) built[name] = true;
            if (companion.problem !is null)
            {
                context.collector.reportError(DiagnosticCode.UnreadableFile, Span(file, 0, 0),
                    format("The tests of '%s' in %s can't be read: %s", start.name, companion.file, companion.problem));
                break;
            }
            unscanned = [addCompanion(program, start, *companion, context)];
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
                if (isInLang(current.name) && !isInLang(name))
                {
                    context.collector.reportError(DiagnosticCode.LangImportsOutside, importNode.span,
                        format("`%s` depends on nothing outside itself, so %s can't import '%s'", langPackage,
                            current.companionOf is null ? "'" ~ current.name ~ "'" : "the tests of '" ~ current.companionOf ~ "'",
                            name));
                    continue;
                }
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
    }
    if (companion !is null)
    {
        import std.algorithm : sort;
        foreach (name; program.modules.keys.sort)
        {
            if (name !in built && program.modules[name].companionOf is null)
                refuseConformances(*program.modules[name], start.name, context);
        }
    }

    return program;
}

/// Reports each conformance in `mod`, which is in the program only because the companion test file
/// of `tested` reaches it. Every module sees a conformance, so `tested`'s code would mean something
/// else when tested than when built.
private void refuseConformances(const Module mod, string tested, SourceContext context)
{
    foreach (decl; mod.declarations)
    {
        if (!decl.kind.match!((const ConformDecl _) => true, _ => false)) continue;
        context.collector.reportError(DiagnosticCode.TestOnlyConformance, decl.span,
            format("'%s' is loaded only for the tests of '%s', so it can't declare a conformance: every module would see it "
                ~ "while testing, so '%s' wouldn't mean what it means when it's built", mod.name, tested, tested));
    }
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

/// A companion test file and its text. `name.test.ag` is part of the module `name.ag`, and is
/// loaded only when testing.
struct Companion
{
    string file;
    string source;
    /// Why the file couldn't be read, or null.
    string problem;
}

/// The companion test file of `file`, read from beside it, or null if there isn't one. A
/// directory of that name isn't one.
Companion* companionOf(string file)
{
    import std.file : isFile;

    if (isCompanionFile(file) || extension(file) != ".ag") return null;
    auto path = file.stripExtension ~ companionExtension;
    if (!exists(path) || !isFile(path)) return null;
    try
    {
        return new Companion(path, readText(path));
    }
    catch (Exception e)
    {
        return new Companion(path, null, e.msg);
    }
}

/// Whether `file` is named as a companion test file.
bool isCompanionFile(string file)
{
    auto name = baseName(file);
    return name.length > companionExtension.length && name.endsWith(companionExtension);
}

/// The module file that the companion test file `file` is part of.
string companionModuleFile(string file)
{
    return file[0 .. $ - companionExtension.length] ~ ".ag";
}

private enum companionExtension = ".test.ag";

/// Adds the companion test file `companion` of the module `start` to `program`, and returns it.
/// Its declarations are private, so only its module sees them, and it names the native library its
/// module does.
private Module* addCompanion(ref Program program, const(Module)* start, const Companion companion, SourceContext context)
{
    context.sources.add(companion.file, companion.source);
    auto name = companionName(start.name);
    auto loaded = new Module;
    *loaded = parse(companion.source, name, new NodeIds(ModuleKey.of(name, companion.source)), companion.file);
    loaded.companionOf = start.name;

    void refuse(Span span, string message)
    {
        context.collector.reportError(DiagnosticCode.NotInCompanion, span, message);
    }
    if (loaded.declaration !is null)
        refuse(loaded.declaration.span, format("A companion test file has no `module` line: it's part of '%s'", start.name));
    if (loaded.library !is null)
        refuse(loaded.library.span, format("A companion test file has no `native library`: it has the one of '%s'", start.name));
    loaded.library = cast(NativeLibrary*) start.library;
    foreach (ref decl; loaded.declarations)
    {
        auto span = decl.span;
        decl.kind.match!(
            (ref FunctionDecl function_) {
                if (function_.name == "main")
                    refuse(function_.nameSpan, "A companion test file can't declare `main`, since it's loaded only for tests");
                function_.isPrivate = true;
            },
            (ref TypeDecl type) { type.isPrivate = true; },
            (ref ConstDecl constant) { constant.isPrivate = true; },
            (ref AliasDecl alias_) { alias_.isPrivate = true; },
            (ref InterfaceDecl interface_) { interface_.isPrivate = true; },
            (ref ImportStmt import_) {
                if (import_.forward) refuse(span, "A companion test file can't `forward import`, since nothing imports it");
            },
            (ref ConformDecl _) {
                refuse(span, "A companion test file can't declare a conformance: every module would see it while testing, "
                    ~ "so its module's code wouldn't be the code that ships");
            },
        );
    }

    program.modules[name] = loaded;
    return loaded;
}

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

    /// A string literal, double-quoted or WYSIWYG, that is `std`, `prelude` or `intrinsics`, or a
    /// module under one.
    enum moduleNameLiteral = `["\x60](std|prelude|intrinsics)(\.[A-Za-z0-9_.]*)?["\x60]`;

    /// `text`, a D source file, without its tests: each `unittest` block, and what each
    /// `version (unittest)` covers, whether a block, one declaration, or with `:` the rest of the
    /// file. Braces are counted without regard to strings and comments, which in the compiler's
    /// sources keep them balanced.
    string withoutTests(string text)
    {
        import std.algorithm : startsWith;
        import std.regex : matchFirst, regex;

        auto start = regex(`\bunittest\s*\{|\bversion\s*\(\s*unittest\s*\)\s*`);
        string kept;
        auto rest = text;
        while (true)
        {
            auto found = rest.matchFirst(start);
            if (found.empty) return kept ~ rest;
            kept ~= found.pre;
            auto after = found.post;
            if (found.hit.startsWith("unittest")) rest = after[closing(after, 1) .. $];
            else if (after.startsWith(":")) return kept;
            else if (after.startsWith("{")) rest = after[1 + closing(after[1 .. $], 1) .. $];
            else
            {
                // One declaration: up to a `;` outside braces, or the end of its first braces.
                size_t end;
                int depth;
                for (; end < after.length; end++)
                {
                    if (after[end] == '{') depth++;
                    else if (after[end] == '}' && --depth == 0) { end++; break; }
                    else if (after[end] == ';' && depth == 0) { end++; break; }
                }
                rest = after[end .. $];
            }
        }
    }

    /// Where `text` is just past the `}` that leaves it with no open braces, given `depth` already open.
    size_t closing(string text, int depth)
    {
        foreach (i, c; text)
        {
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return i + 1;
        }
        return text.length;
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

@("load refuses a starting file that would be a module of lang from somewhere else, by its module line or its name")
unittest
{
    auto directory = makeModuleDirectory("lang-claimed", ["lang/evil.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    void refused(string source, string file, Span at)
    {
        auto context = new SourceContext;
        load(source, file, [], null, context);
        auto errors = context.collector.errors.array;
        errors.length.should.equal(1);
        errors[0].code.should.equal(DiagnosticCode.NotInLang);
        errors[0].message.should.contain("ships with the compiler");
        errors[0].span.should.equal(at);
    }
    refused("module lang.evil", buildPath(directory, "lang", "evil.ag"), Span(buildPath(directory, "lang", "evil.ag"), 0, 16));
    refused("def main(): Unit { }", "lang.evil.ag", Span("lang.evil.ag", 0, 0));
    refused("def main(): Unit { }", "lang.ag", Span("lang.ag", 0, 0));
    refused("module lang", "lang.ag", Span("lang.ag", 0, 11));
}

@("load refuses an import in a module of lang of anything outside lang")
unittest
{
    // The compiler's own file of `lang.char`, with other text, stands in for a module of lang.
    auto path = buildPath(standardLibraryPath(), "lang", "char.ag");
    auto source = "module lang.char\nimport lang.io\nimport std.ref\nforward import other";
    auto context = new SourceContext;
    auto program = load(source, path, [], null, context);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.LangImportsOutside, DiagnosticCode.LangImportsOutside]);
    errors[0].span.start.should.equal(source.indexOf("import std.ref"));
    errors[1].span.start.should.equal(source.indexOf("forward import other"));
    assert("std.ref" !in program.modules);
}

@("every module of lang loads as the starting file, as `silver test` runs them, importing only lang")
unittest
{
    import std.algorithm : filter;
    import std.file : dirEntries, SpanMode;

    auto lang = buildPath(standardLibraryPath(), langPackage);
    foreach (path; dirEntries(lang, "*.ag", SpanMode.depth).map!(e => e.name).filter!(f => !isCompanionFile(f)).array
        ~ [lang ~ ".ag"])
    {
        auto context = new SourceContext;
        auto program = load(readText(path), path, [], null, context);
        assert(context.collector.diagnostics.length == 0, path);
        assert(ownModules(program).length == 0, path);
    }
}


@("the compiler names no module outside lang")
unittest
{
    import std.algorithm : canFind, startsWith;
    import std.string : strip;
    import std.file : dirEntries, SpanMode;
    import std.regex : matchFirst, regex;

    // The standard library's prelude is named only where a build picks it, as `standardPrelude`.
    // Tests may name what they like. `testing/` and the driver are the build, so they aren't read.
    auto root = buildNormalizedPath(standardLibraryPath(), "..");
    auto named = regex(moduleNameLiteral);
    size_t read;
    foreach (package_; ["ast", "syntax", "loader", "sema", "core", "interpreter", "codegen"])
    {
        foreach (file; dirEntries(buildPath(root, package_, "source"), "*.d", SpanMode.depth).map!(e => e.name))
        {
            foreach (line; withoutTests(readText(file)).split("\n"))
            {
                if (line.canFind("enum standardPrelude") || line.strip.startsWith("//")) continue;
                auto found = line.matchFirst(named);
                assert(found.empty, file ~ " names " ~ found.hit);
                read++;
            }
        }
    }
    assert(read > 20_000, "Only %s lines were read".format(read));
}

@("the check that the compiler names no module outside lang reads all of each file's non-test code")
unittest
{
    import std.algorithm : canFind;
    import std.regex : matchFirst, regex;

    auto text = readText(buildPath(standardLibraryPath(), "..", "sema", "source", "silver", "sema", "analysis.d"));
    assert(withoutTests(text).canFind("Analysis analyze("), "analysis.d's analyze isn't read");
    withoutTests("a\nversion (unittest) import b;\nc\n@(\"t\") unittest { if (x) { y(); } }\nd\n"
        ~ "version (unittest) { e }\nf\nversion (unittest) void g() { h; }\ni\nversion (unittest):\nj")
        .should.equal("a\n\nc\n@(\"t\") \nd\n\nf\n\ni\n");
    auto named = regex(moduleNameLiteral);
    assert(!"x = `std.c`;".matchFirst(named).empty);
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

@("load adds the companion test file it's given as part of the starting module, with its declarations private")
unittest
{
    import std.sumtype : match;

    auto companion = Companion("shape.test.ag", "import extra\ndef helper(): Int => 1\ntype Fake(n: Int)\ntest \"t\" => expect(true)");
    auto directory = makeModuleDirectory("companion", ["extra.ag": "module extra\ndef e(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto program = load("def area(): Int => 1", "shape.ag", [directory], null, context, &companion);
    context.collector.diagnostics.length.should.equal(0);
    ownModules(program).should.equal(["extra", "shape", companionName("shape")]);
    auto loaded = program.modules[companionName("shape")];
    loaded.companionOf.should.equal("shape");
    loaded.span.file.should.equal("shape.test.ag");
    assert(context.sources.has("shape.test.ag"));
    foreach (decl; loaded.declarations)
    {
        assert(decl.kind.match!(
            (const FunctionDecl f) => f.isPrivate,
            (const TypeDecl t) => t.isPrivate,
            (const ImportStmt _) => true,
            _ => false,
        ));
    }
    assert(idProblems(program.modules.byValue.map!(m => *m).array) == []);

    auto without = load("def area(): Int => 1", "shape.ag", [directory], null, new SourceContext);
    ownModules(without).should.equal(["shape"]);
}

@("companionOf reads name.test.ag from beside name.ag, and a companion has none of its own")
unittest
{
    auto directory = makeModuleDirectory("companion-of",
        ["shape.ag": "", "shape.test.ag": "test \"t\" => expect(true)", "alone.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    auto found = companionOf(buildPath(directory, "shape.ag"));
    assert(found !is null);
    found.file.should.equal(buildPath(directory, "shape.test.ag"));
    found.source.should.equal("test \"t\" => expect(true)");
    assert(companionOf(buildPath(directory, "alone.ag")) is null);
    assert(companionOf(buildPath(directory, "shape.test.ag")) is null);
    assert(isCompanionFile("a/shape.test.ag") && !isCompanionFile("a/shape.ag") && !isCompanionFile("a/.test.ag"));
    companionModuleFile(buildPath("a", "shape.test.ag")).should.equal(buildPath("a", "shape.ag"));
}

@("no import reaches a companion test file")
unittest
{
    auto directory = makeModuleDirectory("companion-import",
        ["shape.ag": "module shape", "shape.test.ag": "def helper(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto program = load("import shape.test", "main.ag", [directory], null, context);
    context.collector.errors.array.map!(e => e.code).array.should.equal([DiagnosticCode.ModuleNotFound]);
    ownModules(program).should.equal(["main"]);
}

@("load refuses a companion test file as the starting file, whether or not its module is there")
unittest
{
    auto directory = makeModuleDirectory("companion-started", ["shape.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    foreach (name; ["shape", "gone"])
    {
        auto file = buildPath(directory, name ~ ".test.ag");
        auto context = new SourceContext;
        load("def main(): Unit => ()", file, [], null, context);
        auto errors = context.collector.errors.array;
        errors.length.should.equal(1);
        errors[0].code.should.equal(DiagnosticCode.CompanionStarted);
        errors[0].span.should.equal(Span(file, 0, 0));
        errors[0].message.should.contain(name == "shape" ? "only by `silver test`" : "which doesn't exist");
    }
}

@("a companion test file has no module line, native library, main, forward import or conformance")
unittest
{
    import std.algorithm : filter;

    auto source = "module shape\nnative library \"m\"\nforward import other\nconform Int: Sized\ndef main(): Unit => ()";
    auto companion = Companion("shape.test.ag", source);
    auto context = new SourceContext;
    load("module shape", "shape.ag", [], null, context, &companion);
    auto errors = context.collector.errors.array.filter!(e => e.code != DiagnosticCode.ModuleNotFound).array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.NotInCompanion, DiagnosticCode.NotInCompanion,
        DiagnosticCode.NotInCompanion, DiagnosticCode.NotInCompanion, DiagnosticCode.NotInCompanion]);
    errors.map!(e => e.span.start).array.should.equal([source.indexOf("module"), source.indexOf("native"),
        source.indexOf("forward"), source.indexOf("conform"), source.indexOf("main")]);
}

@("a companion of a module of lang is in lang, so it imports nothing outside lang")
unittest
{
    auto path = buildPath(standardLibraryPath(), "lang", "char.ag");
    auto source = "import lang.io\nimport std.ref\ntest \"t\" => expect(true)";
    auto companion = Companion(buildPath(standardLibraryPath(), "lang", "char.test.ag"), source);
    auto context = new SourceContext;
    auto program = load(readText(path), path, [standardLibraryPath()], standardPrelude, context, &companion);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.LangImportsOutside]);
    errors[0].span.start.should.equal(source.indexOf("import std.ref"));
    errors[0].message.should.contain("the tests of 'lang.char'");
    assert(isInLang(companionName("lang.char")) && isInLang(companionName(langPackage)));
}

@("a module in the program only for the companion test file can't declare a conformance, and one the module reaches can")
unittest
{
    auto directory = makeModuleDirectory("companion-conformance", [
        "fakes.ag": "module fakes\nconform Int: Sized",
        "shared.ag": "module shared\nconform Int: Sized",
        "deep.ag": "module deep\nimport fakes",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto companion = Companion("shape.test.ag", "import deep\nimport shared");
    auto context = new SourceContext;
    load("import shared", "shape.ag", [directory], null, context, &companion);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.TestOnlyConformance]);
    errors[0].span.file.should.equal(buildPath(directory, "fakes.ag"));
    errors[0].message.should.contain("only for the tests of 'shape'");
}

@("a companion test file that can't be read is reported, and the starting file's name is checked before it's parsed")
unittest
{
    auto unreadable = Companion("shape.test.ag", null, "Invalid UTF-8 sequence");
    auto context = new SourceContext;
    load("def area(): Int => 1", "shape.ag", [], null, context, &unreadable);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.UnreadableFile]);
    errors[0].message.should.contain("shape.test.ag can't be read: Invalid UTF-8 sequence");

    context = new SourceContext;
    load("def = broken", "gone.test.ag", [], null, context);
    context.collector.errors.array.map!(e => e.code).array.should.equal([DiagnosticCode.CompanionStarted]);
}
