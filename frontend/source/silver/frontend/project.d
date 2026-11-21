/// Finds a project's package file, reads and checks it, follows every package it uses to the file
/// that describes that package, and turns what it found into the compiler's options. It reports,
/// located in the package file, only what it sees by reading files; every rule about packages
/// themselves (cycles, a package that uses a program, directories inside one another) is left to
/// the compiler, which is given the facts.
module silver.frontend.project;

import silver.frontend.toml;

/// The name of a package file.
enum packageFileName = "silver.toml";

/// The standard library's package, which every package uses without listing it and the compiler
/// adds itself.
enum standardPackage = "std";

/// A stable ID for each kind of mistake in what a package file says, after the TOML codes.
enum ProjectCode : string
{
    /// The file couldn't be read.
    Unreadable = "F0015",
    UnknownField = "F0016",
    WrongType = "F0017",
    MissingField = "F0018",
    BadName = "F0019",
    /// A `source` or a part's `path` that isn't under the directory it's taken from.
    OutsideDirectory = "F0020",
    NotADirectory = "F0021",
    /// Two packages of one file with one name, or a name listed twice.
    DuplicateName = "F0022",
    /// Two parts at one path.
    SamePath = "F0023",
    /// A part's directory, or a `source`, in or under a directory with a package file of its own
    /// below the file that names it, so that the other file's package would hold its files.
    UnderPackageFile = "F0024",
    /// A name in `uses` that's neither a part, nor under `[paths]`, nor the standard library.
    UnknownPackage = "F0025",
    /// A directory under `[paths]` that no package file describes.
    NoPackageThere = "F0026",
    /// A directory under `[paths]` whose package file describes a package of another name there.
    WrongPackageThere = "F0027",
    /// One package name reached at two directories.
    TwoDirectories = "F0028",
    /// The standard library in `uses` or under `[paths]`.
    StandardLibraryListed = "F0029",
    /// A name under `[paths]` that's the file's own package or one of its parts.
    PathForOwnPackage = "F0030",
    /// `uses` on a package that has parts and no `source`, so no modules to use anything.
    UsesWithoutModules = "F0031",
    /// An empty string where a directory goes.
    EmptyDirectory = "F0032",
    /// No file named, and no package file at or above the working directory.
    NoProject = "F0033",
    /// A directory given to `run` or `build` that's no package's or part's directory.
    NotAPackageDirectory = "F0034",
    /// A package reached through `[paths]` whose directory is inside, or holds, the directory of a
    /// package whose modules are its whole directory.
    InsidePackage = "F0035",
    /// `--package`, `--uses` or `--parts` given by hand inside a project.
    PackageOptionGiven = "F0036",
}

/// One mistake in a package file, or in reading one.
struct Mistake
{
    string file;
    string code;
    /// Where in `file`; line 0 when the mistake has no place in it, as when it can't be read.
    Span span;
    string message;
}

/// `mistake` as the compiler gives its diagnostics, with its file shown as `shown` gives it.
string formatMistake(const Mistake mistake, string delegate(string) shown = null)
{
    if (mistake.file is null) return "Error " ~ mistake.code ~ ": " ~ mistake.message;
    auto file = shown is null ? mistake.file : shown(mistake.file);
    if (mistake.span.line == 0) return file ~ ": Error " ~ mistake.code ~ ": " ~ mistake.message;
    return formatTomlError(file, TomlError(cast(TomlCode) mistake.code, mistake.span, mistake.message));
}

/// A name in a package file and where it's written.
struct Named
{
    string name;
    Span span;
}

/// A `[[part]]` of a package file.
struct Part
{
    Named name;
    /// The part's directory, absolute.
    string directory;
    Span pathSpan;
    /// Where its modules are, absolute: `directory`, or its `source` under it.
    string modules;
    Named[] uses;
    /// The `[[part]]` header, or the inline table.
    Span span;
}

/// An entry under `[paths]`.
struct PathEntry
{
    Named name;
    /// The directory, absolute.
    string directory;
    /// The value as written.
    Span span;
}

/// What a package file says, checked.
struct PackageFile
{
    /// The file, absolute.
    string file;
    string directory;
    Named name;
    /// Where the package's own modules are, absolute, or null when it only holds its parts.
    string modules;
    Named[] uses;
    PathEntry[] paths;
    Part[] parts;
}

/// The facts the compiler is given about one package.
struct Facts
{
    string name;
    /// Where its modules are, absolute, or null when it only holds its parts.
    string directory;
    string[] uses;
    string[] parts;
    /// The package file that describes it.
    string file;
    /// The directory `[paths]` names it by: its file's for a package, and its `path` for a part.
    string home;
}

/// Every package reachable from a project's package file: the file's own package and parts first,
/// then the packages they use, each with the packages of its file, in the order they were reached.
struct Project
{
    string file;
    Facts[] packages;
}

/// The package file in `directory` or in the nearest directory above it, absolute, or null.
string findPackageFile(string directory)
{
    import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;

    auto at = buildNormalizedPath(absolutePath(directory));
    while (true)
    {
        auto candidate = buildPath(at, packageFileName);
        if (isFile(candidate)) return candidate;
        auto above = dirName(at);
        if (above == at) return null;
        at = above;
    }
}

/// Reads the package file `file` and checks what it says.
bool readPackageFile(string file, out PackageFile result, out Mistake mistake)
{
    import std.file : read;
    import std.path : absolutePath, buildNormalizedPath;

    file = buildNormalizedPath(absolutePath(file));
    string text;
    try
    {
        text = cast(string) read(file);
    }
    catch (Exception e)
    {
        mistake = Mistake(file, ProjectCode.Unreadable, Span(), "The package file can't be read: " ~ e.msg);
        return false;
    }
    return checkPackageFile(file, text, result, mistake);
}

/// Checks `text`, the package file `file` (absolute), and the directories it names.
bool checkPackageFile(string file, string text, out PackageFile result, out Mistake mistake)
{
    auto document = readToml(text);
    if (document.failed)
    {
        mistake = Mistake(file, document.error.code, document.error.span, document.error.message);
        return false;
    }
    auto checker = Checker(file);
    if (!checker.check(document.root))
    {
        mistake = checker.mistake;
        return false;
    }
    result = checker.result;
    return true;
}

/// Reads the project whose package file is `file`, and every package file its packages lead to.
bool readProject(string file, out Project project, out Mistake mistake)
{
    PackageFile root;
    if (!readPackageFile(file, root, mistake)) return false;
    auto reader = ProjectReader();
    if (!reader.add(root, mistake)) return false;
    project = Project(root.file, reader.packages);
    return true;
}

/// The packages and parts whose files with no `module` line `path` may hold: the one
/// whose home holds `path`, the deepest when several do, and when `path` is a directory, each whose
/// home is inside it. A script is beside the package whose home it's under, so a script beside a
/// `silver.toml` whose package keeps its modules in `source` is beside that package.
const(Facts)[] scriptHomes(const Project project, string path)
{
    import std.path : absolutePath, buildNormalizedPath;

    path = buildNormalizedPath(absolutePath(path));
    const(Facts)* deepest;
    const(Facts)[] inside;
    foreach (ref p; project.packages)
    {
        if (within(path, p.home))
        {
            if (deepest is null || segments(p.home).length > segments(deepest.home).length) deepest = &p;
        }
        else if (within(p.home, path))
        {
            inside ~= p;
        }
    }
    return deepest is null ? inside : *deepest ~ inside;
}

/// The package or part of the project's own file whose home holds `directory`, the deepest, or the
/// file's package when none does: the package `silver` is started in there.
const(Facts)* startedIn(const Project project, string directory)
{
    import std.path : absolutePath, buildNormalizedPath;

    directory = buildNormalizedPath(absolutePath(directory));
    const(Facts)* deepest;
    foreach (ref p; project.packages)
    {
        if (!samePath(p.file, project.file) || !within(directory, p.home)) continue;
        if (deepest is null || segments(p.home).length > segments(deepest.home).length) deepest = &p;
    }
    return deepest is null ? &project.packages[0] : deepest;
}

