/// Fetching a commit of a git repository into the shared cache with the user's `git`, and the hash of
/// the files fetched. The files are written from the blobs git stores, never checked out, so no line
/// ending is converted and no filter runs, and the hash is the same on every platform.
module silver.frontend.git;

/// What an entry says to take from a repository.
enum Want : ubyte
{
    defaultBranch,
    tag,
    branch,
    rev,
}

/// A `tag`, `branch` or `rev`, or none.
struct Wanted
{
    Want want;
    /// The tag's or branch's name, or the commit's hash.
    string name;
}

/// What a `git` field gives, as the docs allow it.
enum SourceKind : ubyte
{
    https,
    ssh,
    /// git's `user@host:path`.
    scpLike,
    local,
    /// Another scheme or a transport: refused.
    other,
}

SourceKind sourceKind(string git)
{
    import std.algorithm : canFind, startsWith;
    import std.ascii : isAlpha, isAlphaNum;
    import std.string : indexOf;

    // git would read it as an option, as `--upload-pack=...`, and run it.
    if (git.startsWith("-")) return SourceKind.other;
    if (git.startsWith("https://")) return SourceKind.https;
    if (git.startsWith("ssh://")) return SourceKind.ssh;
    // A scheme, `name://`, or a transport, `name::`.
    size_t k;
    while (k < git.length && (isAlphaNum(git[k]) || git[k] == '+' || git[k] == '-' || git[k] == '.')) k++;
    if (k > 0 && isAlpha(git[0]) && k < git.length && (git[k .. $].startsWith("://") || git[k .. $].startsWith("::")))
        return SourceKind.other;
    // git takes a colon before any slash as `host:path`, but a drive letter on Windows.
    immutable colon = git.indexOf(':');
    if (colon > 0)
    {
        immutable slash = git[0 .. colon].canFind('/') || git[0 .. colon].canFind('\\');
        version (Windows) immutable drive = colon == 1 && isAlpha(git[0]);
        else immutable drive = false;
        if (!slash && !drive) return SourceKind.scpLike;
    }
    return SourceKind.local;
}

