/// Finds a project's package file, reads and checks it, follows every package it uses to the file
/// that describes that package, and turns what it found into the compiler's options. It reports,
/// located in the package file, only what it sees by reading files; every rule about packages
/// themselves (cycles, a package that uses a program, directories inside one another) is left to
/// the compiler, which is given the facts.
module silver.frontend.project;

import silver.frontend.git : Want, Wanted;
import silver.frontend.lock : lockCode;
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
    /// A `source` or a described package's `path` that isn't under the directory it's taken from.
    OutsideDirectory = "F0020",
    NotADirectory = "F0021",
    /// Two packages of one file with one name, or a name listed twice.
    DuplicateName = "F0022",
    /// Two `[[package]]` entries at one path.
    SamePath = "F0023",
    /// A described package's directory, or a `source`, under a directory with a package file of its own
    /// below the file that names it, so that the other file's package would hold its files.
    UnderPackageFile = "F0024",
    /// A name in `uses` that no `[[package]]` entry gives, and isn't the file's own package or the
    /// standard library.
    UnknownPackage = "F0025",
    /// An entry with only a `path`, whose directory has no package file and is described by none above it.
    NoPackageThere = "F0026",
    /// One package name reached at two directories.
    TwoDirectories = "F0028",
    /// The standard library in `uses`.
    StandardLibraryListed = "F0029",
    /// An entry with only a `path` that leads to a package this file describes itself.
    ListsOwnPackage = "F0030",
    /// `uses` on a package that describes others and has no `source`, so no modules to use anything.
    UsesWithoutModules = "F0031",
    /// An empty string where a directory goes.
    EmptyDirectory = "F0032",
    /// No file named, and no package file at or above the working directory.
    NoProject = "F0033",
    /// A directory given to `run` or `build` that's no described package's directory.
    NotAPackageDirectory = "F0034",
    /// A package with a file of its own whose directory is inside, or holds, the directory of a package
    /// whose modules are its whole directory.
    InsidePackage = "F0035",
    /// `--package`, `--uses` or `--project` given by hand inside a project.
    PackageOptionGiven = "F0036",
    /// An entry with a `name`, `source` or `uses` whose directory has a package file of its own.
    DescribesItself = "F0037",
    /// What isn't built of remote packages: `version`, and `test = true` on one.
    RemotePackage = "F0038",
    /// `source` or `uses` on a remote entry.
    RemoteField = "F0039",
    /// Two of `tag`, `branch` and `rev`, or an empty one.
    RemoteWant = "F0040",
    /// A `rev` that isn't a full hash.
    ShortRev = "F0041",
    /// A `git` of a kind silver doesn't fetch from.
    RemoteSource = "F0042",
    /// A repository holding a symbolic link, or a path that can't be written the same everywhere.
    Unfetchable = "F0043",
    /// A remote entry whose `name` isn't the name the package's own file gives it.
    NameMismatch = "F0044",
    /// Two entries for one name that reach different commits or directories.
    RemoteConflict = "F0045",
    /// git couldn't fetch, isn't there, or the cache can't be written.
    FetchFailed = "F0046",
    /// A tree in the cache whose hash isn't the lock's.
    HashMismatch = "F0047",
    /// A `path` entry of a remote package outside its repository.
    OutsideRepository = "F0048",
    /// A mistake in what `silver.lock` says.
    BadLock = lockCode,
    /// An absolute path in a `[native.<library>.<platform>]` table.
    AbsoluteNativePath = "F0050",
    /// A file a `[native.<library>.<platform>]` table names for this platform that isn't there.
    NoNativeFile = "F0051",
    /// A `[native]` table's library that `native library` can't name or an option can't carry: empty, or
    /// holding `=` or a NUL.
    BadNativeLibrary = "F0052",
}

/// The platforms a `[native.<library>.<platform>]` table can be for.
immutable nativePlatforms = ["windows", "linux"];

/// The platform `silver` runs on, as a `[native]` table names it, or null where none is for it.
version (Windows) enum hostPlatform = "windows";
else version (linux) enum hostPlatform = "linux";
else enum string hostPlatform = null;

/// A `[native.<library>.<platform>]` table: the files `native library "<library>"` means there.
struct NativeTable
{
    string library;
    string platform;
    /// The package file it's in, absolute.
    string file;
    /// Where its platform is written, in its header.
    Span span;
    /// `link` and `load`, absolute, or null when not given.
    string link;
    string load;
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

/// A `[[package]]` entry that describes a package here, with its `name` and `path`.
struct Described
{
    Named name;
    /// The package's directory, absolute.
    string directory;
    Span pathSpan;
    /// Where its modules are, absolute: `directory`, or its `source` under it.
    string modules;
    Named[] uses;
    /// The `[[package]]` header, or the inline table.
    Span span;
    /// Whether `silver test` from the file tests it: its `test`, true unless given.
    bool test = true;
}

/// A `[[package]]` entry with only a `path`: a package with a package file of its own there, or one
/// that the nearest package file above it describes.
struct Listed
{
    /// The directory, absolute.
    string directory;
    Span pathSpan;
    /// Its `test`, when it's given: whether `silver test` from the file tests it, which unless given
    /// depends on whether `directory` is under the file's.
    bool testGiven;
    bool test;
}

/// A `[[package]]` entry with a `git`: a package fetched from a repository.
struct Remote
{
    Named name;
    /// As written.
    string git;
    Span gitSpan;
    /// For a directory on this machine, that directory, absolute; null for a URL.
    string directory;
    /// The package's directory inside the repository, normalized with `/`, or null for its root.
    string path;
    Span pathSpan;
    Wanted wanted;
    /// The `[[package]]` header, or the inline table.
    Span span;
}

/// What a package file says, checked.
struct PackageFile
{
    /// The file, absolute.
    string file;
    string directory;
    Named name;
    /// Where the package's own modules are, absolute, or null when it only describes others.
    string modules;
    Named[] uses;
    Described[] described;
    Listed[] listed;
    NativeTable[] natives;
    Remote[] remotes;
}

/// The facts the compiler is given about one package.
struct Facts
{
    string name;
    /// Where its modules are, absolute, or null when it only describes others.
    string directory;
    string[] uses;
    /// The packages it describes, which with it are one project.
    string[] describes;
    /// The package file that describes it.
    string file;
    /// The directory a `[[package]]` entry names it by: its file's for a package, and its `path` for
    /// one a file describes.
    string home;
}

/// Every package reachable from a project's package file: the file's own package and those it describes
/// first, then the packages they use, each with the packages of its file, in the order they were reached.
struct Project
{
    string file;
    Facts[] packages;
    /// The `[native]` tables of the package files whose packages were reached, for every platform. Each is
    /// for the modules of its own file's packages.
    NativeTable[] natives;
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

/// Reads the project whose package file is `file`, and every package file its packages lead to,
/// fetching the remote packages they use with `remotes`. With none given, the lock beside `file` is
/// written once the project is read; the caller of one given writes it, with `Remotes.finish`.
bool readProject(string file, out Project project, out Mistake mistake, Remotes remotes = null)
{
    PackageFile root;
    if (!readPackageFile(file, root, mistake)) return false;
    auto reader = ProjectReader();
    reader.remotes = remotes is null ? new Remotes(root.file) : remotes;
    if (!reader.add(root, mistake)) return false;
    if (!reader.fetchAll(root, mistake)) return false;
    if (remotes is null && !reader.remotes.finish(mistake)) return false;
    project = Project(root.file, reader.packages, reader.natives);
    return true;
}

/// The remote packages one run reaches, from the package file it starts from: what the lock beside
/// that file says, and what's taken, so that the lock is written once, when everything is read.
final class Remotes
{
    import silver.frontend.git : Tree;
    import silver.frontend.lock : Locked;

    /// The lock, beside the starting package file.
    string lockFile;
    /// Says what's being fetched, as it starts.
    void delegate(string) say;

    private Locked[] locked;
    private bool lockRead;
    private bool lockThere;
    private Locked[] taken;
    /// The directory of each of `taken`'s files.
    private string[] trees;

    this(string startingFile, void delegate(string) say = null)
    {
        import silver.frontend.lock : lockFileName;
        import std.path : buildPath, dirName;
        import std.stdio : stderr;

        lockFile = buildPath(dirName(startingFile), lockFileName);
        this.say = say !is null ? say : (string line) { stderr.writeln(line); };
    }

    /// The directory the files of the commit that `remote`, an entry of `from`, takes are in, and the
    /// commit: the lock's when it has the entry as written, else the one its tag or branch is at now.
    bool checkout(const ref PackageFile from, const ref Remote remote, out string files, out string commit,
        out Mistake mistake)
    {
        import silver.frontend.git : cacheDirectory, cached, fetch, Failure, Problem, resolve;
        import silver.frontend.lock : sameEntry;
        import std.path : dirName;

        bool fail(string code, string message)
        {
            mistake = Mistake(from.file, code, remote.gitSpan, message);
            return false;
        }
        if (!readLock(mistake)) return false;
        auto wanted = Locked(remote.name.name, remote.directory is null ? remote.git
            : written(remote.directory, dirName(lockFile)), remote.path, remote.wanted);
        foreach (k, t; taken)
        {
            if (!sameEntry(t, wanted)) continue;
            files = trees[k];
            commit = t.commit;
            return true;
        }
        const(Locked)* lock;
        foreach (ref l; locked)
        {
            if (sameEntry(l, wanted)) lock = &l;
        }
        auto cache = cacheDirectory();
        if (cache is null)
        {
            return fail(ProjectCode.FetchFailed, "There's nowhere to keep remote packages: neither HOME nor "
                ~ "XDG_CACHE_HOME is set, so set SILVER_CACHE to a directory for them");
        }
        auto url = remote.directory is null ? remote.git : remote.directory;
        auto what = quoted(remote.name.name);
        Failure failure;
        bool failed()
        {
            return fail(failure.problem == Problem.unfetchable ? ProjectCode.Unfetchable : ProjectCode.FetchFailed,
                failure.problem == Problem.cache ? failure.message : what ~ " can't be fetched"
                ~ (failure.problem == Problem.noGit ? ", since " : ": ") ~ failure.message);
        }
        if (lock !is null) commit = lock.commit;
        else if (remote.wanted.want == Want.rev) commit = remote.wanted.name;
        else if (!resolve(url, remote.wanted, commit, failure)) return failed();
        Tree tree;
        if (!cached(cache, commit, tree, failure))
        {
            if (failure.message !is null) return failed();
            say("Fetching " ~ remote.name.name ~ " from " ~ remote.git ~ wantedText(remote.wanted) ~ ", commit " ~ commit);
            if (!fetch(cache, url, remote.wanted, commit, tree, failure)) return failed();
        }
        if (lock !is null && tree.hash != lock.hash)
        {
            return fail(ProjectCode.HashMismatch, "The files of " ~ what ~ " at commit " ~ commit ~ ", in "
                ~ dirName(tree.directory) ~ ", have the hash " ~ tree.hash ~ ", and " ~ lockFile ~ " says "
                ~ lock.hash ~ ": the cache or the lock has been changed. Deleting that directory has the commit "
                ~ "fetched again, and if its hash still differs, the lock's is wrong");
        }
        wanted.commit = commit;
        wanted.hash = tree.hash;
        taken ~= wanted;
        trees ~= tree.directory;
        files = tree.directory;
        return true;
    }

    /// Writes the lock with every entry taken, sorted, unless it already says that, and with none when
    /// nothing is remote, only if there's a lock to empty.
    bool finish(out Mistake mistake)
    {
        import silver.frontend.lock : lockText, tidied;
        import std.conv : to;
        import std.file : remove, rename, write;
        import std.process : thisProcessID;

        if (!readLock(mistake)) return false;
        auto now = tidied(taken);
        if (lockThere ? now == tidied(locked) : now.length == 0) return true;
        auto temporary = lockFile ~ "." ~ thisProcessID.to!string ~ ".tmp";
        try
        {
            write(temporary, lockText(now));
            rename(temporary, lockFile);
        }
        catch (Exception e)
        {
            try remove(temporary);
            catch (Exception) {}
            mistake = Mistake(lockFile, ProjectCode.BadLock, Span(), "The lock can't be written: " ~ e.msg);
            return false;
        }
        locked = now;
        lockThere = true;
        return true;
    }

