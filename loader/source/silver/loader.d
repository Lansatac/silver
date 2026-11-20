module silver.loader;

import std.algorithm : canFind, countUntil, endsWith, map, sort;
import std.array : array, join, split;
import std.file : exists, isDir, readText;
import std.format : format;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName, extension, stripExtension;
import std.sumtype;
import std.typecons : Tuple;

import silver.ast;
import silver.syntax.parse : parse;

/// What a build says about packages: the ones it knows, and what a file with no `module` line,
/// a program of its own, uses.
struct Packages
{
    Package[] declared;
    string[] scriptUses;
}

/// Parses `source` (read from `file`) and everything it needs: `lang`, the module `prelude` names
/// unless it's null, and every imported module, transitively. A module is found by the package
/// in `packages` whose name is the longest start of the module's name, and then by the rest of its
/// name as a path under the package's directory. `lang`'s modules are read from
/// `standardLibraryPath()` alone. Each file's text is added to `context.sources`, so errors can be
/// reported even if loading fails. An import that isn't found is reported to `context.collector`
/// and skipped, and so is a prelude that isn't, or an import from a package the importing module's
/// package doesn't list.
///
/// Every imported file must start with a `module` line matching the name it was imported by.
/// `file` may leave it out, and is then a program of its own, named after the file, that can't be
/// imported and uses what `packages.scriptUses` lists. If it has one, the line must name the module
/// that `file` is.
///
/// `companion`, when testing, is the starting file's companion test file, which is loaded as part
/// of it. A companion can't be the starting file.
/// Throws: ParseException.
Program load(string source, string file, const Packages packages, string prelude, SourceContext context,
    const(Companion)* companion = null)
{
    context.sources.add(file, source);
    Program program;
    program.sources = context.sources;
    program.prelude = prelude;
    program.packages = packages.declared;
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
    auto layout = Layout(packages.declared, packages.scriptUses);
    if (auto declaration = start.declaration)
    {
        start.name = declaration.path.join(".");
        if (!isInLang(start.name))
        {
            auto found = layout.locate(declaration.path);
            if (found.package_ is null || found.path is null)
            {
                context.collector.reportError(DiagnosticCode.ModuleDeclarationMismatch, declaration.span,
                    format("Module '%s' is in no package: %s", start.name, found.problem));
            }
            else
            {
                program.packageOf[start.name] = found.package_.name;
                if (!sameFile(file, found.path))
                {
                    context.collector.reportError(DiagnosticCode.ModuleDeclarationMismatch, declaration.span,
                        format("Module '%s' is in the package '%s', at %s, so it must be the file %s",
                            start.name, found.package_.name, found.package_.directory, found.path));
                }
            }
        }
    }
    else
    {
        layout.script = start.name;
        program.packageOf[start.name] = start.name;
    }
    // A file with no module line is named after itself, so `lang.ag` would be `lang` too.
    if (isInLang(start.name) && !sameFile(file, langModulePath(start.name.split("."))))
    {
        context.collector.reportError(DiagnosticCode.NotInLang,
            start.declaration is null ? Span(file, 0, 0) : start.declaration.span,
            format("'%s' would be a module of `%s`, which ships with the compiler, and only the compiler's own %s can be\n%s",
                start.name, langPackage, langModulePath(start.name.split(".")),
                start.declaration is null ? "Rename the file, or give it a `module` line outside `lang`"
                    : "Name the module outside `lang`"));
    }
    if (isInLang(start.name)) program.packageOf[start.name] = langPackage;
    program.modules[start.name] = start;
    program.entryModule = start.name;
    if (!layout.described(context)) return program;

    // Modules whose imports haven't been followed yet.
    Module*[] unscanned = [start];
    string[] roots = [program.packageOf.get(start.name, null)];
    foreach (i, implicit; [langPackage, prelude])
    {
        if (implicit is null || implicit in program.modules) continue;
        auto chain = implicit.split(".");
        auto found = layout.locate(chain);
        if (found.path !is null && exists(found.path))
        {
            program.modules[implicit] = parseModuleFile(found.path, chain, context);
            program.packageOf[implicit] = found.package_ is null ? langPackage : found.package_.name;
            roots ~= program.packageOf[implicit];
            unscanned ~= program.modules[implicit];
        }
        else if (i == 1)
        {
            context.collector.reportError(DiagnosticCode.ModuleNotFound, Span(file, 0, 0),
                format("The prelude, '%s', wasn't found: %s", prelude, found.problem));
        }
    }
    layout.checkUses(roots, context);

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
            auto added = addCompanion(program, start, *companion, context);
            program.packageOf[added.name] = program.packageOf.get(start.name, null);
            unscanned = [added];
        }
        while (unscanned.length > 0)
        {
            auto current = unscanned[$ - 1];
            unscanned = unscanned[0 .. $ - 1];
            auto importer = program.packageOf.get(current.name, null);
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
                auto found = layout.locate(path);
                if (found.package_ !is null && !layout.mayUse(importer, found.package_.name))
                {
                    context.collector.reportError(DiagnosticCode.ImportOutsideUses, importNode.span,
                        layout.outsideUses(importer, current.companionOf is null ? current.name : current.companionOf,
                            name, found.package_.name));
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
                if (found.path is null || !exists(found.path))
                {
                    context.collector.reportError(DiagnosticCode.ModuleNotFound, importNode.span,
                        format("Module '%s' not found: %s", name, found.problem));
                    continue;
                }
                program.modules[name] = parseModuleFile(found.path, path, context);
                program.packageOf[name] = found.package_ is null ? langPackage : found.package_.name;
                unscanned ~= program.modules[name];
            }
        }
    }
    if (companion !is null)
    {
        foreach (name; program.modules.keys.sort)
        {
            if (name !in built && program.modules[name].companionOf is null)
                refuseConformances(*program.modules[name], start.name, context);
        }
    }

    return program;
}