/// Whether `rev` is a commit's full hash, SHA-1 or SHA-256, in lowercase as git writes it.
bool fullHash(string rev)
{
    import std.algorithm : all;

    return (rev.length == 40 || rev.length == 64) && rev.all!(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
}

/// The shared cache: `SILVER_CACHE`, or the platform's cache directory with `silver` under it.
string cacheDirectory()
{
    import std.path : buildPath;
    import std.process : environment;

    auto given = environment.get("SILVER_CACHE");
    if (given !is null && given.length > 0) return given;
    version (Windows)
    {
        auto local = environment.get("LOCALAPPDATA");
        if (local !is null && local.length > 0) return buildPath(local, "silver");
    }
    auto xdg = environment.get("XDG_CACHE_HOME");
    if (xdg !is null && xdg.length > 0) return buildPath(xdg, "silver");
    auto home = environment.get("HOME");
    if (home is null || home.length == 0) home = environment.get("USERPROFILE");
    if (home is null || home.length == 0) return null;
    return buildPath(home, ".cache", "silver");
}

/// A commit's files in the cache: the directory they're in and their hash.
struct Tree
{
    string directory;
    string hash;
}

/// Why fetching failed.
enum Problem : ubyte
{
    /// git isn't on the PATH.
    noGit,
    /// git failed, or the commit or ref isn't there.
    failed,
    /// The repository holds a symbolic link, or a path that can't be written the same everywhere.
    unfetchable,
    /// The cache can't be written or read.
    cache,
}

struct Failure
{
    Problem problem;
    string message;
}

/// The commit `commit`'s files, when the cache has them.
bool cached(string cache, string commit, out Tree tree, out Failure failure)
{
    import std.file : exists, read;
    import std.path : buildPath;
    import std.string : strip;

    auto at = buildPath(cache, "git", commit);
    if (!exists(at)) return false;
    auto hashFile = buildPath(at, "hash");
    try
    {
        tree = Tree(buildPath(at, "files"), strip(cast(string) read(hashFile)));
        if (!exists(tree.directory)) throw new Exception("there's no " ~ tree.directory);
    }
    catch (Exception e)
    {
        failure = Failure(Problem.cache, "The cache's copy of commit " ~ commit ~ ", " ~ at ~ ", is broken (" ~ e.msg
            ~ "); deleting that directory has it fetched again");
        tree = Tree.init;
        return false;
    }
    return true;
}

/// The commit `wanted` names in the repository `url`, asked of it with `git ls-remote`.
bool resolve(string url, Wanted wanted, out string commit, out Failure failure)
{
    import std.algorithm : endsWith, startsWith;
    import std.string : lineSplitter, split;

    assert(wanted.want != Want.rev);
    string[] words = ["ls-remote"];
    final switch (wanted.want)
    {
        case Want.defaultBranch: words ~= ["--", url, "HEAD"]; break;
        // A pattern matches whole names, so an annotated tag's peeled line is asked for too.
        case Want.tag: words ~= ["--tags", "--", url, "refs/tags/" ~ wanted.name, "refs/tags/" ~ wanted.name ~ "^{}"]; break;
        case Want.branch: words ~= ["--heads", "--", url, "refs/heads/" ~ wanted.name]; break;
        case Want.rev: assert(false);
    }
    string output;
    if (!git(words, null, output, failure)) return false;
    immutable target = wanted.want == Want.defaultBranch ? "HEAD"
        : (wanted.want == Want.tag ? "refs/tags/" : "refs/heads/") ~ wanted.name;
    string direct, peeled;
    foreach (line; output.lineSplitter)
    {
        auto parts = line.split('\t');
        if (parts.length != 2) continue;
        if (parts[1] == target) direct = parts[0];
        else if (parts[1] == target ~ "^{}") peeled = parts[0];
    }
    // An annotated tag names a tag object; the commit is the peeled line's.
    commit = peeled !is null ? peeled : direct;
    if (commit is null || !fullHash(commit))
    {
        failure = Failure(Problem.failed, url ~ (wanted.want == Want.defaultBranch ? " has no default branch"
            : " has no " ~ (wanted.want == Want.tag ? "tag " : "branch ") ~ "\"" ~ wanted.name ~ "\""));
        commit = null;
        return false;
    }
    return true;
}

/// Fetches the commit `commit` of the repository `url` into the cache, which `wanted` led to, and
/// gives its files and their hash. When another run put it there first, that copy is the one given.
bool fetch(string cache, string url, Wanted wanted, string commit, out Tree tree, out Failure failure)
{
    import std.conv : to;
    import std.file : exists, mkdirRecurse, rename, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.random : uniform;

    auto final_ = buildPath(cache, "git", commit);
    string work;
    try
    {
        mkdirRecurse(buildPath(cache, "git"));
        work = buildPath(cache, "tmp", commit ~ "-" ~ thisProcessID.to!string ~ "-" ~ uniform(0, 1_000_000_000).to!string);
        mkdirRecurse(buildPath(work, "entry"));
    }
    catch (Exception e)
    {
        failure = Failure(Problem.cache, "The cache, " ~ cache ~ ", can't be written: " ~ e.msg);
        return false;
    }
    scope (exit) removeAll(work);
    sweep(buildPath(cache, "tmp"), work);
    auto repository = buildPath(work, "repository");
    string ignored;
    auto format = commit.length == 64 ? ["--object-format=sha256"] : null;
    if (!git(["init", "-q", "--bare", "--template="] ~ format ~ ["--", repository], null, ignored, failure)) return false;
    if (!fetchCommit(repository, url, wanted, commit, failure)) return false;
    string type;
    if (!git(["--git-dir=" ~ repository, "cat-file", "-t", commit], null, type, failure)) return false;
    import std.string : strip;

    if (strip(type) != "commit")
    {
        failure = Failure(Problem.failed, commit ~ " in " ~ url ~ " is a " ~ strip(type) ~ ", not a commit");
        return false;
    }
    auto files = buildPath(work, "entry", "files");
    string hash;
    if (!writeTree(repository, commit, files, hash, failure)) return false;
    try
    {
        write(buildPath(work, "entry", "hash"), hash ~ "\n");
        try rename(buildPath(work, "entry"), final_);
        catch (Exception e)
        {
            // Another run fetched it first.
            if (!exists(final_)) throw e;
        }
    }
    catch (Exception e)
    {
        failure = Failure(Problem.cache, "The cache, " ~ cache ~ ", can't be written: " ~ e.msg);
        return false;
    }
    return cached(cache, commit, tree, failure);
}

/// The hash of a tree of files: SHA-256 over one line per file, sorted by path, of the SHA-256 of its
/// content, whether it's executable, and its path with `/`. `files` is each path with its content and
/// whether it's executable.
string treeHash(const File_[] files)
{
    Hashed[] hashed;
    foreach (ref f; files) hashed ~= Hashed(f.path, contentHash(f.content), f.executable);
    return treeHash(hashed);
}

/// The same, from each file's `contentHash`, so the files needn't be held while it's taken.
string treeHash(const Hashed[] files)
{
    import std.algorithm : sort;
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : SHA256;

    auto sorted = files.dup;
    sorted.sort!((a, b) => a.path < b.path);
    SHA256 all;
    all.start();
    foreach (ref f; sorted)
        all.put(cast(const(ubyte)[]) (f.content ~ " " ~ (f.executable ? "x" : "-") ~ " " ~ f.path ~ "\n"));
    return "sha256-" ~ toHexString!(LetterCase.lower)(all.finish()).idup;
}

/// A file's content's SHA-256, in lowercase hex.
string contentHash(const(ubyte)[] content)
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : sha256Of;

    return toHexString!(LetterCase.lower)(sha256Of(content)).idup;
}

