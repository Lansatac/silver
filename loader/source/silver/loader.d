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
    /// How the build says to list `used` among what the package `user` uses, or a file with no
    /// `module` line uses when `user` is null, added to the messages that need it. Null for nothing.
    string delegate(string user, string used) usesHint;
    /// How the build says to make a package named `name` known to the package `user`, which may be a
    /// script's (`scriptPackage`), or null when no package asks, likewise.
    string delegate(string user, string name) packageHint;
    /// The directories whose files with no `module` line are beside a package: such a file uses what
    /// the package uses, and the package too unless it's a program. The deepest that holds it wins.
    ScriptHome[] scriptHomes;
    /// Whether the packages were described in package files, so a file with no `module` line that no
    /// `scriptHomes` directory holds has nowhere to list what it uses.
    bool fromPackageFiles;
    /// Whether `silver` is the one driving, so no message names an option to give.
    bool bySilver;
    /// The files `--native-link` and `--native-load` give for a `native library` name in a package's
    /// modules, by package. A name given none is found by the linker's and the system's search paths.
    NativeFiles[string] natives;
    /// The package file each package was described in, from `--package-file`, for messages.
    string[string] packageFiles;
}

/// The files given for native libraries, by the name `native library` gives: `link`, what a compiled
/// program is linked against, and `load`, the shared library itself.
struct NativeFiles
{
    string[string] link;
    string[string] load;
}

/// Reads `--native-link package:library=file` and `--native-load package:library=file` into `packages`:
/// the file for `native library "library"` in the modules of `package`, which has to be declared. Returns
/// what's wrong with one, or null: how it's written, a library given twice for a package, or a file that
/// isn't there.
string describeNativeFiles(const string[] links, const string[] loads, ref Packages packages)
{
    import std.file : isFile;
    import std.string : indexOf;

    foreach (i, list; [links, loads])
    {
        immutable option = i == 0 ? "--native-link" : "--native-load";
        foreach (given; list)
        {
            auto at = given.indexOf('=');
            auto colon = at < 0 ? -1 : given[0 .. at].indexOf(':');
            if (colon <= 0 || colon == at - 1 || at == given.length - 1)
                return format("%s takes a package, a library as `native library` names it in that package's modules, "
                    ~ "and a file, as `%s app:raylib=lib/%s`, not `%s`", option, option,
                    i == 0 ? "raylib.lib" : "raylib.dll", given);
            immutable package_ = given[0 .. colon];
            immutable library = given[colon + 1 .. at];
            immutable file = given[at + 1 .. $];
            if (!packages.declared.canFind!(p => p.name == package_))
                return undeclared(option, package_);
            auto natives = &packages.natives.require(package_, NativeFiles.init);
            auto files = i == 0 ? &natives.link : &natives.load;
            if (library in *files)
                return format("%s gives the library '%s' of '%s' twice, as %s and as %s", option, library, package_,
                    (*files)[library], file);
            bool present;
            try present = exists(file) && isFile(file);
            catch (Exception) present = false;
            if (!present)
                return format("%s gives the library '%s' of '%s' the file %s, which isn't there", option, library,
                    package_, file);
            (*files)[library] = file;
        }
    }
    return null;
}

@("--native-link and --native-load give a library's files for a declared package, once each, and the files have to be there")
unittest
{
    import std.algorithm : canFind;
    import std.file : remove, tempDir, write;

    auto file = buildPath(tempDir, "silver-loader-native-files.dll");
    write(file, "");
    scope (exit) remove(file);
    Packages packages;
    assert(describePackages(["a=a", "b=b"], null, null, null, packages) is null);
    assert(describeNativeFiles(["a:ray=" ~ file], ["a:ray=" ~ file, "b:ray=" ~ file, "a:x:y=" ~ file], packages) is null);
    assert(packages.natives["a"].link == ["ray": file] && packages.natives["a"].load == ["ray": file, "x:y": file]);
    assert(packages.natives["b"].load == ["ray": file]);

    foreach (wrong; ["ray=" ~ file, "a:ray", ":ray=" ~ file, "a:=" ~ file, "a:ray="])
        assert(describeNativeFiles([wrong], null, packages).canFind("--native-link takes a package"), wrong);
    assert(describeNativeFiles(null, ["c:ray=" ~ file], packages).canFind("'c', which no --package"));
    assert(describeNativeFiles(null, ["a:ray=" ~ file], packages).canFind("gives the library 'ray' of 'a' twice"));
    assert(describeNativeFiles([buildPath("b:ray=" ~ tempDir, "silver-no-such-file.a")], null, packages)
        .canFind("which isn't there"));
    assert(describeNativeFiles(["b:z=" ~ tempDir], null, packages).canFind("which isn't there"));
}

/// The files of `packages.natives` that `program` uses, by library: for each `native library` name, the
/// file the package of a module that names it gives. Two packages whose modules name one library and
/// give it different files are reported to `context`, at the second module's `native library`, and the
/// first one's file is kept.
NativeFiles nativesOf(const ref Program program, const Packages packages, SourceContext context)
{
    import std.path : filenameCmp;

    NativeFiles result;
    if (packages.natives.length == 0) return result;
    struct Given
    {
        string file;
        string package_;
        string module_;
    }
    Given[string][2] seen;
    string by(size_t kind, string package_, string library, string file)
    {
        if (auto described = package_ in packages.packageFiles) return format("%s, for '%s'", *described, package_);
        return format("`%s %s:%s=%s`", kind == 0 ? "--native-link" : "--native-load", package_, library, file);
    }
    foreach (name; program.modules.keys.sort)
    {
        auto m = program.modules[name];
        if (m.library is null) continue;
        auto package_ = name in program.packageOf;
        if (package_ is null) continue;
        auto files = *package_ in packages.natives;
        if (files is null) continue;
        immutable library = m.library.name;
        foreach (kind; 0 .. 2)
        {
            auto file = library in (kind == 0 ? files.link : files.load);
            if (file is null) continue;
            if (auto earlier = library in seen[kind])
            {
                if (filenameCmp(buildNormalizedPath(absolutePath(earlier.file)), buildNormalizedPath(absolutePath(*file)))
                    == 0)
                    continue;
                context.collector.reportError(DiagnosticCode.NativeFilesDisagree, m.library.span, format("The library "
                    ~ "'%s' is given two files to %s in this program: %s by %s, where %s names it, and %s by %s, here. A "
                    ~ "program has one file for each library, so give it in one of the two, or the same file in both",
                    library, kind == 0 ? "link against" : "load", earlier.file, by(kind, earlier.package_, library,
                    earlier.file), earlier.module_, *file, by(kind, *package_, library, *file)));
                continue;
            }
            seen[kind][library] = Given(*file, *package_, name);
            if (kind == 0) result.link[library] = *file;
            else result.load[library] = *file;
        }
    }
    return result;
}

/// A directory whose files with no `module` line use what the package `package_` uses.
struct ScriptHome
{
    string package_;
    string directory;
}

/// The package of the file started from when it has no `module` line, by its module's name. It
/// can't be a package's name, as a script can be named as a package it uses.
string scriptPackage(string moduleName)
{
    return "(" ~ moduleName ~ ")";
}