/// The package or part of the project's own file whose home is `directory`, or null.
const(Facts)* homedAt(const Project project, string directory)
{
    foreach (ref p; project.packages)
    {
        if (samePath(p.file, project.file) && samePath(p.home, directory)) return &p;
    }
    return null;
}

/// The packages and parts of the project's own file, each with its home as `shown` gives it, as a
/// list for a message.
string homesOf(const Project project, string delegate(string) shown)
{
    import std.array : join;

    string[] listed;
    foreach (ref p; project.packages)
    {
        if (samePath(p.file, project.file)) listed ~= quoted(p.name) ~ " at " ~ shown(p.home);
    }
    return listed.join(", ");
}

/// `package_` and its parts, those with modules, whose homes the compiler is told so that what it
/// says about their programs names the directories they're chosen by.
const(Facts)[] programHomes(const Project project, const Facts package_)
{
    const(Facts)[] homes;
    foreach (ref p; project.packages)
    {
        if (p.directory is null) continue;
        bool part;
        foreach (name; package_.parts) part = part || name == p.name;
        if (part || p.name == package_.name) homes ~= p;
    }
    return homes;
}

/// The directories under `directory` with a package file that `project` didn't read, each another
/// project, the outermost only: a directory with one isn't looked into.
string[] otherProjects(const Project project, string directory)
{
    import std.algorithm : any, sort;
    import std.file : dirEntries, SpanMode;
    import std.path : absolutePath, buildNormalizedPath, buildPath;

    string[] found;
    void walk(string at)
    {
        string[] inner;
        try
        {
            foreach (entry; dirEntries(at, SpanMode.shallow, false))
            {
                if (entry.isDir) inner ~= entry.name;
            }
        }
        catch (Exception)
        {
            return;
        }
        foreach (sub; inner.sort)
        {
            auto file = buildPath(sub, packageFileName);
            if (isFile(file) && !project.packages.any!(p => samePath(p.file, file)) && !samePath(project.file, file))
                found ~= sub;
            else
                walk(sub);
        }
    }
    walk(buildNormalizedPath(absolutePath(directory)));
    return found;
}

/// The compiler's options for `project`: each package's directory, uses, parts and file, and the
/// home of each of `homes` as a directory of files beside it, with paths as `shown` gives them.
string[] compilerOptions(const Project project, string delegate(string) shown, const Facts[] homes = null)
{
    import std.array : join;

    string[] options;
    foreach (ref p; project.packages)
    {
        if (p.directory !is null) options ~= ["--package", p.name ~ "=" ~ shown(p.directory)];
    }
    foreach (ref p; project.packages)
    {
        if (p.uses.length > 0) options ~= ["--uses", p.name ~ "=" ~ p.uses.join(",")];
    }
    foreach (ref p; project.packages)
    {
        if (p.parts.length > 0) options ~= ["--parts", p.name ~ "=" ~ p.parts.join(",")];
    }
    foreach (ref p; project.packages)
    {
        options ~= ["--package-file", p.name ~ "=" ~ shown(p.file)];
    }
    foreach (ref p; homes) options ~= ["--scripts-in", p.name ~ "=" ~ shown(p.home)];
    return options;
}

/// `path` relative to `workingDirectory` when it's inside it, which is shorter; otherwise as it is.
string shownFrom(string workingDirectory, string path)
{
    import std.path : absolutePath, buildNormalizedPath, relativePath;

    auto base = buildNormalizedPath(absolutePath(workingDirectory));
    if (!within(path, base)) return path;
    auto relative = relativePath(path, base);
    return relative.length == 0 ? "." : relative;
}

/// Whether the path `inner` is `outer` or inside it, comparing names as the file system does.
bool within(string inner, string outer)
{
    import std.path : filenameCmp;

    auto i = segments(inner);
    auto o = segments(outer);
    if (o.length > i.length) return false;
    foreach (k, segment; o)
    {
        if (filenameCmp(segment, i[k]) != 0) return false;
    }
    return true;
}

/// Whether `a` and `b` are the same path, comparing names as the file system does.
bool samePath(string a, string b) => within(a, b) && within(b, a);

/// Whether `name` is a package's name: names joined by `.`, each a letter or `_` and then letters,
/// digits and `_`, as the compiler requires.
bool validName(string name)
{
    import std.algorithm : all, splitter;
    import std.ascii : isAlpha, isAlphaNum;

    if (name.length == 0) return false;
    foreach (segment; name.splitter('.'))
    {
        if (segment.length == 0 || !(isAlpha(segment[0]) || segment[0] == '_')
            || !segment.all!(c => isAlphaNum(c) || c == '_'))
            return false;
    }
    return true;
}

private:

string[] segments(string path)
{
    import std.array : array;
    import std.path : buildNormalizedPath, pathSplitter;

    return pathSplitter(buildNormalizedPath(path)).array;
}

bool isFile(string path)
{
    import std.file : exists, isFile;

    try return exists(path) && isFile(path);
    catch (Exception) return false;
}

bool isDirectory(string path)
{
    import std.file : exists, isDir;

    try return exists(path) && isDir(path);
    catch (Exception) return false;
}

/// `written`, a directory as a package file gives it, taken from `base`, absolute and normalized.
string directoryFrom(string base, string written)
{
    import std.path : absolutePath, buildNormalizedPath;

    return buildNormalizedPath(absolutePath(written, base));
}

string quoted(string name) => "'" ~ name ~ "'";

/// A package file in `inner` or a directory above it short of `outer`, or null.
string packageFileBetween(string inner, string outer)
{
    import std.path : buildPath, dirName;

    for (auto at = inner; within(at, outer) && !samePath(at, outer); at = dirName(at))
    {
        auto file = buildPath(at, packageFileName);
        if (isFile(file)) return file;
        if (dirName(at) == at) break;
    }
    return null;
}

/// Where a mistake with no better place in a file goes: its first character.
enum fileStart = Span(0, 0, 1, 1);

struct Checker
{
    string file;
    PackageFile result;
    Mistake mistake;

    bool fail(string code, Span span, string message)
    {
        mistake = Mistake(file, code, span, message);
        return false;
    }

    bool check(Table root)
    {
        import std.path : dirName;

        result.file = file;
        result.directory = dirName(file);
        const(Value)* source;
        Span sourceKey;
        foreach (ref entry; root.entries)
        {
            switch (entry.key)
            {
                case "name":
                    if (!name(entry.value, result.name)) return false;
                    break;
                case "source":
                    source = &entry.value;
                    sourceKey = entry.keySpan;
                    break;
                case "uses":
                    if (!uses(entry.value, result.uses)) return false;
                    break;
                case "paths":
                    if (!paths(entry.value)) return false;
                    break;
                case "part":
                    if (!parts(entry.value)) return false;
                    break;
                default:
                    return unknown(entry, "A package file has `name`, `source`, `uses`, `[paths]` and `[[part]]`");
            }
        }
        if (result.name.name is null)
        {
            return fail(ProjectCode.MissingField, fileStart, "A package file has to give the package's `name`, as "
                ~ "name = \"geometry\"");
        }
        if (source !is null)
        {
            if (!directory(*source, "`source`", result.directory, "the package file's directory", true, result.modules))
                return false;
        }
        else if (result.parts.length == 0)
        {
            result.modules = result.directory;
        }
        if (result.modules is null && result.uses.length > 0)
        {
            return fail(ProjectCode.UsesWithoutModules, root.entry("uses").keySpan, "The package "
                ~ quoted(result.name.name) ~ " has parts and no `source`, so it has no modules of its own to use "
                ~ "anything; list what each part uses in its `uses`, or give the package a `source`");
        }
        return names();
    }