/// A file of a tree with its content's hash in place of its content.
struct Hashed
{
    string path;
    string content;
    bool executable;
}

/// A file of a tree: its path with `/`, its bytes, and whether it's executable.
struct File_
{
    string path;
    const(ubyte)[] content;
    bool executable;
}

/// Removes `directory` and everything in it, read-only files too, ignoring what can't be removed.
void removeAll(string directory)
{
    import std.file : dirEntries, exists, rmdirRecurse, SpanMode;

    if (directory is null) return;
    try
    {
        if (!exists(directory)) return;
        foreach (entry; dirEntries(directory, SpanMode.depth, false)) writable(entry.name, entry.isDir);
        rmdirRecurse(directory);
    }
    catch (Exception)
    {
    }
}

private:

/// Runs git with `words`, in `directory` unless it's null, giving its standard output.
bool git(string[] words, string directory, out string output, out Failure failure)
{
    import std.process : Config, execute, ProcessException;

    auto command = ["git", "-c", "core.hooksPath=" ~ nowhere, "-c", "core.autocrlf=false"] ~ words;
    try
    {
        auto ran = execute(command, gitEnvironment(), Config.newEnv, size_t.max, directory);
        if (ran.status != 0)
        {
            failure = Failure(Problem.failed, "`git " ~ words[0] ~ "` failed" ~ errorsOf(ran.output));
            return false;
        }
        output = ran.output;
        return true;
    }
    catch (ProcessException e)
    {
        failure = Failure(Problem.noGit, "git isn't on the PATH, and silver fetches a remote package with it ("
            ~ e.msg ~ ")");
        return false;
    }
}

/// The environment git runs in: this one, less what would point it at another repository, and with
/// what keeps it to silver's sources and from waiting for a login nobody can type.
string[string] gitEnvironment()
{
    import std.process : environment;

    string[string] env;
    foreach (key, value; environment.toAA())
    {
        // What a git hook or a shell inside a repository sets would point these commands elsewhere.
        if (key == "GIT_DIR" || key == "GIT_WORK_TREE" || key == "GIT_INDEX_FILE" || key == "GIT_OBJECT_DIRECTORY"
            || key == "GIT_ALTERNATE_OBJECT_DIRECTORIES" || key == "GIT_NAMESPACE" || key == "GIT_COMMON_DIR")
            continue;
        env[key] = value;
    }
    // Only the sources silver accepts, so that git refuses `ext::` and the like too.
    env["GIT_ALLOW_PROTOCOL"] = allowedProtocols(environment.get("GIT_ALLOW_PROTOCOL"));
    // With a terminal a login prompt can be answered; without one, as in CI, it would wait forever.
    if (!terminal()) env["GIT_TERMINAL_PROMPT"] = "0";
    return env;
}