    private bool readLock(out Mistake mistake)
    {
        import silver.frontend.lock : parseLock = readLock;
        import std.file : exists, read;

        if (lockRead) return true;
        lockRead = true;
        if (!exists(lockFile)) return true;
        lockThere = true;
        string text, code, message;
        Span span;
        try text = cast(string) read(lockFile);
        catch (Exception e)
        {
            mistake = Mistake(lockFile, ProjectCode.Unreadable, Span(), "The lock can't be read: " ~ e.msg);
            return false;
        }
        if (!parseLock(text, locked, code, span, message))
        {
            mistake = Mistake(lockFile, code, span, message);
            return false;
        }
        return true;
    }
}

/// What `wanted` takes, as an entry writes it after a comma, or nothing for the default branch.
string wantedText(Wanted wanted)
{
    final switch (wanted.want)
    {
        case Want.defaultBranch: return "";
        case Want.tag: return ", tag = \"" ~ wanted.name ~ "\"";
        case Want.branch: return ", branch = \"" ~ wanted.name ~ "\"";
        case Want.rev: return ", rev = \"" ~ wanted.name ~ "\"";
    }
}

/// The packages whose files with no `module` line `path` may hold: the one
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

/// The package of the project's own file whose home holds `directory`, the deepest, or the
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

/// The package of the project's own file whose home is `directory`, or null.
const(Facts)* homedAt(const Project project, string directory)
{
    foreach (ref p; project.packages)
    {
        if (samePath(p.file, project.file) && samePath(p.home, directory)) return &p;
    }
    return null;
}

/// The packages of the project's own file, each with its home as `shown` gives it, as a
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

/// `package_` and the packages it describes, those with modules, whose homes the compiler is told so
/// that what it says about their programs names the directories they're chosen by.
const(Facts)[] programHomes(const Project project, const Facts package_)
{
    const(Facts)[] homes;
    foreach (ref p; project.packages)
    {
        if (p.directory is null) continue;
        bool described;
        foreach (name; package_.describes) described = described || name == p.name;
        if (described || p.name == package_.name) homes ~= p;
    }
    return homes;
}

/// The directories under `directory` with a package file, the outermost only: a directory with one
/// isn't looked into.
string[] projectsUnder(string directory)
{
    import std.algorithm : sort;
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
            if (isFile(buildPath(sub, packageFileName))) found ~= sub;
            else walk(sub);
        }
    }
    walk(buildNormalizedPath(absolutePath(directory)));
    return found;
}

/// A package a package file names that `silver test` leaves out: its directory, and whether that's
/// because it's outside the file's directory and not opted in, rather than opted out.
struct LeftOut
{
    string directory;
    bool outside;
}

/// What `silver test` over a directory in a project runs: every package that's declared for it, the
/// directories whose files are tested, the first the one asked for, the directories under them left
/// out, and what the package files name that's left out.
struct TestRun
{
    Project project;
    string[] tested;
    string[] skipped;
    LeftOut[] leftOut;
}

/// What `silver test` over `directory` runs, from `file`, the package file at or above it. Testing a
/// directory tests what's under it that the file names, and nothing it doesn't: the packages the file
/// describes, unless their `test` is false; each package with a file of its own that the file lists
/// under it, unless its `test` is false, as `silver test` would test it from there; and when
/// `directory` is the file's own, each listed package outside it whose `test` is true, alone. A
/// directory under it with a package file that isn't named this way is another project, left out.
bool readTestRun(string file, string directory, out TestRun run, out Mistake mistake, Remotes remotes = null)
{
    import std.algorithm : any, canFind, filter;
    import std.array : array;
    import std.path : absolutePath, buildNormalizedPath;

    PackageFile root;
    if (!readPackageFile(file, root, mistake)) return false;
    auto reader = ProjectReader();
    reader.remotes = remotes is null ? new Remotes(root.file) : remotes;
    if (!reader.add(root, mistake)) return false;
    if (!reader.fetchAll(root, mistake)) return false;
    directory = buildNormalizedPath(absolutePath(directory));

    // A directory tested, and the directories under it that aren't tested with it.
    struct Covered
    {
        string directory;
        string[] excluded;
    }
    Covered[] covered;
    // What the starting file's own entries say isn't tested, which a wider directory tested doesn't override.
    string[] optedOut;
    void optOut(string at, bool outside)
    {
        run.leftOut ~= LeftOut(at, outside);
        if (!within(directory, at)) optedOut ~= at;
    }
    // `top` is the directory asked for, whose file's outside entries opted in are tested; `alone` is one
    // of those, tested without what its file lists.
    bool cover(const PackageFile from, string at, bool top, bool alone)
    {
        if (covered.any!(c => samePath(c.directory, at))) return true;
        auto c = Covered(at, projectsUnder(at));
        foreach (ref d; from.described)
        {
            if (d.test || !within(d.directory, at) || samePath(d.directory, at)) continue;
            c.excluded ~= d.directory;
            if (top) optOut(d.directory, false);
        }
        immutable index = covered.length;
        covered ~= c;
        if (alone) return true;
        foreach (ref l; from.listed)
        {
            immutable inside = within(l.directory, from.directory);
            bool alsoAlone;
            if (inside)
            {
                if (!within(l.directory, at) || samePath(l.directory, at)) continue;
                if (l.testGiven && !l.test)
                {
                    covered[index].excluded ~= l.directory;
                    if (top) optOut(l.directory, false);
                    continue;
                }
            }
            else
            {
                if (!top || !samePath(at, from.directory)) continue;
                if (!(l.testGiven && l.test))
                {
                    optOut(l.directory, !l.testGiven);
                    continue;
                }
                alsoAlone = true;
            }
            PackageFile there;
            if (!reader.include(from, l.directory, there, mistake)) return false;
            if (!cover(there, l.directory, false, alsoAlone)) return false;
        }
        return true;
    }
    if (!cover(root, directory, true, false)) return false;
    covered = covered[0 .. 1] ~ covered[1 .. $].filter!(c => !optedOut.any!(o => within(c.directory, o))).array;
    foreach (ref c; covered) c.excluded ~= optedOut;

    bool isCovered(string at) => covered.any!(c => samePath(c.directory, at));
    foreach (ref c; covered)
    {
        foreach (x; c.excluded)
        {
            if (!isCovered(x) && !run.skipped.any!(s => samePath(s, x))) run.skipped ~= x;
        }
    }
    // A directory is walked from one tested above it unless a directory skipped is between them.
    foreach (ref c; covered)
    {
        immutable reached = run.tested.any!(t => within(c.directory, t) && !run.skipped.any!(s => within(c.directory, s)
            && within(s, t) && !samePath(s, t)));
        if (!reached) run.tested ~= c.directory;
    }
    run.skipped = run.skipped.filter!(s => run.tested.any!(t => within(s, t) && !samePath(s, t))).array;
    if (remotes is null && !reader.remotes.finish(mistake)) return false;
    run.project = Project(root.file, reader.packages, reader.natives);
    return true;
}

/// The compiler's options for `project`: each package's directory, uses, project and file, and the
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
        if (p.describes.length > 0) options ~= ["--project", p.name ~ "=" ~ p.describes.join(",")];
    }
    foreach (ref p; project.packages)
    {
        options ~= ["--package-file", p.name ~ "=" ~ shown(p.file)];
    }
    foreach (ref p; homes) options ~= ["--scripts-in", p.name ~ "=" ~ shown(p.home)];
    foreach (ref n; project.natives)
    {
        if (n.platform != hostPlatform) continue;
        foreach (ref p; project.packages)
        {
            if (p.directory is null || !samePath(p.file, n.file)) continue;
            if (n.link !is null) options ~= ["--native-link", p.name ~ ":" ~ n.library ~ "=" ~ shown(n.link)];
            if (n.load !is null) options ~= ["--native-load", p.name ~ ":" ~ n.library ~ "=" ~ shown(n.load)];
        }
    }
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

/// Whether `name` is a package's name: segments joined by `.`, each one a module's name could have, a
/// lowercase letter or `_` and then letters, digits and `_`, so that the package can have modules. A
/// copy of `isPackageName` in loader/source/silver/loader.d, which this package can't import.
bool validName(string name)
{
    import std.algorithm : all, splitter;
    import std.ascii : isAlphaNum, isLower;

    if (name.length == 0) return false;
    foreach (segment; name.splitter('.'))
    {
        if (segment.length == 0 || !(isLower(segment[0]) || segment[0] == '_')
            || !segment.all!(c => isAlphaNum(c) || c == '_'))
            return false;
    }
    return true;
}