    bool unknown(const ref Entry entry, string known)
    {
        return fail(ProjectCode.UnknownField, entry.keySpan, "`" ~ entry.key ~ "` isn't a field of a package file. "
            ~ known);
    }

    bool str(const ref Value value, string what)
    {
        if (value.kind == ValueKind.string_) return true;
        return fail(ProjectCode.WrongType, value.span, what ~ " is a string, in quotes");
    }

    bool name(const ref Value value, out Named named)
    {
        if (!str(value, "A package's `name`")) return false;
        if (!validName(value.text))
        {
            return fail(ProjectCode.BadName, value.span, "\"" ~ value.text ~ "\" isn't a package name: it's one or "
                ~ "more names joined by `.`, each a letter or `_` and then letters, digits and `_`, as \"silver.core\"");
        }
        named = Named(value.text, value.span);
        return true;
    }

    bool uses(const ref Value value, out Named[] list)
    {
        if (value.kind != ValueKind.array)
        {
            return fail(ProjectCode.WrongType, value.span, "`uses` is a list of package names, as uses = [\"geometry\"]");
        }
        foreach (ref item; value.items)
        {
            if (item.kind != ValueKind.string_)
            {
                return fail(ProjectCode.WrongType, item.span, "`uses` is a list of package names, each a string in "
                    ~ "quotes");
            }
            Named named;
            if (!name(item, named)) return false;
            if (named.name == standardPackage)
            {
                return fail(ProjectCode.StandardLibraryListed, item.span, "The standard library, `std`, isn't listed: "
                    ~ "every package uses it");
            }
            foreach (ref earlier; list)
            {
                if (earlier.name == named.name)
                {
                    return fail(ProjectCode.DuplicateName, item.span, quoted(named.name) ~ " is listed twice, at "
                        ~ "column " ~ decimal(earlier.span.column) ~ (earlier.span.line == item.span.line ? ""
                        : " of line " ~ decimal(earlier.span.line)));
                }
            }
            list ~= named;
        }
        return true;
    }

    bool paths(const ref Value value)
    {
        if (value.kind != ValueKind.table)
        {
            return fail(ProjectCode.WrongType, value.span, "`paths` is a table of package names and directories, "
                ~ "written [paths]");
        }
        foreach (ref entry; value.table.entries)
        {
            if (entry.value.kind == ValueKind.table)
            {
                return fail(ProjectCode.WrongType, entry.keySpan, "`" ~ entry.key ~ "` holds a table, not a "
                    ~ "directory: a name of more than one segment is quoted under [paths], as \"" ~ entry.key
                    ~ ".name\" = \"../" ~ entry.key ~ "/name\"");
            }
            if (!str(entry.value, "A directory under [paths]")) return false;
            if (entry.value.text.length == 0)
            {
                return fail(ProjectCode.EmptyDirectory, entry.value.span, "The directory of " ~ quoted(entry.key)
                    ~ " under [paths] is \"\", which names none; give where it is, as \"../" ~ entry.key ~ "\"");
            }
            if (!validName(entry.key))
            {
                return fail(ProjectCode.BadName, entry.keySpan, "\"" ~ entry.key ~ "\" isn't a package name: it's one "
                    ~ "or more names joined by `.`, as \"silver.core\"");
            }
            if (entry.key == standardPackage)
            {
                return fail(ProjectCode.StandardLibraryListed, entry.keySpan, "The standard library, `std`, ships with "
                    ~ "the compiler and needs no path");
            }
            result.paths ~= PathEntry(Named(entry.key, entry.keySpan), directoryFrom(result.directory,
                entry.value.text), entry.value.span);
        }
        return true;
    }

    bool parts(const ref Value value)
    {
        if (value.kind != ValueKind.array || !(value.ofTables || allTables(value)))
        {
            return fail(ProjectCode.WrongType, value.span, "`part` is a list of parts, each written under [[part]]");
        }
        foreach (ref item; value.items)
        {
            if (!part(item)) return false;
        }
        return true;
    }

    static bool allTables(const ref Value value)
    {
        foreach (ref item; value.items)
        {
            if (item.kind != ValueKind.table) return false;
        }
        return true;
    }

    bool part(const ref Value value)
    {
        Part p;
        p.span = value.span;
        const(Value)* path;
        const(Value)* source;
        foreach (ref entry; value.table.entries)
        {
            switch (entry.key)
            {
                case "name":
                    if (!name(entry.value, p.name)) return false;
                    break;
                case "path":
                    if (!str(entry.value, "A part's `path`")) return false;
                    path = &entry.value;
                    break;
                case "source":
                    source = &entry.value;
                    break;
                case "uses":
                    if (!uses(entry.value, p.uses)) return false;
                    break;
                default:
                    return unknown(entry, "A part has `name`, `path`, `source` and `uses`");
            }
        }
        if (p.name.name is null)
        {
            return fail(ProjectCode.MissingField, value.span, "A part has to give its `name`, as name = \"silver.core\"");
        }
        if (path is null)
        {
            return fail(ProjectCode.MissingField, value.span, "The part " ~ quoted(p.name.name) ~ " has to give its "
                ~ "`path`, the directory it's in, as path = \"core\"");
        }
        p.pathSpan = path.span;
        if (!directory(*path, "A part's `path`", result.directory, "the package file's directory", false, p.directory))
            return false;
        if (source is null) p.modules = p.directory;
        else if (!directory(*source, "A part's `source`", p.directory, "the part's directory", true, p.modules))
            return false;
        result.parts ~= p;
        return true;
    }

    /// Checks `value`, a directory under `base`, and puts it in `found`, absolute. `self` says
    /// whether it may be `base` itself.
    bool directory(const ref Value value, string what, string base, string baseName, bool self, out string found)
    {
        if (!str(value, what)) return false;
        if (value.text.length == 0)
        {
            return fail(ProjectCode.EmptyDirectory, value.span, what ~ " names a directory, and \"\" names none"
                ~ (self ? "; leave it out to mean " ~ baseName : ", as \"core\""));
        }
        auto at = directoryFrom(base, value.text);
        if (!within(at, base) || (!self && samePath(at, base)))
        {
            return fail(ProjectCode.OutsideDirectory, value.span, what ~ " is a directory " ~ (self ? "in" : "under")
                ~ " " ~ baseName ~ ", " ~ base ~ ", and " ~ at ~ " isn't");
        }
        if (!isDirectory(at))
        {
            return fail(ProjectCode.NotADirectory, value.span, what ~ " is " ~ at ~ ", which isn't a directory");
        }
        if (auto other = packageFileBetween(at, result.directory))
        {
            import std.path : dirName;

            return fail(ProjectCode.UnderPackageFile, value.span, what ~ " is " ~ at ~ ", and " ~ other ~ " would make "
                ~ (samePath(dirName(other), at) ? "it" : "a directory above it") ~ " a package of its own, holding "
                ~ "its files; a part is described only in its parent's file, and a directory with a package file is "
                ~ "used through [paths]");
        }
        found = at;
        return true;
    }

    /// Checks that the file's package and parts have different names and paths, and that `[paths]`
    /// names none of them.
    bool names()
    {
        foreach (k, ref p; result.parts)
        {
            if (p.name.name == result.name.name)
            {
                return fail(ProjectCode.DuplicateName, p.name.span, "A part can't have its package's own name, "
                    ~ quoted(p.name.name));
            }
            foreach (ref earlier; result.parts[0 .. k])
            {
                if (earlier.name.name == p.name.name)
                {
                    return fail(ProjectCode.DuplicateName, p.name.span, "There's already a part named "
                        ~ quoted(p.name.name) ~ ", at line " ~ decimal(earlier.name.span.line));
                }
                if (samePath(earlier.directory, p.directory))
                {
                    return fail(ProjectCode.SamePath, p.pathSpan, "The parts " ~ quoted(earlier.name.name) ~ " and "
                        ~ quoted(p.name.name) ~ " are both at " ~ p.directory);
                }
            }
        }
        foreach (ref entry; result.paths)
        {
            if (entry.name.name == result.name.name || ownPart(entry.name.name) !is null)
            {
                return fail(ProjectCode.PathForOwnPackage, entry.name.span, quoted(entry.name.name) ~ " is "
                    ~ (entry.name.name == result.name.name ? "this file's own package" : "a part in this file")
                    ~ ", so it needs no path");
            }
        }
        return true;
    }