/// Parses `source` (read from `file`) and everything it needs: `lang`, the module `prelude` names
/// unless it's null, and every imported module, transitively. A module is found by the package
/// in `packages` whose name is the longest start of the module's name, and then by the rest of its
/// name as a path under the package's directory, or, for the package's own name, as the
/// directory's `package.ag`. `lang`'s modules are read from
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
    auto layout = Layout(packages.declared, packages.scriptUses, packages.usesHint, packages.packageHint);
    layout.fromPackageFiles = packages.fromPackageFiles;
    layout.bySilver = packages.bySilver;
    layout.homes = packages.scriptHomes;
    if (auto declaration = start.declaration)
    {
        start.name = declaration.path.join(".");
        if (!isInLang(start.name))
        {
            auto found = layout.locate(declaration.path, null, file);
            if (found.package_ is null || found.path is null)
            {
                context.collector.reportError(DiagnosticCode.ModuleDeclarationMismatch, declaration.span,
                    found.package_ is null ? format("Module '%s' is in no package: %s", start.name, found.problem)
                        : format("Module '%s' can't be in the package '%s': %s", start.name, found.package_.name,
                            found.problem));
            }
            else
            {
                program.packageOf[start.name] = found.package_.name;
                if (!sameFile(file, found.path))
                {
                    context.collector.reportError(DiagnosticCode.ModuleDeclarationMismatch, declaration.span,
                        format("Module '%s' is in the package '%s', at %s, so it must be the file %s%s",
                            start.name, found.package_.name, found.package_.directory, found.path,
                            misplacedRootHint(found.path)));
                }
            }
        }
    }
    else
    {
        layout.script = scriptPackage(start.name);
        layout.scriptModule = start.name;
        program.packageOf[start.name] = layout.script;
    }
    if (isInLang(start.name) && namesRootFile(start.name.split("."), 1))
    {
        context.collector.reportError(DiagnosticCode.ModuleDeclarationMismatch,
            start.declaration is null ? Span(file, 0, 0) : start.declaration.span,
            format("Module '%s' can't be in `%s`: %s", start.name, langPackage, layout.locate(start.name.split(".")).problem));
    }
    // A file with no module line is named after itself, so `lang.ag` would be `lang` too.
    else if (isInLang(start.name) && !sameFile(file, langModulePath(start.name.split("."))))
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
    if (prelude !is null && !isInLang(prelude))
    {
        if (auto owner = layout.locate(prelude.split(".")).package_) layout.preludePackage = owner.name;
    }
    if (layout.script !is null) layout.placeScript(file, packages.scriptHomes, context);

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
                auto found = layout.locate(path, importer);
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
                    if ((*loaded).declaration is null && found.package_ !is null && found.path !is null
                        && exists(found.path) && !sameFile(found.path, (*loaded).span.file))
                    {
                        context.collector.reportError(DiagnosticCode.MissingModuleDeclaration, importNode.span,
                            format("'%s' is the root module of the package '%s', %s, and the file started from, %s, has "
                                ~ "no `module` line, so it's named '%s' after its file too\nRename %s",
                                name, found.package_.name, found.path, (*loaded).span.file, name, (*loaded).span.file));
                    }
                    else if ((*loaded).declaration is null && found.package_ !is null && found.package_.name == name
                        && found.path !is null)
                    {
                        context.collector.reportError(DiagnosticCode.ModuleNotFound, importNode.span,
                            format("Module '%s' not found: the package '%s' has no root module, %s, and the file started "
                                ~ "from, %s, has no `module` line, so it's named '%s' after its file and couldn't import "
                                ~ "the root module anyway\nRename %s, or import a module of the package, as '%s.name' "
                                ~ "for %s", name, name, found.path, (*loaded).span.file, name, (*loaded).span.file, name,
                                buildPath(found.package_.directory, "name.ag")));
                    }
                    else if ((*loaded).declaration is null)
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
                if (layout.unparsed.canFind!(f => sameFile(f, found.path))) continue;
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
    const(string delegate(string, string)) usesHint;
    const(string delegate(string, string)) packageHint;
    /// The package of the starting file when it has no `module` line, and so is a package of its
    /// own, as `scriptPackage` names it, and its module's name.
    string script;
    string scriptModule;
    /// The package the script is beside, by `Packages.scriptHomes`, or null; and when that package is a
    /// program, its module that declares `main`.
    string scriptHome;
    string homeMain;
    Span homeMainAt;
    /// The package with no modules of its own, which only describes others, whose directory holds the
    /// script, when that's the deepest.
    string describerHome;
    const(ScriptHome)[] homes;
    bool fromPackageFiles;
    bool bySilver;
    /// The package the prelude is in, which every package and script uses without listing it, or
    /// null when there's no prelude or it's in no package.
    string preludePackage;
    /// The files read for `main` whose parse error was reported then, so importing one doesn't report it again.
    string[] unparsed;

    /// Where the module `chain` would be, and why it isn't if it isn't: imported by a module of the
    /// package `user`, or named by the `module` line of `startingFile`.
    Location locate(const string[] chain, string user = null, string startingFile = null) const
    {
        Location found;
        if (isInLang(chain.join(".")))
        {
            if (namesRootFile(chain, 1))
            {
                found.problem = rootFileProblem(chain, 1, buildPath(standardLibraryPath(), langPackage), langPackage);
                return found;
            }
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
            auto suggested = startingFile is null ? null : moduleNameHint(startingFile);
            auto asking = user;
            if (suggested is null && user !is null && user == script)
            {
                if (scriptHome !is null) asking = scriptHome;
                else if (fromPackageFiles || bySilver) suggested = homelessScriptHint(chain[0]);
            }
            if (suggested is null && packageHint !is null)
            {
                suggested = packageHint(asking, chain[0]);
                if (suggested !is null && asking !is user)
                    suggested = format("A file with no `module` line under the directory of the package '%s' uses what "
                        ~ "'%s' uses
%s", asking, asking, suggested);
            }
            found.problem = format("no package is named '%s', or by any longer start of '%s'%s", chain[0],
                chain.join("."), hint(suggested));
        }
        else if (found.package_.directory.length == 0)
        {
            found.problem = length == chain.length
                ? format("'%s' is a package that only describes others, so it has no module of its own",
                    found.package_.name)
                : format("the package '%s' only describes others, so it has no modules of its own, and no package "
                    ~ "it describes is named by a start of '%s'", found.package_.name, chain.join("."));
        }
        else if (length == chain.length)
        {
            found.path = buildPath(found.package_.directory, rootModuleFile);
            found.problem = format("'%s' is a package, at %s, and there's no %s, its root module\nAdd %s to give the "
                ~ "package a module of its own, or import a module of the package, as '%s.name' for %s",
                chain.join("."), found.package_.directory, found.path, found.path, chain.join("."),
                buildPath(found.package_.directory, "name.ag"));
        }
        else if (namesRootFile(chain, length))
        {
            found.problem = rootFileProblem(chain, length, found.package_.directory, found.package_.name);
        }
        else
        {
            found.path = buildPath(found.package_.directory ~ chain[length .. $]) ~ ".ag";
            found.problem = format("it's in the package '%s', at %s, and there's no %s%s",
                found.package_.name, found.package_.directory, found.path, misplacedRootHint(found.path));
        }
        return found;
    }

    /// What the `module` line of `file` has to say, by the package whose directory of modules holds it,
    /// the deepest, with its folders and file named as they are on disk; or, when only the directory a
    /// package is beside holds it, where that package's modules go; or null.
    string moduleNameHint(string file) const
    {
        const(Package)* holder;
        foreach (ref p; declared)
        {
            if (p.name.length == 0 || p.directory.length == 0 || !within(file.dirName, p.directory)) continue;
            if (holder is null || within(p.directory, holder.directory)) holder = &p;
        }
        if (holder is null) return modulesElsewhereHint(file);
        immutable where = format("%s is in the package '%s', at %s", file, holder.name, holder.directory);
        auto under = spelledOnDisk(holder.directory, segmentsBelow(file, holder.directory));
        if (under is null)
            return format("%s, so its `module` line is '%s' followed by the folders and the file it's in there", where,
                holder.name);
        under[$ - 1] = under[$ - 1].stripExtension;
        if (under == [rootModuleFile.stripExtension]) under = [];
        foreach (i, segment; under)
        {
            if (moduleSegment(segment)) continue;
            immutable what = i + 1 == under.length ? "file" : "folder";
            return format("%s, and its `module` line would be named by its path there, but the %s name '%s' can't be "
                ~ "part of a module's name, which starts each part with a lowercase letter or `_` followed by letters, "
                ~ "digits and `_`\nRename the %s", where, what, segment, what);
        }
        return format("%s, so its `module` line is `module %s`", where, (segmentsOf(holder.name) ~ under).join("."));
    }

    /// For `file`, under the directory a package is beside but not under its directory of modules, where
    /// a module of that package goes; or null when no such package holds it.
    string modulesElsewhereHint(string file) const
    {
        const(ScriptHome)* deepest;
        foreach (ref home; homes)
        {
            auto p = named(home.package_);
            if (p is null || p.directory.length == 0 || !within(file.dirName, home.directory)) continue;
            if (deepest is null || within(home.directory, deepest.directory)) deepest = &home;
        }
        if (deepest is null) return null;
        auto p = named(deepest.package_);
        return format("%s is under the directory of the package '%s', at %s, whose modules are under %s, so a module of "
            ~ "'%s' belongs there, as %s for `module %s.name`", file, p.name, deepest.directory, p.directory, p.name,
            buildPath(p.directory, "name.ag"), p.name);
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

    /// What the package `name` uses: what it lists, and the prelude's package.
    const(string)[] usesOf(string name) const
    {
        auto found = named(name);
        const(string)[] listed = script !is null && name == script ? scriptUses : found is null ? [] : found.uses;
        if (preludePackage is null || name == preludePackage || isInLang(name) || listed.canFind(preludePackage))
            return listed;
        return listed ~ preludePackage;
    }

    /// Makes the script, the file `file`, use what the package of the deepest of `homes` that holds it
    /// uses, and that package too unless it's a program.
    void placeScript(string file, const ScriptHome[] homes, SourceContext context)
    {
        const(ScriptHome)* deepest;
        foreach (ref home; homes)
        {
            if (within(file.dirName, home.directory) && (deepest is null || within(home.directory, deepest.directory)))
                deepest = &home;
        }
        if (deepest is null || named(deepest.package_) is null) return;
        if (named(deepest.package_).directory.length == 0)
        {
            describerHome = deepest.package_;
            return;
        }
        scriptHome = deepest.package_;
        auto found = mainOf(scriptHome, context);
        homeMain = found[0];
        homeMainAt = found[1];
        const(string)[] uses = scriptUses;
        foreach (used; named(scriptHome).uses ~ (homeMain is null ? [scriptHome] : []))
        {
            if (!uses.canFind(used)) uses ~= used;
        }
        scriptUses = uses;
    }

    /// For a script under no package's directory, when packages come from package files or `silver`
    /// is driving, why it can't use the package `name`.
    string homelessScriptHint(string name) const
    {
        if (!fromPackageFiles)
            return format("%sTo use '%s', put a `silver.toml` at or above it that names a package of its own, with "
                ~ "'%s' in its `uses` and a `[[package]]` entry whose `path` is the directory of '%s', whose own "
                ~ "`silver.toml` names it", scriptUses.length == 0
                    ? "A file in no project uses only the standard library. " : "", name, name, name);
        if (auto describer = named(describerHome))
            return format("A file with no `module` line under the directory of '%s', a package that only describes "
                ~ "others, uses only the standard library, so one that needs '%s' belongs under the directory of one of "
                ~ "the packages it describes, %s, or of a package that uses it", describerHome, name,
                describer.describes.map!(d => "'" ~ d ~ "'").join(", "));
        return format("A file with no `module` line that's under no package's directory uses only the standard "
            ~ "library, so one that needs '%s' belongs under the directory of that package or of one that uses it", name);
    }

    /// Whether a module of the package `from` may import from the package `to`.
    bool mayUse(string from, string to) const
    {
        return from == to || from.length == 0 || to.length == 0 || from == langPackage || usesOf(from).canFind(to);
    }

    /// Why the module `importing`, of the package `from`, can't import `name`, of the package `to`.
    string outsideUses(string from, string importing, string name, string to) const
    {
        auto uses = ["`" ~ langPackage ~ "`"] ~ usesOf(from).map!(u => "'" ~ u ~ "'").array;
        auto listed = "uses no package but " ~ (uses.length == 1 ? uses[0] : uses[0 .. $ - 1].join(", ") ~ " and " ~ uses[$ - 1]);
        if (from == script && scriptHome !is null && to == scriptHome && homeMain !is null)
            return format("'%s' is a file with no `module` line under the directory of the package '%s', and it can't "
                ~ "import '%s': '%s' declares `main`, so '%s' is a program, and nothing can use a program, not even a "
                ~ "file beside it\nA file beside a program uses only what the program uses: move what both need to a "
                ~ "library they use", importing, to, name, homeMain, to);
        if (from == script && scriptHome !is null)
            return format("'%s' is a file with no `module` line under the directory of the %s '%s', so a program of "
                ~ "its own that uses what '%s' uses%s, and %s, and it can't import '%s', from the package '%s'\nList "
                ~ "'%s' among what '%s' uses%s", importing, homeMain is null ? "library" : "program", scriptHome,
                scriptHome, homeMain is null ? " and '" ~ scriptHome ~ "' itself" : "", listed, name, to, to,
                scriptHome, hint(usesHint is null ? null : usesHint(scriptHome, to)));
        if (from == script && (fromPackageFiles || bySilver))
            return format("'%s' is a file with no `module` line, so a program of its own that %s, and it can't import "
                ~ "'%s', from the package '%s'\n%s", importing, listed, name, to, homelessScriptHint(to));
        auto suggested = hint(usesHint is null ? null : usesHint(from == script ? null : from, to));
        return from == script
            ? format("'%s' is a file with no `module` line, so a program of its own that %s, and it can't import '%s', "
                ~ "from the package '%s'\nList '%s' among what it uses%s", importing, listed, name, to, to, suggested)
            : format("The package '%s' %s, so '%s' can't import '%s', from the package '%s'\nList '%s' among what '%s' "
                ~ "uses%s", from, listed, importing, name, to, to, from, suggested);
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
        string[string] describerOf;
        foreach (i, ref p; declared)
        {
            if (p.name.length > 0 && !isPackageName(p.name))
                problem(DiagnosticCode.InvalidPackages, format("'%s' isn't a package name: %s", p.name,
                    packageNameRule));
            else if (isInLang(p.name))
                problem(DiagnosticCode.NotInLang, format("'%s' would be part of `%s`, which ships with the compiler, "
                    ~ "so it can't be declared", p.name, langPackage));
            else if (p.name.length > 0 && namesRootFile(segmentsOf(p.name), 0))
                problem(DiagnosticCode.InvalidPackages, format("'%s' can't be a package's name: its last segment is "
                    ~ "`%s`, and a %s is a package's root module, so the name would be taken for one",
                    p.name, rootModuleFile.stripExtension, rootModuleFile));
            if (p.name in seen)
                problem(DiagnosticCode.InvalidPackages, format("There are two packages named '%s'", p.name));
            seen[p.name] = true;
            // A package can exist only to describe others, and then has nowhere for modules.
            if (p.directory.length == 0 && p.name.length > 0 && p.describes.length > 0) continue;
            if (!exists(p.directory) || !isDir(p.directory))
            {
                problem(DiagnosticCode.InvalidPackages, format("The package '%s' is at %s, which isn't a directory",
                    p.name, p.directory));
                continue;
            }
            // The unnamed package of a test's fixtures may hold anything.
            if (p.name.length == 0) continue;
            foreach (ref other; declared[0 .. i])
            {
                if (other.name.length == 0 || !exists(other.directory) || !isDir(other.directory)) continue;
                if (within(p.directory, other.directory) || within(other.directory, p.directory))
                    problem(DiagnosticCode.InvalidPackages, format("The package '%s' is at %s and '%s' at %s, and "
                        ~ "a package's directory can't be inside another's, or be another's: a file in both would "
                        ~ "be a module of each", other.name, other.directory, p.name, p.directory));
            }
        }
        void checkList(string user, string owner, const string[] list, string what)
        {
            foreach (entry; list)
            {
                if (isInLang(entry))
                    problem(DiagnosticCode.InvalidPackages, format("%s lists `%s` among what it %s, and every "
                        ~ "package uses `%s` without listing it", owner, entry, what, langPackage));
                else if (entry.length > 0 && named(entry) is null && !isPackageName(entry))
                    problem(DiagnosticCode.InvalidPackages, format("%s lists '%s' among what it %s, and '%s' isn't "
                        ~ "a package name: %s", owner, entry, what, entry, packageNameRule));
                else if (entry.length == 0 || named(entry) is null)
                    problem(DiagnosticCode.InvalidPackages, format("%s lists '%s' among what it %s, and there's no "
                        ~ "package of that name%s", owner, entry, what,
                        hint(entry.length == 0 ? null : user == script && bySilver && !fromPackageFiles
                            ? homelessScriptHint(entry) : packageHint is null ? null : packageHint(user, entry))));
            }
        }
        foreach (ref p; declared)
        {
            checkList(p.name, format("The package '%s'", p.name), p.uses, "uses");
            checkList(p.name, format("The package '%s'", p.name), p.describes, "describes");
            foreach (other; p.describes)
            {
                auto found = named(other);
                if (other == p.name)
                    problem(DiagnosticCode.InvalidPackages, format("The package '%s' describes itself", other));
                else if (auto first = other in describerOf)
                    problem(DiagnosticCode.InvalidPackages, format("'%s' is described by both '%s' and '%s', and a "
                        ~ "package is described by one", other, *first, p.name));
                else if (found !is null && found.describes.length > 0)
                    problem(DiagnosticCode.InvalidPackages, format("'%s' is described by '%s' and describes packages "
                        ~ "of its own, and a package another describes can't describe others", other, p.name));
                describerOf[other] = p.name;
            }
        }
        if (script !is null) checkList(script, format("'%s', the file with no `module` line,", scriptModule), scriptUses, "uses");
        return ok;
    }

    /// Reports a cycle among what the packages `roots` use, directly or not, and each of them that
    /// uses a program.
    void checkUses(const string[] roots, SourceContext context)
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

        // The script's package was read for `main` already, and what was wrong with it reported then.
        Tuple!(string, Span)[string] mains;
        if (scriptHome !is null) mains[scriptHome] = Tuple!(string, Span)(homeMain, homeMainAt);
        foreach (user; reached)
        {
            foreach (used; usesOf(user))
            {
                if (used !in mains) mains[used] = mainOf(used, context);
                auto main = mains[used];
                if (main[0] is null) continue;
                context.collector.reportError(DiagnosticCode.UsesProgram, main[1],
                    format("'%s' declares `main`, so the package '%s' is a program, and %s can't use it: nothing can "
                        ~ "depend on a program%s", main[0], used, user == script
                            ? format("'%s', the file started from,", scriptModule) : format("the package '%s'", user),
                        user == script && used == scriptHome ? ", not even a file beside it, which uses only what the "
                            ~ "program uses" : ""));
            }
        }
    }

    /// The first module of the package `name`, by name, that declares `main`, and where; or null.
    Tuple!(string, Span) mainOf(string name, SourceContext context, string why = null)
    {
        auto found = mainsOf(name, context, why, false);
        return found.length == 0 ? typeof(return).init : found[0];
    }

    /// The modules of the package `name`, by name, that declare `main`, and where: the first, or with
    /// `every`, all of them. Every `.ag` file under the package's directory with a `module` line is read, other than
    /// companion test files and those whose names put them in another package or in none, as a
    /// `package.ag` below the package's directory. The root module is among them. A file with no
    /// `module` line is a program of its own and not one of the package's modules. With `unparseable`, a
    /// module's parse error goes there instead of being reported.
    Tuple!(string, Span)[] mainsOf(string name, SourceContext context, string why, bool every,
        Diagnostic[]* unparseable = null)
    {
        import silver.syntax.parse : ParseException;

        auto package_ = named(name);
        if (package_ is null || !exists(package_.directory) || !isDir(package_.directory)) return null;
        typeof(return) mains;
        if (why is null)
            why = format("It was read because every module of a package that's used is, to check that the package "
                ~ "'%s' isn't a program", name);
        foreach (path; filesUnder(package_.directory, name, why, context))
        {
            if (isCompanionFile(path)) continue;
            auto under = segmentsBelow(path.stripExtension, package_.directory);
            auto chain = segmentsOf(name) ~ (under == [rootModuleFile.stripExtension] ? [] : under);
            auto found = locate(chain);
            if (found.package_ !is package_ || !sameFile(path, found.path)) continue;
            string text;
            try
            {
                text = readText(path);
            }
            catch (Exception e)
            {
                context.collector.reportError(DiagnosticCode.UnreadableFile, Span(path, 0, 0),
                    format("'%s' can't be read: %s\n%s", path, e.msg, why));
                continue;
            }
            context.sources.add(path, text);
            const(Module)* read;
            try
            {
                read = parsed(chain.join("."), text, path);
            }
            catch (ParseException e)
            {
                // One with no module line isn't the package's, so what's wrong with it is its own business.
                if (startsWithModuleLine(text))
                {
                    auto problem = Diagnostic(e.diagnostic.code, e.diagnostic.span, e.diagnostic.message ~ "\n" ~ why,
                        Severity.Error);
                    if (unparseable !is null) *unparseable ~= problem;
                    else
                    {
                        context.collector.report(problem);
                        unparsed ~= path;
                    }
                }
                continue;
            }
            if (read.declaration is null) continue;
            foreach (declaration; read.declarations)
            {
                auto main = declaration.kind.match!(
                    (const FunctionDecl f) => f.name == "main" ? f.nameSpan : Span(),
                    _ => Span());
                if (main.file is null) continue;
                mains ~= Tuple!(string, Span)(chain.join("."), main);
                if (!every) return mains;
                break;
            }
        }
        return mains;
    }
}