/// What a package's name is, worded to follow "isn't a package name: ", as the compiler words it.
enum nameRule = "it's one or more segments joined by `.`, as \"silver.core\", each a lowercase letter or `_` "
    ~ "followed by letters, digits and `_`, as in a module's name";

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
        foreach (ref entry; root.entries)
        {
            switch (entry.key)
            {
                case "name":
                    if (!name(entry.value, result.name)) return false;
                    break;
                case "source":
                    source = &entry.value;
                    break;
                case "uses":
                    if (!uses(entry.value, result.uses)) return false;
                    break;
                case "package":
                    if (!entries(entry.value)) return false;
                    break;
                case "native":
                    if (!natives(entry.value)) return false;
                    break;
                case "paths":
                    return fail(ProjectCode.UnknownField, entry.keySpan, "`[paths]` is replaced by `[[package]]`: a "
                        ~ "package elsewhere is an entry whose `path` is its directory, as [[package]] path = "
                        ~ "\"../geometry\", and its name is read from the silver.toml there");
                case "part":
                    return fail(ProjectCode.UnknownField, entry.keySpan, "`[[part]]` is replaced by `[[package]]`, an "
                        ~ "entry with the same `name`, `path`, `source` and `uses`");
                default:
                    return unknown(entry, "A package file has `name`, `source`, `uses`, `[[package]]` and "
                        ~ "`[native.<library>.<platform>]`");
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
        else if (result.described.length == 0)
        {
            result.modules = result.directory;
        }
        if (result.modules is null && result.uses.length > 0)
        {
            return fail(ProjectCode.UsesWithoutModules, root.entry("uses").keySpan, "The package "
                ~ quoted(result.name.name) ~ " describes others and has no `source`, so it has no modules of its own to "
                ~ "use anything; list what each package it describes uses in that package's `uses`, or give it a "
                ~ "`source`");
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
            return fail(ProjectCode.BadName, value.span, "\"" ~ value.text ~ "\" isn't a package name: " ~ nameRule);
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

    bool entries(const ref Value value)
    {
        if (value.kind != ValueKind.array || !(value.ofTables || allTables(value)))
        {
            return fail(ProjectCode.WrongType, value.span, "`package` is a list of packages, each written under "
                ~ "[[package]]");
        }
        foreach (ref item; value.items)
        {
            if (!entry(item)) return false;
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

    /// Checks one `[[package]]` entry: one this file describes, with a `name`, or one with only a `path`.
    bool entry(const ref Value value)
    {
        import std.path : buildPath;

        Described d;
        d.span = value.span;
        const(Value)* path;
        const(Value)* source;
        // The first of `name`, `source` and `uses`, which only a package described here has.
        const(Entry)* describing;
        const(Value)* test;
        const(Entry)* git;
        // The `tag`, `branch` and `rev` given.
        const(Entry)*[] wants;
        foreach (ref field; value.table.entries)
        {
            switch (field.key)
            {
                case "name":
                    if (!name(field.value, d.name)) return false;
                    break;
                case "path":
                    if (!str(field.value, "A package's `path`")) return false;
                    path = &field.value;
                    break;
                case "source":
                    source = &field.value;
                    break;
                case "uses":
                    if (!uses(field.value, d.uses)) return false;
                    break;
                case "test":
                    if (field.value.kind != ValueKind.boolean)
                        return fail(ProjectCode.WrongType, field.value.span, "`test` is true or false");
                    test = &field.value;
                    break;
                case "version":
                    return fail(ProjectCode.RemotePackage, field.keySpan, "`version` asks for a package from the "
                        ~ "registry, which isn't built yet; a remote package can come from git, with its `name`, `git` "
                        ~ "and a `tag`, `branch` or `rev`");
                case "git":
                    if (!str(field.value, "`git`")) return false;
                    git = &field;
                    break;
                case "branch":
                case "rev":
                case "tag":
                    if (!str(field.value, "`" ~ field.key ~ "`")) return false;
                    wants ~= &field;
                    break;
                default:
                    return unknown(field, "A `[[package]]` entry has `path`, and `name`, `source` and `uses` when it "
                        ~ "describes the package, and `test`; a remote one has `name`, `git`, `path` and one of `tag`, "
                        ~ "`branch` and `rev`");
            }
            if (describing is null && (field.key == "name" || field.key == "source" || field.key == "uses"))
                describing = &field;
        }
        if (git !is null) return remote(value, d.name, *git, path, wants, test);
        if (wants.length > 0)
        {
            return fail(ProjectCode.MissingField, wants[0].keySpan, "`" ~ wants[0].key ~ "` says what to take from a "
                ~ "git repository, and this entry gives no `git`, the repository");
        }
        if (path is null)
        {
            return fail(ProjectCode.MissingField, value.span, (d.name.name is null ? "A `[[package]]` entry"
                : "The package " ~ quoted(d.name.name)) ~ " has to give its `path`, the directory it's in, as path = "
                ~ "\"core\"");
        }
        d.pathSpan = path.span;
        if (path.text.length == 0)
        {
            return fail(ProjectCode.EmptyDirectory, path.span, "A package's `path` names a directory, and \"\" names "
                ~ "none, as \"core\"");
        }
        auto at = directoryFrom(result.directory, path.text);
        if (!isDirectory(at))
        {
            return fail(ProjectCode.NotADirectory, path.span, "A package's `path` is " ~ at ~ ", which isn't a "
                ~ "directory");
        }
        if (describing is null)
        {
            result.listed ~= Listed(at, path.span, test !is null, test !is null && test.boolean);
            return true;
        }
        if (isFile(buildPath(at, packageFileName)))
        {
            return fail(ProjectCode.DescribesItself, describing.keySpan, "`" ~ describing.key ~ "` is given for the "
                ~ "package at " ~ at ~ ", which has a silver.toml of its own that describes it, so here it's listed "
                ~ "by its `path` alone");
        }
        if (d.name.name is null)
        {
            return fail(ProjectCode.MissingField, value.span, "A package described here has to give its `name`, as "
                ~ "name = \"silver.core\"; one with a silver.toml of its own is listed by its `path` alone");
        }
        if (!directory(*path, "A package's `path`", result.directory, "the package file's directory", false, d.directory))
            return false;
        if (test !is null) d.test = test.boolean;
        if (source is null) d.modules = d.directory;
        else if (!directory(*source, "A package's `source`", d.directory, "the package's directory", true, d.modules))
            return false;
        result.described ~= d;
        return true;
    }

    /// Checks a remote entry, one with a `git`: its `name`, the repository, its `path` inside it, and
    /// what it takes.
    bool remote(const ref Value value, Named named, const ref Entry git, const(Value)* path,
        const(Entry)*[] wants, const(Value)* test)
    {
        import silver.frontend.git : fullHash, SourceKind, sourceKind, validRefName;
        import std.path : buildNormalizedPath, isAbsolute;

        foreach (ref field; value.table.entries)
        {
            if (field.key == "source" || field.key == "uses")
            {
                return fail(ProjectCode.RemoteField, field.keySpan, "`" ~ field.key ~ "` isn't given for a remote "
                    ~ "package: its own silver.toml says " ~ (field.key == "source" ? "where its modules are"
                    : "what it uses"));
            }
        }
        if (named.name is null)
        {
            return fail(ProjectCode.MissingField, value.span, "A remote package has to give its `name`, the name its "
                ~ "own silver.toml gives it, as name = \"cards\"");
        }
        if (test !is null && test.boolean)
        {
            return fail(ProjectCode.RemotePackage, test.span, "Testing a remote package isn't built yet, so its entry "
                ~ "can't say `test = true`");
        }
        Remote r = Remote(named, git.value.text, git.value.span);
        r.span = value.span;
        immutable kind = sourceKind(r.git);
        if (r.git.length == 0 || kind == SourceKind.other)
        {
            return fail(ProjectCode.RemoteSource, git.value.span, "`git` is an https:// or ssh:// URL, git's "
                ~ "user@host:path, or a directory on this machine, and \"" ~ r.git ~ "\" is none of those");
        }
        if (kind == SourceKind.local) r.directory = directoryFrom(result.directory, r.git);
        if (wants.length > 1)
        {
            return fail(ProjectCode.RemoteWant, wants[1].keySpan, "A remote package takes at most one of `tag`, `branch` "
                ~ "and `rev`, and this entry gives `" ~ wants[0].key ~ "` and `" ~ wants[1].key ~ "`");
        }
        if (wants.length == 1)
        {
            auto w = wants[0];
            r.wanted = Wanted(w.key == "tag" ? Want.tag : w.key == "branch" ? Want.branch : Want.rev, w.value.text);
            if (r.wanted.want == Want.rev && !fullHash(w.value.text))
            {
                return fail(ProjectCode.ShortRev, w.value.span, "A `rev` is a commit's full hash, its 40 characters as "
                    ~ "git writes it in lowercase, so that the commit can be fetched alone");
            }
            if (w.value.text.length == 0)
            {
                return fail(ProjectCode.RemoteWant, w.value.span, "`" ~ w.key ~ "` names a " ~ w.key ~ ", and \"\" "
                    ~ "names none; with no `tag`, `branch` or `rev` the repository's default branch is taken");
            }
            if (r.wanted.want != Want.rev && !validRefName(w.value.text))
            {
                return fail(ProjectCode.RemoteWant, w.value.span, "\"" ~ w.value.text ~ "\" isn't a name git gives a "
                    ~ w.key ~ ": it has no spaces, `~`, `^`, `:`, `?`, `*`, `[`, `\\`, `..` or `@{`, doesn't start "
                    ~ "with `-` or `.`, and doesn't end with `/`, `.` or `.lock`");
            }
        }
        if (path !is null)
        {
            if (path.text.length == 0)
            {
                return fail(ProjectCode.EmptyDirectory, path.span, "A remote package's `path` names a directory in its "
                    ~ "repository, and \"\" names none; leave it out to mean the repository's root");
            }
            auto inside = buildNormalizedPath(path.text);
            import std.array : replace;
            import std.algorithm : startsWith;

            inside = inside.replace("\\", "/");
            if (isAbsolute(path.text) || inside == ".." || inside.startsWith("../"))
            {
                return fail(ProjectCode.OutsideDirectory, path.span, "A remote package's `path` is a directory inside "
                    ~ "its repository, and \"" ~ path.text ~ "\" isn't");
            }
            if (inside != ".") r.path = inside;
            r.pathSpan = path.span;
        }
        result.remotes ~= r;
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
                ~ " " ~ baseName ~ ", " ~ base ~ ", and " ~ at ~ " isn't" ~ (self || within(at, base) ? ""
                : "; a package outside this file's directory has a silver.toml of its own there, and is listed by its "
                ~ "`path` alone"));
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
                ~ "its files; a package described in this file can't be in the directory of another silver.toml, so "
                ~ (self ? "move it out from under that file" : "list the package there by its `path` alone if that "
                ~ "file describes it, or move this one out from under that file"));
        }
        found = at;
        return true;
    }

    /// Checks `[native]`: a table for each library, of a table for each platform, of `link` and `load`, each a
    /// path relative to the file's directory, which for this platform has to be a file that's there.
    bool natives(const ref Value value)
    {
        import std.algorithm : canFind;
        import std.path : buildNormalizedPath, buildPath;

        enum shape = "`native` is a table for each library, with a table for each platform that gives the library's "
            ~ "files there, written as [native.raylib.windows]";
        if (value.kind != ValueKind.table) return fail(ProjectCode.WrongType, value.span, shape);
        foreach (ref library; value.table.entries)
        {
            if (library.value.kind != ValueKind.table) return fail(ProjectCode.WrongType, library.value.span, shape);
            if (library.key.length == 0 || library.key.canFind('=') || library.key.canFind('\0'))
            {
                return fail(ProjectCode.BadNativeLibrary, library.keySpan, "\"" ~ library.key ~ "\" isn't a library "
                    ~ "this table can give files for: it's the name a module's `native library` gives, which isn't empty "
                    ~ "and here can't hold `=` or a NUL character");
            }
            immutable named = "native." ~ library.key;
            foreach (ref platform; library.value.table.entries)
            {
                if (!nativePlatforms.canFind(platform.key))
                {
                    return fail(ProjectCode.UnknownField, platform.keySpan, "`" ~ platform.key ~ "` isn't a platform of `["
                        ~ named ~ "]`: the platforms are `windows` and `linux`");
                }
                immutable header = "[" ~ named ~ "." ~ platform.key ~ "]";
                if (platform.value.kind != ValueKind.table)
                {
                    return fail(ProjectCode.WrongType, platform.value.span, "`" ~ named ~ "." ~ platform.key ~ "` is a "
                        ~ "table of the library's files, `link` and `load`, written under " ~ header);
                }
                auto table = NativeTable(library.key, platform.key, file, platform.keySpan);
                foreach (ref field; platform.value.table.entries)
                {
                    if (field.key != "link" && field.key != "load")
                    {
                        return fail(ProjectCode.UnknownField, field.keySpan, "`" ~ field.key ~ "` isn't a field of "
                            ~ header ~ ", which has `link`, the file a program is linked against, and `load`, the "
                            ~ "shared library itself");
                    }
                    if (!str(field.value, "`" ~ field.key ~ "`, a path relative to this file,")) return false;
                    immutable written = field.value.text;
                    if (absolute(written))
                    {
                        return fail(ProjectCode.AbsoluteNativePath, field.value.span, "`" ~ field.key ~ "` is a path "
                            ~ "relative to this file's directory, and \"" ~ written ~ "\" is absolute, which would only be "
                            ~ "right on one machine");
                    }
                    auto path = buildNormalizedPath(buildPath(result.directory, written));
                    if (platform.key == hostPlatform && (written.length == 0 || !isFile(path)))
                    {
                        return fail(ProjectCode.NoNativeFile, field.value.span, "`" ~ field.key ~ "` for the library '"
                            ~ library.key ~ "' is " ~ path ~ ", which isn't a file");
                    }
                    if (field.key == "link") table.link = path;
                    else table.load = path;
                }
                result.natives ~= table;
            }
        }
        return true;
    }

    /// Whether `path` is absolute on any platform: from a root, from a drive, or a share.
    static bool absolute(string path)
    {
        import std.ascii : isAlpha;

        return path.length > 0 && (path[0] == '/' || path[0] == '\\'
            || (path.length >= 2 && isAlpha(path[0]) && path[1] == ':'));
    }

    /// Checks that the file's own package and those it describes have different names and paths, and
    /// that no entry with only a `path` leads to one of them.
    bool names()
    {
        foreach (k, ref d; result.described)
        {
            if (d.name.name == result.name.name)
            {
                return fail(ProjectCode.DuplicateName, d.name.span, "A package described here can't have this file's "
                    ~ "own name, " ~ quoted(d.name.name));
            }
            foreach (ref earlier; result.described[0 .. k])
            {
                if (earlier.name.name == d.name.name)
                {
                    return fail(ProjectCode.DuplicateName, d.name.span, "There's already a package named "
                        ~ quoted(d.name.name) ~ " here, at line " ~ decimal(earlier.name.span.line));
                }
                if (samePath(earlier.directory, d.directory))
                {
                    return fail(ProjectCode.SamePath, d.pathSpan, "The packages " ~ quoted(earlier.name.name) ~ " and "
                        ~ quoted(d.name.name) ~ " are both at " ~ d.directory);
                }
            }
        }
        foreach (k, ref l; result.listed)
        {
            if (samePath(l.directory, result.directory))
            {
                return fail(ProjectCode.ListsOwnPackage, l.pathSpan, l.directory ~ " is this file's own directory, so "
                    ~ "the package there is this file's own, " ~ quoted(result.name.name) ~ ", and needs no entry");
            }
            foreach (ref d; result.described)
            {
                if (samePath(l.directory, d.directory))
                {
                    return fail(ProjectCode.ListsOwnPackage, l.pathSpan, l.directory ~ " is the directory of "
                        ~ quoted(d.name.name) ~ ", which this file describes already, so this entry isn't needed");
                }
            }
            foreach (ref earlier; result.listed[0 .. k])
            {
                if (samePath(earlier.directory, l.directory))
                {
                    return fail(ProjectCode.SamePath, l.pathSpan, "Another `[[package]]` entry is at " ~ l.directory
                        ~ ", at line " ~ decimal(earlier.pathSpan.line));
                }
            }
        }
        foreach (k, ref r; result.remotes)
        {
            string line;
            if (r.name.name == result.name.name) line = "is this file's own";
            foreach (ref d; result.described)
            {
                if (d.name.name == r.name.name) line = "is described here, at line " ~ decimal(d.name.span.line);
            }
            foreach (ref earlier; result.remotes[0 .. k])
            {
                if (earlier.name.name == r.name.name)
                    line = "has another remote entry here, at line " ~ decimal(earlier.name.span.line);
            }
            if (line !is null)
            {
                return fail(ProjectCode.DuplicateName, r.name.span, "The package " ~ quoted(r.name.name) ~ " " ~ line
                    ~ ", and a program holds one package of a name");
            }
        }
        return true;
    }
}

/// What a `[[package]]` entry with only a `path` leads to.
struct Reached
{
    /// The package's name, as the file that describes it gives it.
    string name;
    /// That file, absolute.
    string file;
    /// The entry's directory, which is the package's home.
    string home;
    /// Where its modules are, absolute, or null when it only describes others.
    string modules;
    Span pathSpan;
    /// Whether `file` is in the entry's directory, rather than above it.
    bool ownFile;
    /// For a fetched package, the entry that fetched it and the commit, for a message; else null.
    string fetched;
}

/// Follows the packages of files, file by file, reading each file once.
struct ProjectReader
{
    Facts[] packages;
    PackageFile[] read;
    NativeTable[] natives;
    /// What fetches remote packages, and records them for the lock.
    Remotes remotes;
    /// The directories fetched packages' repositories are in.
    string[] checkouts;
    /// For each package fetched, the entry that fetched it, for a message about another that disagrees.
    string[string] fetchedBy;

    const(Facts)* named(string name) const
    {
        foreach (ref p; packages)
        {
            if (p.name == name) return &p;
        }
        return null;
    }

    /// The package file `file`, read and checked once.
    bool fileAt(string file, out PackageFile found, out Mistake mistake)
    {
        foreach (ref f; read)
        {
            if (samePath(f.file, file))
            {
                found = f;
                return true;
            }
        }
        if (!readPackageFile(file, found, mistake)) return false;
        read ~= found;
        return true;
    }

    /// Adds the packages of `file`, then follows what each uses.
    bool add(PackageFile file, out Mistake mistake)
    {
        import std.algorithm : map;
        import std.array : array;

        bool declare(Named name, string home, string modules, Named[] uses, string[] describes)
        {
            if (auto other = named(name.name))
            {
                mistake = Mistake(file.file, ProjectCode.TwoDirectories, name.span, "There's already a package named "
                    ~ quoted(name.name) ~ ", at " ~ other.home ~ ", described in " ~ other.file);
                return false;
            }
            packages ~= Facts(name.name, modules, uses.map!(u => u.name).array, describes, file.file, home);
            return true;
        }
        if (!declare(file.name, file.directory, file.modules, file.uses, file.described.map!(d => d.name.name).array))
            return false;
        natives ~= file.natives;
        foreach (ref d; file.described)
        {
            if (!declare(d.name, d.directory, d.modules, d.uses, null)) return false;
        }
        Reached[] listed;
        if (!resolve(file, listed, mistake)) return false;
        if (!follow(file, file.uses, listed, mistake)) return false;
        foreach (ref d; file.described)
        {
            if (!follow(file, d.uses, listed, mistake)) return false;
        }
        return true;
    }

    /// Reads the file behind each of `file.listed`: the package file in its directory, or else the nearest
    /// above it, which has to describe a package there. A fetched package's entries stay in its repository.
    bool resolve(const ref PackageFile file, out Reached[] reached, out Mistake mistake)
    {
        immutable confine = checkoutHolding(file.file);
        foreach (ref entry; file.listed)
        {
            bool fail(string code, string message)
            {
                mistake = Mistake(file.file, code, entry.pathSpan, message);
                return false;
            }
            if (confine !is null && !within(entry.directory, confine))
            {
                return fail(ProjectCode.OutsideRepository, "This package was fetched, and its entries stay in its "
                    ~ "repository, " ~ confine ~ ", which " ~ entry.directory ~ " is outside");
            }
            Reached r;
            if (!locate(file, entry.directory, entry.pathSpan, confine, r, mistake)) return false;
            string clash;
            if (r.name == file.name.name) clash = file.directory;
            foreach (ref d; file.described)
            {
                if (d.name.name == r.name) clash = d.directory;
            }
            foreach (ref earlier; reached)
            {
                if (earlier.name == r.name) clash = earlier.home;
            }
            if (clash !is null)
            {
                return fail(ProjectCode.TwoDirectories, quoted(r.name) ~ " is at " ~ entry.directory ~ ", described in "
                    ~ r.file ~ ", and this file already has a package of that name, at " ~ clash);
            }
            foreach (ref remote; file.remotes)
            {
                if (remote.name.name == r.name)
                {
                    return fail(ProjectCode.DuplicateName, quoted(r.name) ~ " is at " ~ entry.directory ~ ", described "
                        ~ "in " ~ r.file ~ ", and this file has a remote entry of that name too, at line "
                        ~ decimal(remote.name.span.line));
                }
            }
            auto there = fileOf(r);
            if (auto inside = nested(r.ownFile ? placedOf(there) : [Placed(r.name, r.modules, r.home)], placedOf(file)))
                return fail(ProjectCode.InsidePackage, inside);
            reached ~= r;
        }
        return true;
    }

    /// The package file at `r.file`, which `locate` has read.
    PackageFile fileOf(const ref Reached r)
    {
        PackageFile found;
        Mistake mistake;
        immutable ok = fileAt(r.file, found, mistake);
        assert(ok);
        return found;
    }

    /// The checkout of a fetched package that holds `path`, or null.
    string checkoutHolding(string path) const
    {
        foreach (c; checkouts)
        {
            if (within(path, c)) return c;
        }
        return null;
    }

    /// What the package at `directory` is, which an entry of `file` at `span` names: the package file in
    /// that directory, or else the nearest above it, which has to describe a package there. With a
    /// `confine`, the directory is in that fetched repository, and no file above it counts.
    bool locate(const ref PackageFile file, string directory, Span span, string confine, out Reached r,
        out Mistake mistake)
    {
        import std.path : buildPath, dirName;

        bool fail(string code, string message)
        {
            mistake = Mistake(file.file, code, span, message);
            return false;
        }
        immutable fetched = confine !is null && !within(file.file, confine);
        auto describing = buildPath(directory, packageFileName);
        immutable own = isFile(describing);
        if (!own)
        {
            auto above = dirName(directory);
            describing = above == directory || (confine !is null && !within(above, confine)) ? null
                : findPackageFile(above);
            if (describing !is null && confine !is null && !within(describing, confine)) describing = null;
        }
        // What to write instead: a package with no file of its own can only be described here when it's
        // under this file's directory.
        immutable noName = fetched
            ? "; a remote entry's `path` is the directory of a package in its repository, one with a silver.toml of "
                ~ "its own or described by the nearest above it"
            : within(directory, file.directory)
            ? "; a package with no silver.toml of its own is described here, with its `name` as well as its `path`"
            : "; a package outside this file's directory has a silver.toml of its own, so give that directory one, "
                ~ "or give the `path` of a package another file describes";
        if (describing is null)
        {
            return fail(ProjectCode.NoPackageThere, directory ~ " has no " ~ packageFileName ~ ", and no "
                ~ "directory above it" ~ (confine is null ? "" : " in its repository") ~ " has one" ~ noName);
        }
        PackageFile there;
        if (!fileAt(describing, there, mistake))
        {
            if (mistake.file !is null && samePath(mistake.file, describing))
                mistake.message ~= "\nIt was read because " ~ file.file ~ " lists it, at line " ~ decimal(span.line);
            return false;
        }
        r = Reached(null, there.file, directory, null, span, own);
        if (own)
        {
            r.name = there.name.name;
            r.modules = there.modules;
            return true;
        }
        foreach (ref d; there.described)
        {
            if (samePath(d.directory, directory))
            {
                r.name = d.name.name;
                r.modules = d.modules;
            }
        }
        if (r.name !is null) return true;
        // A directory of modules below a package's own: that package is what's meant.
        string holder;
        foreach (p; placedOf(there))
        {
            if (within(directory, p.modules)) holder = p.home;
        }
        return fail(ProjectCode.NoPackageThere, directory ~ " has no " ~ packageFileName ~ ", and " ~ describing
            ~ ", the nearest above it, describes no package there" ~ (holder is null ? noName
            : "; it holds modules of the package at " ~ holder ~ ", which is listed as `path = \""
            ~ written(holder, fetched ? confine : file.directory) ~ "\"`"));
    }

    /// Fetches the package that `remote`, an entry of `file`, names, and finds it as `locate` does in its
    /// repository's files.
    bool fetch(const ref PackageFile file, const ref Remote remote, out Reached r, out Mistake mistake)
    {
        import std.path : buildNormalizedPath;

        bool fail(string code, Span span, string message)
        {
            mistake = Mistake(file.file, code, span, message);
            return false;
        }
        assert(remotes !is null, "a project with remote packages is read with a Remotes");
        if (remote.directory !is null)
        {
            if (auto repository = checkoutHolding(file.file))
            {
                return fail(ProjectCode.OutsideRepository, remote.gitSpan, "This package was fetched, and its remote "
                    ~ "entries name repositories by URL: a directory, \"" ~ remote.git ~ "\", names one on its author's "
                    ~ "machine");
            }
        }
        string files, commit;
        if (!remotes.checkout(file, remote, files, commit, mistake)) return false;
        auto home = remote.path is null ? files : buildNormalizedPath(files, remote.path);
        immutable span = remote.path is null ? remote.gitSpan : remote.pathSpan;
        auto source = remote.git ~ " at commit " ~ commit;
        if (!isDirectory(home))
        {
            return fail(ProjectCode.NotADirectory, span, "The repository " ~ source ~ " has no directory " ~ remote.path
                ~ ", the entry's `path`");
        }
        bool known;
        foreach (c; checkouts) known = known || samePath(c, files);
        if (!known) checkouts ~= files;
        if (!locate(file, home, span, files, r, mistake)) return false;
        if (r.name != remote.name.name)
        {
            return fail(ProjectCode.NameMismatch, remote.name.span, "This entry names the package " ~ quoted(remote.name.name)
                ~ ", and " ~ r.file ~ ", which describes the package at " ~ (remote.path is null ? "the root of "
                ~ source : remote.path ~ " in " ~ source) ~ ", names it " ~ quoted(r.name) ~ "; a remote entry's `name` is "
                ~ "the name the package's own file gives it, which is the name its modules are under");
        }
        r.fetched = "the entry at line " ~ decimal(remote.span.line) ~ " of " ~ file.file ~ ", git = "
            ~ quotedString(remote.git) ~ (remote.path is null ? "" : ", path = " ~ quotedString(remote.path))
            ~ wantedText(remote.wanted) ~ ", which is commit " ~ commit;
        return true;
    }

    /// Finds each of `uses`, listed in `file`, whose entries with only a `path` lead to `listed`, and
    /// whose remote entries are fetched.
    bool follow(const ref PackageFile file, const Named[] uses, const Reached[] listed, out Mistake mistake)
    {
        foreach (used; uses)
        {
            bool own = used.name == file.name.name;
            foreach (ref d; file.described) own = own || d.name.name == used.name;
            if (own) continue;
            const(Reached)* entry;
            foreach (ref r; listed)
            {
                if (r.name == used.name) entry = &r;
            }
            if (entry is null)
            {
                import std.array : join;

                bool fetched;
                foreach (ref remote; file.remotes)
                {
                    if (remote.name.name != used.name) continue;
                    Reached r;
                    if (!fetch(file, remote, r, mistake)) return false;
                    if (!reach(file, r, mistake)) return false;
                    fetched = true;
                    break;
                }
                if (fetched) continue;

                // The names the entries do give, so that a name written differently shows.
                string[] given;
                foreach (ref d; file.described) given ~= quoted(d.name.name) ~ " at line " ~ decimal(d.name.span.line);
                foreach (ref r; listed)
                    given ~= quoted(r.name) ~ " at line " ~ decimal(r.pathSpan.line) ~ ", as its silver.toml names it";
                foreach (ref r; file.remotes) given ~= quoted(r.name.name) ~ " at line " ~ decimal(r.name.span.line);
                mistake = Mistake(file.file, ProjectCode.UnknownPackage, used.span, "No `[[package]]` entry here "
                    ~ "gives " ~ quoted(used.name) ~ (given.length > 0 ? ": the entries give " ~ given.join("; ")
                        ~ ", and a name in `uses` is the name a package's own file gives it"
                    : ": a package described here is an entry with its `name` and `path`, and one with a silver.toml "
                        ~ "of its own an entry with its `path` alone, as [[package]] path = \"../" ~ used.name ~ "\""));
                return false;
            }
            if (!reach(file, *entry, mistake)) return false;
        }
        return true;
    }

    /// Fetches every remote package that the project's own files name, whether or not anything uses it:
    /// `root` and each file its `path` entries lead to, in turn, used or not. A package fetched is followed
    /// as when it's used, only as far as what it uses, so its other entries, such as those only its own
    /// tests use, aren't fetched. So what the lock holds depends only on the package files, never on the
    /// command. What's found is added to a copy of this reader, so the packages given to the compiler stay
    /// those the run uses, while two entries that disagree are still refused.
    bool fetchAll(const ref PackageFile root, out Mistake mistake)
    {
        auto named = this;
        named.fetchedBy = fetchedBy.dup;
        PackageFile[] pending = [cast(PackageFile) root];
        string[] seen = [root.file];
        for (size_t k = 0; k < pending.length; k++)
        {
            auto file = pending[k];
            Reached[] listed;
            if (!named.resolve(file, listed, mistake)) return false;
            foreach (ref r; listed)
            {
                bool known;
                foreach (f; seen) known = known || samePath(f, r.file);
                if (known || named.checkoutHolding(r.file) !is null) continue;
                seen ~= r.file;
                PackageFile found;
                if (!named.fileAt(r.file, found, mistake)) return false;
                pending ~= found;
            }
            foreach (ref remote; file.remotes)
            {
                Reached r;
                if (!named.fetch(file, remote, r, mistake)) return false;
                if (!named.reach(file, r, mistake)) return false;
            }
        }
        return true;
    }

    /// Adds the packages of the file that the entry of `from` at `directory` leads to, as when it's used,
    /// and gives that file.
    bool include(const ref PackageFile from, string directory, out PackageFile found, out Mistake mistake)
    {
        Reached[] listed;
        if (!resolve(from, listed, mistake)) return false;
        foreach (ref r; listed)
        {
            if (!samePath(r.home, directory)) continue;
            if (!reach(from, r, mistake)) return false;
            return fileAt(r.file, found, mistake);
        }
        assert(false, "no entry at " ~ directory);
    }

    /// Adds the packages of the file that `entry` leads to, unless they have been.
    bool reach(const ref PackageFile from, const ref Reached entry, out Mistake mistake)
    {
        bool fail(string code, string message)
        {
            mistake = Mistake(from.file, code, entry.pathSpan, message);
            return false;
        }
        if (auto known = named(entry.name))
        {
            if (samePath(known.home, entry.home)) return true;
            auto before = known.name in fetchedBy;
            if (entry.fetched !is null || before !is null)
            {
                return fail(ProjectCode.RemoteConflict, quoted(entry.name) ~ " is reached by " ~ (entry.fetched is null
                    ? "the entry here, at " ~ entry.home : entry.fetched) ~ ", and already by " ~ (before is null
                    ? "the package at " ~ known.home ~ ", described in " ~ known.file : *before) ~ "; a program holds "
                    ~ "one package of a name, from one source at one commit");
            }
            return fail(ProjectCode.TwoDirectories, quoted(entry.name) ~ " is at " ~ entry.home ~ " here, and already "
                ~ "at " ~ known.home ~ ", described in " ~ known.file);
        }
        PackageFile found;
        if (!fileAt(entry.file, found, mistake)) return false;
        Placed[] known;
        foreach (ref p; packages)
        {
            if (p.directory !is null) known ~= Placed(p.name, p.directory, p.home);
        }
        if (auto inside = nested(placedOf(found), known)) return fail(ProjectCode.InsidePackage, inside);
        if (entry.fetched !is null) fetchedBy[entry.name] = entry.fetched;
        if (!add(found, mistake))
        {
            if (entry.fetched !is null && mistake.file !is null && !samePath(mistake.file, from.file)
                && checkoutHolding(mistake.file) !is null)
                mistake.message ~= "\nIt was fetched for " ~ entry.fetched;
            return false;
        }
        return true;
    }
}

/// A package with modules: its name, where they are, and its home.
struct Placed
{
    string name;
    string modules;
    string home;
}

/// The packages of `file` that have modules.
Placed[] placedOf(const ref PackageFile file)
{
    Placed[] placed;
    if (file.modules !is null) placed ~= Placed(file.name.name, file.modules, file.directory);
    foreach (ref d; file.described)
    {
        if (d.modules !is null) placed ~= Placed(d.name.name, d.modules, d.directory);
    }
    return placed;
}

/// Why one of `added` and one of `known` would have one directory of modules inside the other because
/// the outer one's modules are its whole directory, or null. The compiler refuses any such pair; only
/// this one comes from how a `silver.toml` maps to directories.
string nested(const Placed[] added, const Placed[] known)
{
    string message(Placed inner, Placed outer)
    {
        return quoted(inner.name) ~ " is at " ~ inner.home ~ ", inside the directory of " ~ quoted(outer.name)
            ~ ", at " ~ outer.home ~ ", whose modules are that whole directory, so a file of " ~ quoted(inner.name)
            ~ " would be a module of both; giving " ~ quoted(outer.name) ~ " a `source` directory below it "
            ~ "avoids it";
    }
    foreach (k; known)
    {
        foreach (a; added)
        {
            if (a.modules is null || k.modules is null) continue;
            if (samePath(k.modules, k.home) && within(a.modules, k.modules)) return message(a, k);
            if (samePath(a.modules, a.home) && within(k.modules, a.modules)) return message(k, a);
        }
    }
    return null;
}

/// `directory` as a `path` in a package file in `base` would write it, with `/`.
string written(string directory, string base)
{
    import std.array : replace;
    import std.path : relativePath;

    return relativePath(directory, base).replace("\\", "/");
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

    /// The compiler's own shape, from docs/silver.md: a root with no modules that describes library
    /// packages and two that are programs.
    enum compilerShape = [
        "tool/silver.toml": "name = \"tool\"\n\n[[package]]\nname = \"tool.ast\"\npath = \"ast\"\n\n"
            ~ "[[package]]\nname = \"tool.syntax\"\npath = \"syntax\"\nuses = [\"tool.ast\"]\n\n"
            ~ "[[package]]\nname = \"tool.compiler\"\npath = \"compiler\"\nsource = \"source\"\n"
            ~ "uses = [\"tool.syntax\", \"tool.ast\"]\n\n"
            ~ "[[package]]\nname = \"tool.frontend\"\npath = \"frontend\"\n",
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

@("a package file's fields, with the defaults for where modules are, and its two kinds of [[package]] entry")
unittest
{
    auto directory = makeTree("project-fields", ["source/": "", "core/src/": "", "lib/": "", "vendor/geo/": "", "x/": ""]);
    scope (exit) rmdirRecurse(directory);

    auto plain = checked(directory, "name = \"geometry\"");
    assert(plain.name.name == "geometry" && plain.modules == directory && plain.described.length == 0);
    assert(checked(directory, "name = \"g\"\nsource = \"source\"").modules == buildPath(directory, "source"));
    assert(checked(directory, "name = \"g\"\nsource = \".\"").modules == directory);

    auto full = checked(directory, "# a project\nname = \"silver\"\nsource = \"source\"\nuses = [\"geometry\", \"x.y\"]\n"
        ~ "[[package]]\npath = \"vendor/geo\"\ntest = false\n[[package]]\npath = 'x'\n"
        ~ "[[package]]\nname = \"silver.core\"\npath = \"core\"\nsource = \"src\"\nuses = [\"geometry\"]\ntest = true\n"
        ~ "[[package]]\nname = \"silver.lib\"\npath = \"lib\"\n");
    assert(full.uses.length == 2 && full.uses[1].name == "x.y" && full.uses[1].span.line == 4);
    assert(full.listed.length == 2 && full.listed[1].directory == buildPath(directory, "x"));
    assert(full.listed[0].pathSpan.line == 6 && full.listed[0].pathSpan.column == 8);
    assert(full.described.length == 2 && full.described[0].modules == buildPath(directory, "core", "src"));
    assert(full.described[1].modules == buildPath(directory, "lib") && full.described[1].span.line == 16);

    // Listing packages with files of their own leaves the file's package its modules; describing one doesn't.
    assert(checked(directory, "name = \"g\"\n[[package]]\npath = \"x\"").modules == directory);
    assert(checked(directory, "name = \"g\"\n[[package]]\nname = \"g.lib\"\npath = \"lib\"").modules is null);
    assert(checked(directory, "name = \"g\"\npackage = [{ name = \"g.lib\", path = \"lib\" }]").described.length == 1);
    assert(checked(directory, "name = \"g\"\npackage = [{ path = \"lib\" }]").listed.length == 1);
}

@("each mistake in a package file has its code and position")
unittest
{
    auto directory = makeTree("project-mistakes", ["lib/": "", "core/": "", "has-file/silver.toml": "name = \"x\"",
        "file.txt": ""]);
    scope (exit) rmdirRecurse(directory);
    alias m = (text, code, line, column) => mistakeIn(directory, text, code, line, column);

    m("name = \"g\"\nversion = \"1\"", ProjectCode.UnknownField, 2, 1);
    m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"lib\"\nmain = true", ProjectCode.UnknownField, 5, 1);
    m("name = \"g\"\n[dependencies]\nx = \"y\"", ProjectCode.UnknownField, 2, 2);
    m("name = 1", ProjectCode.WrongType, 1, 8);
    m("name = \"g\"\nsource = [\"a\"]", ProjectCode.WrongType, 2, 10);
    m("name = \"g\"\nuses = \"geometry\"", ProjectCode.WrongType, 2, 8);
    m("name = \"g\"\nuses = [\"a\", 2]", ProjectCode.WrongType, 2, 14);
    m("name = \"g\"\npackage = \"x\"", ProjectCode.WrongType, 2, 11);
    m("name = \"g\"\n[package]\nname = \"x\"", ProjectCode.WrongType, 2, 1);
    m("name = \"g\"\npackage = [1]", ProjectCode.WrongType, 2, 11);
    m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = 1", ProjectCode.WrongType, 4, 8);
    auto test = m("name = \"g\"\n[[package]]\npath = \"lib\"\ntest = \"yes\"", ProjectCode.WrongType, 4, 8);
    assert(test.message == "`test` is true or false", test.message);
    m("uses = [\"a\"]", ProjectCode.MissingField, 1, 1);
    m("", ProjectCode.MissingField, 1, 1);
    m("name = \"g\"\n\n[[package]]\nuses = [\"a\"]", ProjectCode.MissingField, 3, 1);
    m("name = \"g\"\n\n[[package]]\nname = \"g.lib\"", ProjectCode.MissingField, 3, 1);
    auto unnamed = m("name = \"g\"\n\n[[package]]\nsource = \"src\"\npath = \"lib\"", ProjectCode.MissingField, 3, 1);
    assert(unnamed.message == "A package described here has to give its `name`, as name = \"silver.core\"; one with a "
        ~ "silver.toml of its own is listed by its `path` alone", unnamed.message);
    m("name = \"geo metry\"", ProjectCode.BadName, 1, 8);
    m("name = \"g.\"", ProjectCode.BadName, 1, 8);
    m("name = \"1g\"", ProjectCode.BadName, 1, 8);
    m("name = \"g\"\nuses = [\"a-b\"]", ProjectCode.BadName, 2, 9);
    m("name = \"g\"\nsource = \"..\"", ProjectCode.OutsideDirectory, 2, 10);
    m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"..\"", ProjectCode.OutsideDirectory, 4, 8);
    m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \".\"", ProjectCode.OutsideDirectory, 4, 8);
    m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"lib\"\nsource = \"../core\"", ProjectCode.OutsideDirectory, 5, 10);
    m("name = \"g\"\nsource = \"missing\"", ProjectCode.NotADirectory, 2, 10);
    m("name = \"g\"\nsource = \"file.txt\"", ProjectCode.NotADirectory, 2, 10);
    m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"missing\"", ProjectCode.NotADirectory, 4, 8);
    m("name = \"g\"\n[[package]]\npath = \"../missing\"", ProjectCode.NotADirectory, 3, 8);
    m("name = \"g\"\nuses = [\"a\", \"b\", \"a\"]", ProjectCode.DuplicateName, 2, 19);
    m("name = \"g\"\n[[package]]\nname = \"g\"\npath = \"lib\"", ProjectCode.DuplicateName, 3, 8);
    m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"lib\"\n[[package]]\nname = \"g.x\"\npath = \"core\"",
        ProjectCode.DuplicateName, 6, 8);
    m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"lib\"\n[[package]]\nname = \"g.y\"\npath = \"./lib/\"",
        ProjectCode.SamePath, 7, 8);
    m("name = \"g\"\n[[package]]\npath = \"core\"\n[[package]]\npath = \"./core\"", ProjectCode.SamePath, 5, 8);
    auto itself = m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"has-file\"", ProjectCode.DescribesItself, 3, 1);
    assert(itself.message == "`name` is given for the package at " ~ buildPath(directory, "has-file") ~ ", which has a "
        ~ "silver.toml of its own that describes it, so here it's listed by its `path` alone", itself.message);
    m("name = \"g\"\n[[package]]\npath = \"has-file\"\nuses = [\"a\"]", ProjectCode.DescribesItself, 4, 1);
    m("name = \"g\"\nuses = [\"std\"]", ProjectCode.StandardLibraryListed, 2, 9);
    m("name = \"g\"\n[[package]]\npath = \".\"", ProjectCode.ListsOwnPackage, 3, 8);
    m("name = \"g\"\n[[package]]\npath = \"lib\"\n[[package]]\nname = \"g.x\"\npath = \"lib\"", ProjectCode.ListsOwnPackage,
        3, 8);
    m("name = \"g\"\nuses = [\"a\"]\n[[package]]\nname = \"g.x\"\npath = \"lib\"", ProjectCode.UsesWithoutModules, 2, 1);
    m("name = \"g\"\nuses = [geometry]", TomlCode.BadValue, 2, 9);
    auto remote = m("name = \"g\"\n[[package]]\nname = \"geo\"\nversion = \"1.2\"", ProjectCode.RemotePackage, 4, 1);
    assert(remote.message == "`version` asks for a package from the registry, which isn't built yet; a remote package "
        ~ "can come from git, with its `name`, `git` and a `tag`, `branch` or `rev`", remote.message);
    m("name = \"g\"\n[[package]]\nname = \"geo\"\ngit = \"https://example.com/geo\"\nversion = \"1\"",
        ProjectCode.RemotePackage, 5, 1);
    m("name = \"g\"\n[[package]]\npath = \"lib\"\nrev = \"abc\"", ProjectCode.MissingField, 4, 1);
    auto ownEntry = m("name = \"g\"\n[[package]]\npath = \".\"", ProjectCode.ListsOwnPackage, 3, 8);
    assert(ownEntry.message == directory ~ " is this file's own directory, so the package there is this file's own, "
        ~ "'g', and needs no entry", ownEntry.message);

    // What replaced the old fields.
    auto paths = m("name = \"g\"\n[paths]\ngeometry = \"../geometry\"", ProjectCode.UnknownField, 2, 2);
    assert(paths.message == "`[paths]` is replaced by `[[package]]`: a package elsewhere is an entry whose `path` is its "
        ~ "directory, as [[package]] path = \"../geometry\", and its name is read from the silver.toml there", paths.message);
    auto part = m("name = \"g\"\n[[part]]\nname = \"g.x\"\npath = \"lib\"", ProjectCode.UnknownField, 2, 3);
    assert(part.message == "`[[part]]` is replaced by `[[package]]`, an entry with the same `name`, `path`, `source` and "
        ~ "`uses`", part.message);
}