    const(Part)* ownPart(string name) const
    {
        foreach (ref p; result.parts)
        {
            if (p.name.name == name) return &p;
        }
        return null;
    }
}

/// Follows the packages of files, file by file, reading each file once.
struct ProjectReader
{
    Facts[] packages;
    PackageFile[] files;

    const(Facts)* named(string name) const
    {
        foreach (ref p; packages)
        {
            if (p.name == name) return &p;
        }
        return null;
    }

    PackageFile* alreadyRead(string file)
    {
        foreach (ref f; files)
        {
            if (samePath(f.file, file)) return &f;
        }
        return null;
    }

    /// Adds the packages of `file`, then follows what each uses.
    bool add(PackageFile file, out Mistake mistake)
    {
        import std.algorithm : map;
        import std.array : array;

        files ~= file;
        bool declare(Named name, string home, string modules, Named[] uses, string[] parts)
        {
            if (auto other = named(name.name))
            {
                mistake = Mistake(file.file, ProjectCode.TwoDirectories, name.span, "There's already a package named "
                    ~ quoted(name.name) ~ ", at " ~ other.home ~ ", described in " ~ other.file);
                return false;
            }
            packages ~= Facts(name.name, modules, uses.map!(u => u.name).array, parts, file.file, home);
            return true;
        }
        if (!declare(file.name, file.directory, file.modules, file.uses, file.parts.map!(p => p.name.name).array))
            return false;
        foreach (ref p; file.parts)
        {
            if (!declare(p.name, p.directory, p.modules, p.uses, null)) return false;
        }
        if (!follow(file, file.uses, mistake)) return false;
        foreach (ref p; file.parts)
        {
            if (!follow(file, p.uses, mistake)) return false;
        }
        return true;
    }

    /// Finds each of `uses`, listed in `file`.
    bool follow(const ref PackageFile file, const Named[] uses, out Mistake mistake)
    {
        foreach (used; uses)
        {
            bool own = used.name == file.name.name;
            foreach (ref p; file.parts) own = own || p.name.name == used.name;
            if (own) continue;
            const(PathEntry)* entry;
            foreach (ref e; file.paths)
            {
                if (e.name.name == used.name) entry = &e;
            }
            if (entry is null)
            {
                mistake = Mistake(file.file, ProjectCode.UnknownPackage, used.span, quoted(used.name) ~ " is neither "
                    ~ "a part in this file nor under [paths]; say where it is there, as \"" ~ used.name
                    ~ "\" = \"../" ~ used.name ~ "\"");
                return false;
            }
            if (!reach(file, *entry, mistake)) return false;
        }
        return true;
    }

    /// Finds the package `entry` names at its directory, and reads its file unless it has been.
    bool reach(const ref PackageFile from, const ref PathEntry entry, out Mistake mistake)
    {
        import std.path : buildPath, dirName;

        bool fail(string code, string message)
        {
            mistake = Mistake(from.file, code, entry.span, message);
            return false;
        }
        immutable name = entry.name.name;
        immutable directory = entry.directory;
        if (!isDirectory(directory))
        {
            return fail(ProjectCode.NotADirectory, quoted(name) ~ " is at " ~ directory ~ ", which isn't a directory");
        }
        // The directory's own file, or else the nearest above it, which has to have it as a part.
        auto file = buildPath(directory, packageFileName);
        immutable asPart = !isFile(file);
        if (asPart)
        {
            auto above = dirName(directory);
            file = above == directory ? null : findPackageFile(above);
            if (file is null)
            {
                return fail(ProjectCode.NoPackageThere, directory ~ " has no " ~ packageFileName ~ ", and no directory "
                    ~ "above it has one to describe it as a part");
            }
        }
        PackageFile read;
        auto found = alreadyRead(file);
        if (found is null)
        {
            if (!readPackageFile(file, read, mistake)) return false;
            found = &read;
        }
        string there;
        if (!asPart)
        {
            there = found.name.name;
        }
        else
        {
            foreach (ref p; found.parts)
            {
                if (samePath(p.directory, directory)) there = p.name.name;
            }
            if (there is null)
            {
                return fail(ProjectCode.NoPackageThere, directory ~ " has no " ~ packageFileName ~ ", and " ~ file
                    ~ ", the nearest above it, has no part there");
            }
        }
        if (there != name)
        {
            return fail(ProjectCode.WrongPackageThere, file ~ " describes " ~ (asPart ? "the part " : "the package ")
                ~ quoted(there) ~ " there, not " ~ quoted(name));
        }
        if (auto known = named(name))
        {
            if (samePath(known.home, directory)) return true;
            return fail(ProjectCode.TwoDirectories, quoted(name) ~ " is at " ~ directory ~ " here, and already at "
                ~ known.home ~ ", described in " ~ known.file);
        }
        if (auto inside = nested(*found)) return fail(ProjectCode.InsidePackage, inside);
        return add(*found, mistake);
    }

    /// Why a package or part of `file`, not yet followed, and one already reached would have one
    /// directory of modules inside the other because the outer one has no `source`, or null. The
    /// compiler refuses any such pair; only this one comes from how a `silver.toml` maps to directories.
    string nested(const ref PackageFile file)
    {
        struct Placed { string name; string modules; string home; }
        Placed[] added;
        if (file.modules !is null) added ~= Placed(file.name.name, file.modules, file.directory);
        foreach (ref p; file.parts)
        {
            if (p.modules !is null) added ~= Placed(p.name.name, p.modules, p.directory);
        }
        string message(Placed inner, Placed outer)
        {
            return quoted(inner.name) ~ " is at " ~ inner.home ~ ", inside the directory of " ~ quoted(outer.name)
                ~ ", at " ~ outer.home ~ ", whose modules are that whole directory, so a file of " ~ quoted(inner.name)
                ~ " would be a module of both; giving " ~ quoted(outer.name) ~ " a `source` directory below it "
                ~ "avoids it";
        }
        foreach (ref p; packages)
        {
            if (p.directory is null) continue;
            auto known = Placed(p.name, p.directory, p.home);
            foreach (a; added)
            {
                if (samePath(known.modules, known.home) && within(a.modules, known.modules)) return message(a, known);
                if (samePath(a.modules, a.home) && within(known.modules, a.modules)) return message(known, a);
            }
        }
        return null;
    }
}