/// Where a module was looked for.
private struct Location
{
    /// The package it's in, or null for `lang` or when no package's name starts the module's.
    const(Package)* package_;
    /// The file it would be in, or null if it can't be in one.
    string path;
    /// Why it isn't there, worded to follow "not found: ".
    string problem;
}

/// The packages of one load, and the checks on them.
private struct Layout
{
    const(Package)[] declared;
    const(string)[] scriptUses;
    /// The module name of the starting file when it has no `module` line, and so is a package of its own.
    string script;

    /// Where the module `chain` would be, and why it isn't if it isn't.
    Location locate(const string[] chain) const
    {
        Location found;
        if (isInLang(chain.join(".")))
        {
            found.path = langModulePath(chain);
            found.problem = format("there's no %s, the only place a module of `%s` can be", found.path, langPackage);
            return found;
        }
        size_t length;
        foreach (ref p; declared)
        {
            auto segments = segmentsOf(p.name);
            if (segments.length <= chain.length && chain[0 .. segments.length] == segments
                && (found.package_ is null || segments.length > length))
            {
                found.package_ = &p;
                length = segments.length;
            }
        }
        if (found.package_ is null)
        {
            found.problem = format("no package is named '%s', or by any longer start of '%s'", chain[0], chain.join("."));
        }
        else if (length == chain.length)
        {
            found.problem = format("'%s' is a package, at %s, and a module's name is the package's followed by its "
                ~ "path under that directory, as '%s.name' for %s", chain.join("."), found.package_.directory,
                chain.join("."), buildPath(found.package_.directory, "name.ag"));
        }
        else
        {
            found.path = buildPath(found.package_.directory ~ chain[length .. $]) ~ ".ag";
            found.problem = format("it's in the package '%s', at %s, and there's no %s",
                found.package_.name, found.package_.directory, found.path);
        }
        return found;
    }

    /// The package named `name`, or null if none is.
    const(Package)* named(string name) const
    {
        foreach (ref p; declared)
        {
            if (p.name == name) return &p;
        }
        return null;
    }

    /// What the package `name` lists as using.
    const(string)[] usesOf(string name) const
    {
        if (script !is null && name == script) return scriptUses;
        auto found = named(name);
        return found is null ? [] : found.uses;
    }

    /// Whether a module of the package `from` may import from the package `to`.
    bool mayUse(string from, string to) const
    {
        return from == to || from.length == 0 || to.length == 0 || from == langPackage || usesOf(from).canFind(to);
    }

    /// Why the module `importing`, of the package `from`, can't import `name`, of the package `to`.
    string outsideUses(string from, string importing, string name, string to) const
    {
        auto uses = usesOf(from);
        auto listed = uses.length == 0 ? "uses no package but `" ~ langPackage ~ "`"
            : "uses only " ~ uses.map!(u => "'" ~ u ~ "'").join(", ");
        return from == script
            ? format("'%s' is a file with no `module` line, so a program of its own that %s, and it can't import '%s', "
                ~ "from the package '%s'\nList '%s' among what it uses", importing, listed, name, to, to)
            : format("The package '%s' %s, so '%s' can't import '%s', from the package '%s'\nList '%s' among what '%s' uses",
                from, listed, importing, name, to, to, from);
    }