@("a [native.<library>.<platform>] table gives `link` and `load` relative to the file, and this platform's have to be there")
unittest
{
    import std.algorithm : canFind;
    import std.conv : to;

    auto directory = makeTree("project-natives", ["lib/ray.a": "", "lib/ray.dll": "", "lib/dir/": ""]);
    scope (exit) rmdirRecurse(directory);
    enum other = hostPlatform == "windows" ? "linux" : "windows";

    auto file = checked(directory, "name = \"g\"\n[native.ray." ~ hostPlatform ~ "]\nlink = \"lib/ray.a\"\n"
        ~ "load = \"./lib/../lib/ray.dll\"\n[native.ray." ~ other ~ "]\nload = \"lib/gone.so\"\n"
        ~ "[native.sdl." ~ hostPlatform ~ "]\nload = \"lib/ray.dll\"");
    assert(file.natives.length == 3, file.natives.to!string);
    auto ray = file.natives[0];
    assert(ray.library == "ray" && ray.platform == hostPlatform && ray.file == buildPath(directory, packageFileName)
        && ray.span.line == 2 && ray.span.column == 13, ray.to!string);
    assert(ray.link == buildPath(directory, "lib", "ray.a") && ray.load == buildPath(directory, "lib", "ray.dll"),
        ray.to!string);
    // Another platform's files aren't read here, so they needn't be there.
    assert(file.natives[1].load == buildPath(directory, "lib", "gone.so") && file.natives[1].link is null);
    // Inline tables are tables too.
    assert(checked(directory, "name = \"g\"\nnative = { ray = { " ~ hostPlatform ~ " = { load = \"lib/ray.dll\" } } }")
        .natives.length == 1);

    alias m = (string text, string code, uint line, uint column) => mistakeIn(directory, "name = \"g\"\n" ~ text, code, line,
        column);
    auto platform = m("[native.ray.macos]\nload = \"lib/ray.dll\"", ProjectCode.UnknownField, 2, 13);
    assert(platform.message == "`macos` isn't a platform of `[native.ray]`: the platforms are `windows` and `linux`",
        platform.message);
    auto key = m("[native.ray." ~ hostPlatform ~ "]\nfile = \"lib/ray.dll\"", ProjectCode.UnknownField, 3, 1);
    assert(key.message.canFind("`file` isn't a field of [native.ray." ~ hostPlatform ~ "], which has `link`"), key.message);
    m("[native.ray." ~ hostPlatform ~ "]\nload = 1", ProjectCode.WrongType, 3, 8);
    m("native = \"ray\"", ProjectCode.WrongType, 2, 10);
    m("native.ray = 1", ProjectCode.WrongType, 2, 14);
    m("native.ray." ~ hostPlatform ~ " = \"lib/ray.dll\"", ProjectCode.WrongType, 2, 15 + cast(uint) hostPlatform.length);
    foreach (absolute; ["/usr/lib/libray.so", `C:\\lib\\ray.dll`, "c:/lib/ray.dll", `\\\\server\\ray.dll`])
    {
        auto refused = m("[native.ray." ~ other ~ "]\nlink = \"" ~ absolute ~ "\"", ProjectCode.AbsoluteNativePath, 3, 8);
        assert(refused.message.canFind("is absolute, which would only be right on one machine"), refused.message);
    }
    auto missing = m("[native.ray." ~ hostPlatform ~ "]\nlink = \"lib/ray.a\"\nload = \"lib/gone.dll\"", ProjectCode.NoNativeFile,
        4, 8);
    assert(missing.message == "`load` for the library 'ray' is " ~ buildPath(directory, "lib", "gone.dll")
        ~ ", which isn't a file", missing.message);
    m("[native.ray." ~ hostPlatform ~ "]\nlink = \"lib/dir\"", ProjectCode.NoNativeFile, 3, 8);
    m("[native.ray." ~ hostPlatform ~ "]\nlink = \"\"", ProjectCode.NoNativeFile, 3, 8);
    auto equals = m("[native.\"a=b\"." ~ other ~ "]\nlink = \"x.a\"", ProjectCode.BadNativeLibrary, 2, 9);
    assert(equals.message == "\"a=b\" isn't a library this table can give files for: it's the name a module's `native "
        ~ "library` gives, which isn't empty and here can't hold `=` or a NUL character", equals.message);
    m("[native.\"\"." ~ hostPlatform ~ "]\nload = \"lib/ray.dll\"", ProjectCode.BadNativeLibrary, 2, 9);
}