/// The protocols git may use: silver's, narrowed to those of `given`, the user's own list, when there is one.
string allowedProtocols(string given)
{
    import std.algorithm : canFind, filter, splitter;
    import std.array : join;

    enum ours = ["https", "ssh", "file"];
    if (given is null) return ours.join(":");
    return ours.filter!(p => given.splitter(':').canFind(p)).join(":");
}

/// Removes what interrupted fetches left in `tmp`, a day or more old, but `own`.
void sweep(string tmp, string own)
{
    import core.time : days;
    import std.datetime.systime : Clock;
    import std.file : dirEntries, SpanMode, timeLastModified;

    try
    {
        auto now = Clock.currTime();
        foreach (entry; dirEntries(tmp, SpanMode.shallow, false))
        {
            if (entry.name != own && now - timeLastModified(entry.name) > 1.days) removeAll(entry.name);
        }
    }
    catch (Exception)
    {
    }
}

/// A hooks directory that doesn't exist, so that git runs no hook.
enum nowhere = "/dev/null/silver-no-hooks";

string errorsOf(string output)
{
    import std.string : strip;

    auto text = strip(output);
    return text.length == 0 ? "" : ": " ~ text;
}

bool terminal()
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty;

        return isatty(0) != 0;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : GetFileType, GetStdHandle, STD_INPUT_HANDLE, FILE_TYPE_CHAR;

        return GetFileType(GetStdHandle(STD_INPUT_HANDLE)) == FILE_TYPE_CHAR;
    }
    else return false;
}

/// Fetches `commit` into `repository`: the commit alone, shallow, when the server allows it; else the
/// ref `wanted` names, shallow, if it's still at the commit; else everything.
bool fetchCommit(string repository, string url, Wanted wanted, string commit, out Failure failure)
{
    string ignored;
    auto at = ["--git-dir=" ~ repository];
    if (git(at ~ ["fetch", "-q", "--depth", "1", "--no-tags", "--", url, commit], null, ignored, failure)) return true;
    // A server that refuses to fetch a commit it doesn't advertise.
    if (wanted.want != Want.rev)
    {
        immutable ref_ = wanted.want == Want.defaultBranch ? "HEAD"
            : (wanted.want == Want.tag ? "refs/tags/" : "refs/heads/") ~ wanted.name;
        Failure byRef;
        if (git(at ~ ["fetch", "-q", "--depth", "1", "--no-tags", "--", url, ref_], null, ignored, byRef) && has(repository, commit))
            return true;
    }
    Failure whole;
    immutable fetched = git(at ~ ["fetch", "-q", "--no-tags", "--", url, "+refs/heads/*:refs/heads/*",
        "+refs/tags/*:refs/tags/*"], null, ignored, whole);
    if (fetched && has(repository, commit)) return true;
    if (fetched) failure = Failure(Problem.failed, url ~ " has no commit " ~ commit);
    else if (failure.problem != Problem.noGit) failure = whole;
    return false;
}

bool has(string repository, string commit)
{
    string ignored;
    Failure failure;
    return git(["--git-dir=" ~ repository, "cat-file", "-e", commit ~ "^{commit}"], null, ignored, failure);
}