string decimal(ulong n)
{
    import std.conv : to;

    return n.to!string;
}
version (unittest)
{
    import silver.frontend : makeTree;
    import std.file : mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;

    /// Asserts that `text`, as the package file of `directory`, has one mistake, with `code`, at
    /// `line` and `column`.
    Mistake mistakeIn(string directory, string text, string code, uint line, uint column)
    {
        PackageFile file;
        Mistake mistake;
        assert(!checkPackageFile(buildPath(directory, packageFileName), text, file, mistake), "no mistake in " ~ text);
        assert(mistake.code == code && mistake.span.line == line && mistake.span.column == column,
            "for " ~ text ~ " got " ~ formatMistake(mistake));
        return mistake;
    }

    PackageFile checked(string directory, string text)
    {
        PackageFile file;
        Mistake mistake;
        assert(checkPackageFile(buildPath(directory, packageFileName), text, file, mistake), formatMistake(mistake));
        return file;
    }

    Project project(string file)
    {
        Project result;
        Mistake mistake;
        assert(readProject(file, result, mistake), formatMistake(mistake));
        return result;
    }

    Mistake projectMistake(string file, string code)
    {
        Project result;
        Mistake mistake;
        assert(!readProject(file, result, mistake), "no mistake reading " ~ file);
        assert(mistake.code == code, formatMistake(mistake));
        return mistake;
    }

    string[] namesOf(const Project p)
    {
        string[] names;
        foreach (ref f; p.packages) names ~= f.name;
        return names;
    }

    const(Facts) factsOf(const Project p, string name)
    {
        foreach (ref f; p.packages)
        {
            if (f.name == name) return f;
        }
        assert(false, "no package " ~ name);
    }

    /// The compiler's own shape, from docs/silver.md: a parent with no modules, library parts, and
    /// two parts that are programs.
    enum compilerShape = [
        "tool/silver.toml": "name = \"tool\"\n\n[[part]]\nname = \"tool.ast\"\npath = \"ast\"\n\n"
            ~ "[[part]]\nname = \"tool.syntax\"\npath = \"syntax\"\nuses = [\"tool.ast\"]\n\n"
            ~ "[[part]]\nname = \"tool.compiler\"\npath = \"compiler\"\nsource = \"source\"\n"
            ~ "uses = [\"tool.syntax\", \"tool.ast\"]\n\n"
            ~ "[[part]]\nname = \"tool.frontend\"\npath = \"frontend\"\n",
        "tool/ast/": "",
        "tool/syntax/": "",
        "tool/compiler/source/": "",
        "tool/frontend/": "",
    ];
}

@("the package file is the first found from the directory named upward, and there may be none")
unittest
{
    auto directory = makeTree("project-find", ["a/silver.toml": "name = \"a\"", "a/b/c/x.ag": "", "lone/x.ag": ""]);
    scope (exit) rmdirRecurse(directory);
    assert(findPackageFile(buildPath(directory, "a", "b", "c")) == buildPath(directory, "a", "silver.toml"));
    assert(findPackageFile(buildPath(directory, "a")) == buildPath(directory, "a", "silver.toml"));
    assert(findPackageFile(buildPath(directory, "a", "b", "..", "b")) == buildPath(directory, "a", "silver.toml"));
    assert(findPackageFile(buildPath(directory, "lone")) is null);
    mkdirRecurse(buildPath(directory, "a", "b", "silver.toml"));
    assert(findPackageFile(buildPath(directory, "a", "b")) == buildPath(directory, "a", "silver.toml"));
}

@("a package file's fields, with the defaults for where modules are")
unittest
{
    auto directory = makeTree("project-fields", ["source/": "", "core/src/": "", "lib/": ""]);
    scope (exit) rmdirRecurse(directory);

    auto plain = checked(directory, "name = \"geometry\"");
    assert(plain.name.name == "geometry" && plain.modules == directory && plain.parts.length == 0);
    assert(checked(directory, "name = \"g\"\nsource = \"source\"").modules == buildPath(directory, "source"));
    assert(checked(directory, "name = \"g\"\nsource = \".\"").modules == directory);

    auto full = checked(directory, "# a project\nname = \"silver\"\nsource = \"source\"\nuses = [\"geometry\", \"x.y\"]\n"
        ~ "[paths]\ngeometry = \"../geometry\"\n\"x.y\" = 'lib'\n"
        ~ "[[part]]\nname = \"silver.core\"\npath = \"core\"\nsource = \"src\"\nuses = [\"geometry\"]\n"
        ~ "[[part]]\nname = \"silver.lib\"\npath = \"lib\"\n");
    assert(full.uses.length == 2 && full.uses[1].name == "x.y" && full.uses[1].span.line == 4);
    assert(full.paths.length == 2 && full.paths[1].directory == buildPath(directory, "lib"));
    assert(full.parts.length == 2 && full.parts[0].modules == buildPath(directory, "core", "src"));
    assert(full.parts[1].modules == buildPath(directory, "lib") && full.parts[1].span.line == 13);

    assert(checked(directory, "name = \"g\"\n[[part]]\nname = \"g.lib\"\npath = \"lib\"").modules is null);
    assert(checked(directory, "name = \"g\"\npart = [{ name = \"g.lib\", path = \"lib\" }]").parts.length == 1);
    assert(checked(directory, "name = \"g\"\npaths = { \"a.b\" = \"x\" }").paths[0].name.name == "a.b");
}

@("each mistake in a package file has its code and position")
unittest
{
    auto directory = makeTree("project-mistakes", ["lib/": "", "core/": "", "has-file/silver.toml": "name = \"x\"",
        "file.txt": ""]);
    scope (exit) rmdirRecurse(directory);
    alias m = (text, code, line, column) => mistakeIn(directory, text, code, line, column);

    m("name = \"g\"\nversion = \"1\"", ProjectCode.UnknownField, 2, 1);
    m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"lib\"\nmain = true", ProjectCode.UnknownField, 5, 1);
    m("name = \"g\"\n[dependencies]\nx = \"y\"", ProjectCode.UnknownField, 2, 2);
    m("name = 1", ProjectCode.WrongType, 1, 8);
    m("name = \"g\"\nsource = [\"a\"]", ProjectCode.WrongType, 2, 10);
    m("name = \"g\"\nuses = \"geometry\"", ProjectCode.WrongType, 2, 8);
    m("name = \"g\"\nuses = [\"a\", 2]", ProjectCode.WrongType, 2, 14);
    m("name = \"g\"\npaths = \"x\"", ProjectCode.WrongType, 2, 9);
    m("name = \"g\"\n[paths]\ngeometry = 1", ProjectCode.WrongType, 3, 12);
    m("name = \"g\"\n[part]\nname = \"x\"", ProjectCode.WrongType, 2, 1);
    m("name = \"g\"\npart = [1]", ProjectCode.WrongType, 2, 8);
    m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = 1", ProjectCode.WrongType, 4, 8);
    auto dotted = m("name = \"g\"\n[paths]\nsilver.core = \"../core\"", ProjectCode.WrongType, 3, 1);
    assert(dotted.message == "`silver` holds a table, not a directory: a name of more than one segment is quoted under "
        ~ "[paths], as \"silver.name\" = \"../silver/name\"", dotted.message);
    m("uses = [\"a\"]", ProjectCode.MissingField, 1, 1);
    m("", ProjectCode.MissingField, 1, 1);
    m("name = \"g\"\n\n[[part]]\npath = \"lib\"", ProjectCode.MissingField, 3, 1);
    m("name = \"g\"\n\n[[part]]\nname = \"g.lib\"", ProjectCode.MissingField, 3, 1);
    m("name = \"geo metry\"", ProjectCode.BadName, 1, 8);
    m("name = \"g.\"", ProjectCode.BadName, 1, 8);
    m("name = \"1g\"", ProjectCode.BadName, 1, 8);
    m("name = \"g\"\nuses = [\"a-b\"]", ProjectCode.BadName, 2, 9);
    m("name = \"g\"\n[paths]\n\"a b\" = \"x\"", ProjectCode.BadName, 3, 1);
    m("name = \"g\"\nsource = \"..\"", ProjectCode.OutsideDirectory, 2, 10);
    m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"../elsewhere\"", ProjectCode.OutsideDirectory, 4, 8);
    m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \".\"", ProjectCode.OutsideDirectory, 4, 8);
    m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"lib\"\nsource = \"../core\"", ProjectCode.OutsideDirectory, 5, 10);
    m("name = \"g\"\nsource = \"missing\"", ProjectCode.NotADirectory, 2, 10);
    m("name = \"g\"\nsource = \"file.txt\"", ProjectCode.NotADirectory, 2, 10);
    m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"missing\"", ProjectCode.NotADirectory, 4, 8);
    m("name = \"g\"\nuses = [\"a\", \"b\", \"a\"]", ProjectCode.DuplicateName, 2, 19);
    m("name = \"g\"\n[[part]]\nname = \"g\"\npath = \"lib\"", ProjectCode.DuplicateName, 3, 8);
    m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"lib\"\n[[part]]\nname = \"g.x\"\npath = \"core\"",
        ProjectCode.DuplicateName, 6, 8);
    m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"lib\"\n[[part]]\nname = \"g.y\"\npath = \"./lib/\"",
        ProjectCode.SamePath, 7, 8);
    m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"has-file\"", ProjectCode.UnderPackageFile, 4, 8);
    m("name = \"g\"\nuses = [\"std\"]", ProjectCode.StandardLibraryListed, 2, 9);
    m("name = \"g\"\n[paths]\nstd = \"x\"", ProjectCode.StandardLibraryListed, 3, 1);
    m("name = \"g\"\n[paths]\ng = \"x\"", ProjectCode.PathForOwnPackage, 3, 1);
    m("name = \"g\"\n[paths]\n\"g.x\" = \"x\"\n[[part]]\nname = \"g.x\"\npath = \"lib\"", ProjectCode.PathForOwnPackage, 3, 1);
    m("name = \"g\"\nuses = [\"a\"]\n[[part]]\nname = \"g.x\"\npath = \"lib\"", ProjectCode.UsesWithoutModules, 2, 1);
    m("name = \"g\"\nuses = [geometry]", TomlCode.BadValue, 2, 9);
}