@("a table is given to the compiler for each package of its own file, and only this platform's files")
unittest
{
    import std.conv : to;

    auto directory = makeTree("project-natives-packages", [
        "app/silver.toml": "name = \"app\"\nuses = [\"ray\"]\n[[package]]\npath = \"../ray\"\n\n[native.ray." ~ hostPlatform
            ~ "]\nload = \"r.dll\"\n",
        "app/r.dll": "",
        "ray/silver.toml": "name = \"ray\"\n[[package]]\nname = \"ray.extra\"\npath = \"extra\"\n\n[native.ray."
            ~ hostPlatform ~ "]\nlink = \"r.a\"\nload = \"r.dll\"\n",
        "ray/extra/": "",
        "ray/r.a": "",
        "ray/r.dll": "",
    ]);
    scope (exit) rmdirRecurse(directory);

    // ray's file describes no modules of its own, only ray.extra's, which is the package its table is for.
    auto options = compilerOptions(project(buildPath(directory, "app", "silver.toml")), (string path) => path);
    auto ray = (string file) => buildPath(directory, "ray", file);
    assert(options[$ - 6 .. $] == ["--native-load", "app:ray=" ~ buildPath(directory, "app", "r.dll"),
        "--native-link", "ray.extra:ray=" ~ ray("r.a"), "--native-load", "ray.extra:ray=" ~ ray("r.dll")],
        options.to!string);
}