/// Writes the files of `commit` in `repository` under `directory`, read-only, from the blobs git stores,
/// and gives their hash.
bool writeTree(string repository, string commit, string directory, out string hash, out Failure failure)
{
    import std.algorithm : splitter;
    import std.file : mkdirRecurse, write;
    import std.path : buildPath, dirName;
    import std.process : Config, pipeProcess, ProcessException, Redirect, wait;
    import std.string : indexOf;
    import std.uni : toLower;

    string listing;
    if (!git(["--git-dir=" ~ repository, "ls-tree", "-r", "-z", "--full-tree", commit], null, listing, failure))
        return false;
    struct Blob
    {
        string path;
        string id;
        bool executable;
    }
    Blob[] blobs;
    Folded folded;
    foreach (record; listing.splitter('\0'))
    {
        if (record.length == 0) continue;
        immutable tab = record.indexOf('\t');
        auto fields = record[0 .. tab].splitter(' ');
        auto mode = fields.front;
        fields.popFront();
        fields.popFront();
        auto id = fields.front;
        auto path = record[tab + 1 .. $];
        if (mode == "160000") continue;
        if (mode == "120000")
        {
            failure = Failure(Problem.unfetchable, "The repository holds a symbolic link, " ~ path ~ ", at commit "
                ~ commit ~ ", and silver refuses one, since a checkout on Windows makes it a file and the files have "
                ~ "to be the same everywhere");
            return false;
        }
        if (auto wrong = unwritable(path))
        {
            failure = Failure(Problem.unfetchable, "The repository holds " ~ path ~ ", at commit " ~ commit ~ ", "
                ~ wrong ~ ", so its files can't be the same everywhere");
            return false;
        }
        if (auto other = folded.clash(path))
        {
            failure = Failure(Problem.unfetchable, "The repository holds " ~ other ~ " and " ~ path ~ ", at commit "
                ~ commit ~ ", which differ only in case, and a Windows or macOS file system can't hold them apart, so "
                ~ "its files can't be the same everywhere");
            return false;
        }
        blobs ~= Blob(path, id, mode == "100755");
    }
    Hashed[] files;
    try
    {
        mkdirRecurse(directory);
        auto cat = pipeProcess(["git", "--git-dir=" ~ repository, "cat-file", "--batch"], Redirect.stdin | Redirect.stdout,
            gitEnvironment(), Config.newEnv);
        scope (exit) wait(cat.pid);
        foreach (ref b; blobs)
        {
            cat.stdin.writeln(b.id);
            cat.stdin.flush();
            import std.array : array, join;
            import std.conv : to;
            import std.string : strip;

            auto header = strip(cat.stdout.readln()).splitter(' ').array;
            if (header.length != 3 || header[1] != "blob")
                throw new Exception("git cat-file gave \"" ~ header.join(" ") ~ "\" for " ~ b.path);
            auto size = header[2].to!size_t;
            auto content = new ubyte[size];
            if (size > 0) cat.stdout.rawRead(content);
            cat.stdout.readln();
            auto target = buildPath(directory, b.path);
            mkdirRecurse(dirName(target));
            write(target, content);
            readOnly(target, b.executable);
            files ~= Hashed(b.path, contentHash(content), b.executable);
        }
        cat.stdin.close();
    }
    catch (ProcessException e)
    {
        failure = Failure(Problem.noGit, "git isn't on the PATH, and silver fetches a remote package with it (" ~ e.msg ~ ")");
        return false;
    }
    catch (Exception e)
    {
        failure = Failure(Problem.cache, "The files of commit " ~ commit ~ " can't be written to the cache: " ~ e.msg);
        return false;
    }
    hash = treeHash(files);
    return true;
}

/// The paths of a tree and the directories above them, folded to lowercase: two spellings of one, or a
/// file and a directory of one, can't be held apart everywhere.
struct Folded
{
    private struct Spelled
    {
        string path;
        bool directory;
    }
    private Spelled[string] seen;

    /// Adds the file `path`, giving the file or directory already there that differs from it or a directory
    /// above it only in case, or that's a file where it needs a directory, or a directory where it's a file.
    string clash(string path)
    {
        import std.uni : toLower;

        string add(string spelled, bool directory)
        {
            auto key = toLower(spelled);
            if (auto earlier = key in seen)
            {
                if (earlier.path == spelled && earlier.directory && directory) return null;
                return earlier.path;
            }
            seen[key] = Spelled(spelled, directory);
            return null;
        }
        foreach (k, char c; path)
        {
            if (c != '/') continue;
            if (auto other = add(path[0 .. k], true)) return other;
        }
        return add(path, false);
    }
}