@("a mistake is formatted with its file shown as asked, and one that can't be read has no position")
unittest
{
    auto directory = makeTree("project-format", ["silver.toml": "name = \"g\"\nother = 1\n"]);
    scope (exit) rmdirRecurse(directory);
    auto file = buildPath(directory, "silver.toml");
    PackageFile read;
    Mistake mistake;
    assert(!readPackageFile(file, read, mistake));
    assert(formatMistake(mistake, (string path) => shownFrom(directory, path)) == "silver.toml(2,1): Error F0016: "
        ~ "`other` isn't a field of a package file. A package file has `name`, `source`, `uses`, `[paths]` and "
        ~ "`[[part]]`", formatMistake(mistake));
    assert(!readPackageFile(buildPath(directory, "missing", "silver.toml"), read, mistake));
    assert(mistake.code == ProjectCode.Unreadable && mistake.span.line == 0);
    auto shown = formatMistake(mistake, (string path) => shownFrom(directory, path));
    assert(shown.length > 0 && shown[0 .. "missing".length] == "missing", shown);
    assert(shown == buildPath("missing", "silver.toml") ~ ": Error F0015: The package file can't be read: "
        ~ mistake.message["The package file can't be read: ".length .. $], shown);
}

@("a project's parts are packages of their own, and a parent without source has no modules")
unittest
{
    auto directory = makeTree("project-parts", compilerShape.dup);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "tool", "silver.toml"));
    assert(namesOf(p) == ["tool", "tool.ast", "tool.syntax", "tool.compiler", "tool.frontend"]);
    auto tool = factsOf(p, "tool");
    assert(tool.directory is null && tool.parts == ["tool.ast", "tool.syntax", "tool.compiler", "tool.frontend"]);
    assert(tool.uses.length == 0 && tool.home == buildPath(directory, "tool"));
    auto compiler = factsOf(p, "tool.compiler");
    assert(compiler.directory == buildPath(directory, "tool", "compiler", "source"));
    assert(compiler.home == buildPath(directory, "tool", "compiler"));
    assert(compiler.uses == ["tool.syntax", "tool.ast"] && compiler.parts.length == 0);
    assert(compiler.file == buildPath(directory, "tool", "silver.toml"));
}

@("a package used through [paths] is read from its own file, and what it uses is followed in turn")
unittest
{
    auto directory = makeTree("project-paths", [
        "app/silver.toml": "name = \"app\"\nuses = [\"cards\", \"geometry\"]\n[paths]\ncards = \"../cards\"\n"
            ~ "geometry = \"../geometry\"\nunused = \"../nowhere\"",
        "cards/silver.toml": "name = \"cards\"\nsource = \"src\"\nuses = [\"geometry\"]\n[paths]\ngeometry = \"../geometry\"",
        "cards/src/": "",
        "geometry/silver.toml": "name = \"geometry\"\nuses = [\"units\"]\n[paths]\nunits = \"../units\"",
        "units/silver.toml": "name = \"units\"",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "app", "silver.toml"));
    assert(namesOf(p) == ["app", "cards", "geometry", "units"]);
    assert(factsOf(p, "app").uses == ["cards", "geometry"]);
    assert(factsOf(p, "cards").directory == buildPath(directory, "cards", "src"));
    assert(factsOf(p, "cards").uses == ["geometry"]);
    assert(factsOf(p, "geometry").directory == buildPath(directory, "geometry"));
    assert(factsOf(p, "units").file == buildPath(directory, "units", "silver.toml"));
}

@("a package elsewhere uses a part by its directory, found in the nearest package file above it")
unittest
{
    auto files = compilerShape.dup;
    files["lint/silver.toml"] = "name = \"lint\"\nuses = [\"tool.syntax\"]\n[paths]\n\"tool.syntax\" = \"../tool/syntax\"";
    auto directory = makeTree("project-uses-part", files);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "lint", "silver.toml"));
    assert(namesOf(p) == ["lint", "tool", "tool.ast", "tool.syntax", "tool.compiler", "tool.frontend"]);
    assert(factsOf(p, "tool.syntax").uses == ["tool.ast"]);
    assert(factsOf(p, "tool").parts.length == 4);
}

@("a library used by two packages, and by a package and a part, is read once")
unittest
{
    auto directory = makeTree("project-shared", [
        "app/silver.toml": "name = \"app\"\nsource = \"src\"\nuses = [\"a\", \"b\", \"geo\"]\n[paths]\na = \"../a\"\n"
            ~ "b = \"../b\"\ngeo = \"../geo\"\n[[part]]\nname = \"app.x\"\npath = \"x\"\nuses = [\"geo\"]",
        "app/x/": "",
        "app/src/": "",
        "a/silver.toml": "name = \"a\"\nuses = [\"geo\"]\n[paths]\ngeo = \"../geo\"",
        "b/silver.toml": "name = \"b\"\nuses = [\"geo\"]\n[paths]\ngeo = \"../geo/\"",
        "geo/silver.toml": "name = \"geo\"",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "app", "silver.toml"));
    assert(namesOf(p) == ["app", "app.x", "a", "geo", "b"]);
}