@("two packages tested in one run that never share a program can each give the same library")
unittest
{
    enum table = "\n[native.num." ~ hostPlatform ~ "]\nload = \"num.dll\"\n";
    auto directory = makeTree("project-natives-tested", [
        "silver.toml": "name = \"ws\"\nsource = \"src\"\n\n[[package]]\npath = \"a\"\n\n[[package]]\npath = \"b\"\n",
        "src/": "",
        "a/silver.toml": "name = \"a\"\nsource = \"src\"\n" ~ table,
        "a/src/": "",
        "a/num.dll": "",
        "b/silver.toml": "name = \"b\"\nsource = \"src\"\n" ~ table,
        "b/src/": "",
        "b/num.dll": "",
    ]);
    scope (exit) rmdirRecurse(directory);

    // Neither uses the other, so no program holds both, and each alone is fine.
    project(buildPath(directory, "a", "silver.toml"));
    project(buildPath(directory, "b", "silver.toml"));
    TestRun run;
    Mistake mistake;
    assert(readTestRun(buildPath(directory, "silver.toml"), directory, run, mistake), formatMistake(mistake));
}

@("a [native] table's library is a name that `native library` can give and an option can carry")
unittest
{
    auto directory = makeTree("project-natives-names", ["num.dll": ""]);
    scope (exit) rmdirRecurse(directory);
    foreach (library; [`""`, `"a=b"`])
    {
        PackageFile file;
        Mistake mistake;
        assert(!checkPackageFile(buildPath(directory, packageFileName), "name = \"g\"\n[native." ~ library ~ "."
            ~ hostPlatform ~ "]\nload = \"num.dll\"", file, mistake), "no mistake for the library " ~ library);
    }
}

@("a remote entry gives a name, a repository, a path in it and what to take, and each mistake in one is located")
unittest
{
    import std.path : dirName;

    auto directory = makeTree("frontend-remote-entries", null);
    scope (exit) rmdirRecurse(directory);
    enum head = "name = \"g\"\n[[package]]\nname = \"cards\"\n";
    auto file = checked(directory, head ~ "git = \"https://example.com/cards\"\npath = \"lib/./cards\"\ntag = \"v1\"\n"
        ~ "test = false\n");
    assert(file.remotes.length == 1 && file.listed.length == 0 && file.described.length == 0);
    assert(file.remotes[0].name.name == "cards" && file.remotes[0].git == "https://example.com/cards");
    assert(file.remotes[0].path == "lib/cards" && file.remotes[0].wanted == Wanted(Want.tag, "v1"));
    assert(file.remotes[0].directory is null && file.remotes[0].span.line == 2);
    auto local = checked(directory, head ~ "git = \"../repo\"\npath = \".\"\n").remotes[0];
    assert(local.directory == buildPath(dirName(directory), "repo") && local.path is null);
    assert(local.wanted == Wanted(Want.defaultBranch));
    enum hash = "4f1c2a9e0b7d3c58e6a1f92d4b0c7e3a5d8f1b26";
    assert(checked(directory, head ~ "git = \"git@host:a/cards\"\nrev = \"" ~ hash ~ "\"\n").remotes[0].wanted
        == Wanted(Want.rev, hash));
    checked(directory, head ~ "git = \"ssh://git@host/a/cards\"\nbranch = \"main\"\n");

    void m(string text, string code, uint line, uint column) => cast(void) mistakeIn(directory, text, code, line, column);
    enum git = "git = \"https://example.com/cards\"\n";
    m(head ~ git ~ "source = \"src\"\n", ProjectCode.RemoteField, 5, 1);
    m(head ~ "uses = [\"x\"]\n" ~ git, ProjectCode.RemoteField, 4, 1);
    m(head ~ git ~ "tag = \"v1\"\nbranch = \"main\"\n", ProjectCode.RemoteWant, 6, 1);
    m(head ~ git ~ "tag = \"\"\n", ProjectCode.RemoteWant, 5, 7);
    m(head ~ git ~ "rev = \"4f1c2a9\"\n", ProjectCode.ShortRev, 5, 7);
    foreach (bad; ["-x", "--upload-pack=y", "a b", "v1:refs/heads/x", "a*", "x^{}"])
    {
        m(head ~ git ~ "tag = \"" ~ bad ~ "\"\n", ProjectCode.RemoteWant, 5, 7);
        m(head ~ git ~ "branch = \"" ~ bad ~ "\"\n", ProjectCode.RemoteWant, 5, 10);
    }
    m(head ~ git ~ "rev = \"" ~ hash[0 .. $ - 1] ~ "G\"\n", ProjectCode.ShortRev, 5, 7);
    foreach (refused; ["http://example.com/cards", "file:///srv/cards", "git://host/cards", "ext::sh -c x", ""])
        m(head ~ "git = \"" ~ refused ~ "\"\n", ProjectCode.RemoteSource, 4, 7);
    m(head ~ git ~ "path = \"../x\"\n", ProjectCode.OutsideDirectory, 5, 8);
    m(head ~ git ~ "path = \"a/../../x\"\n", ProjectCode.OutsideDirectory, 5, 8);
    m(head ~ git ~ "path = \"/x\"\n", ProjectCode.OutsideDirectory, 5, 8);
    m(head ~ git ~ "path = \"\"\n", ProjectCode.EmptyDirectory, 5, 8);
    m(head ~ git ~ "test = true\n", ProjectCode.RemotePackage, 5, 8);
    m("name = \"g\"\n[[package]]\n" ~ git, ProjectCode.MissingField, 2, 1);
    m("name = \"g\"\n[[package]]\npath = \"lib\"\ntag = \"v1\"\n", ProjectCode.MissingField, 4, 1);
    m(head ~ git ~ "[[package]]\nname = \"cards\"\ngit = \"https://example.com/other\"\n", ProjectCode.DuplicateName, 6, 8);
    m("name = \"cards\"\n[[package]]\nname = \"cards\"\n" ~ git, ProjectCode.DuplicateName, 3, 8);
    m(head ~ git ~ "flavour = \"x\"\n", ProjectCode.UnknownField, 5, 1);
}