/// Whether `name` is one git takes as a tag's or a branch's: what `git check-ref-format` allows of a name
/// under refs/tags or refs/heads, and not starting with `-`.
public bool validRefName(string name)
{
    import std.algorithm : canFind, endsWith, splitter, startsWith;

    if (name.length == 0 || name == "@" || name.startsWith("-") || name.startsWith("/") || name.endsWith("/")
        || name.endsWith(".") || name.canFind("..") || name.canFind("@{") || name.canFind("//"))
        return false;
    foreach (char c; name)
    {
        if (c < 0x20 || c == 0x7F || " ~^:?*[\\".canFind(c)) return false;
    }
    foreach (part; name.splitter('/'))
    {
        if (part.startsWith(".") || part.endsWith(".lock")) return false;
    }
    return true;
}

/// Why `path`, a path in a repository, can't be written the same on every platform, or null.
string unwritable(string path)
{
    import std.algorithm : splitter;
    import std.uni : sicmp;

    import std.algorithm : canFind;
    import std.string : indexOf;
    import std.utf : validate;

    try validate(path);
    catch (Exception) return "whose name isn't UTF-8, which Windows can't name a file with";
    foreach (char c; path)
    {
        if (c < 0x20 || c == 0x7F) return "whose name has a control character";
        if ("\\:*?<>\"|".canFind(c)) return "whose name has a `" ~ c ~ "`, which Windows doesn't allow";
    }
    foreach (segment; path.splitter('/'))
    {
        if (segment.length == 0 || segment == "." || segment == "..") return "which isn't a path inside it";
        if (sicmp(segment, ".git") == 0) return "inside a directory named .git";
        if (segment[$ - 1] == '.' || segment[$ - 1] == ' ')
            return "whose name ends in a dot or a space, which Windows drops";
        immutable dot = segment.indexOf('.');
        auto stem = dot < 0 ? segment : segment[0 .. dot];
        foreach (device; ["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
            "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"])
        {
            if (sicmp(stem, device) == 0) return "whose name is a device's on Windows";
        }
    }
    return null;
}

void readOnly(string path, bool executable)
{
    version (Posix)
    {
        import std.file : setAttributes;

        setAttributes(path, executable ? octal!555 : octal!444);
    }
    else version (Windows)
    {
        import core.sys.windows.winnt : FILE_ATTRIBUTE_READONLY;
        import std.file : getAttributes, setAttributes;

        setAttributes(path, getAttributes(path) | FILE_ATTRIBUTE_READONLY);
    }
}

void writable(string path, bool directory)
{
    version (Posix)
    {
        import std.file : getAttributes, setAttributes;

        setAttributes(path, getAttributes(path) | octal!200 | (directory ? octal!700 : 0));
    }
    else version (Windows)
    {
        import core.sys.windows.winnt : FILE_ATTRIBUTE_READONLY;
        import std.file : getAttributes, setAttributes;

        setAttributes(path, getAttributes(path) & ~FILE_ATTRIBUTE_READONLY);
    }
}

import std.conv : octal;

@("a `git` field's kind, as git reads it")
unittest
{
    assert(sourceKind("https://github.com/a/b") == SourceKind.https);
    assert(sourceKind("ssh://git@host/a") == SourceKind.ssh);
    assert(sourceKind("git@github.com:a/b.git") == SourceKind.scpLike);
    assert(sourceKind("host:a/b") == SourceKind.scpLike);
    assert(sourceKind("../repo") == SourceKind.local && sourceKind("/srv/repo.git") == SourceKind.local);
    assert(sourceKind("./a:b") == SourceKind.local);
    foreach (refused; ["http://h/a", "git://h/a", "file:///srv/a", "ext::sh -c x", "fd::3", "HTTPS://h/a"])
        assert(sourceKind(refused) == SourceKind.other, refused);
    version (Windows) assert(sourceKind(`C:\repos\a`) == SourceKind.local);
}