@("what can only be seen by reading files is a mistake located in the file that leads there")
unittest
{
    auto files = compilerShape.dup;
    files["app/silver.toml"] = "name = \"app\"\nuses = [\"geo\"]\n[paths]\ngeo = \"../geo\"";
    files["geo/silver.toml"] = "name = \"geometry\"";
    files["missing/silver.toml"] = "name = \"m\"\nuses = [\"gone\"]\n[paths]\ngone = \"../gone\"";
    files["file/silver.toml"] = "name = \"f\"\nuses = [\"x\"]\n[paths]\nx = \"silver.toml\"";
    files["unlisted/silver.toml"] = "name = \"u\"\nuses = [\"nowhere\"]";
    files["plain/silver.toml"] = "name = \"p\"\nuses = [\"x\"]\n[paths]\nx = \"../bare\"";
    files["bare/"] = "";
    files["wrongpart/silver.toml"] = "name = \"w\"\nuses = [\"tool.other\"]\n[paths]\n\"tool.other\" = \"../tool/ast\"";
    files["notpart/silver.toml"] = "name = \"n\"\nuses = [\"tool.x\"]\n[paths]\n\"tool.x\" = \"../tool/compiler/source\"";
    files["twice/silver.toml"] = "name = \"t\"\nuses = [\"geometry\", \"b\"]\n[paths]\ngeometry = \"../geo\"\nb = \"../b\"";
    files["b/silver.toml"] = "name = \"b\"\nuses = [\"geometry\"]\n[paths]\ngeometry = \"../geo2\"";
    files["geo2/silver.toml"] = "name = \"geometry\"";
    files["clash/silver.toml"] = "name = \"c\"\n[paths]\n\"tool.ast\" = \"../tool/ast\"\n"
        ~ "[[part]]\nname = \"tool.frontend\"\npath = \"part\"\nuses = [\"tool.ast\"]";
    files["clash/part/"] = "";
    files["badlib/silver.toml"] = "name = \"bl\"\nuses = [\"broken\"]\n[paths]\nbroken = \"../broken\"";
    files["broken/silver.toml"] = "name = \"broken\"\nnope = 1";
    auto directory = makeTree("project-reading", files);
    scope (exit) rmdirRecurse(directory);
    Mistake of(string project, string code) => projectMistake(buildPath(directory, project, "silver.toml"), code);

    auto wrong = of("app", ProjectCode.WrongPackageThere);
    assert(wrong.file == buildPath(directory, "app", "silver.toml") && wrong.span.line == 4 && wrong.span.column == 7);
    assert(wrong.message == buildPath(directory, "geo", "silver.toml") ~ " describes the package 'geometry' there, "
        ~ "not 'geo'", wrong.message);
    auto gone = of("missing", ProjectCode.NotADirectory);
    assert(gone.span.line == 4 && gone.span.column == 8);
    of("file", ProjectCode.NotADirectory);
    auto unlisted = of("unlisted", ProjectCode.UnknownPackage);
    assert(unlisted.span.line == 2 && unlisted.span.column == 9);
    auto bare = of("plain", ProjectCode.NoPackageThere);
    assert(bare.span.line == 4 && bare.span.column == 5);
    auto wrongPart = of("wrongpart", ProjectCode.WrongPackageThere);
    assert(wrongPart.message == buildPath(directory, "tool", "silver.toml") ~ " describes the part 'tool.ast' there, "
        ~ "not 'tool.other'", wrongPart.message);
    auto notPart = of("notpart", ProjectCode.NoPackageThere);
    assert(notPart.message == buildPath(directory, "tool", "compiler", "source") ~ " has no silver.toml, and "
        ~ buildPath(directory, "tool", "silver.toml") ~ ", the nearest above it, has no part there", notPart.message);
    auto twice = of("twice", ProjectCode.TwoDirectories);
    assert(twice.file == buildPath(directory, "b", "silver.toml") && twice.span.line == 4, formatMistake(twice));
    assert(twice.message == "'geometry' is at " ~ buildPath(directory, "geo2") ~ " here, and already at "
        ~ buildPath(directory, "geo") ~ ", described in " ~ buildPath(directory, "geo", "silver.toml"), twice.message);
    auto clash = of("clash", ProjectCode.TwoDirectories);
    assert(clash.file == buildPath(directory, "tool", "silver.toml") && clash.span.line == 19, formatMistake(clash));
    auto broken = of("badlib", ProjectCode.UnknownField);
    assert(broken.file == buildPath(directory, "broken", "silver.toml") && broken.span.line == 2);
}

@("a script is beside the package or part whose home holds it, the deepest, and a directory holds those inside it")
unittest
{
    import std.algorithm : map;
    import std.array : array;

    auto files = compilerShape.dup;
    files["geo/silver.toml"] = "name = \"geo\"";
    files["geo/shapes/"] = "";
    files["app/silver.toml"] = "name = \"app\"\nsource = \"src\"\nuses = [\"geo\"]\n[paths]\ngeo = \"../geo\"\n"
        ~ "[[part]]\nname = \"app.tools\"\npath = \"tools\"";
    files["app/src/"] = "";
    files["app/tools/"] = "";
    auto directory = makeTree("project-script-homes", files);
    scope (exit) rmdirRecurse(directory);
    string[] of(const Project p, string[] path...) => scriptHomes(p, buildPath(directory ~ path)).map!(f => f.name.idup).array;

    auto tool = project(buildPath(directory, "tool", "silver.toml"));
    assert(of(tool, "tool", "ast", "node.ag") == ["tool.ast"]);
    assert(of(tool, "tool", "compiler", "source", "main.ag") == ["tool.compiler"]);
    // Beside the part's own files, outside its source.
    assert(of(tool, "tool", "compiler", "build.ag") == ["tool.compiler"]);
    // The parent only holds its parts, and a file beside them is told so.
    assert(of(tool, "tool", "scratch.ag") == ["tool"]);
    assert(of(tool, "tool", "ast") == ["tool.ast"]);
    assert(of(tool, "tool") == ["tool", "tool.ast", "tool.syntax", "tool.compiler", "tool.frontend"]);
    auto app = project(buildPath(directory, "app", "silver.toml"));
    assert(of(app, "app", "src", "deep", "x.ag") == ["app"]);
    assert(of(app, "app", "tryout.ag") == ["app"]);
    assert(of(app, "app", "tools", "x.ag") == ["app.tools"]);
    assert(of(app, "app") == ["app", "app.tools"]);
    assert(of(app, "geo", "shapes", "circle.ag") == ["geo"]);
    assert(of(app, "elsewhere.ag") == []);
}

@("the package started in is the deepest of the project's own file whose home holds the directory, and its file's package otherwise")
unittest
{
    auto files = compilerShape.dup;
    files["tool/ast/deep/"] = "";
    files["tool/notes/"] = "";
    files["geo/silver.toml"] = "name = \"geo\"";
    files["app/silver.toml"] = "name = \"app\"\nsource = \"src\"\nuses = [\"geo\"]\n[paths]\ngeo = \"../geo\"";
    files["app/src/inner/"] = "";
    auto directory = makeTree("project-started-in", files);
    scope (exit) rmdirRecurse(directory);
    string at(const Project p, string[] path...) => startedIn(p, buildPath(directory ~ path)).name;

    auto tool = project(buildPath(directory, "tool", "silver.toml"));
    assert(at(tool, "tool") == "tool");
    assert(at(tool, "tool", "notes") == "tool");
    assert(at(tool, "tool", "ast") == "tool.ast");
    assert(at(tool, "tool", "ast", "deep") == "tool.ast");
    assert(at(tool, "tool", "compiler") == "tool.compiler");
    assert(at(tool, "tool", "compiler", "source") == "tool.compiler");
    assert(at(tool, "elsewhere") == "tool");
    auto app = project(buildPath(directory, "app", "silver.toml"));
    assert(at(app, "app", "src", "inner") == "app");
    // A package the project uses is another file's, even where its home holds the directory.
    assert(at(app, "geo") == "app");

    assert(homedAt(tool, buildPath(directory, "tool", "compiler")).name == "tool.compiler");
    assert(homedAt(tool, buildPath(directory, "tool")).name == "tool");
    assert(homedAt(tool, buildPath(directory, "tool", "compiler", "source")) is null);
    assert(homedAt(app, buildPath(directory, "geo")) is null);
    assert(homesOf(tool, (string path) => shownFrom(buildPath(directory, "tool"), path)) == "'tool' at ., 'tool.ast' at "
        ~ "ast, 'tool.syntax' at syntax, 'tool.compiler' at compiler, 'tool.frontend' at frontend");

    import std.algorithm : map;
    import std.array : array;
    auto names = (const Facts[] facts) => facts.map!(f => f.name.idup).array;
    assert(names(programHomes(tool, factsOf(tool, "tool"))) == ["tool.ast", "tool.syntax", "tool.compiler",
        "tool.frontend"]);
    assert(names(programHomes(tool, factsOf(tool, "tool.ast"))) == ["tool.ast"]);
    assert(names(programHomes(app, factsOf(app, "app"))) == ["app"]);
}