    /// Reports what makes the packages impossible to follow, and returns whether nothing does.
    bool described(SourceContext context) const
    {
        bool ok = true;
        void problem(DiagnosticCode code, string message)
        {
            context.collector.reportError(code, Span(), message);
            ok = false;
        }
        bool[string] seen;
        string[string] parentOf;
        foreach (ref p; declared)
        {
            if (p.name.length > 0 && !validName(p.name))
                problem(DiagnosticCode.InvalidPackages, format("'%s' isn't a package name: it's one or more names "
                    ~ "joined by `.`, as `silver.core`", p.name));
            else if (isInLang(p.name))
                problem(DiagnosticCode.NotInLang, format("'%s' would be part of `%s`, which ships with the compiler, "
                    ~ "so it can't be declared", p.name, langPackage));
            if (p.name in seen)
                problem(DiagnosticCode.InvalidPackages, format("There are two packages named '%s'", p.name));
            seen[p.name] = true;
            if (!exists(p.directory) || !isDir(p.directory))
                problem(DiagnosticCode.InvalidPackages, format("The package '%s' is at %s, which isn't a directory",
                    p.name, p.directory));
            if (script !is null && p.name == script)
                problem(DiagnosticCode.InvalidPackages, format("The file started from, with no `module` line, is a "
                    ~ "program named '%s', which is also the name of the package at %s\nRename one of them",
                    script, p.directory));
        }
        void checkList(string owner, const string[] list, string what)
        {
            foreach (entry; list)
            {
                if (isInLang(entry))
                    problem(DiagnosticCode.InvalidPackages, format("%s lists `%s` among what it %s, and every "
                        ~ "package uses `%s` without listing it", owner, entry, what, langPackage));
                else if (entry.length == 0 || named(entry) is null)
                    problem(DiagnosticCode.InvalidPackages, format("%s lists '%s' among what it %s, and there's no "
                        ~ "package of that name", owner, entry, what));
            }
        }
        foreach (ref p; declared)
        {
            checkList(format("The package '%s'", p.name), p.uses, "uses");
            checkList(format("The package '%s'", p.name), p.parts, "has as parts");
            foreach (part; p.parts)
            {
                auto found = named(part);
                if (part == p.name)
                    problem(DiagnosticCode.InvalidPackages, format("The package '%s' lists itself as a part", part));
                else if (auto other = part in parentOf)
                    problem(DiagnosticCode.InvalidPackages, format("'%s' is listed as a part of both '%s' and '%s', "
                        ~ "and a package is a part of one parent", part, *other, p.name));
                else if (found !is null && found.parts.length > 0)
                    problem(DiagnosticCode.InvalidPackages, format("'%s' is a part of '%s' and lists parts of its "
                        ~ "own, and a part can't have parts", part, p.name));
                parentOf[part] = p.name;
            }
        }
        if (script !is null) checkList(format("'%s', the file with no `module` line,", script), scriptUses, "uses");
        return ok;
    }

    /// Reports a cycle among what the packages `roots` use, directly or not, and each of them that
    /// uses a program.
    void checkUses(const string[] roots, SourceContext context) const
    {
        enum State { open, done }
        State[string] state;
        string[] path;
        bool cycleReported;
        string[] reached;
        void visit(string name)
        {
            if (auto known = name in state)
            {
                if (*known == State.open && !cycleReported)
                {
                    cycleReported = true;
                    auto cycle = path[path.countUntil(name) .. $] ~ name;
                    context.collector.reportError(DiagnosticCode.PackageCycle, Span(), cycle.length == 2
                        ? format("The package '%s' lists itself among what it uses", name)
                        : format("What the packages use forms a cycle: %s\nA package can't use itself, directly or "
                            ~ "through others", cycle.map!(c => "'" ~ c ~ "'").join(" uses ")));
                }
                return;
            }
            state[name] = State.open;
            path ~= name;
            reached ~= name;
            foreach (used; usesOf(name)) visit(used);
            path = path[0 .. $ - 1];
            state[name] = State.done;
        }
        foreach (root; roots)
        {
            if (root.length > 0 && !isInLang(root)) visit(root);
        }

        Tuple!(string, Span)[string] mains;
        foreach (user; reached)
        {
            foreach (used; usesOf(user))
            {
                if (used !in mains) mains[used] = mainOf(used, context);
                auto main = mains[used];
                if (main[0] is null) continue;
                context.collector.reportError(DiagnosticCode.UsesProgram, main[1],
                    format("'%s' declares `main`, so the package '%s' is a program, and %s can't use it: nothing can "
                        ~ "depend on a program", main[0], used,
                        user == script ? format("'%s', the file started from,", user) : format("the package '%s'", user)));
            }
        }
    }