@("a rev is a full hash")
unittest
{
    assert(fullHash("4f1c2a9e0b7d3c58e6a1f92d4b0c7e3a5d8f1b26"));
    assert(!fullHash("4f1c2a9") && !fullHash("4F1C2A9E0B7D3C58E6A1F92D4B0C7E3A5D8F1B26"));
    assert(!fullHash("4f1c2a9e0b7d3c58e6a1f92d4b0c7e3a5d8f1b2g"));
}

@("the tree hash is of paths, contents and execute bits, in path order, whatever order they're given in")
unittest
{
    auto a = File_("a.ag", cast(const(ubyte)[]) "x\n", false);
    auto b = File_("d/b.ag", cast(const(ubyte)[]) "y\r\n", true);
    assert(treeHash([a, b]) == treeHash([b, a]));
    // Fixed, so that a change to the hash's form is seen: what's locked would stop matching.
    assert(treeHash([a, b]) == "sha256-3e9a9d12f8a06dfb5d8eeda9ad4f80c5a9d45a9e2244833923adb688de4adaa0", treeHash([a, b]));
    assert(treeHash([a, File_("d/b.ag", b.content, false)]) != treeHash([a, b]));
    assert(treeHash([a, File_("d/b.ag", cast(const(ubyte)[]) "y\n", true)]) != treeHash([a, b]));
    assert(treeHash(cast(File_[]) []) != treeHash([a]));
}

@("a path a platform can't write is refused")
unittest
{
    assert(unwritable("a/b.ag") is null && unwritable(".gitignore") is null);
    assert(unwritable("a\\b") !is null && unwritable("a:b") !is null && unwritable("a\nb") !is null);
    assert(unwritable("x/.GIT/config") !is null && unwritable("../a") !is null);
}

@("a path Windows can't write as it is is refused everywhere, so the files are the same on every platform")
unittest
{
    // Windows refuses these characters in a name, and a device name with any extension.
    foreach (c; ["*", "?", "<", ">", "\"", "|"]) assert(unwritable("a" ~ c ~ "b.ag") !is null, c);
    foreach (device; ["CON", "con.ag", "nul", "aux.txt", "prn", "com1.ag", "LPT1", "d/nul.ag"])
        assert(unwritable(device) !is null, device);
    // Windows drops a trailing dot or space, so "a." would be written as "a".
    foreach (trailing; ["a.", "a ", "d./b.ag", "d /b.ag"]) assert(unwritable(trailing) !is null, trailing);
    // A name that isn't UTF-8 can't be written on Windows, which names files in UTF-16.
    assert(unwritable("a\xFF.ag") !is null);
    assert(unwritable("console.ag") is null && unwritable("a.b/c.ag") is null && unwritable(".hidden") is null);
}

@("a file and a directory, or two directories, that differ only in case clash, and one directory's files don't")
unittest
{
    Folded f;
    assert(f.clash("a/b.ag") is null && f.clash("a/c.ag") is null && f.clash("a/d/e.ag") is null);
    assert(f.clash("A/x.ag") == "a");
    Folded g;
    assert(g.clash("a") is null && g.clash("a/b") == "a");
    Folded h;
    assert(h.clash("d/x") is null && h.clash("D") == "d");
    Folded i;
    assert(i.clash("Read.me") is null && i.clash("read.ME") == "Read.me");
}

@("a tag's or branch's name is one git takes, never an option")
unittest
{
    foreach (good; ["v1", "v0.3.0", "release/1.2", "main", "feature-x", "a_b"]) assert(validRefName(good), good);
    foreach (bad; ["", "-x", "--upload-pack=y", "a..b", "a b", "a:b", "a*", "x^{}", "a~1", "a?", "a[", "a\\b",
        "/a", "a/", "a.", ".a", "a/.b", "a.lock", "a/b.lock", "@", "a@{1}", "a//b"])
        assert(!validRefName(bad), bad);
}

@("git may use silver's protocols, narrowed to the user's own list")
unittest
{
    assert(allowedProtocols(null) == "https:ssh:file");
    assert(allowedProtocols("https") == "https");
    assert(allowedProtocols("ssh:git:https") == "https:ssh");
    assert(allowedProtocols("") == "");
}