@("the compiler is given every package's directory, uses, parts and file, relative where that's inside")
unittest
{
    import std.conv : to;

    auto files = compilerShape.dup;
    files["lint/silver.toml"] = "name = \"lint\"\nuses = [\"tool.syntax\"]\n[paths]\n\"tool.syntax\" = \"../tool/syntax\"";
    auto directory = makeTree("project-options", files);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "lint", "silver.toml"));
    auto lint = buildPath(directory, "lint");
    auto options = compilerOptions(p, (string path) => shownFrom(lint, path));
    auto tool = (string rest) => buildPath(directory, "tool", rest);
    assert(options == [
        "--package", "lint=.",
        "--package", "tool.ast=" ~ tool("ast"),
        "--package", "tool.syntax=" ~ tool("syntax"),
        "--package", "tool.compiler=" ~ buildPath(tool("compiler"), "source"),
        "--package", "tool.frontend=" ~ tool("frontend"),
        "--uses", "lint=tool.syntax",
        "--uses", "tool.syntax=tool.ast",
        "--uses", "tool.compiler=tool.syntax,tool.ast",
        "--parts", "tool=tool.ast,tool.syntax,tool.compiler,tool.frontend",
        "--package-file", "lint=silver.toml",
        "--package-file", "tool=" ~ tool("silver.toml"),
        "--package-file", "tool.ast=" ~ tool("silver.toml"),
        "--package-file", "tool.syntax=" ~ tool("silver.toml"),
        "--package-file", "tool.compiler=" ~ tool("silver.toml"),
        "--package-file", "tool.frontend=" ~ tool("silver.toml"),
    ], options.to!string);
    auto homes = compilerOptions(p, (string path) => shownFrom(lint, path), scriptHomes(p, tool("compiler")));
    assert(homes[options.length .. $] == ["--scripts-in", "tool.compiler=" ~ tool("compiler")], homes.to!string);
    assert(shownFrom(directory, buildPath(directory, "tool", "ast")) == buildPath("tool", "ast"));
    assert(shownFrom(buildPath(directory, "tool"), buildPath(directory, "lint")) == buildPath(directory, "lint"));
}

@("a part or a source inside the directory of another package file is refused, since that file would claim its files")
unittest
{
    auto directory = makeTree("project-nested-part", ["vendor/x/silver.toml": "name = \"x\"", "vendor/x/sub/src/": "",
        "lib/": ""]);
    scope (exit) rmdirRecurse(directory);
    auto m = mistakeIn(directory, "name = \"g\"\n[[part]]\nname = \"g.sub\"\npath = \"vendor/x/sub\"",
        ProjectCode.UnderPackageFile, 4, 8);
    assert(m.message == "A part's `path` is " ~ buildPath(directory, "vendor", "x", "sub") ~ ", and "
        ~ buildPath(directory, "vendor", "x", "silver.toml") ~ " would make a directory above it a package of its own, "
        ~ "holding its files; a part is described only in its parent's file, and a directory with a package file is "
        ~ "used through [paths]", m.message);
    mistakeIn(directory, "name = \"g\"\nsource = \"vendor/x/sub/src\"", ProjectCode.UnderPackageFile, 2, 10);
    mistakeIn(directory, "name = \"g\"\nsource = \"vendor/x\"", ProjectCode.UnderPackageFile, 2, 10);
    mistakeIn(directory, "name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"lib\"\nsource = \"../vendor/x/sub\"",
        ProjectCode.OutsideDirectory, 5, 10);
    mistakeIn(directory, "name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"vendor/x/sub/src\"",
        ProjectCode.UnderPackageFile, 4, 8);
}

@("an empty directory in a package file gets a message that names a directory")
unittest
{
    import std.algorithm : canFind;

    auto directory = makeTree("project-empty", ["lib/": ""]);
    scope (exit) rmdirRecurse(directory);
    auto source = mistakeIn(directory, "name = \"g\"\nsource = \"\"", ProjectCode.EmptyDirectory, 2, 10);
    assert(source.message == "`source` names a directory, and \"\" names none; leave it out to mean the package file's "
        ~ "directory", source.message);
    auto path = mistakeIn(directory, "name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"\"", ProjectCode.EmptyDirectory, 4, 8);
    assert(path.message == "A part's `path` names a directory, and \"\" names none, as \"core\"", path.message);
    mistakeIn(directory, "name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"lib\"\nsource = ''", ProjectCode.EmptyDirectory,
        5, 10);
    auto paths = mistakeIn(directory, "name = \"g\"\n[paths]\ngeo = \"\"", ProjectCode.EmptyDirectory, 3, 7);
    assert(paths.message == "The directory of 'geo' under [paths] is \"\", which names none; give where it is, as "
        ~ "\"../geo\"", paths.message);
    foreach (m; [source, path, paths]) assert(!m.message.canFind(" , ") && !m.message.canFind("and  isn't"), m.message);
}


@("a used package inside the directory of a package with no source, or holding one, is refused at the [paths] entry")
unittest
{
    auto directory = makeTree("project-nested", [
        "outer/silver.toml": "name = \"outer\"\nuses = [\"inner\"]\n\n[paths]\ninner = \"inner\"",
        "outer/inner/silver.toml": "name = \"inner\"",
        "sourced/silver.toml": "name = \"sourced\"\nsource = \"src\"\nuses = [\"inner\"]\n\n[paths]\ninner = \"inner\"",
        "dot/silver.toml": "name = \"dot\"\nsource = \".\"\nuses = [\"inner\"]\n\n[paths]\ninner = \"inner\"",
        "dot/inner/silver.toml": "name = \"inner\"",
        "sourced/src/": "",
        "sourced/inner/silver.toml": "name = \"inner\"",
        "app/silver.toml": "name = \"app\"\nuses = [\"a\", \"b\"]\n\n[paths]\na = \"../a\"\nb = \"../a/b\"",
        "around/silver.toml": "name = \"around\"\nuses = [\"b\", \"a\"]\n\n[paths]\nb = \"../a/b\"\na = \"../a\"",
        "a/silver.toml": "name = \"a\"",
        "a/b/silver.toml": "name = \"b\"\nsource = \"src\"",
        "a/b/src/": "",
        "tools/silver.toml": "name = \"tools\"\nuses = [\"kit.core\"]\n\n[paths]\n\"kit.core\" = \"kit/core\"",
        "tools/kit/silver.toml": "name = \"kit\"\n\n[[part]]\nname = \"kit.core\"\npath = \"core\"",
        "tools/kit/core/": "",
    ]);
    scope (exit) rmdirRecurse(directory);
    Mistake of(string project) => projectMistake(buildPath(directory, project, "silver.toml"), ProjectCode.InsidePackage);
    string message(string inner, string innerHome, string outer, string outerHome)
    {
        import std.path : buildNormalizedPath;

        return "'" ~ inner ~ "' is at " ~ buildNormalizedPath(directory, innerHome) ~ ", inside the directory of '" ~ outer
            ~ "', at " ~ buildNormalizedPath(directory, outerHome) ~ ", whose modules are that whole directory, so a file "
            ~ "of '" ~ inner ~ "' would be a module of both; giving '" ~ outer ~ "' a `source` directory below it avoids it";
    }

    auto outer = of("outer");
    assert(outer.file == buildPath(directory, "outer", "silver.toml") && outer.span.line == 5 && outer.span.column == 9,
        formatMistake(outer));
    assert(outer.message == message("inner", "outer/inner", "outer", "outer"), outer.message);
    // Reached in either order, the package with no source is the outer one.
    auto app = of("app");
    assert(app.span.line == 6 && app.message == message("b", "a/b", "a", "a"), formatMistake(app));
    auto around = of("around");
    assert(around.span.line == 6 && around.message == message("b", "a/b", "a", "a"), formatMistake(around));
    // A part of another file is refused in the same way.
    auto part = of("tools");
    assert(part.message == message("kit.core", "tools/kit/core", "tools", "tools"), part.message);
    // `source = "."` is the whole directory too.
    assert(of("dot").message == message("inner", "dot/inner", "dot", "dot"), of("dot").message);
    // With source, the used package's directory holds none of the other's modules.
    Project project;
    Mistake mistake;
    assert(readProject(buildPath(directory, "sourced", "silver.toml"), project, mistake), formatMistake(mistake));
}