/// `text` prefixed by a new line, or nothing when `text` is null.
private string hint(string text)
{
    return text is null ? "" : "\n" ~ text;
}

/// Whether the directory `inner` is `outer` or inside it.
private bool within(string inner, string outer)
{
    import std.algorithm : startsWith;
    import std.path : dirSeparator, filenameCmp;

    auto a = buildNormalizedPath(absolutePath(inner));
    auto b = buildNormalizedPath(absolutePath(outer));
    return filenameCmp(a, b) == 0 || (a.length > b.length && filenameCmp(a[0 .. b.length], b) == 0
        && a[b.length .. $].startsWith(dirSeparator));
}

/// Whether `segment` can be one part of a module's name, as the parser reads a `module` line: a
/// lowercase letter or `_`, then letters, digits and `_`.
private bool moduleSegment(string segment)
{
    import std.algorithm : all;
    import std.ascii : isAlphaNum, isLower;

    return segment.length > 0 && (isLower(segment[0]) || segment[0] == '_')
        && segment.all!(c => isAlphaNum(c) || c == '_');
}

/// `segments`, a path below the directory `directory`, each as the file system spells it there, which
/// may differ from how it was written where names compare without case; or null when one isn't found.
private string[] spelledOnDisk(string directory, const string[] segments)
{
    import std.file : dirEntries, SpanMode;
    import std.path : filenameCmp;

    string[] spelled;
    auto at = buildNormalizedPath(absolutePath(directory));
    foreach (segment; segments)
    {
        string match;
        try
        {
            foreach (entry; dirEntries(at, SpanMode.shallow, false))
            {
                auto name = baseName(entry.name);
                if (name == segment || filenameCmp(name, segment) == 0) match = name;
                if (name == segment) break;
            }
        }
        catch (Exception)
        {
            return null;
        }
        if (match is null) return null;
        spelled ~= match;
        at = buildPath(at, match);
    }
    return spelled;
}

/// The segments of `path` below the directory `outer`, which holds it, with both normalized first, so
/// neither `.` nor `..` in either becomes a segment.
private string[] segmentsBelow(string path, string outer)
{
    import std.path : pathSplitter, relativePath;

    return pathSplitter(relativePath(buildNormalizedPath(absolutePath(path)), buildNormalizedPath(absolutePath(outer))))
        .array;
}

/// Every regular `.ag` file under `directory`, sorted. A directory that can't be listed is reported,
/// with `why` it was read, and skipped.
private string[] filesUnder(string directory, string package_, string why, SourceContext context)
{
    import std.file : dirEntries, SpanMode;

    string[] files;
    string[] directories;
    try
    {
        foreach (entry; dirEntries(directory, SpanMode.shallow, false))
        {
            if (entry.isDir) directories ~= entry.name;
            else if (entry.isFile && extension(entry.name) == ".ag") files ~= entry.name;
        }
    }
    catch (Exception e)
    {
        context.collector.reportError(DiagnosticCode.UnreadableFile, Span(),
            format("The directory %s, in the package '%s', can't be read: %s\n%s", directory, package_, e.msg, why));
    }
    foreach (inner; directories.sort) files ~= filesUnder(inner, package_, why, context);
    return files.sort.release;
}

/// Whether the first line of `text` that isn't blank or a `//` comment is a `module` line.
private bool startsWithModuleLine(string text)
{
    import std.algorithm : startsWith;
    import std.string : lineSplitter, strip;

    foreach (line; text.lineSplitter)
    {
        auto stripped = line.strip;
        if (stripped.length == 0 || stripped.startsWith("//")) continue;
        return stripped.startsWith("module ");
    }
    return false;
}

/// The segments of the package name `name`, and none for the unnamed one.
private string[] segmentsOf(string name)
{
    return name.length == 0 ? [] : name.split(".");
}

/// Whether `name` is a package's name: segments joined by `.`, each one a module's name could have, so
/// that the package can have modules. frontend/source/silver/frontend/project.d has a copy, `validName`.
bool isPackageName(string name)
{
    import std.algorithm : all;

    return name.length > 0 && name.split(".").all!moduleSegment;
}

/// What a package's name is, worded to follow "isn't a package name: ".
enum packageNameRule = "it's one or more segments joined by `.`, as `silver.core`, each a lowercase letter or `_` "
    ~ "followed by letters, digits and `_`, as in a module's name";

/// The file the module `chain` of `lang` is, which is only ever the compiler's own.
private string langModulePath(const string[] chain)
{
    return chain.length == 1 ? buildPath(standardLibraryPath(), langPackage, rootModuleFile)
        : buildPath(standardLibraryPath() ~ chain) ~ ".ag";
}

/// The file in a package's directory that is the package's own module, named as the package.
enum rootModuleFile = "package.ag";

/// Whether the module `chain`, in a package whose name is its first `length` segments, would be a
/// file named as the root module. Only the one in the package's directory is a module, and it's named
/// as the package.
private bool namesRootFile(const string[] chain, size_t length)
{
    return chain.length > length && chain[$ - 1] == rootModuleFile.stripExtension;
}

/// For a module that would be the file `path` below a package's directory, a line saying to move a
/// `package.ag` in the folder `path` names to `path`, when there is one; otherwise nothing.
private string misplacedRootHint(string path)
{
    import std.file : isFile;

    if (baseName(path) == rootModuleFile) return "";
    auto misplaced = buildPath(path.stripExtension, rootModuleFile);
    if (!exists(misplaced) || !isFile(misplaced)) return "";
    return format("\nThere's a %s, and a %s is a root module only in a package's own directory: a module deeper in "
        ~ "is the file beside the folder, so move it to %s", misplaced, rootModuleFile, path);
}

/// Why `chain`, for which `namesRootFile` holds, isn't a module, worded to follow "not found: ".
private string rootFileProblem(const string[] chain, size_t length, string directory, string package_)
{
    auto name = chain.join(".");
    if (chain.length == length + 1)
        return package_.length == 0
            ? format("no module is named '%s', since a %s is a package's root module", name, rootModuleFile)
            : format("%s is the root module of the package '%s', so it's `module %s`, and no module is named '%s'",
                buildPath(directory, rootModuleFile), package_, package_, name);
    auto folder = buildPath(directory ~ chain[length .. $ - 1]);
    return format("a %s is a root module only in a package's directory, so no module is named '%s': the module '%s' "
        ~ "is %s, beside the folder %s", rootModuleFile, name, chain[0 .. $ - 1].join("."), folder ~ ".ag", folder);
}

/// Reads packages as the command line gives them. Each of `declared` is `name=directory`, each of
/// `uses` is `name=package,package` for what the package `name` uses, or `package,package` for what
/// a file with no `module` line uses, and each of `projects` is `name=package,package`, the packages
/// `name` describes, which with it are one project; it declares `name` as a package with no directory
/// when none of `declared` does. A relative directory
/// is taken from `base`. The standard library is added unless one of `declared` is named as it is.
/// Returns what's wrong with how one is written, or null; what's wrong with what they say is for
/// `load` to report.
string describePackages(const string[] declared, const string[] uses, const string[] projects, string base,
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
    foreach (i, list; [uses, projects])
    {
        immutable flag = i == 0 ? "--uses" : "--project";
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
                    ? format("--uses takes a package and what it uses, as `--uses app=geometry`, or for a file "
                        ~ "with no `module` line only what it uses, as `--uses geometry`, not `%s`", option)
                    : format("--project takes a package and the packages it describes, as "
                        ~ "`--project silver=silver.core`, not `%s`", option);
            auto owner = find(option[0 .. at]);
            // A package that only describes others has no directory, so `--project` alone declares it.
            if (owner is null && i == 1)
            {
                packages.declared ~= Package(option[0 .. at]);
                owner = &packages.declared[$ - 1];
            }
            if (owner is null)
                return undeclared(flag, option[0 .. at], "--package");
            if (i == 0) owner.uses ~= listOf(option[at + 1 .. $]);
            else owner.describes ~= listOf(option[at + 1 .. $]);
        }
    }
    packages.declared = withStandardLibrary(packages.declared);
    packages.usesHint = (user, used) => user is null
        ? format("Give `--uses %s` to list it", used) : format("Give `--uses %s=%s` to list it", user, used);
    packages.packageHint = (user, name) => format("Give `--package %s=<directory>` to declare one", name);
    return null;
}

/// Why the option `option` can't name `name`, which none of `declarers` declares: that it can't be a
/// package's name at all, when it can't.
string undeclared(string option, string name, string declarers = "--package or --project")
{
    return isPackageName(name) ? format("%s names '%s', which no %s declares", option, name, declarers)
        : format("%s names '%s', which isn't a package name: %s", option, name, packageNameRule);
}

/// Says that `silver` is the one driving, from `--from-silver`: the hints for what no package file
/// describes say what a user of `silver` can do, which is to write a `silver.toml`, and name no
/// option. Read after `describePackages` and before `describePackageFiles`.
void describeSilver(ref Packages packages)
{
    packages.bySilver = true;
    packages.usesHint = (user, used) => user is null ? null
        : format("'%s' is described in no `silver.toml`, and what a package uses is listed in its `silver.toml`, as "
            ~ "`uses`, with a `[[package]]` entry for each package it uses", user);
    packages.packageHint = (user, name) => user is null
        ? format("A file in no project is in no package: a package is a directory with a `silver.toml` that names it, "
            ~ "as `name = \"%s\"`, and a file with no `module` line is a program of its own", name)
        : format("'%s' is described in no `silver.toml`, and a package it uses is listed in its `silver.toml`, as "
            ~ "`uses`, with a `[[package]]` entry whose `path` is its directory", user);
}

/// Reads `--package-file name=file`, which says that what the package `name` is, uses and describes
/// was read from the package file `file`, so that the messages about it name that file and its
/// fields instead of options that weren't given. Packages it doesn't name keep the options' hints.
/// Returns what's wrong with how one is written, or null.
string describePackageFiles(const string[] files, ref Packages packages)
{
    import std.string : indexOf;

    if (files.length == 0) return null;
    packages.fromPackageFiles = true;
    string[string] fileOf;
    foreach (option; files)
    {
        auto at = option.indexOf('=');
        if (at <= 0 || at == option.length - 1)
            return format("--package-file takes a package and the file it's described in, as "
                ~ "`--package-file geometry=geometry/silver.toml`, not `%s`", option);
        immutable name = option[0 .. at];
        if (!packages.declared.canFind!(p => p.name == name))
            return undeclared("--package-file", name);
        fileOf[name] = option[at + 1 .. $];
        packages.packageFiles[name] = option[at + 1 .. $];
    }
    string[string] describerOf;
    foreach (ref p; packages.declared)
    {
        foreach (other; p.describes) describerOf[other] = p.name;
    }
    string listIn(string user, string file)
    {
        return user in describerOf ? format("the `uses` of the package '%s' in %s", user, file) : "`uses` in " ~ file;
    }
    auto optionUses = packages.usesHint;
    packages.usesHint = (user, used) {
        auto file = user is null ? null : user in fileOf;
        if (file is null) return optionUses is null ? null : optionUses(user, used);
        auto list = "That list is " ~ listIn(user, *file);
        auto usedFile = used in fileOf;
        if (usedFile !is null && *usedFile == *file) return list;
        return list ~ format(", with a `[[package]]` entry for '%s' there if it has none", used);
    };
    auto optionPackage = packages.packageHint;
    packages.packageHint = (user, name) {
        auto file = user is null ? null : user in fileOf;
        if (file is null)
            return user is null || optionPackage is null ? null : optionPackage(user, name);
        return format("List it in %s, with a `[[package]]` entry whose `path` is its directory there",
            listIn(user, *file));
    };
    return null;
}