@("a `git` that begins with `-` is refused, since git would read it as an option, such as --upload-pack, and run it")
unittest
{
    auto directory = makeTree("frontend-remote-option", null);
    scope (exit) rmdirRecurse(directory);
    enum head = "name = \"g\"\n[[package]]\nname = \"cards\"\n";
    foreach (refused; ["--upload-pack=touch${IFS}x;false:", "-oProxyCommand=x:y", "--config=a.b=c:d"])
        mistakeIn(directory, head ~ "git = \"" ~ refused ~ "\"\n", ProjectCode.RemoteSource, 4, 7);
}

@("a package's name has the segments a module's name has, wherever a silver.toml writes one")
unittest
{
    auto directory = makeTree("project-names", ["lib/": ""]);
    scope (exit) rmdirRecurse(directory);
    alias m = (text, line, column) => mistakeIn(directory, text, ProjectCode.BadName, line, column);

    foreach (bad; ["Geo", "geoShapes.X", "geo.Shapes", "1geo", "geo.2d", "geo-x", "a..b", ".a", "a.", "café", "geo x"])
    {
        auto named = m("name = \"" ~ bad ~ "\"", 1, 8);
        assert(named.message == "\"" ~ bad ~ "\" isn't a package name: it's one or more segments joined by `.`, as "
            ~ "\"silver.core\", each a lowercase letter or `_` followed by letters, digits and `_`, as in a module's "
            ~ "name", named.message);
        m("name = \"g\"\nuses = [\"a\", \"" ~ bad ~ "\"]", 2, 14);
        m("name = \"g\"\n[[package]]\nname = \"" ~ bad ~ "\"\npath = \"lib\"", 3, 8);
        m("name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"lib\"\nuses = [\"" ~ bad ~ "\"]", 5, 9);
    }
    foreach (good; ["geo", "geoShapes", "geo_x", "_", "_geo", "geo2", "val", "if", "match", "silver.core"])
        assert(validName(good), good);
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
        ~ "`other` isn't a field of a package file. A package file has `name`, `source`, `uses`, `[[package]]` and "
        ~ "`[native.<library>.<platform>]`", formatMistake(mistake));
    assert(!readPackageFile(buildPath(directory, "missing", "silver.toml"), read, mistake));
    assert(mistake.code == ProjectCode.Unreadable && mistake.span.line == 0);
    auto shown = formatMistake(mistake, (string path) => shownFrom(directory, path));
    assert(shown.length > 0 && shown[0 .. "missing".length] == "missing", shown);
    assert(shown == buildPath("missing", "silver.toml") ~ ": Error F0015: The package file can't be read: "
        ~ mistake.message["The package file can't be read: ".length .. $], shown);
}

@("the packages a file describes are packages of their own and one project, and a root without source has no modules")
unittest
{
    auto directory = makeTree("project-described", compilerShape.dup);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "tool", "silver.toml"));
    assert(namesOf(p) == ["tool", "tool.ast", "tool.syntax", "tool.compiler", "tool.frontend"]);
    auto tool = factsOf(p, "tool");
    assert(tool.directory is null && tool.describes == ["tool.ast", "tool.syntax", "tool.compiler", "tool.frontend"]);
    assert(tool.uses.length == 0 && tool.home == buildPath(directory, "tool"));
    auto compiler = factsOf(p, "tool.compiler");
    assert(compiler.directory == buildPath(directory, "tool", "compiler", "source"));
    assert(compiler.home == buildPath(directory, "tool", "compiler"));
    assert(compiler.uses == ["tool.syntax", "tool.ast"] && compiler.describes.length == 0);
    assert(compiler.file == buildPath(directory, "tool", "silver.toml"));
}

@("a package listed by its path is read from its own file, and what it uses is followed in turn")
unittest
{
    auto directory = makeTree("project-listed", [
        "app/silver.toml": "name = \"app\"\nuses = [\"cards\", \"geometry\"]\n[[package]]\npath = \"../cards\"\n"
            ~ "[[package]]\npath = \"../geometry\"\n[[package]]\npath = \"../spare\"",
        "cards/silver.toml": "name = \"cards\"\nsource = \"src\"\nuses = [\"geometry\"]\n[[package]]\npath = \"../geometry\"",
        "cards/src/": "",
        "geometry/silver.toml": "name = \"geometry\"\nuses = [\"units\"]\n[[package]]\npath = \"../units\"",
        "units/silver.toml": "name = \"units\"",
        // Listed and not used: read for its name, and not followed.
        "spare/silver.toml": "name = \"spare\"\nuses = [\"nowhere\"]",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "app", "silver.toml"));
    assert(namesOf(p) == ["app", "cards", "geometry", "units"]);
    assert(factsOf(p, "app").uses == ["cards", "geometry"] && factsOf(p, "app").describes.length == 0);
    assert(factsOf(p, "cards").directory == buildPath(directory, "cards", "src"));
    assert(factsOf(p, "cards").uses == ["geometry"]);
    assert(factsOf(p, "geometry").directory == buildPath(directory, "geometry"));
    assert(factsOf(p, "units").file == buildPath(directory, "units", "silver.toml"));
}

@("a package with a file of its own may be inside the file's directory or elsewhere, and is its own project")
unittest
{
    import std.algorithm : canFind, count;
    import std.array : join;

    auto directory = makeTree("project-own-files", [
        "root/silver.toml": "name = \"root\"\nsource = \"src\"\nuses = [\"lib\", \"far\"]\n[[package]]\npath = \"lib\"\n"
            ~ "[[package]]\npath = \"../far\"\n[[package]]\nname = \"root.tool\"\npath = \"tool\"\nuses = [\"lib\", \"far.x\"]"
            ~ "\n[[package]]\npath = \"../far/x\"",
        "root/src/": "",
        "root/tool/": "",
        "root/lib/silver.toml": "name = \"lib\"\nuses = [\"units\"]\n[[package]]\npath = \"../../units\"",
        "far/silver.toml": "name = \"far\"\nsource = \"src\"\n[[package]]\nname = \"far.x\"\npath = \"x\"",
        "far/src/": "",
        "far/x/": "",
        "units/silver.toml": "name = \"units\"",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "root", "silver.toml"));
    assert(namesOf(p) == ["root", "root.tool", "lib", "units", "far", "far.x"], namesOf(p).join(", "));
    assert(factsOf(p, "root").describes == ["root.tool"]);
    assert(factsOf(p, "lib").describes.length == 0 && factsOf(p, "lib").home == buildPath(directory, "root", "lib"));
    assert(factsOf(p, "lib").file == buildPath(directory, "root", "lib", "silver.toml"));
    assert(factsOf(p, "far").describes == ["far.x"] && factsOf(p, "far.x").file == buildPath(directory, "far", "silver.toml"));
    auto options = compilerOptions(p, (string path) => path);
    assert(options.count("--project") == 2, options.join(" "));
    assert(options.canFind("root=root.tool") && options.canFind("far=far.x"), options.join(" "));
}

@("a package elsewhere uses one package another project describes by its directory, found in the nearest package file above it")
unittest
{
    auto files = compilerShape.dup;
    files["lint/silver.toml"] = "name = \"lint\"\nuses = [\"tool.syntax\"]\n[[package]]\npath = \"../tool/syntax\"";
    auto directory = makeTree("project-uses-described", files);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "lint", "silver.toml"));
    assert(namesOf(p) == ["lint", "tool", "tool.ast", "tool.syntax", "tool.compiler", "tool.frontend"]);
    assert(factsOf(p, "tool.syntax").uses == ["tool.ast"]);
    assert(factsOf(p, "tool").describes.length == 4 && factsOf(p, "lint").describes.length == 0);
}

@("a library used by two packages, and by a package and one it describes, is read once")
unittest
{
    auto directory = makeTree("project-shared", [
        "app/silver.toml": "name = \"app\"\nsource = \"src\"\nuses = [\"a\", \"b\", \"geo\"]\n[[package]]\npath = \"../a\"\n"
            ~ "[[package]]\npath = \"../b\"\n[[package]]\npath = \"../geo\"\n"
            ~ "[[package]]\nname = \"app.x\"\npath = \"x\"\nuses = [\"geo\"]",
        "app/x/": "",
        "app/src/": "",
        "a/silver.toml": "name = \"a\"\nuses = [\"geo\"]\n[[package]]\npath = \"../geo\"",
        "b/silver.toml": "name = \"b\"\nuses = [\"geo\"]\n[[package]]\npath = \"../geo/\"",
        "geo/silver.toml": "name = \"geo\"",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "app", "silver.toml"));
    assert(namesOf(p) == ["app", "app.x", "a", "geo", "b"]);
}

@("what can only be seen by reading files is a mistake located in the file that leads there")
unittest
{
    import std.algorithm : endsWith;

    auto files = compilerShape.dup;
    files["app/silver.toml"] = "name = \"app\"\nuses = [\"geo\"]\n[[package]]\npath = \"../geo\"";
    files["geo/silver.toml"] = "name = \"geometry\"";
    files["unlisted/silver.toml"] = "name = \"u\"\nuses = [\"nowhere\"]";
    files["plain/silver.toml"] = "name = \"p\"\n[[package]]\npath = \"../bare\"";
    files["bare/"] = "";
    files["notdescribed/silver.toml"] = "name = \"n\"\n[[package]]\npath = \"../tool/compiler/source\"";
    files["inside/silver.toml"] = "name = \"i\"\nsource = \"src\"\n[[package]]\npath = \"loose\"";
    files["inside/src/"] = "";
    files["inside/loose/"] = "";
    files["twice/silver.toml"] = "name = \"t\"\nuses = [\"geometry\", \"b\"]\n[[package]]\npath = \"../geo\"\n"
        ~ "[[package]]\npath = \"../b\"";
    files["b/silver.toml"] = "name = \"b\"\nuses = [\"geometry\"]\n[[package]]\npath = \"../geo2\"";
    files["geo2/silver.toml"] = "name = \"geometry\"";
    files["same/silver.toml"] = "name = \"s\"\n[[package]]\npath = \"../geo\"\n[[package]]\npath = \"../geo2\"";
    files["own/silver.toml"] = "name = \"geometry\"\n[[package]]\npath = \"../geo\"";
    files["clash/silver.toml"] = "name = \"c\"\n[[package]]\npath = \"../tool/ast\"\n"
        ~ "[[package]]\nname = \"tool.frontend\"\npath = \"front\"\nuses = [\"tool.ast\"]";
    files["clash/front/"] = "";
    files["badlib/silver.toml"] = "name = \"bl\"\n[[package]]\npath = \"../broken\"";
    files["broken/silver.toml"] = "name = \"broken\"\nnope = 1";
    files["insource/silver.toml"] = "name = \"is\"\n[[package]]\npath = \"../geo3/src\"";
    files["geo3/silver.toml"] = "name = \"geo3\"\nsource = \"src\"";
    files["geo3/src/"] = "";
    auto directory = makeTree("project-reading", files);
    scope (exit) rmdirRecurse(directory);
    Mistake of(string project, string code) => projectMistake(buildPath(directory, project, "silver.toml"), code);

    // A name is found among the entries by the name each one's file gives.
    auto wrong = of("app", ProjectCode.UnknownPackage);
    assert(wrong.file == buildPath(directory, "app", "silver.toml") && wrong.span.line == 2 && wrong.span.column == 9);
    assert(wrong.message == "No `[[package]]` entry here gives 'geo': the entries give 'geometry' at line 4, as its "
        ~ "silver.toml names it, and a name in `uses` is the name a package's own file gives it", wrong.message);
    auto unlisted = of("unlisted", ProjectCode.UnknownPackage);
    assert(unlisted.span.line == 2 && unlisted.span.column == 9);
    auto bare = of("plain", ProjectCode.NoPackageThere);
    assert(bare.span.line == 3 && bare.span.column == 8, formatMistake(bare));
    auto notDescribed = of("notdescribed", ProjectCode.NoPackageThere);
    assert(notDescribed.message == buildPath(directory, "tool", "compiler", "source") ~ " has no silver.toml, and "
        ~ buildPath(directory, "tool", "silver.toml") ~ ", the nearest above it, describes no package there; it holds "
        ~ "modules of the package at " ~ buildPath(directory, "tool", "compiler") ~ ", which is listed as `path = "
        ~ "\"../tool/compiler\"`", notDescribed.message);
    // Outside the file's directory, a package with no file of its own can't be described here.
    assert(bare.message == buildPath(directory, "bare") ~ " has no silver.toml, and no directory above it has one; a "
        ~ "package outside this file's directory has a silver.toml of its own, so give that directory one, or give the "
        ~ "`path` of a package another file describes", bare.message);
    // The nearest file above is the lister's own, which describes nothing there.
    auto loose = of("inside", ProjectCode.NoPackageThere);
    assert(loose.span.line == 4, formatMistake(loose));
    auto twice = of("twice", ProjectCode.TwoDirectories);
    assert(twice.file == buildPath(directory, "b", "silver.toml") && twice.span.line == 4, formatMistake(twice));
    assert(twice.message == "'geometry' is at " ~ buildPath(directory, "geo2") ~ " here, and already at "
        ~ buildPath(directory, "geo") ~ ", described in " ~ buildPath(directory, "geo", "silver.toml"), twice.message);
    // Two entries of one file, or an entry and the file's own package, giving one name.
    auto same = of("same", ProjectCode.TwoDirectories);
    assert(same.span.line == 5 && same.message == "'geometry' is at " ~ buildPath(directory, "geo2") ~ ", described in "
        ~ buildPath(directory, "geo2", "silver.toml") ~ ", and this file already has a package of that name, at "
        ~ buildPath(directory, "geo"), formatMistake(same));
    assert(of("own", ProjectCode.TwoDirectories).span.line == 3);
    auto clash = of("clash", ProjectCode.TwoDirectories);
    assert(clash.file == buildPath(directory, "tool", "silver.toml") && clash.span.line == 19, formatMistake(clash));
    auto broken = of("badlib", ProjectCode.UnknownField);
    assert(broken.file == buildPath(directory, "broken", "silver.toml") && broken.span.line == 2);
    // A directory of a package's modules is listed by the package's own directory.
    assert(of("insource", ProjectCode.NoPackageThere).message.endsWith("; it holds modules of the package at "
        ~ buildPath(directory, "geo3") ~ ", which is listed as `path = \"../geo3\"`"));
    // Reached only because it's listed, the mistake says which entry listed it.
    assert(broken.message.endsWith("\nIt was read because " ~ buildPath(directory, "badlib", "silver.toml") ~ " lists "
        ~ "it, at line 3"), broken.message);
}