    /// The first module of the package `name`, by name, that declares `main`, and where; or null.
    /// Every `.ag` file under the package's directory is read, other than companion test files and
    /// those whose names put them in another package.
    Tuple!(string, Span) mainOf(string name, SourceContext context) const
    {
        import std.file : dirEntries, SpanMode;
        import std.path : pathSplitter, relativePath;

        auto package_ = named(name);
        if (package_ is null || !exists(package_.directory) || !isDir(package_.directory)) return typeof(return).init;
        foreach (path; dirEntries(package_.directory, "*.ag", SpanMode.depth).map!(e => e.name).array.sort)
        {
            if (isCompanionFile(path)) continue;
            auto chain = segmentsOf(name) ~ pathSplitter(relativePath(absolutePath(path.stripExtension),
                absolutePath(package_.directory))).array;
            if (locate(chain).package_ !is package_) continue;
            string text;
            try
            {
                text = readText(path);
            }
            catch (Exception e)
            {
                context.collector.reportError(DiagnosticCode.UnreadableFile, Span(path, 0, 0),
                    format("'%s', in the package '%s', can't be read: %s", path, name, e.msg));
                continue;
            }
            context.sources.add(path, text);
            auto read = parsed(chain.join("."), text, path);
            foreach (declaration; read.declarations)
            {
                auto main = declaration.kind.match!(
                    (const FunctionDecl f) => f.name == "main" ? f.nameSpan : Span(),
                    _ => Span());
                if (main.file !is null) return typeof(return)(chain.join("."), main);
            }
        }
        return typeof(return).init;
    }
}

/// The segments of the package name `name`, and none for the unnamed one.
private string[] segmentsOf(string name)
{
    return name.length == 0 ? [] : name.split(".");
}

/// Whether `name` is one or more identifiers joined by `.`.
private bool validName(string name)
{
    import std.algorithm : all;
    import std.ascii : isAlpha, isAlphaNum;

    foreach (segment; name.split("."))
    {
        if (segment.length == 0 || !(isAlpha(segment[0]) || segment[0] == '_')
            || !segment.all!(c => isAlphaNum(c) || c == '_'))
            return false;
    }
    return true;
}

/// The file the module `chain` of `lang` is, which is only ever the compiler's own.
private string langModulePath(const string[] chain)
{
    return buildPath(standardLibraryPath() ~ chain) ~ ".ag";
}

/// Reads packages as the command line gives them. Each of `declared` is `name=directory`, each of
/// `uses` is `name=package,package` for what the package `name` uses, or `package,package` for what
/// a file with no `module` line uses, and each of `parts` is `name=part,part`. A relative directory
/// is taken from `base`. The standard library is added unless one of `declared` is named as it is.
/// Returns what's wrong with how one is written, or null; what's wrong with what they say is for
/// `load` to report.
string describePackages(const string[] declared, const string[] uses, const string[] parts, string base,
    out Packages packages)
{
    import std.string : indexOf, strip;

    string[] listOf(string text)
    {
        string[] list;
        foreach (entry; text.split(",")) list ~= entry.strip;
        return list;
    }
    foreach (option; declared)
    {
        auto at = option.indexOf('=');
        if (at <= 0 || at == option.length - 1)
            return format("--package takes a name and a directory, as `--package geometry=lib/geometry`, not `%s`", option);
        auto directory = option[at + 1 .. $];
        packages.declared ~= Package(option[0 .. at], base.length == 0 ? directory : buildPath(base, directory));
    }
    Package* find(string name)
    {
        foreach (ref p; packages.declared)
        {
            if (p.name == name) return &p;
        }
        return null;
    }
    foreach (i, list; [uses, parts])
    {
        immutable flag = i == 0 ? "--uses" : "--parts";
        foreach (option; list)
        {
            auto at = option.indexOf('=');
            if (at < 0 && i == 0)
            {
                packages.scriptUses ~= listOf(option);
                continue;
            }
            if (at <= 0)
                return i == 0
                    ? format("--uses takes a package and what it uses, as `--uses app=geometry,std`, or for a file "
                        ~ "with no `module` line only what it uses, as `--uses geometry,std`, not `%s`", option)
                    : format("--parts takes a package and its parts, as `--parts silver=silver.core`, not `%s`", option);
            auto owner = find(option[0 .. at]);
            if (owner is null)
                return format("%s names '%s', which no --package declares", flag, option[0 .. at]);
            if (i == 0) owner.uses ~= listOf(option[at + 1 .. $]);
            else owner.parts ~= listOf(option[at + 1 .. $]);
        }
    }
    packages.declared = withStandardLibrary(packages.declared);
    return null;
}