/// Reads `--scripts-in name=directory`, which says that a file with no `module` line under `directory`
/// uses what the package `name` uses, and `name` too unless it's a program. The package must be declared,
/// with a directory of modules inside `directory`, and one directory can't be given for two packages.
/// A relative directory is taken from `base`. Returns what's wrong with how one is written, or null.
string describeScriptHomes(const string[] options, string base, ref Packages packages)
{
    import std.path : filenameCmp;
    import std.string : indexOf;

    foreach (option; options)
    {
        auto at = option.indexOf('=');
        if (at <= 0 || at == option.length - 1)
            return format("--scripts-in takes a package and a directory, as `--scripts-in geometry=geometry`, not `%s`",
                option);
        immutable name = option[0 .. at];
        auto directory = base.length == 0 ? option[at + 1 .. $] : buildPath(base, option[at + 1 .. $]);
        auto found = packages.declared.countUntil!(p => p.name == name);
        if (found < 0)
            return undeclared("--scripts-in", name);
        auto modules = packages.declared[found].directory;
        if (modules.length > 0 && !within(modules, directory))
            return format("--scripts-in gives '%s' the directory %s, which doesn't hold its modules, at %s", name,
                directory, modules);
        foreach (other; packages.scriptHomes)
        {
            if (other.package_ == name)
                return format("--scripts-in names '%s' twice", name);
            if (filenameCmp(buildNormalizedPath(absolutePath(other.directory)), buildNormalizedPath(absolutePath(directory))) == 0)
                return format("--scripts-in gives %s to both '%s' and '%s'", directory, other.package_, name);
        }
        packages.scriptHomes ~= ScriptHome(name, directory);
    }
    return null;
}

/// The file the program of the package `name` starts from, for the command `command` (`run` or
/// `build`), and in `chosen` the package whose program it is; or null after reporting to `context`
/// why there's none to choose. The programs are the package itself when a module of it declares
/// `main`, and each package it describes that has one. A file with no `module` line is never one. The
/// package has to be declared.
string programStart(string name, string command, const Packages packages, SourceContext context, out string chosen)
{
    auto layout = Layout(packages.declared, packages.scriptUses, packages.usesHint, packages.packageHint);
    auto package_ = layout.named(name);
    assert(package_ !is null, "--program names an undeclared package");
    immutable why = format("It was read to find which module of '%s' declares `main`", name);
    immutable verb = command == "build" ? "build" : "run";
    // A described package is shown at the directory it's known by, which `--scripts-in` gives when its
    // modules are below it.
    string directoryOf(string package_)
    {
        foreach (ref home; packages.scriptHomes)
        {
            if (home.package_ == package_) return home.directory;
        }
        return layout.named(package_).directory;
    }
    if (!layout.described(context)) return null;
    immutable tool = packages.fromPackageFiles ? "silver" : "silverc";
    string[] names;
    Tuple!(string, Span)[][] mains;
    Diagnostic[] unparseable;
    foreach (candidate; [name] ~ package_.describes)
    {
        if (layout.named(candidate) is null) continue;
        auto found = layout.mainsOf(candidate, context, why, true, &unparseable);
        if (found.length == 0) continue;
        names ~= candidate;
        mains ~= found;
    }
    // A module that can't be parsed might declare `main`, so with one, what the package's programs are
    // isn't known. The one `main` found is started from, as naming its file would be, and what's wrong
    // with the module is reported by loading only if the program imports it; otherwise nothing is
    // concluded and the parse errors are all that's said.
    if (names.length == 1 && mains[0].length == 1)
    {
        chosen = names[0];
        return mains[0][0][1].file;
    }
    if (unparseable.length > 0)
    {
        foreach (problem; unparseable) context.collector.report(problem);
        return null;
    }
    foreach (i, candidate; names)
    {
        auto found = mains[i];
        if (found.length < 2) continue;
        context.collector.reportError(DiagnosticCode.SeveralMains, Span(), format("The package '%s' has more than "
            ~ "one module that declares `main`, so it has no one program to %s:\n%s\nName the file to %s, as `%s "
            ~ "%s %s`", candidate, verb, found.map!(m => "  " ~ m[1].file).join("\n"), verb, tool, verb,
            found[0][1].file));
        return null;
    }
    immutable tests = packages.fromPackageFiles ? "Its tests are run with `silver test`"
        : "Its tests are run with `silverc test`, given a directory or a file";
    immutable scripts = format("A file with no `module` line is a program of its own, and is run by naming it, as "
        ~ "`%s %s demo.ag`", tool, verb);
    if (names.length == 0)
    {
        context.collector.reportError(DiagnosticCode.NoProgram, Span(), package_.describes.length == 0
            ? format("The package '%s' is a library: none of its modules declares `main`, so it has no program to "
                ~ "%s\n%s\n%s", name, verb, tests, scripts)
            : format("The package '%s' %s, and none of the packages it describes is a program: no module of %s "
                ~ "declares `main`, so there's no program to %s\n%s\n%s", name, package_.directory.length == 0
                    ? "only describes others"
                    : "is a library", package_.directory.length == 0 ? "theirs" : "it or of them", verb, tests, scripts));
        return null;
    }
    // The package's own program can't be chosen by its directory, which would name the package again.
    string[] lines;
    foreach (i, candidate; names)
    {
        lines ~= candidate == name
            ? format("  '%s' itself, whose `main` is in %s, chosen by naming that file", candidate, mains[i][0][1].file)
            : format("  '%s', at %s, whose `main` is in %s", candidate, directoryOf(candidate), mains[i][0][1].file);
    }
    auto first = names[0] == name ? names[1] : names[0];
    string choose = packages.fromPackageFiles
        ? format("Choose one by its directory, as `silver %s %s`", verb, directoryOf(first))
        : format("Choose one with `--program`, as `--program %s`", first);
    if (names[0] == name)
        choose ~= format(", or the program of '%s' itself by its file, as `%s %s %s`", name, tool, verb,
            mains[0][0][1].file);
    context.collector.reportError(DiagnosticCode.SeveralPrograms, Span(), format("The package '%s' holds more than one "
        ~ "program, so which to %s has to be said:\n%s\n%s", name, verb, lines.join("\n"), choose));
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

/// Directory holding `lang` and the standard library that ships with the compiler: `stdlib`
/// beside the executable. The build puts the test executables in build/, beside a link to stdlib/, as it does silver and silverc in out/.
string standardLibraryPath()
{
    import std.file : thisExePath;

    return buildPath(thisExePath.dirName, "stdlib");
}

/// What to tell the user when the standard library isn't at `standardLibraryPath()`, or null when it is.
string missingStandardLibrary()
{
    auto path = standardLibraryPath();
    if (exists(buildPath(path, langPackage, rootModuleFile))) return null;
    return "The standard library wasn't found. It's the directory `stdlib` beside the compiler, which would be " ~ path
        ~ ".";
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
            format("This file is the module '%s', by its package and its path, but its `module` line names '%s'%s",
                name, loaded.declaration.path.join("."), baseName(path) == rootModuleFile
                    && loaded.declaration.path == chain ~ rootModuleFile.stripExtension
                    ? format("\nA %s in a package's directory is the package's root module, named as the package: "
                        ~ "write `module %s`", rootModuleFile, name) : ""));
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

    /// Whether `message` names no command-line option, as `--uses`.
    bool mentionsNoOption(string message)
    {
        import std.regex : matchFirst, regex;

        return message.matchFirst(regex(`--[a-z]`)).empty;
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
    /// null.
    Packages loose(string directory)
    {
        return Packages(withStandardLibrary(directory is null ? [] : [Package(null, directory)]));
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

@("load reports an import that no package has, and keeps going")
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
    assert(exists(buildPath(standardLibraryPath(), langPackage, rootModuleFile)));
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

@("load reports a prelude that no package has")
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
        ["lang.ag": "module lang\ndef fake(): Int => 1", "lang/package.ag": "module lang\ndef fake(): Int => 1",
            "lang/io.ag": "module lang.io\ndef fake(): Int => 1"]);
    scope (exit) rmdirRecurse(directory);

    auto program = load("import lang.io", "main.ag", loose(directory), null, new SourceContext);
    program.modules[langPackage].span.file.should.equal(buildPath(standardLibraryPath(), "lang", "package.ag"));
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
    foreach (path; dirEntries(lang, "*.ag", SpanMode.depth).map!(e => e.name).filter!(f => !isCompanionFile(f)).array)
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
    auto root = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..");
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

    auto text = readText(buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "sema", "source", "silver",
        "sema", "analysis.d"));
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
    errors[0].message.should.contain(buildPath("std", "maths.ag"));
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
    program.packageOf["main"].should.equal(scriptPackage("main"));
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
    errors[0].message.should.contain("'main' is a file with no `module` line, so a program of its own that uses no package but `lang` and 'geometry'");
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

@("a package's own name isn't a module without a package.ag, which the message says to add, and a name no package starts isn't found")
unittest
{
    auto directory = makeModuleDirectory("packages-root", ["geometry/area.ag": "module geometry.area"]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    load("import geometry\nimport shapes.circle", "main.ag",
        Packages([Package("geometry", buildPath(directory, "geometry"))], ["geometry"]), null, context);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.ModuleNotFound, DiagnosticCode.ModuleNotFound]);
    auto root = buildPath(directory, "geometry", "package.ag");
    errors[0].message.should.equal(format("Module 'geometry' not found: 'geometry' is a package, at %s, and there's no "
        ~ "%s, its root module\nAdd %s to give the package a module of its own, or import a module of the package, as "
        ~ "'geometry.name' for %s", buildPath(directory, "geometry"), root, root,
        buildPath(directory, "geometry", "name.ag")));
    errors[1].message.should.contain("no package is named 'shapes'");
}