@("a script is beside the package whose home holds it, the deepest, and a directory holds those inside it")
unittest
{
    import std.algorithm : map;
    import std.array : array;

    auto files = compilerShape.dup;
    files["geo/silver.toml"] = "name = \"geo\"";
    files["geo/shapes/"] = "";
    files["app/silver.toml"] = "name = \"app\"\nsource = \"src\"\nuses = [\"geo\"]\n[[package]]\npath = \"../geo\"\n"
        ~ "[[package]]\nname = \"app.tools\"\npath = \"tools\"";
    files["app/src/"] = "";
    files["app/tools/"] = "";
    auto directory = makeTree("project-script-homes", files);
    scope (exit) rmdirRecurse(directory);
    string[] of(const Project p, string[] path...) => scriptHomes(p, buildPath(directory ~ path)).map!(f => f.name.idup).array;

    auto tool = project(buildPath(directory, "tool", "silver.toml"));
    assert(of(tool, "tool", "ast", "node.ag") == ["tool.ast"]);
    assert(of(tool, "tool", "compiler", "source", "main.ag") == ["tool.compiler"]);
    // Beside the described package's own files, outside its source.
    assert(of(tool, "tool", "compiler", "build.ag") == ["tool.compiler"]);
    // The root only describes others, and a file beside them is told so.
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
    files["app/silver.toml"] = "name = \"app\"\nsource = \"src\"\nuses = [\"geo\"]\n[[package]]\npath = \"../geo\"";
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

@("the compiler is given every package's directory, uses, project and file, relative where that's inside")
unittest
{
    import std.conv : to;

    auto files = compilerShape.dup;
    files["lint/silver.toml"] = "name = \"lint\"\nuses = [\"tool.syntax\"]\n[[package]]\npath = \"../tool/syntax\"";
    auto directory = makeTree("project-options", files);
    scope (exit) rmdirRecurse(directory);
    auto p = project(buildPath(directory, "lint", "silver.toml"));
    auto lint = buildPath(directory, "lint");
    auto options = compilerOptions(p, (string path) => shownFrom(lint, path));
    auto tool = (string rest) => buildPath(directory, "tool", rest);
    // lint lists tool.syntax and isn't in its project, which is the one tool's file describes.
    assert(options == [
        "--package", "lint=.",
        "--package", "tool.ast=" ~ tool("ast"),
        "--package", "tool.syntax=" ~ tool("syntax"),
        "--package", "tool.compiler=" ~ buildPath(tool("compiler"), "source"),
        "--package", "tool.frontend=" ~ tool("frontend"),
        "--uses", "lint=tool.syntax",
        "--uses", "tool.syntax=tool.ast",
        "--uses", "tool.compiler=tool.syntax,tool.ast",
        "--project", "tool=tool.ast,tool.syntax,tool.compiler,tool.frontend",
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

@("a described package or a source inside the directory of another package file is refused, since that file would claim its files")
unittest
{
    auto directory = makeTree("project-nested-described", ["vendor/x/silver.toml": "name = \"x\"",
        "vendor/x/sub/src/": "", "lib/": ""]);
    scope (exit) rmdirRecurse(directory);
    auto m = mistakeIn(directory, "name = \"g\"\n[[package]]\nname = \"g.sub\"\npath = \"vendor/x/sub\"",
        ProjectCode.UnderPackageFile, 4, 8);
    assert(m.message == "A package's `path` is " ~ buildPath(directory, "vendor", "x", "sub") ~ ", and "
        ~ buildPath(directory, "vendor", "x", "silver.toml") ~ " would make a directory above it a package of its own, "
        ~ "holding its files; a package described in this file can't be in the directory of another silver.toml, so "
        ~ "list the package there by its `path` alone if that file describes it, or move this one out from under that "
        ~ "file", m.message);
    mistakeIn(directory, "name = \"g\"\nsource = \"vendor/x/sub/src\"", ProjectCode.UnderPackageFile, 2, 10);
    mistakeIn(directory, "name = \"g\"\nsource = \"vendor/x\"", ProjectCode.UnderPackageFile, 2, 10);
    mistakeIn(directory, "name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"lib\"\nsource = \"../vendor/x/sub\"",
        ProjectCode.OutsideDirectory, 5, 10);
    mistakeIn(directory, "name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"vendor/x/sub/src\"",
        ProjectCode.UnderPackageFile, 4, 8);
    // At that file's own directory, the package there describes itself.
    mistakeIn(directory, "name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"vendor/x\"", ProjectCode.DescribesItself, 3, 1);
    // Listed by its path alone, it's that file's package.
    checked(directory, "name = \"g\"\n[[package]]\npath = \"vendor/x\"");
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
    auto path = mistakeIn(directory, "name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"\"", ProjectCode.EmptyDirectory, 4, 8);
    assert(path.message == "A package's `path` names a directory, and \"\" names none, as \"core\"", path.message);
    mistakeIn(directory, "name = \"g\"\n[[package]]\nname = \"g.x\"\npath = \"lib\"\nsource = ''", ProjectCode.EmptyDirectory,
        5, 10);
    auto listed = mistakeIn(directory, "name = \"g\"\n[[package]]\npath = \"\"", ProjectCode.EmptyDirectory, 3, 8);
    foreach (m; [source, path, listed]) assert(!m.message.canFind(" , ") && !m.message.canFind("and  isn't"), m.message);
}

@("a package with a file of its own inside the directory of a package with no source, or holding one, is refused at its entry")
unittest
{
    auto directory = makeTree("project-nested", [
        "outer/silver.toml": "name = \"outer\"\nuses = [\"inner\"]\n\n[[package]]\npath = \"inner\"",
        "outer/inner/silver.toml": "name = \"inner\"",
        "unused/silver.toml": "name = \"unused\"\n\n[[package]]\npath = \"inner\"",
        "unused/inner/silver.toml": "name = \"inner\"",
        "sourced/silver.toml": "name = \"sourced\"\nsource = \"src\"\nuses = [\"inner\"]\n\n[[package]]\npath = \"inner\"",
        "dot/silver.toml": "name = \"dot\"\nsource = \".\"\nuses = [\"inner\"]\n\n[[package]]\npath = \"inner\"",
        "dot/inner/silver.toml": "name = \"inner\"",
        "sourced/src/": "",
        "sourced/inner/silver.toml": "name = \"inner\"",
        "app/silver.toml": "name = \"app\"\nuses = [\"a\", \"b\"]\n\n[[package]]\npath = \"../a\"\n[[package]]\npath = \"../a/b\"",
        "around/silver.toml": "name = \"around\"\nuses = [\"b\", \"a\"]\n\n[[package]]\npath = \"../a/b\"\n[[package]]\npath = \"../a\"",
        "a/silver.toml": "name = \"a\"",
        "a/b/silver.toml": "name = \"b\"\nsource = \"src\"",
        "a/b/src/": "",
        "tools/silver.toml": "name = \"tools\"\nuses = [\"kit.core\"]\n\n[[package]]\npath = \"kit/core\"",
        "tools/kit/silver.toml": "name = \"kit\"\n\n[[package]]\nname = \"kit.core\"\npath = \"core\"",
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
    assert(outer.file == buildPath(directory, "outer", "silver.toml") && outer.span.line == 5 && outer.span.column == 8,
        formatMistake(outer));
    assert(outer.message == message("inner", "outer/inner", "outer", "outer"), outer.message);
    // Listed and not used, it's refused all the same.
    assert(of("unused").message == message("inner", "unused/inner", "unused", "unused"), of("unused").message);
    // Reached in either order, the package with no source is the outer one.
    auto app = of("app");
    assert(app.span.line == 7 && app.message == message("b", "a/b", "a", "a"), formatMistake(app));
    auto around = of("around");
    assert(around.span.line == 7 && around.message == message("b", "a/b", "a", "a"), formatMistake(around));
    // A package another file describes is refused in the same way.
    auto described = of("tools");
    assert(described.message == message("kit.core", "tools/kit/core", "tools", "tools"), described.message);
    // `source = "."` is the whole directory too.
    assert(of("dot").message == message("inner", "dot/inner", "dot", "dot"), of("dot").message);
    // With source, the used package's directory holds none of the other's modules.
    Project project;
    Mistake mistake;
    assert(readProject(buildPath(directory, "sourced", "silver.toml"), project, mistake), formatMistake(mistake));
}

@("a mistake about a listed or described package outside the file's directory says what to write instead")
unittest
{
    import std.algorithm : canFind;
    import std.array : join;

    auto directory = makeTree("project-review", [
        "app/silver.toml": "name = \"app\"\nuses = [\"geo\"]\n[[package]]\npath = \"../geo\"",
        "geo/silver.toml": "name = \"geometry\"",
        "plain/silver.toml": "name = \"p\"\n[[package]]\npath = \"../bare\"",
        "bare/": "",
        "outside/silver.toml": "name = \"o\"\n[[package]]\nname = \"o.x\"\npath = \"../bare\"",
    ]);
    scope (exit) rmdirRecurse(directory);
    Mistake of(string project, string code) => projectMistake(buildPath(directory, project, "silver.toml"), code);
    string[] failures;

    // The entry at ../geo is there; its file names it 'geometry'. Suggesting `path = "../geo"` repeats
    // what's written. The message has to say which name the entries give.
    auto renamed = of("app", ProjectCode.UnknownPackage);
    if (!renamed.message.canFind("'geometry'"))
        failures ~= "F0025 doesn't name what the entry gives: " ~ renamed.message;

    // ../bare is outside plain/, so describing it here, as F0026 suggests, is refused (F0020).
    auto bare = of("plain", ProjectCode.NoPackageThere);
    if (bare.message.canFind("is described here, with its `name`"))
        failures ~= "F0026 suggests describing a package outside the file's directory: " ~ bare.message;

    // A described package outside the file's directory: what to write is a silver.toml there, listed by path.
    auto outside = mistakeIn(buildPath(directory, "outside"), "name = \"o\"\n[[package]]\nname = \"o.x\"\npath = "
        ~ "\"../bare\"", ProjectCode.OutsideDirectory, 4, 8);
    if (!outside.message.canFind("`path` alone"))
        failures ~= "F0020 doesn't say a package elsewhere has its own silver.toml and is listed by `path` alone: "
            ~ outside.message;

    assert(failures.length == 0, failures.join("\n"));
}
