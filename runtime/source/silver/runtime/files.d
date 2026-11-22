/// Reading and writing a file whole, under `lang.file`'s intrinsics. The interpreter compiles this
/// module too, so both backends give the same results and the same messages. It uses only Phobos,
/// nothing else of the runtime's, and its memory is the GC's: the runtime copies a file it read
/// into a buffer of its own.
module silver.runtime.files;

/// `lang.file`'s statuses.
enum FileStatus : int
{
    done = 0,
    notFound = 1,
    notUtf8 = 2,
    failed = 3,
}

struct FileOutcome
{
    FileStatus status;
    /// The file's bytes when it was read, or the system's message when it failed.
    const(char)[] text;
}

/// Phobos opens a file with the system's wide API on Windows, so a path is UTF-8 there too, and
/// reads and writes bytes as they are, with no line endings translated.
FileOutcome readWhole(const(char)[] path, bool text) nothrow
{
    import std.file : FileException, read;
    import std.utf : validate;

    if (auto problem = pathProblem(path)) return FileOutcome(FileStatus.failed, problem);
    // Windows says only "Access is denied." of a directory.
    if (isDirectory(path)) return FileOutcome(FileStatus.failed, isADirectory);
    const(char)[] contents;
    try contents = cast(const(char)[]) read(path);
    catch (FileException e)
    {
        auto status = e.errno != 0 && isMissing(e.errno) ? FileStatus.notFound : FileStatus.failed;
        return FileOutcome(status, status == FileStatus.notFound ? null : messageOf(e));
    }
    catch (Exception e) return FileOutcome(FileStatus.failed, e.msg);
    if (text)
    {
        try validate(contents);
        catch (Exception) return FileOutcome(FileStatus.notUtf8);
    }
    return FileOutcome(FileStatus.done, contents);
}

/// Writes `data` to `path`, replacing the file or adding to its end, and creating it either way.
FileOutcome writeWhole(const(char)[] path, const(ubyte)[] data, bool append) nothrow
{
    import std.file : FileException;
    static import std.file;

    if (auto problem = pathProblem(path)) return FileOutcome(FileStatus.failed, problem);
    if (isDirectory(path)) return FileOutcome(FileStatus.failed, isADirectory);
    try
    {
        if (append) std.file.append(path, data);
        else std.file.write(path, data);
    }
    catch (FileException e) return FileOutcome(FileStatus.failed, messageOf(e));
    catch (Exception e) return FileOutcome(FileStatus.failed, e.msg);
    return FileOutcome(FileStatus.done);
}

/// Whether there's a file or a directory at `path`.
bool pathExists(const(char)[] path) nothrow
{
    import std.file : exists;

    if (pathProblem(path) !is null) return false;
    try return exists(path);
    catch (Exception) return false;
}

/// POSIX's own words for it.
private enum isADirectory = "Is a directory";

/// Why no system call could take `path`: C's strings would end it at a NUL.
private string pathProblem(const(char)[] path) nothrow
{
    foreach (c; path)
    {
        if (c == '\0') return "The path contains a NUL character";
    }
    return null;
}

private bool isDirectory(const(char)[] path) nothrow
{
    import std.file : isDir;

    try return isDir(path);
    catch (Exception) return false;
}

/// Whether the system's error `code` means there's nothing at the path, or a part of it on the way
/// isn't a directory.
private bool isMissing(uint code) nothrow
{
    version (Windows)
    {
        import core.sys.windows.winerror : ERROR_FILE_NOT_FOUND, ERROR_INVALID_NAME, ERROR_PATH_NOT_FOUND;

        return code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND || code == ERROR_INVALID_NAME;
    }
    else
    {
        import core.stdc.errno : ENOENT, ENOTDIR;

        return code == ENOENT || code == ENOTDIR;
    }
}

/// The system's message for the failure `e`, without the path Phobos puts first.
private string messageOf(Exception e) nothrow
{
    import std.file : FileException;

    auto failure = cast(FileException) e;
    if (failure is null || failure.errno == 0) return e.msg;
    try
    {
        version (Windows)
        {
            import std.string : stripRight;
            import std.windows.syserror : sysErrorString;

            return sysErrorString(failure.errno).stripRight;
        }
        else
        {
            import core.stdc.string : strerror;
            import std.string : fromStringz;

            return strerror(cast(int) failure.errno).fromStringz.idup;
        }
    }
    catch (Exception) return e.msg;
}

version (unittest)
{
    private string scratch(string name)
    {
        import std.conv : to;
        import std.file : mkdirRecurse, tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        auto directory = buildPath(tempDir, "silver-files-" ~ thisProcessID.to!string ~ "-" ~ name);
        mkdirRecurse(directory);
        return directory;
    }
}

@("bytes are written and read back as they are, and text only when it's UTF-8")
unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    auto directory = scratch("bytes");
    scope (exit) rmdirRecurse(directory);
    auto path = buildPath(directory, "café.bin");
    immutable ubyte[] data = [0x0D, 0x0A, 0x00, 0xFF];
    assert(writeWhole(path, data, false).status == FileStatus.done);
    assert(writeWhole(path, [0x41], true).status == FileStatus.done);
    auto read = readWhole(path, false);
    assert(read.status == FileStatus.done && cast(const(ubyte)[]) read.text == data ~ ubyte(0x41));
    assert(readWhole(path, true).status == FileStatus.notUtf8);
    assert(pathExists(path));
}

@("a missing file is notFound, and a directory or a NUL fails with a message of Silver's own")
unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    auto directory = scratch("failures");
    scope (exit) rmdirRecurse(directory);
    assert(readWhole(buildPath(directory, "missing"), true) == FileOutcome(FileStatus.notFound));
    assert(readWhole(buildPath(directory, "missing", "nested"), false) == FileOutcome(FileStatus.notFound));
    assert(readWhole(directory, true) == FileOutcome(FileStatus.failed, "Is a directory"));
    assert(writeWhole(directory, [], true) == FileOutcome(FileStatus.failed, "Is a directory"));
    assert(readWhole("a\0b", true) == FileOutcome(FileStatus.failed, "The path contains a NUL character"));
    assert(!pathExists("a\0b"));
    assert(pathExists(directory));

    auto failed = writeWhole(buildPath(directory, "missing", "new"), [], false);
    assert(failed.status == FileStatus.failed && failed.text.length > 0);
    assert(!pathExists(buildPath(directory, "missing")));
}