@("a package's package.ag is its root module, imported by the package's name, and usually a facade of forwards")
unittest
{
    auto directory = makeModuleDirectory("packages-root-module", [
        "cards/package.ag": "module cards\nforward import cards.deck\nforward import cards.suit : Suit",
        "cards/deck.ag": "module cards.deck\ndef size(): Int => 52",
        "cards/suit.ag": "module cards.suit\ntype Suit(n: Int)",
        "core/package.ag": "module silver.core\nforward import silver.core.lower",
        "core/lower.ag": "module silver.core.lower\nimport cards",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto packages = Packages([
        Package("cards", buildPath(directory, "cards")),
        Package("silver.core", buildPath(directory, "core"), ["cards"]),
    ], ["cards", "silver.core"]);
    auto context = new SourceContext;
    auto program = load("import cards\nimport silver.core", "main.ag", packages, null, context);
    context.collector.diagnostics.length.should.equal(0);
    ownModules(program).should.equal(["cards", "cards.deck", "cards.suit", "main", "silver.core", "silver.core.lower"]);
    program.modules["cards"].span.file.should.equal(buildPath(directory, "cards", "package.ag"));
    program.modules["silver.core"].span.file.should.equal(buildPath(directory, "core", "package.ag"));
    program.packageOf["cards"].should.equal("cards");
    program.packageOf["silver.core"].should.equal("silver.core");

    // Started from, alone or with its companion test file.
    auto file = buildPath(directory, "cards", "package.ag");
    context = new SourceContext;
    program = load(readText(file), file, packages, null, context);
    context.collector.diagnostics.length.should.equal(0);
    program.entryModule.should.equal("cards");
    program.packageOf["cards"].should.equal("cards");
    write(buildPath(directory, "cards", "package.test.ag"), "test \"t\" => expect(cards.deck.size() == 52)");
    auto companion = companionOf(file);
    assert(companion !is null);
    context = new SourceContext;
    program = load(readText(file), file, packages, null, context, companion);
    context.collector.diagnostics.length.should.equal(0);
    program.modules[companionName("cards")].companionOf.should.equal("cards");
}

@("no module of a package is named after package.ag, in its directory or below, and lang follows the same rule")
unittest
{
    auto directory = makeModuleDirectory("packages-root-misnamed", [
        "cards/package.ag": "module cards.package",
        "geometry/shapes.ag": "module geometry.shapes",
        "geometry/shapes/package.ag": "module geometry.shapes.package",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto packages = Packages([Package("cards", buildPath(directory, "cards")),
        Package("geometry", buildPath(directory, "geometry"))], ["cards", "geometry"]);

    string[] problems(string source, string file = "main.ag")
    {
        auto context = new SourceContext;
        load(source, file, packages, null, context);
        return context.collector.errors.map!(e => cast(string) e.code ~ ": " ~ e.message).array;
    }
    auto root = buildPath(directory, "cards", "package.ag");
    problems("import cards").should.equal([format("L0003: This file is the module 'cards', by its package and its path, "
        ~ "but its `module` line names 'cards.package'\nA package.ag in a package's directory is the package's root "
        ~ "module, named as the package: write `module cards`")]);
    problems("import cards.package").should.equal([format("L0001: Module 'cards.package' not found: %s is the root "
        ~ "module of the package 'cards', so it's `module cards`, and no module is named 'cards.package'", root)]);
    problems(readText(root), root).should.equal([format("L0003: Module 'cards.package' can't be in the package 'cards': "
        ~ "%s is the root module of the package 'cards', so it's `module cards`, and no module is named 'cards.package'",
        root)]);

    auto deeper = buildPath(directory, "geometry", "shapes", "package.ag");
    auto why = format("a package.ag is a root module only in a package's directory, so no module is named "
        ~ "'geometry.shapes.package': the module 'geometry.shapes' is %s.ag, beside the folder %s",
        buildPath(directory, "geometry", "shapes"), buildPath(directory, "geometry", "shapes"));
    problems("import geometry.shapes.package").should.equal(["L0001: Module 'geometry.shapes.package' not found: " ~ why]);
    problems(readText(deeper), deeper).should.equal(["L0003: Module 'geometry.shapes.package' can't be in the package "
        ~ "'geometry': " ~ why]);
    problems("import geometry.shapes").length.should.equal(0);

    problems("import lang.package")[0].should.contain("L0001: Module 'lang.package' not found: "
        ~ buildPath(standardLibraryPath(), "lang", "package.ag") ~ " is the root module of the package 'lang'");
    auto langRoot = buildPath(standardLibraryPath(), "lang", "package.ag");
    problems("module lang.package", langRoot)[0].should.contain("L0003: Module 'lang.package' can't be in `lang`");

    // A package that only describes others has no directory, and so no root module either.
    auto kit = Packages([Package("kit", null, [], ["kit.words"]), Package("kit.words", buildPath(directory, "geometry"))],
        ["kit"]);
    auto context = new SourceContext;
    load("import kit\nimport kit.package", "main.ag", kit, null, context);
    context.collector.errors.map!(e => e.message.idup).array.should.equal([
        "Module 'kit' not found: 'kit' is a package that only describes others, so it has no module of its own",
        "Module 'kit.package' not found: the package 'kit' only describes others, so it has no modules of its own, and "
            ~ "no package it describes is named by a start of 'kit.package'"]);
}

@("the root module is one of the package's files when looking for a main, and a package.ag below the directory isn't")
unittest
{
    auto directory = makeModuleDirectory("packages-root-main", [
        "tool/package.ag": "module tool\ndef main(): Unit { }",
        "tool/util.ag": "module tool.util",
        "lib/util.ag": "module lib.util",
        "lib/util/package.ag": "module lib.util.package\ndef main(): Unit { }",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto packages = Packages([Package("tool", buildPath(directory, "tool")), Package("lib", buildPath(directory, "lib"))],
        ["tool", "lib"]);
    auto context = new SourceContext;
    load("import tool.util\nimport lib.util", "main.ag", packages, null, context);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.UsesProgram]);
    errors[0].span.file.should.equal(buildPath(directory, "tool", "package.ag"));
    errors[0].message.should.contain("'tool' declares `main`, so the package 'tool' is a program");
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

@("a package can describe others and have no directory, and any number of those can be programs")
unittest
{
    auto directory = makeModuleDirectory("packages-project-only", [
        "words/list.ag": "module kit.words.list\n\ndef word(): Int => 1",
        "count/main.ag": "module kit.count.main\n\nimport kit.words.list\n\ndef main(): Unit {}",
        "tool/main.ag": "module kit.tool.main\n\nimport kit.words.list\n\ndef main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto declared = [
        Package("kit", null, [], ["kit.words", "kit.count", "kit.tool"]),
        Package("kit.words", buildPath(directory, "words")),
        Package("kit.count", buildPath(directory, "count"), ["kit.words"]),
        Package("kit.tool", buildPath(directory, "tool"), ["kit.words"]),
    ];
    foreach (member; ["count", "tool"])
    {
        auto context = new SourceContext;
        auto file = buildPath(directory, member, "main.ag");
        auto program = load(readText(file), file, Packages(declared), null, context);
        context.collector.errors.array.map!(e => e.message).array.should.equal(cast(string[])[]);
        program.packageOf["kit." ~ member ~ ".main"].should.equal("kit." ~ member);
        program.packageOf["kit.words.list"].should.equal("kit.words");
    }

    string[] problems(string source, Package[] packages)
    {
        auto context = new SourceContext;
        load(source, "main.ag", Packages(packages, ["kit"]), null, context);
        return context.collector.errors.map!(e => cast(string) e.code ~ ": " ~ e.message).array;
    }
    problems("import kit", declared)[0].should.contain("L0001: Module 'kit' not found: 'kit' is a package that only describes others");
    problems("import kit.missing.x", declared)[0].should.contain("no package it describes is named by a start of 'kit.missing.x'");
    problems("", [Package("kit", null)])[0].should.contain("isn't a directory");

    Packages described;
    describePackages(["kit.words=words"], ["kit"], ["kit=kit.words"], null, described).should.equal(null);
    described.declared[1].should.equal(Package("kit", null, [], ["kit.words"]));
    describePackages([], ["kit=kit.words"], ["kit=kit.words"], null, described)
        .should.contain("--uses names 'kit', which no --package declares");
}

@("a description that can't be followed is reported, and nothing more is loaded")
unittest
{
    auto directory = makeModuleDirectory("packages-invalid", ["a/x.ag": "module a.x", "a/deeper/y.ag": "", "b/x.ag": "", "c/x.ag": ""]);
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
    problems(Packages([a, Package("main", buildPath(directory, "b"))], ["a"])).length.should.equal(0);
    problems(Packages([a, Package("inner", buildPath(directory, "a", "deeper"))], ["a"]))[0]
        .should.contain("L0013: The package 'a' is at");
    problems(Packages([Package("inner", buildPath(directory, "a", "deeper")), a], ["a"]))[0]
        .should.contain("can't be inside another's");
    problems(Packages([a, Package("again", a.directory)], ["a"]))[0].should.contain("or be another's");

    auto c = Package("c", buildPath(directory, "c"));
    problems(Packages([Package("a", a.directory, [], ["b"]), Package("c", c.directory, [], ["b"]), b], ["a"]))[0]
        .should.contain("'b' is described by both 'a' and 'c'");
    problems(Packages([Package("a", a.directory, [], ["b"]), Package("b", b.directory, [], ["c"]), c], ["a"]))[0]
        .should.contain("a package another describes can't describe others");
    problems(Packages([Package("a", a.directory, [], ["a"])], ["a"]))[0].should.contain("describes itself");
    problems(Packages([Package("a", a.directory, [], ["b"]), b], ["a"])).length.should.equal(0);
}

@("a package's name has the segments a module's name has, wherever it's given, and one that can't be a name says so")
unittest
{
    auto directory = makeModuleDirectory("package-names", ["a/x.ag": "module a.x", "b/x.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    enum rule = "it's one or more segments joined by `.`, as `silver.core`, each a lowercase letter or `_` followed by "
        ~ "letters, digits and `_`, as in a module's name";
    auto bad = ["Geo", "geo.Shapes", "1geo", "geo.2d", "geo-x", "a..b", ".a", "b.", "café", "geo x"];
    foreach (name; bad) isPackageName(name).should.equal(false);
    foreach (name; ["geo", "geoShapes", "geo_x", "_", "_geo", "geo2", "val", "if", "match", "silver.core"])
        isPackageName(name).should.equal(true);

    string[] problems(Packages packages)
    {
        auto context = new SourceContext;
        load("import a.x", "main.ag", packages, null, context);
        return context.collector.errors.map!(e => cast(string) e.code ~ ": " ~ e.message).array;
    }
    auto a = Package("a", buildPath(directory, "a"));
    foreach (name; bad)
    {
        // Declared, it's refused once, and a list naming it isn't told there's no such package.
        problems(Packages([a, Package(name, buildPath(directory, "b"))], ["a", name]))
            .should.equal([format("L0013: '%s' isn't a package name: %s", name, rule)]);
        problems(Packages([a, Package("p", null, [], [name])], ["a"])).should.equal([format("L0013: The package 'p' "
            ~ "lists '%s' among what it describes, and '%s' isn't a package name: %s", name, name, rule)]);
        problems(Packages([Package("a", a.directory, [name])], ["a"])).should.equal([format("L0013: The package 'a' "
            ~ "lists '%s' among what it uses, and '%s' isn't a package name: %s", name, name, rule)]);
        problems(Packages([a], ["a", name])).should.equal([format("L0013: 'main', the file with no `module` line, "
            ~ "lists '%s' among what it uses, and '%s' isn't a package name: %s", name, name, rule)]);
    }
    problems(Packages([a], ["a", "geo"]))[0].should.endWith("lists 'geo' among what it uses, and there's no package of that name");
    problems(Packages([a, Package("shapes.package", buildPath(directory, "b"))], ["a"]))[0]
        .should.contain("its last segment is `package`");

    Packages packages;
    describePackages(["Geo=b"], [], [], null, packages).should.equal(null);
    describePackages([], ["Geo=a"], [], null, packages)
        .should.equal("--uses names 'Geo', which isn't a package name: " ~ rule);
    describePackages(["a=a"], [], [], null, packages).should.equal(null);
    describePackageFiles(["Geo=x/silver.toml"], packages)
        .should.equal("--package-file names 'Geo', which isn't a package name: " ~ rule);
    describePackages(["a=" ~ a.directory], [], [], null, packages).should.equal(null);
    describeScriptHomes(["Geo=" ~ directory], null, packages)
        .should.equal("--scripts-in names 'Geo', which isn't a package name: " ~ rule);
    undeclared("--program", "Geo").should.equal("--program names 'Geo', which isn't a package name: " ~ rule);
    undeclared("--program", "geo").should.equal("--program names 'geo', which no --package or --project declares");
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
    packages.declared[0].describes.should.equal(["silver.core"]);
    packages.declared[2].directory.should.equal(buildPath(standardLibraryPath(), standardPackage));
    packages.scriptUses.should.equal(["std", "geometry"]);

    describePackages(["std=mine"], [], [], null, packages).should.equal(null);
    packages.declared.should.equal([Package("std", "mine")]);

    describePackages(["geometry"], [], [], null, packages).should.contain("--package takes a name and a directory");
    describePackages(["=lib"], [], [], null, packages).should.contain("--package takes");
    describePackages([], ["app=std"], [], null, packages).should.contain("'app', which no --package declares");
    describePackages(["a=a"], [], ["b"], null, packages).should.contain("--project takes a package and the packages it describes");
}

@("the standard library is the package std, and its modules import it and the prelude without listing anything")
unittest
{
    auto context = new SourceContext;
    auto program = load("import std.random", "main.ag", Packages(withStandardLibrary([])),
        standardPrelude, context);
    context.collector.diagnostics.length.should.equal(0);
    program.packageOf["std.random"].should.equal(standardPackage);
    program.packageOf[standardPrelude].should.equal(standardPackage);

    context = new SourceContext;
    load("def f(): Int => 1", "main.ag", Packages(withStandardLibrary([])), standardPrelude, context);
    context.collector.diagnostics.length.should.equal(0);
}

@("every package and script uses the prelude's package without listing it, and listing it changes nothing")
unittest
{
    auto context = new SourceContext;
    load("import std.random", "main.ag", Packages(withStandardLibrary([])), standardPrelude, context);
    context.collector.diagnostics.length.should.equal(0);

    auto directory = makeModuleDirectory("packages-prelude-implicit", [
        "geo/shapes.ag": "module geo.shapes\nimport std.math",
        "base/prelude.ag": "module base.prelude",
        "base/extra.ag": "module base.extra",
        "kit/tool.ag": "module kit.tool\nimport base.extra",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto geo = Package("geo", buildPath(directory, "geo"));
    context = new SourceContext;
    load("import geo.shapes\nimport std.math", "main.ag", Packages(withStandardLibrary([geo]), ["geo"]),
        standardPrelude, context);
    context.collector.diagnostics.length.should.equal(0);
    context = new SourceContext;
    load("import geo.shapes", "main.ag", Packages(withStandardLibrary([Package("geo", geo.directory, ["std"])]),
        ["geo", "std"]), standardPrelude, context);
    context.collector.diagnostics.length.should.equal(0);

    // The package is the prelude's, whatever it's named, and std is then listed like any other.
    auto packages = Packages(withStandardLibrary([Package("base", buildPath(directory, "base")),
        Package("kit", buildPath(directory, "kit"))]), ["kit"]);
    context = new SourceContext;
    load("import kit.tool\nimport base.extra", "main.ag", packages, "base.prelude", context);
    context.collector.diagnostics.length.should.equal(0);
    context = new SourceContext;
    load("import std.random", "main.ag", packages, "base.prelude", context);
    context.collector.errors.array.map!(e => e.code).array.should.equal([DiagnosticCode.ImportOutsideUses]);
}

@("a module of lang can't import the prelude's package")
unittest
{
    auto context = new SourceContext;
    auto lang = langModulePath(["lang", "io"]);
    load("module lang.io\nimport std.math", lang, Packages(withStandardLibrary([])), standardPrelude, context);
    context.collector.errors.array.map!(e => e.code).canFind(DiagnosticCode.LangImportsOutside).should.equal(true);
}

@("a file with no module line in a package's directory is a program of its own, so its main doesn't make the package one")
unittest
{
    auto directory = makeModuleDirectory("packages-script-in-library", [
        "geo/shapes.ag": "module geo.shapes\ndef area(x: Int): Int => x * x",
        "geo/example.ag": "import geo.shapes\ndef main(): Unit { }",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto packages = Packages([Package("geo", buildPath(directory, "geo"))], ["geo"]);
    auto context = new SourceContext;
    load("import geo.shapes\ndef main(): Unit { }", "main.ag", packages, null, context);
    context.collector.errors.array.map!(e => cast(string) e.code ~ ": " ~ e.message).array.should.equal([]);

    // Nor does the starting file, run from the package's directory.
    auto started = buildPath(directory, "geo", "example.ag");
    context = new SourceContext;
    load(readText(started), started, packages, null, context);
    context.collector.errors.array.map!(e => cast(string) e.code ~ ": " ~ e.message).array.should.equal([]);
}

@("a directory in a package's directory named as a module file isn't read as one")
unittest
{
    auto directory = makeModuleDirectory("packages-directory-named-ag", ["geo/shapes.ag": "module geo.shapes"]);
    scope (exit) rmdirRecurse(directory);
    mkdirRecurse(buildPath(directory, "geo", "data.ag"));

    auto context = new SourceContext;
    load("import geo.shapes", "main.ag", Packages([Package("geo", buildPath(directory, "geo"))], ["geo"]), null, context);
    context.collector.errors.array.map!(e => cast(string) e.code ~ ": " ~ e.message).array.should.equal([]);
}

version (Posix)
@("a directory in a used package that can't be listed is reported with a code, not thrown")
unittest
{
    import std.exception : assertNotThrown;
    import std.file : getAttributes, setAttributes;

    auto directory = makeModuleDirectory("packages-unlistable", ["geo/shapes.ag": "module geo.shapes"]);
    auto locked = buildPath(directory, "geo", "locked");
    mkdirRecurse(locked);
    auto attributes = getAttributes(locked);
    setAttributes(locked, 0);
    scope (exit)
    {
        setAttributes(locked, attributes);
        rmdirRecurse(directory);
    }

    auto context = new SourceContext;
    assertNotThrown(load("import geo.shapes", "main.ag", Packages([Package("geo", buildPath(directory, "geo"))], ["geo"]),
        null, context));
}

@("a file with no module line may be named as a package it uses, and importing the package's root module from it says to rename it")
unittest
{
    auto directory = makeModuleDirectory("packages-script-named-as-package",
        ["geo/shapes.ag": "module geo.shapes", "geo/package.ag": "module geo"]);
    scope (exit) rmdirRecurse(directory);

    auto script = buildPath(directory, "geo.ag");
    auto packages = Packages([Package("geo", buildPath(directory, "geo"))], ["geo"]);
    auto context = new SourceContext;
    load("import geo.shapes\ndef main(): Unit { }", script, packages, null, context);
    context.collector.errors.array.map!(e => cast(string) e.code ~ ": " ~ e.message).array.should.equal([]);

    context = new SourceContext;
    load("import geo\ndef main(): Unit { }", script, packages, null, context);
    context.collector.errors.array.map!(e => cast(string) e.code ~ ": " ~ e.message).array.should.equal([format(
        "L0002: 'geo' is the root module of the package 'geo', %s, and the file started from, %s, has no `module` line, "
        ~ "so it's named 'geo' after its file too\nRename %s", buildPath(directory, "geo", "package.ag"), script, script)]);
}

@("a syntax error in a module of a used package that nothing imports says why the file was read, and a broken script there isn't read")
unittest
{
    auto directory = makeModuleDirectory("packages-broken", [
        "geo/shapes.ag": "module geo.shapes",
        "geo/demo.ag": "// a demo\ndef = broken",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto packages = Packages([Package("geo", buildPath(directory, "geo"))], ["geo"]);

    auto context = new SourceContext;
    load("import geo.shapes", "main.ag", packages, null, context);
    context.collector.errors.empty.should.equal(true);

    write(buildPath(directory, "geo", "broken.ag"), "module geo.broken\ndef = broken");
    context = new SourceContext;
    load("import geo.shapes", "main.ag", packages, null, context);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.ParseError]);
    errors[0].span.file.should.equal(buildPath(directory, "geo", "broken.ag"));
    errors[0].message.should.contain("to check that the package 'geo' isn't a program");
}

@("what the command line describes names the option that fixes what's missing")
unittest
{
    auto directory = makeModuleDirectory("packages-hints", [
        "geo/shapes.ag": "module geo.shapes\nimport units.length",
        "units/length.ag": "module units.length",
    ]);
    scope (exit) rmdirRecurse(directory);

    string[] problems(string source, string[] uses)
    {
        Packages packages;
        assert(describePackages(["geo=" ~ buildPath(directory, "geo"), "units=" ~ buildPath(directory, "units")], uses,
            [], null, packages) is null);
        auto context = new SourceContext;
        load(source, "main.ag", packages, standardPrelude, context);
        return context.collector.errors.map!(e => e.message.idup).array;
    }
    problems("import geo.shapes", [])[0].should.contain("\nGive `--uses geo` to list it");
    problems("import geo.shapes", ["geo"])[0].should.contain("\nGive `--uses geo=units` to list it");
    problems("import shapes.circle", [])[0].should.contain("\nGive `--package shapes=<directory>` to declare one");
    problems("def f(): Int => 1", ["nope"])[0].should.contain("\nGive `--package nope=<directory>` to declare one");
}

@("--package-file makes the hints name the package file and its fields instead of options")
unittest
{
    auto directory = makeModuleDirectory("packages-file-hints", [
        "geo/shapes.ag": "module geo.shapes",
        "kit/tool.ag": "module geo.kit.tool",
        "units/length.ag": "module units.length",
    ]);
    scope (exit) rmdirRecurse(directory);

    string[] problems(string source, string[] files, string start = "main.ag")
    {
        Packages packages;
        assert(describePackages(["geo=" ~ buildPath(directory, "geo"), "geo.kit=" ~ buildPath(directory, "kit"),
            "units=" ~ buildPath(directory, "units")], [], ["geo=geo.kit"], null, packages) is null);
        assert(describePackageFiles(files, packages) is null);
        auto context = new SourceContext;
        load(source, start, packages, standardPrelude, context);
        return context.collector.errors.map!(e => e.message.idup).array;
    }
    auto files = ["geo=geo/silver.toml", "geo.kit=geo/silver.toml", "units=units/silver.toml"];
    auto shapes = buildPath(directory, "geo", "shapes.ag");
    auto tool = buildPath(directory, "kit", "tool.ag");
    auto root = problems("module geo.shapes\nimport units.length", files, shapes);
    root.length.should.equal(1);
    root[0].should.endWith("\nList 'units' among what 'geo' uses\nThat list is `uses` in geo/silver.toml, with a "
        ~ "`[[package]]` entry for 'units' there if it has none");
    problems("module geo.kit.tool\nimport units.length", files, tool)[0]
        .should.endWith("\nThat list is the `uses` of the package 'geo.kit' in geo/silver.toml, with a `[[package]]` "
            ~ "entry for 'units' there if it has none");
    problems("module geo.kit.tool\nimport geo.shapes", files, tool)[0]
        .should.endWith("\nList 'geo' among what 'geo.kit' uses\nThat list is the `uses` of the package 'geo.kit' in geo/silver.toml");
    problems("module geo.shapes\nimport shapes.circle", files, shapes)[0]
        .should.endWith("\nList it in `uses` in geo/silver.toml, with a `[[package]]` entry whose `path` is its directory there");
    problems("module geo.kit.tool\nimport shapes.circle", files, tool)[0]
        .should.endWith("\nList it in the `uses` of the package 'geo.kit' in geo/silver.toml, with a `[[package]]` "
            ~ "entry whose `path` is its directory there");
    // A file with no module line under no package's directory has nowhere to list what it uses.
    immutable homeless = "\nA file with no `module` line that's under no package's directory uses only the standard "
        ~ "library, so one that needs '%s' belongs under the directory of that package or of one that uses it";
    problems("import shapes.circle", files)[0].should.endWith(format(homeless, "shapes"));
    auto script = problems("import geo.shapes", files);
    script[0].should.endWith(format(homeless, "geo"));
    script[0].should.not.contain("List 'geo'");
    problems("import geo.shapes", [])[0].should.endWith("\nGive `--uses geo` to list it");
    auto misnamed = problems("module wrong.shapes", files, shapes);
    misnamed.length.should.equal(1);
    misnamed[0].should.endWith(format("\n%s is in the package 'geo', at %s, so its `module` line is `module geo.shapes`",
        shapes, buildPath(directory, "geo")));
    problems("module wrong.thing", files, buildPath(directory, "elsewhere.ag"))[0]
        .should.endWith("or by any longer start of 'wrong.thing'");
    problems("module geo.shapes\nimport units.length", ["geo.kit=geo/silver.toml"], shapes)[0]
        .should.endWith("\nGive `--uses geo=units` to list it");

    Packages packages;
    assert(describePackages(["geo=geo"], [], [], null, packages) is null);
    describePackageFiles(["geo"], packages).should.contain("--package-file takes a package and the file");
    describePackageFiles(["geo="], packages).should.contain("--package-file takes");
    describePackageFiles(["other=x/silver.toml"], packages).should.contain("'other', which no --package or --project declares");
    describePackageFiles([], packages).should.equal(null);
}


@("a file with no module line beside a library uses what the library uses and the library")
unittest
{
    auto directory = makeModuleDirectory("script-beside-library", [
        "geo/shapes.ag": "module geo.shapes\nimport units.length\ndef side(): Int => metre()",
        "units/length.ag": "module units.length\ndef metre(): Int => 1",
        "other/x.ag": "module other.x\ndef x(): Int => 2",
    ]);
    scope (exit) rmdirRecurse(directory);

    string[] problems(string source, string[] scriptUses = [], string start = "demo.ag", string[] homes = ["geo=geo"])
    {
        Packages packages;
        assert(describePackages(["geo=geo", "units=units", "other=other"], ["geo=units"] ~ scriptUses, [], directory,
            packages) is null);
        assert(describeScriptHomes(homes, directory, packages) is null);
        auto context = new SourceContext;
        auto file = buildPath(directory, start);
        load(source, file, packages, standardPrelude, context);
        return context.collector.errors.map!(e => cast(string) e.code ~ ": " ~ e.message).array;
    }
    immutable script = buildPath("geo", "demo.ag");
    problems("import geo.shapes\nimport units.length\nimport std.math\ndef main(): Unit {}", [], script).length
        .should.equal(0);
    problems("import other.x", [], script).should.equal([
        "L0010: 'demo' is a file with no `module` line under the directory of the library 'geo', so a program of its "
            ~ "own that uses what 'geo' uses and 'geo' itself, and uses no package but `lang`, 'units', 'geo' and "
            ~ "'std', and it can't import 'other.x', from the package 'other'\nList 'other' among what 'geo' uses\n"
            ~ "Give `--uses geo=other` to list it"]);
    // What the command line adds for a file with no module line still counts.
    problems("import other.x\nimport geo.shapes", ["other"], script).length.should.equal(0);
    // A file outside every directory given keeps only what it's given.
    problems("import geo.shapes")[0].should.startWith("L0010: 'demo' is a file with no `module` line, so a program of its own");
    // The deepest directory holding the file wins.
    problems("import units.length\nimport geo.shapes", [], buildPath("units", "demo.ag"), ["geo=.", "units=units"])[0]
        .should.contain("can't import 'geo.shapes'");
    problems("import geo.shapes", [], "demo.ag", ["geo=.", "units=units"]).length.should.equal(0);
    // A file with a module line is its package's, wherever it is.
    problems("module units.length\nimport geo.shapes", [], buildPath("units", "length.ag"), ["geo=."])[0]
        .should.startWith("L0010: The package 'units' uses no package but");
}

@("a file with no module line beside a program uses what the program uses, and can't use the program")
unittest
{
    auto directory = makeModuleDirectory("script-beside-program", [
        "shop/src/main.ag": "module shop.main\nimport units.length\ndef main(): Unit {}",
        "units/length.ag": "module units.length\ndef metre(): Int => 1",
    ]);
    scope (exit) rmdirRecurse(directory);

    string[] problems(string source, string[] scriptUses = [], string[] files = [])
    {
        Packages packages;
        assert(describePackages(["shop=shop/src", "units=units"], ["shop=units"] ~ scriptUses, [], directory,
            packages) is null);
        assert(describePackageFiles(files, packages) is null);
        assert(describeScriptHomes(["shop=shop"], directory, packages) is null);
        auto context = new SourceContext;
        load(source, buildPath(directory, "shop", "tryout.ag"), packages, standardPrelude, context);
        return context.collector.errors.map!(e => cast(string) e.code ~ ": " ~ e.message).array;
    }
    problems("import units.length\ndef main(): Unit {}").length.should.equal(0);
    problems("import shop.main").should.equal([
        "L0010: 'tryout' is a file with no `module` line under the directory of the package 'shop', and it can't import "
            ~ "'shop.main': 'shop.main' declares `main`, so 'shop' is a program, and nothing can use a program, not even "
            ~ "a file beside it\nA file beside a program uses only what the program uses: move what both need to a "
            ~ "library they use"]);
    auto listed = problems("import units.length", ["shop"]);
    listed.length.should.equal(1);
    listed[0].should.startWith("L0011: 'shop.main' declares `main`, so the package 'shop' is a program, and 'tryout', "
        ~ "the file started from, can't use it: nothing can depend on a program, not even a file beside it");
    problems("import std.math\nimport geo.x")[0].should.endWith("\nGive `--package geo=<directory>` to declare one");
    auto files = ["shop=shop/silver.toml", "units=units/silver.toml"];
    problems("import geo.x", [], files)[0].should.endWith("\nA file with no `module` line under the directory of the "
        ~ "package 'shop' uses what 'shop' uses\nList it in `uses` in shop/silver.toml, with a `[[package]]` entry "
        ~ "whose `path` is its directory there");
    problems("import shop.main", [], files)[0].should.contain("nothing can use a program");
}

@("--scripts-in names a declared package with modules, and a directory that holds them")
unittest
{
    auto directory = makeModuleDirectory("scripts-in-option", ["geo/shapes.ag": "module geo.shapes", "kit/a/x.ag": ""]);
    scope (exit) rmdirRecurse(directory);

    string mistake(string[] options)
    {
        Packages packages;
        assert(describePackages(["geo=geo", "kit.a=kit/a"], [], ["kit=kit.a"], directory, packages) is null);
        return describeScriptHomes(options, directory, packages);
    }
    mistake(["geo=geo"]).should.equal(null);
    mistake(["geo=.", "kit.a=kit"]).should.equal(null);
    mistake(["geo"]).should.contain("--scripts-in takes a package and a directory");
    mistake(["geo="]).should.contain("--scripts-in takes");
    mistake(["nope=geo"]).should.contain("'nope', which no --package or --project declares");
    // A package that only describes others may be given one, and a file there then uses only the standard library.
    mistake(["kit=kit"]).should.equal(null);
    mistake(["geo=kit"]).should.contain("which doesn't hold its modules");
    mistake(["geo=geo", "geo=."]).should.contain("names 'geo' twice");
    mistake(["geo=.", "kit.a=."]).should.contain("to both 'geo' and 'kit.a'");
}

@("a package's program starts from its module that declares main, or from the one package it describes that's a program")
unittest
{
    auto directory = makeModuleDirectory("program-start", [
        "app/main.ag": "module app.main\ndef main(): Unit {}",
        "app/util.ag": "module app.util\ndef one(): Int => 1",
        "root/package.ag": "module root\ndef main(): Unit {}",
        "geo/shapes.ag": "module geo.shapes\ndef sides(): Int => 4",
        "kit/a/x.ag": "module kit.a.x\ndef x(): Int => 1",
        "kit/b/main.ag": "module kit.b.main\ndef main(): Unit {}",
        "kit/c/src/main.ag": "module kit.c.main\ndef main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);

    string start(string name, string[] declared, string[] projects, out string chosen)
    {
        Packages packages;
        assert(describePackages(declared, [], projects, directory, packages) is null);
        auto context = new SourceContext;
        auto file = programStart(name, "run", packages, context, chosen);
        assert(context.collector.errors.empty, context.collector.errors.front.message);
        return file;
    }
    string chosen;
    start("app", ["app=app"], [], chosen).should.equal(buildPath(directory, "app", "main.ag"));
    chosen.should.equal("app");
    start("root", ["root=root"], [], chosen).should.equal(buildPath(directory, "root", "package.ag"));
    start("kit", ["kit.a=kit/a", "kit.b=kit/b"], ["kit=kit.a,kit.b"], chosen).should.equal(buildPath(directory, "kit/b",
        "main.ag"));
    chosen.should.equal("kit.b");
    // A described package is a package of its own, so its program is its own.
    start("kit.b", ["kit.a=kit/a", "kit.b=kit/b"], ["kit=kit.a,kit.b"], chosen).should.equal(buildPath(directory,
        "kit/b", "main.ag"));
}

@("a package with no program is reported as a library, and one with several lists them and says how to choose")
unittest
{
    auto directory = makeModuleDirectory("program-none-or-several", [
        "app/main.ag": "module app.main\ndef main(): Unit {}",
        "geo/shapes.ag": "module geo.shapes\ndef sides(): Int => 4",
        "geo/demo.ag": "def main(): Unit {}",
        "kit/a/x.ag": "module kit.a.x\ndef x(): Int => 1",
        "kit/b/main.ag": "module kit.b.main\ndef main(): Unit {}",
        "kit/c/src/main.ag": "module kit.c.main\ndef main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);

    string problem(string name, string[] declared, string[] projects, string[] homes = [], string[] files = [],
        string command = "run")
    {
        Packages packages;
        assert(describePackages(declared, [], projects, directory, packages) is null);
        assert(describePackageFiles(files, packages) is null);
        assert(describeScriptHomes(homes, directory, packages) is null);
        auto context = new SourceContext;
        string chosen;
        programStart(name, command, packages, context, chosen).should.equal(null);
        chosen.should.equal(null);
        auto errors = context.collector.errors.array;
        assert(errors.length == 1);
        return cast(string) errors[0].code ~ ": " ~ errors[0].message;
    }
    // A file with no module line is a program of its own, not the package's.
    problem("geo", ["geo=geo"], []).should.equal("L0014: The package 'geo' is a library: none of its modules declares "
        ~ "`main`, so it has no program to run\nIts tests are run with `silverc test`, given a directory or a file\n"
        ~ "A file with no `module` line is a program of its own, and is run by naming it, as `silverc run demo.ag`");
    problem("geo", ["geo=geo"], [], [], ["geo=silver.toml"], "build").should.equal("L0014: The package 'geo' is a "
        ~ "library: none of its modules declares `main`, so it has no program to build\nIts tests are run with "
        ~ "`silver test`\nA file with no `module` line is a program of its own, and is run by naming it, as `silver build demo.ag`");
    problem("kit", ["kit.a=kit/a"], ["kit=kit.a"]).should.equal("L0014: The package 'kit' only describes others, and "
        ~ "none of the packages it describes is a program: no module of theirs declares `main`, so there's no program "
        ~ "to run\nIts tests "
        ~ "are run with `silverc test`, given a directory or a file\nA file with no `module` line is a program of its own, and is run "
        ~ "by naming it, as `silverc run demo.ag`");
    problem("geo", ["geo=geo", "kit.a=kit/a"], ["geo=kit.a"]).should.startWith("L0014: The package 'geo' is a library, "
        ~ "and none of the packages it describes is a program: no module of it or of them declares `main`");

    auto kit = ["kit.a=kit/a", "kit.b=kit/b", "kit.c=kit/c/src"];
    auto b = buildPath(directory, "kit/b");
    auto c = buildPath(directory, "kit/c");
    problem("kit", kit, ["kit=kit.a,kit.b,kit.c"], ["kit.c=kit/c"]).should.equal("L0015: The package 'kit' holds more "
        ~ "than one program, so which to run has to be said:\n"
        ~ "  'kit.b', at " ~ b ~ ", whose `main` is in " ~ buildPath(b, "main.ag") ~ "\n"
        ~ "  'kit.c', at " ~ c ~ ", whose `main` is in " ~ buildPath(directory, "kit/c/src", "main.ag") ~ "\n"
        ~ "Choose one with `--program`, as `--program kit.b`");
    problem("kit", kit, ["kit=kit.a,kit.b,kit.c"], ["kit.b=kit/b"], ["kit.b=silver.toml"], "build")
        .should.endWith("\nChoose one by its directory, as `silver build " ~ b ~ "`");
    // The package's own program is among them, and is chosen by its file.
    auto itself = problem("app", ["app=app", "kit.b=kit/b"], ["app=kit.b"]);
    itself.should.contain("\n  'app' itself, whose `main` is in " ~ buildPath(directory, "app", "main.ag") ~ ", chosen "
        ~ "by naming that file\n  'kit.b', at " ~ b ~ ",");
    itself.should.endWith("\nChoose one with `--program`, as `--program kit.b`, or the program of 'app' itself by its "
        ~ "file, as `silverc run " ~ buildPath(directory, "app", "main.ag") ~ "`");
}

@("a package whose name ends in the segment package can't make a module named <package>.package")
unittest
{
    auto directory = makeModuleDirectory("package-named-package", [
        "cards/deck.ag": "module cards.deck",
        "inner/package.ag": "module cards.package",
        "middle/y.ag": "module cards.package.x.y",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto context = new SourceContext;
    auto program = load("import cards.package", "main.ag", Packages([Package("cards", buildPath(directory, "cards")),
        Package("cards.package", buildPath(directory, "inner"))], ["cards", "cards.package"]), null, context);
    assert(!context.collector.errors.empty, "the module 'cards.package' was accepted, as the package 'cards.package''s root");
    assert("cards.package" !in program.modules);
    context.collector.errors.map!(e => cast(string) e.code ~ ": " ~ e.message).array.should.equal([
        "L0013: 'cards.package' can't be a package's name: its last segment is `package`, and a package.ag is a "
            ~ "package's root module, so the name would be taken for one"]);

    context = new SourceContext;
    load("def f(): Int => 1", "main.ag", Packages([Package("package", buildPath(directory, "inner"))]), null, context);
    context.collector.errors.map!(e => e.code).array.should.equal([DiagnosticCode.InvalidPackages]);

    // A middle segment is an ordinary one, in a package's name as in a module's.
    context = new SourceContext;
    program = load("import cards.package.x.y", "main.ag", Packages([Package("cards.package.x",
        buildPath(directory, "middle"))], ["cards.package.x"]), null, context);
    context.collector.errors.empty.should.equal(true);
    assert("cards.package.x.y" in program.modules);
}

@("a script named after a package with no root module that imports the package isn't told to add a module line")
unittest
{
    auto directory = makeModuleDirectory("script-imports-missing-root", ["geo/shapes.ag": "module geo.shapes"]);
    scope (exit) rmdirRecurse(directory);

    auto script = buildPath(directory, "geo.ag");
    auto context = new SourceContext;
    load("import geo\ndef main(): Unit { }", script, Packages([Package("geo", buildPath(directory, "geo"))], ["geo"]),
        null, context);
    auto errors = context.collector.errors.array;
    errors.length.should.equal(1);
    // Adding `module geo` to geo.ag makes it claim to be geo/package.ag, which is L0003.
    errors[0].message.should.not.contain("Add `module geo`");
    errors[0].message.should.contain(buildPath(directory, "geo", "package.ag"));
    errors[0].message.should.equal(format("Module 'geo' not found: the package 'geo' has no root module, %s, and the "
        ~ "file started from, %s, has no `module` line, so it's named 'geo' after its file and couldn't import the root "
        ~ "module anyway\nRename %s, or import a module of the package, as 'geo.name' for %s",
        buildPath(directory, "geo", "package.ag"), script, script, buildPath(directory, "geo", "name.ag")));
}

@("a package.ag in the folder a module's name maps to says it belongs beside the folder, when imported or started from")
unittest
{
    auto directory = makeModuleDirectory("misplaced-root", ["geo/shapes/package.ag": "module geo.shapes"]);
    scope (exit) rmdirRecurse(directory);

    auto misplaced = buildPath(directory, "geo", "shapes", "package.ag");
    auto hint = format("\nThere's a %s, and a package.ag is a root module only in a package's own directory: a module "
        ~ "deeper in is the file beside the folder, so move it to %s", misplaced, buildPath(directory, "geo", "shapes.ag"));
    auto packages = Packages([Package("geo", buildPath(directory, "geo"))], ["geo"]);
    auto context = new SourceContext;
    load("import geo.shapes", "main.ag", packages, null, context);
    auto errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.ModuleNotFound]);
    errors[0].message.should.endWith(hint);

    context = new SourceContext;
    load(readText(misplaced), misplaced, packages, null, context);
    errors = context.collector.errors.array;
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.ModuleDeclarationMismatch]);
    errors[0].message.should.endWith(hint);

    context = new SourceContext;
    load("import geo.lines", "main.ag", packages, null, context);
    context.collector.errors.front.message.should.not.contain("root module");
}

@("a package with two modules that declare main has no one program to start from, and says which files")
unittest
{
    auto directory = makeModuleDirectory("program-two-mains", [
        "two/a.ag": "module two.a\ndef main(): Unit {}",
        "two/b.ag": "module two.b\ndef main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);

    Packages packages;
    assert(describePackages(["two=two"], [], [], directory, packages) is null);
    auto context = new SourceContext;
    string chosen;
    programStart("two", "run", packages, context, chosen).should.equal(null);
    auto errors = context.collector.errors.array;
    assert(errors.length == 1, "the first module declaring main was chosen silently");
    errors[0].code.should.equal(DiagnosticCode.SeveralMains);
    errors[0].message.should.startWith("The package 'two' has more than one module that declares `main`");
    errors[0].message.should.contain(buildPath(directory, "two", "a.ag"));
    errors[0].message.should.contain(buildPath(directory, "two", "b.ag"));
}

@("a starting file's module line is named by its package and path with . and .. resolved, relative or absolute")
unittest
{
    import std.file : getcwd;
    import std.path : relativePath;

    auto directory = makeModuleDirectory("packages-dotted-paths", [
        "geo/package.ag": "module geo",
        "geo/area.ag": "module geo.area",
        "geo/shapes/circle.ag": "module geo.shapes.circle\ndef main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);

    string[] problems(string source, string start, string geo)
    {
        Packages packages;
        assert(describePackages(["geo=" ~ geo], [], [], null, packages) is null);
        auto context = new SourceContext;
        load(source, start, packages, standardPrelude, context);
        return context.collector.errors.map!(e => e.message.idup).array;
    }
    string hint(string file, string geo, string name)
    {
        return format("\n%s is in the package 'geo', at %s, so its `module` line is `module %s`", file, geo, name);
    }
    // From the tests' working directory the temp directory is reached through `..`.
    auto relative = relativePath(directory, getcwd());
    foreach (base; [directory, relative])
    {
        foreach (geo; [buildPath(base, "geo"), buildPath(base, "geo", "."), buildPath(base, "geo", "shapes", "..")])
        {
            auto area = buildPath(base, "geo", "shapes", "..", "area.ag");
            problems("module area", area, geo).should.equal(["Module 'area' is in no package: no package is named "
                ~ "'area', or by any longer start of 'area'" ~ hint(area, geo, "geo.area")]);
            auto circle = buildPath(geo, "shapes", ".", "circle.ag");
            problems("module circle\ndef main(): Unit {}", circle, geo)[0]
                .should.endWith(hint(circle, geo, "geo.shapes.circle"));
            auto root = buildPath(base, "geo", ".", "package.ag");
            problems("module wrong", root, geo)[0].should.endWith(hint(root, geo, "geo"));
        }
    }
}

@("a package read for main finds its modules by their paths with . and .. resolved")
unittest
{
    import std.file : getcwd;
    import std.path : relativePath;

    auto directory = makeModuleDirectory("packages-dotted-main", [
        "geo/area.ag": "module geo.area",
        "geo/shapes/circle.ag": "module geo.shapes.circle\ndef main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto relative = relativePath(directory, getcwd());
    foreach (base; [directory, relative])
    {
        foreach (geo; [buildPath(base, "geo", "."), buildPath(base, "geo", "shapes", "..")])
        {
            Packages packages;
            assert(describePackages(["geo=" ~ geo], [], [], null, packages) is null);
            assert(describeScriptHomes(["geo=" ~ geo], null, packages) is null);
            auto context = new SourceContext;
            string chosen;
            programStart("geo", "run", packages, context, chosen).should.equal(buildPath(geo, "shapes", "circle.ag"));
            // The script beside it can't use it, since it's a program.
            context = new SourceContext;
            load("import geo.area\ndef main(): Unit {}", buildPath(base, "geo", "shapes", "..", "demo.ag"), packages,
                standardPrelude, context);
            context.collector.errors.map!(e => e.message.idup).array.should.equal([
                "'demo' is a file with no `module` line under the directory of the package 'geo', and it can't import "
                ~ "'geo.area': 'geo.shapes.circle' declares `main`, so 'geo' is a program, and nothing can use a program, "
                ~ "not even a file beside it\nA file beside a program uses only what the program uses: move what both "
                ~ "need to a library they use"]);
        }
    }
}

@("a syntax error in a module of a script's package is reported once, whether the script imports it or nothing")
unittest
{
    auto directory = makeModuleDirectory("packages-broken-once", [
        "kit/good.ag": "module kit.good\ndef f(): Int => 1",
        "kit/bad.ag": "module kit.bad\ndef = broken",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto kit = buildPath(directory, "kit");

    foreach (source; ["def main(): Unit {}", "import kit.bad\ndef main(): Unit {}", "import kit.good\ndef main(): Unit {}"])
    {
        Packages packages;
        assert(describePackages(["kit=" ~ kit], [], [], null, packages) is null);
        assert(describeScriptHomes(["kit=" ~ kit], null, packages) is null);
        auto context = new SourceContext;
        load(source, buildPath(kit, "s.ag"), packages, standardPrelude, context);
        auto errors = context.collector.errors.array;
        errors.map!(e => e.code).array.should.equal([DiagnosticCode.ParseError]);
        errors[0].span.file.should.equal(buildPath(kit, "bad.ag"));
    }
    // A script given the package by hand, with no directory to be beside, is told once too.
    Packages packages;
    assert(describePackages(["kit=" ~ kit], ["kit"], [], null, packages) is null);
    auto context = new SourceContext;
    load("import kit.bad\ndef main(): Unit {}", "main.ag", packages, standardPrelude, context);
    context.collector.errors.array.map!(e => e.code).array.should.equal([DiagnosticCode.ParseError]);
}

@("a module that can't be parsed leaves a package's program unknown, unless one main is found, which is started from")
unittest
{
    auto directory = makeModuleDirectory("program-unparseable", [
        "lone/main.ag": "module lone.main\ndef main(): Unit {\n  def = broken\n}",
        "lone/util.ag": "module lone.util\ndef one(): Int => 1",
        "app/main.ag": "module app.main\ndef main(): Unit {}",
        "app/bad.ag": "module app.bad\ndef = broken",
        "two/a.ag": "module two.a\ndef main(): Unit {}",
        "two/b.ag": "module two.b\ndef main(): Unit {}",
        "two/bad.ag": "module two.bad\ndef = broken",
        "kit/a/main.ag": "module kit.a.main\ndef main(): Unit {}",
        "kit/b/main.ag": "module kit.b.main\ndef main(): Unit {}",
        "kit/b/bad.ag": "module kit.b.bad\ndef = broken",
        "kit/c/bad.ag": "module kit.c.bad\ndef = broken",
    ]);
    scope (exit) rmdirRecurse(directory);

    string start(string name, string[] declared, string[] projects, out DiagnosticCode[] codes)
    {
        Packages packages;
        assert(describePackages(declared, [], projects, directory, packages) is null);
        auto context = new SourceContext;
        string chosen;
        auto file = programStart(name, "run", packages, context, chosen);
        codes = context.collector.errors.map!(e => cast() e.code).array;
        foreach (e; context.collector.errors)
        {
            if (e.code == DiagnosticCode.ParseError)
                e.message.should.endWith("It was read to find which module of '" ~ name ~ "' declares `main`");
        }
        return file;
    }
    DiagnosticCode[] codes;
    // The only module that declares main can't be parsed: not a library, just the parse error.
    start("lone", ["lone=lone"], [], codes).should.equal(null);
    codes.should.equal([DiagnosticCode.ParseError]);
    // Several mains, or several programs, with a module that can't be parsed: no listing that it might change.
    start("two", ["two=two"], [], codes).should.equal(null);
    codes.should.equal([DiagnosticCode.ParseError]);
    start("kit", ["kit.a=kit/a", "kit.b=kit/b"], ["kit=kit.a,kit.b"], codes).should.equal(null);
    codes.should.equal([DiagnosticCode.ParseError]);
    // One main found: it's started from, as naming its file would be.
    start("app", ["app=app"], [], codes).should.equal(buildPath(directory, "app", "main.ag"));
    codes.length.should.equal(0);
    start("kit", ["kit.a=kit/a", "kit.c=kit/c"], ["kit=kit.a,kit.c"], codes).should.equal(buildPath(directory, "kit/a",
        "main.ag"));
    codes.length.should.equal(0);

    // Loading the program then reports the module once if it's imported, and not at all if it isn't.
    foreach (imports; [false, true])
    {
        Packages packages;
        assert(describePackages(["app=app"], [], [], directory, packages) is null);
        auto context = new SourceContext;
        string chosen;
        auto file = programStart("app", "run", packages, context, chosen);
        auto source = (imports ? "module app.main\nimport app.bad\n" : "module app.main\n") ~ "def main(): Unit {}";
        try load(source, file, packages, standardPrelude, context);
        catch (DiagnosticException e) context.collector.report(e.diagnostic);
        auto expected = imports ? [DiagnosticCode.ParseError] : [];
        context.collector.errors.map!(e => cast() e.code).array.should.equal(expected);
    }
}

@("with silver driving, the hints for what no package file describes say what to write in a silver.toml, naming no option")
unittest
{
    auto directory = makeModuleDirectory("packages-silver-hints", [
        "geo/shapes.ag": "module geo.shapes",
        "units/length.ag": "module units.length",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto geo = buildPath(directory, "geo");
    auto shapes = buildPath(geo, "shapes.ag");
    auto declared = ["geo=" ~ geo, "units=" ~ buildPath(directory, "units")];

    string[] problems(string source, string[] declared, string[] uses, string[] files = [], string start = "main.ag",
        bool bySilver = true)
    {
        Packages packages;
        assert(describePackages(declared, uses, [], null, packages) is null);
        if (bySilver) describeSilver(packages);
        assert(describePackageFiles(files, packages) is null);
        auto context = new SourceContext;
        load(source, start, packages, standardPrelude, context);
        auto messages = context.collector.errors.map!(e => e.message.idup).array;
        if (bySilver) foreach (m; messages) assert(mentionsNoOption(m), m);
        return messages;
    }
    immutable lone = "\nA file in no project uses only the standard library. To use '%s', put a `silver.toml` at or "
        ~ "above it that names a package of its own, with '%s' in its `uses` and a `[[package]]` entry whose `path` is "
        ~ "the directory of '%s', whose own `silver.toml` names it";
    immutable listed = "\nTo use '%s', put a `silver.toml` at or above it that names a package of its own, with '%s' "
        ~ "in its `uses` and a `[[package]]` entry whose `path` is the directory of '%s', whose own `silver.toml` names it";
    // A script in no project, importing a package nothing declares, or one declared by hand.
    problems("import geometry.area", [], []).should.equal(["Module 'geometry.area' not found: no package is named "
        ~ "'geometry', or by any longer start of 'geometry.area'" ~ format(lone, "geometry", "geometry", "geometry")]);
    auto unlisted = problems("import geo.shapes", declared, []);
    unlisted.length.should.equal(1);
    unlisted[0].should.contain("'main' is a file with no `module` line, so a program of its own that uses no package "
        ~ "but `lang` and 'std', and it can't import 'geo.shapes'");
    unlisted[0].should.endWith(format(lone, "geo", "geo", "geo"));
    // Once it's given packages by hand, it no longer uses only the standard library.
    problems("import units.length", declared, ["geo"])[0].should.endWith(format(listed, "units", "units", "units"));
    problems("def main(): Unit {}", declared, ["nope"])[0].should.endWith(format(listed, "nope", "nope", "nope"));
    // A module of a package declared by hand.
    problems("module geo.shapes\nimport units.length", declared, [], [], shapes)[0].should.endWith("\nList 'units' "
        ~ "among what 'geo' uses\n'geo' is described in no `silver.toml`, and what a package uses is listed in its "
        ~ "`silver.toml`, as `uses`, with a `[[package]]` entry for each package it uses");
    immutable undeclared = "\n'geo' is described in no `silver.toml`, and a package it uses is listed in its "
        ~ "`silver.toml`, as `uses`, with a `[[package]]` entry whose `path` is its directory";
    problems("module geo.shapes\nimport shapes.circle", declared, [], [], shapes)[0].should.endWith(undeclared);
    problems("def main(): Unit {}", declared, ["geo=nope"])[0].should.endWith(undeclared);
    // A starting file whose module line names no package, in no package's directory.
    problems("module app.main", [], [], [], buildPath(directory, "app", "main.ag")).should.equal(["Module 'app.main' "
        ~ "is in no package: no package is named 'app', or by any longer start of 'app.main'\nA file in no project is in "
        ~ "no package: a package is a directory with a `silver.toml` that names it, as `name = \"app\"`, and a file with "
        ~ "no `module` line is a program of its own"]);
    // In a package's directory, it's told its name, as by hand.
    problems("module shapes", declared, [], [], shapes)[0].should.endWith("so its `module` line is `module geo.shapes`");
    // What a package file describes is named by it, as before.
    auto files = ["geo=geo/silver.toml", "units=units/silver.toml"];
    problems("module geo.shapes\nimport units.length", declared, [], files, shapes)[0].should.endWith("\nThat list is "
        ~ "`uses` in geo/silver.toml, with a `[[package]]` entry for 'units' there if it has none");
    problems("import geo.shapes", declared, [], files)[0].should.endWith("\nA file with no `module` line that's under "
        ~ "no package's directory uses only the standard library, so one that needs 'geo' belongs under the directory "
        ~ "of that package or of one that uses it");
    // By hand, the options are named as they always were.
    problems("import geometry.area", [], [], [], "main.ag", false)[0]
        .should.endWith("\nGive `--package geometry=<directory>` to declare one");
    problems("import geo.shapes", declared, [], [], "main.ag", false)[0].should.endWith("\nGive `--uses geo` to list it");
}

@("the module-line hint doesn't offer a name that can't be a module's, from a folder or file name or the path's case")
unittest
{
    auto directory = makeModuleDirectory("review-hint-segments", [
        "geo/my-shapes/a.ag": "module a",
        "geo/my shapes/a.ag": "module a",
        // Not Shapes: on Windows that would be the folder shapes below.
        "geo/Rings/a.ag": "module a",
        "geo/2d/a.ag": "module a",
        "geo/ok/My-File.ag": "module a",
        "geo/shapes/circle.ag": "module a",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto geo = buildPath(directory, "geo");

    string message(string file)
    {
        Packages packages;
        assert(describePackages(["geo=" ~ geo], [], [], null, packages) is null);
        auto context = new SourceContext;
        load("module a\ndef main(): Unit {}", file, packages, standardPrelude, context);
        return context.collector.errors.map!(e => e.message.idup).array.join("\n");
    }
    foreach (bad; ["my-shapes/a", "my shapes/a", "Rings/a", "2d/a", "ok/My-File"])
    {
        auto file = buildPath(geo, bad ~ ".ag");
        auto text = message(file);
        auto segment = bad.split("/");
        immutable what = segment[1] == "a" ? "folder" : "file";
        assert(text.endsWith(format("
%s is in the package 'geo', at %s, and its `module` line would be named by its "
            ~ "path there, but the %s name '%s' can't be part of a module's name, which starts each part with a "
            ~ "lowercase letter or `_` followed by letters, digits and `_`
Rename the %s", file, geo, what,
            what == "folder" ? segment[0] : segment[1], what)), text);
    }
    // The name comes from the file as it is on disk, not as the path given spells it.
    version (Windows)
    {
        auto text = message(buildPath(geo, "SHAPES", "Circle.ag"));
        assert(text.canFind("`module geo.shapes.circle`"), text);
    }
}

@("a file whose module line names no package is told where its package's modules go, or that it's beside a package that only describes others")
unittest
{
    auto directory = makeModuleDirectory("packages-hint-homes", [
        "shop/src/main.ag": "module shop.main",
        "kit/a/x.ag": "module kit.a.x",
    ]);
    scope (exit) rmdirRecurse(directory);

    string[] problems(string source, string start, string[] homes)
    {
        Packages packages;
        assert(describePackages(["shop=" ~ buildPath("shop", "src"), "kit.a=" ~ buildPath("kit", "a")], [], ["kit=kit.a"],
            directory, packages) is null);
        assert(describePackageFiles(["shop=shop/silver.toml", "kit=kit/silver.toml", "kit.a=kit/silver.toml"],
            packages) is null);
        assert(describeScriptHomes(homes, directory, packages) is null);
        auto context = new SourceContext;
        load(source, buildPath(directory, start), packages, standardPrelude, context);
        return context.collector.errors.map!(e => e.message.idup).array;
    }
    auto other = buildPath(directory, "shop", "other.ag");
    problems("module other", buildPath("shop", "other.ag"), ["shop=shop"]).should.equal(["Module 'other' is in no "
        ~ "package: no package is named 'other', or by any longer start of 'other'
" ~ other ~ " is under the "
        ~ "directory of the package 'shop', at " ~ buildPath(directory, "shop") ~ ", whose modules are under "
        ~ buildPath(directory, "shop", "src") ~ ", so a module of 'shop' belongs there, as "
        ~ buildPath(directory, "shop", "src", "name.ag") ~ " for `module shop.name`"]);
    problems("import kit.a.x", "kit/s.ag", ["kit=kit", "kit.a=kit/a"]).should.equal(["'s' is a file with no `module` "
        ~ "line, so a program of its own that uses no package but `lang` and 'std', and it can't import 'kit.a.x', from "
        ~ "the package 'kit.a'
A file with no `module` line under the directory of 'kit', a package that only describes "
        ~ "others, uses only the standard library, so one that needs 'kit.a' belongs under the directory of one of "
        ~ "the packages it describes, 'kit.a', or of a package that uses it"]);
}