/// `given`, and the standard library that ships with the compiler unless one of `given` is named as it is.
Package[] withStandardLibrary(Package[] given)
{
    foreach (p; given)
    {
        if (p.name == standardPackage) return given;
    }
    return given ~ Package(standardPackage, buildPath(standardLibraryPath(), standardPackage));
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

/// The package of the standard library that ships with the compiler, which a build declares at
/// `standardLibraryPath()` when it's told of no other. The compiler itself never names it.
enum standardPackage = "std";

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
            format("This file is the module '%s', by its package and its path, but its `module` line names '%s'",
                name, loaded.declaration.path.join(".")));
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

    /// The standard library, and `directory` as the unnamed package of a test's fixtures unless it's
    /// null, with a starting file that has no `module` line using the standard library.
    Packages loose(string directory)
    {
        return Packages(withStandardLibrary(directory is null ? [] : [Package(null, directory)]), [standardPackage]);
    }
}

@("load includes transitive imports")
unittest
{
    auto directory = makeModuleDirectory("transitive",
        ["a.ag": "module a\nimport b", "b.ag": "module b\ndef b(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.ag", loose(directory), null, new SourceContext);
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

    auto program = load("import a", "main.ag", loose(directory), null, new SourceContext);
    ownModules(program).should.equal(["a", "b", "c", "main"]);
}

@("load maps a dotted import to a directory")
unittest
{
    auto directory = makeModuleDirectory("dotted", ["a/b.ag": "module a.b\ndef b(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a.b", "main.ag", loose(directory), null, new SourceContext);
    assert("a.b" in program.modules);
    program.modules["a.b"].name.should.equal("a.b");
}

@("load terminates on an import cycle")
unittest
{
    auto directory = makeModuleDirectory("cycle",
        ["a.ag": "module a\nimport b", "b.ag": "module b\nimport a"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import a", "main.ag", loose(directory), null, new SourceContext);
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
    auto program = load(source, "main.ag", loose(directory), null, context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.ModuleNotFound);
    errors[0].message.should.contain("Module 'nope' not found");
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
import a", "main.ag", loose(directory), null, context);

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
def main(): Unit => ()", "main.ag", loose(directory), "base", new SourceContext);
    ownModules(program).should.equal(["a", "base", "main"]);
    assert(idProblems(program.modules.byValue.map!(m => *m).array) == []);
}

@("load shares an imported module between programs until its file changes")
unittest
{
    import std.file : write;

    auto directory = makeModuleDirectory("shared", ["a.ag": "module a\ndef a(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto first = load("import a", "main.ag", loose(directory), null, new SourceContext);
    auto second = load("import a\ndef main(): Unit => ()", "main.ag", loose(directory), null, new SourceContext);
    assert(first.modules["a"] is second.modules["a"]);
    assert(first.modules["main"] !is second.modules["main"]);

    write(buildPath(directory, "a.ag"), "module a\ndef a(): Int => 2");
    auto changed = load("import a", "main.ag", loose(directory), null, new SourceContext);
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

    auto program = load("def x(): Int => 1", "main.ag", loose(directory), "kit.base", new SourceContext);
    ownModules(program).should.equal(["kit.base", "main"]);
    program.prelude.should.equal("kit.base");
}

@("load includes no prelude when it's given none, and a module named prelude is ordinary")
unittest
{
    auto directory = makeModuleDirectory("no-prelude", ["prelude.ag": "module prelude\ndef p(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("def x(): Int => 1", "main.ag", loose(directory), null, new SourceContext);
    ownModules(program).should.equal(["main"]);
}

@("load reports a prelude that isn't on any import path")
unittest
{
    auto context = new SourceContext;
    load("def x(): Int => 1", "main.ag", loose(null), "kit.base", context);

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

    auto program = load("import lang.io", "main.ag", loose(directory), null, new SourceContext);
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
        load(source, file, loose(null), null, context);
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
    auto program = load(source, path, loose(null), null, context);
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
        auto program = load(readText(path), path, loose(null), null, context);
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
                if (line.canFind("enum standardPrelude") || line.canFind("enum standardPackage") || line.strip.startsWith("//")) continue;
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
        load("import bad", "main.ag", loose(directory), null, context);
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
    auto program = load("import a.b", "main.ag", loose(directory), null, context);

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
    load("import a.b", "main.ag", loose(directory), null, context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.ModuleDeclarationMismatch);
    errors[0].span.file.should.equal(buildPath(directory, "a", "b.ag"));
    errors[0].span.start.should.equal(source.indexOf("module a.c"));
}

@("load names a declared entry module by its module line, not its file name")
unittest
{
    auto directory = makeModuleDirectory("entry-name", ["source/tool.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto program = load("module app.tool", buildPath(directory, "source", "tool.ag"),
        Packages([Package("app", buildPath(directory, "source"))]), null, context);
    context.collector.diagnostics.length.should.equal(0);
    assert("app.tool" in program.modules);
    program.modules["app.tool"].name.should.equal("app.tool");
}

@("load names an undeclared entry module by its file name")
unittest
{
    auto program = load("def main(): Unit => ()", "script.ag", loose(null), null, new SourceContext);
    assert("script" in program.modules);
}

@("load reports a declared entry module whose module line doesn't match its path")
unittest
{
    auto source = "module std.maths";
    auto context = new SourceContext;
    load(source, buildPath("lib", "std", "math.ag"), loose(null), null, context);

    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.ModuleDeclarationMismatch);
    errors[0].message.should.contain("std/maths.ag");
}

@("load gives an import of the declared starting module the module already loaded")
unittest
{
    auto directory = makeModuleDirectory("entry-imported",
        ["main.ag": "", "helper.ag": "module app.helper\nimport app.main"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto program = load("module app.main\nimport app.helper", buildPath(directory, "main.ag"),
        Packages([Package("app", directory)]), null, context);

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
    load("import helper", buildPath(directory, "script.ag"), loose(directory), null, context);

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
    auto program = load("def area(): Int => 1", "shape.ag", loose(directory), null, context, &companion);
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

    auto without = load("def area(): Int => 1", "shape.ag", loose(directory), null, new SourceContext);
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
    auto program = load("import shape.test", "main.ag", loose(directory), null, context);
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
        load("def main(): Unit => ()", file, loose(null), null, context);
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
    load("module shape", "shape.ag", loose("."), null, context, &companion);
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
    auto program = load(readText(path), path, loose(null), standardPrelude, context, &companion);
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
    load("import shared", "shape.ag", loose(directory), null, context, &companion);
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
    load("def area(): Int => 1", "shape.ag", loose(null), null, context, &unreadable);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.UnreadableFile]);
    errors[0].message.should.contain("shape.test.ag can't be read: Invalid UTF-8 sequence");

    context = new SourceContext;
    load("def = broken", "gone.test.ag", loose(null), null, context);
    context.collector.errors.array.map!(e => e.code).array.should.equal([DiagnosticCode.CompanionStarted]);
}

@("a module is found by the package whose name is the longest start of its name, and the rest as a path")
unittest
{
    auto directory = makeModuleDirectory("packages-prefix", [
        "source/app.ag": "module silver.app\nimport silver.core.lower",
        "core/source/lower.ag": "module silver.core.lower\nimport silver.core.tree.node",
        "core/source/tree/node.ag": "module silver.core.tree.node",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto packages = Packages([
        Package("silver", buildPath(directory, "source"), ["silver.core"]),
        Package("silver.core", buildPath(directory, "core", "source")),
    ], ["silver"]);
    auto context = new SourceContext;
    auto program = load("import silver.app", "main.ag", packages, null, context);
    context.collector.diagnostics.length.should.equal(0);
    ownModules(program).should.equal(["main", "silver.app", "silver.core.lower", "silver.core.tree.node"]);
    program.modules["silver.core.lower"].span.file.should.equal(buildPath(directory, "core", "source", "lower.ag"));
    program.packageOf["silver.app"].should.equal("silver");
    program.packageOf["silver.core.tree.node"].should.equal("silver.core");
    program.packageOf["main"].should.equal("main");
    program.packageOf[langPackage].should.equal(langPackage);
}

@("an import from a package that the importing module's package doesn't list is L0010, and isn't followed")
unittest
{
    auto directory = makeModuleDirectory("packages-outside", [
        "geometry/area.ag": "module geometry.area\nimport units.length",
        "units/length.ag": "module units.length",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto packages = Packages([Package("geometry", buildPath(directory, "geometry")),
        Package("units", buildPath(directory, "units"))], ["geometry"]);
    auto source = "import geometry.area\nimport units.length";
    auto context = new SourceContext;
    auto program = load(source, "main.ag", packages, null, context);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.ImportOutsideUses, DiagnosticCode.ImportOutsideUses]);
    errors[0].span.start.should.equal(source.indexOf("import units"));
    errors[0].message.should.contain("'main' is a file with no `module` line, so a program of its own that uses only 'geometry'");
    errors[1].span.file.should.equal(buildPath(directory, "geometry", "area.ag"));
    errors[1].message.should.contain("The package 'geometry' uses no package but `lang`, so 'geometry.area' can't import "
        ~ "'units.length', from the package 'units'");
    assert("units.length" !in program.modules);
}

@("a module imports from its own package, lang, and the unnamed fixture package without listing them")
unittest
{
    auto directory = makeModuleDirectory("packages-own", [
        "kit/a.ag": "module kit.a\nimport kit.b\nimport lang.io\nimport loose",
        "kit/b.ag": "module kit.b",
        "fixtures/loose.ag": "module loose",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto packages = Packages([Package("kit", buildPath(directory, "kit")), Package(null, buildPath(directory, "fixtures"))],
        ["kit"]);
    auto context = new SourceContext;
    auto program = load("import kit.a", "main.ag", packages, null, context);
    context.collector.diagnostics.length.should.equal(0);
    ownModules(program).should.equal(["kit.a", "kit.b", "loose", "main"]);
}

@("a package's own name isn't a module, and a name no package starts isn't found")
unittest
{
    auto directory = makeModuleDirectory("packages-root", ["geometry/area.ag": "module geometry.area"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    load("import geometry\nimport shapes.circle", "main.ag",
        Packages([Package("geometry", buildPath(directory, "geometry"))], ["geometry"]), null, context);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.ModuleNotFound, DiagnosticCode.ModuleNotFound]);
    errors[0].message.should.contain("'geometry' is a package");
    errors[1].message.should.contain("no package is named 'shapes'");
}

@("a starting file's module line must name the file it is, by its package")
unittest
{
    auto directory = makeModuleDirectory("packages-start", ["lib/shapes/circle.ag": ""]);
    scope (exit) rmdirRecurse(directory);
    auto file = buildPath(directory, "lib", "shapes", "circle.ag");
    auto packages = Packages([Package("geometry", buildPath(directory, "lib"))]);

    string[] problems(string source)
    {
        auto context = new SourceContext;
        load(source, file, packages, null, context);
        return context.collector.errors.map!(e => cast(string) e.code ~ ": " ~ e.message).array;
    }
    problems("module geometry.shapes.circle").length.should.equal(0);
    auto wrong = problems("module geometry.circle");
    wrong.length.should.equal(1);
    wrong[0].should.contain("L0003: Module 'geometry.circle' is in the package 'geometry'");
    auto nowhere = problems("module shapes.circle");
    nowhere.length.should.equal(1);
    nowhere[0].should.contain("L0003: Module 'shapes.circle' is in no package");
}

@("a package that uses a program is L0011, at the program's main, even when nothing imports its module")
unittest
{
    auto directory = makeModuleDirectory("packages-program", [
        "tool/cli.ag": "module tool.cli\ndef main(): Unit { }",
        "tool/util.ag": "module tool.util",
        "tool/util.test.ag": "def main(): Unit { }",
        "lib/util.ag": "module lib.util",
        "lib/tool/x.ag": "def main(): Unit { }",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto packages = Packages([
        Package("tool", buildPath(directory, "tool")),
        Package("lib", buildPath(directory, "lib")),
        Package("lib.tool", buildPath(directory, "elsewhere")),
    ], ["tool", "lib"]);
    mkdirRecurse(buildPath(directory, "elsewhere"));
    auto context = new SourceContext;
    load("import tool.util", "main.ag", packages, null, context);
    auto errors = context.collector.errors.array;
    // lib/tool/x.ag would be lib.tool.x, which is in lib.tool, so it's in no package's files.
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.UsesProgram]);
    errors[0].span.file.should.equal(buildPath(directory, "tool", "cli.ag"));
    errors[0].message.should.contain("'tool.cli' declares `main`, so the package 'tool' is a program, and 'main', the "
        ~ "file started from, can't use it");
}

@("packages whose lists of what they use form a cycle are L0012, reported once")
unittest
{
    auto directory = makeModuleDirectory("packages-cycle", ["a/x.ag": "", "b/x.ag": "", "c/x.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    load("def f(): Int => 1", "main.ag", Packages([
        Package("a", buildPath(directory, "a"), ["b"]),
        Package("b", buildPath(directory, "b"), ["c"]),
        Package("c", buildPath(directory, "c"), ["a"]),
    ], ["a"]), null, context);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.PackageCycle]);
    errors[0].message.should.contain("'a' uses 'b' uses 'c' uses 'a'");
    errors[0].span.file.length.should.equal(0);

    context = new SourceContext;
    load("def f(): Int => 1", "main.ag", Packages([Package("a", buildPath(directory, "a"), ["a"])], ["a"]), null, context);
    context.collector.errors.array.map!(e => e.message).array.should.equal(["The package 'a' lists itself among what it uses"]);
}

@("a description that can't be followed is reported, and nothing more is loaded")
unittest
{
    auto directory = makeModuleDirectory("packages-invalid", ["a/x.ag": "module a.x", "b/x.ag": "", "c/x.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    string[] problems(Packages packages, string file = "main.ag")
    {
        auto context = new SourceContext;
        auto program = load("import a.x", file, packages, null, context);
        assert("a.x" !in program.modules || context.collector.errors.empty);
        return context.collector.errors.map!(e => cast(string) e.code ~ ": " ~ e.message).array;
    }
    auto a = Package("a", buildPath(directory, "a"));
    auto b = Package("b", buildPath(directory, "b"));
    problems(Packages([a, b], ["a", "nope"]))
        .should.equal(["L0013: 'main', the file with no `module` line, lists 'nope' among what it uses, and there's no package of that name"]);
    problems(Packages([a], ["a", "lang"]))[0].should.contain("every package uses `lang` without listing it");
    problems(Packages([a, Package("a", buildPath(directory, "b"))], ["a"]))[0].should.contain("two packages named 'a'");
    problems(Packages([a, Package("b", buildPath(directory, "gone"))], ["a"]))[0].should.contain("isn't a directory");
    problems(Packages([a, Package("b.", buildPath(directory, "b"))], ["a"]))[0].should.contain("isn't a package name");
    problems(Packages([a, Package("lang.extra", buildPath(directory, "b"))], ["a"]))[0].should.contain("L0004:");
    problems(Packages([a, Package("main", buildPath(directory, "b"))], ["a"]))[0].should.contain("also the name of the package");

    auto c = Package("c", buildPath(directory, "c"));
    problems(Packages([Package("a", a.directory, [], ["b"]), Package("c", c.directory, [], ["b"]), b], ["a"]))[0]
        .should.contain("'b' is listed as a part of both 'a' and 'c'");
    problems(Packages([Package("a", a.directory, [], ["b"]), Package("b", b.directory, [], ["c"]), c], ["a"]))[0]
        .should.contain("a part can't have parts");
    problems(Packages([Package("a", a.directory, [], ["a"])], ["a"]))[0].should.contain("lists itself as a part");
    problems(Packages([Package("a", a.directory, [], ["b"]), b], ["a"])).length.should.equal(0);
}

@("describePackages reads the command line's spelling, from a base directory, and adds the standard library")
unittest
{
    Packages packages;
    describePackages(["geometry=lib/geometry", "silver.core=core"], ["geometry=std", "std, geometry"],
        ["geometry=silver.core"], "base", packages).should.equal(null);
    packages.declared.map!(p => p.name).array.should.equal(["geometry", "silver.core", standardPackage]);
    packages.declared[0].directory.should.equal(buildPath("base", "lib/geometry"));
    packages.declared[0].uses.should.equal(["std"]);
    packages.declared[0].parts.should.equal(["silver.core"]);
    packages.declared[2].directory.should.equal(buildPath(standardLibraryPath(), standardPackage));
    packages.scriptUses.should.equal(["std", "geometry"]);

    describePackages(["std=mine"], [], [], null, packages).should.equal(null);
    packages.declared.should.equal([Package("std", "mine")]);

    describePackages(["geometry"], [], [], null, packages).should.contain("--package takes a name and a directory");
    describePackages(["=lib"], [], [], null, packages).should.contain("--package takes");
    describePackages([], ["app=std"], [], null, packages).should.contain("'app', which no --package declares");
    describePackages(["a=a"], [], ["b"], null, packages).should.contain("--parts takes a package and its parts");
}

@("the standard library is the package std, and its modules import it and the prelude without listing anything")
unittest
{
    auto context = new SourceContext;
    auto program = load("import std.random", "main.ag", Packages(withStandardLibrary([]), [standardPackage]),
        standardPrelude, context);
    context.collector.diagnostics.length.should.equal(0);
    program.packageOf["std.random"].should.equal(standardPackage);
    program.packageOf[standardPrelude].should.equal(standardPackage);

    context = new SourceContext;
    load("def f(): Int => 1", "main.ag", Packages(withStandardLibrary([])), standardPrelude, context);
    context.collector.diagnostics.length.should.equal(0);
    context = new SourceContext;
    load("import std.random", "main.ag", Packages(withStandardLibrary([])), standardPrelude, context);
    context.collector.errors.array.map!(e => e.code).array.should.equal([DiagnosticCode.ImportOutsideUses]);
}
