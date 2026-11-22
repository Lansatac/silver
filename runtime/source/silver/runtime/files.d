/// Reading and writing a file whole, under `lang.file`'s intrinsics. The interpreter compiles this
/// module too, so both backends give the same results and the same messages. It uses only druntime
/// and Phobos, nothing else of the runtime's: the runtime passes in how to get a buffer for what's
/// read.
///
/// It talks to the system itself rather than through `std.file`, which on Windows opens a file
/// without sharing, leaves it open when a write fails, and can't reach a path over 260 characters.
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

/// Gives room for `size` bytes, which the caller fills. A file is read into the last room asked for.
alias Allocate = char[] delegate(size_t size) nothrow;

/// The file at `path`, whole, in memory from `allocate`, or from the collector without it. Bytes are
/// read as they are, with no line ending translated. Memory running out isn't a failure of the file's,
/// so it's thrown as ever.
FileOutcome readWhole(const(char)[] path, bool text, scope Allocate allocate = null) nothrow
{
    import std.utf : validate;

    if (path.length == 0) return FileOutcome(FileStatus.notFound);
    if (auto problem = pathProblem(path)) return FileOutcome(FileStatus.failed, problem);
    auto file = SystemPath(path);
    if (file.failure != 0) return FileOutcome(FileStatus.failed, systemMessage(file.failure));
    // Windows says only "Access is denied." of a directory.
    if (file.isDirectory) return FileOutcome(FileStatus.failed, isADirectory);
    if (endsInSeparator(path)) return FileOutcome(FileStatus.failed, notAFile);
    char[] contents;
    Allocate room = allocate;
    if (room is null) room = (size_t size) => collected(size);
    if (auto failure = file.read(room, contents))
    {
        if (isMissing(failure)) return FileOutcome(FileStatus.notFound);
        return FileOutcome(FileStatus.failed, systemMessage(failure));
    }
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
    if (path.length == 0) return FileOutcome(FileStatus.failed, "The path is empty");
    if (auto problem = pathProblem(path)) return FileOutcome(FileStatus.failed, problem);
    auto file = SystemPath(path);
    if (file.failure != 0) return FileOutcome(FileStatus.failed, systemMessage(file.failure));
    if (file.isDirectory) return FileOutcome(FileStatus.failed, isADirectory);
    if (endsInSeparator(path)) return FileOutcome(FileStatus.failed, notAFile);
    if (auto failure = file.write(data, append)) return FileOutcome(FileStatus.failed, systemMessage(failure));
    return FileOutcome(FileStatus.done);
}

/// Whether there's a file or a directory at `path`.
bool pathExists(const(char)[] path) nothrow
{
    if (path.length == 0 || pathProblem(path) !is null) return false;
    auto file = SystemPath(path);
    return file.failure == 0 && (endsInSeparator(path) ? file.isDirectory : file.exists);
}

/// Whether `path` ends in a separator, which makes it a directory's name on every system. Windows would
/// otherwise take `notes.txt/` for `notes.txt`, and write a file where a directory was meant.
private bool endsInSeparator(const(char)[] path) nothrow
{
    version (Windows) return path[$ - 1] == '/' || path[$ - 1] == '\\';
    else return path[$ - 1] == '/';
}

/// POSIX's own words for it.
private enum isADirectory = "Is a directory";
private enum notAFile = "A path ending in a separator names a directory, not a file";

/// Why no system call could take `path`: C's strings would end it at a NUL.
private string pathProblem(const(char)[] path) nothrow
{
    foreach (c; path)
    {
        if (c == '\0') return "The path contains a NUL character";
    }
    return null;
}

/// Room from the collector, which needn't look through it for pointers.
private char[] collected(size_t size) nothrow
{
    import core.memory : GC;

    if (size == 0) return null;
    return (cast(char*) GC.malloc(size, GC.BlkAttr.NO_SCAN))[0 .. size];
}

/// How much more to read at a time once a file has given what its size promised, or when it gave none.
private enum chunk = 64 * 1024;

/// Reads with `next`, which gives how many bytes it put in the room it's given (0 at the end) or
/// sets `failure`, into room from `allocate`, starting with `expected` bytes and growing when the
/// file turns out longer.
private uint readAll(scope Allocate allocate, size_t expected, scope long delegate(char[] room, out uint failure) nothrow next,
    out char[] contents) nothrow
{
    import core.stdc.string : memcpy;

    auto room = allocate(expected);
    size_t filled;
    char[chunk] extra = void;
    while (true)
    {
        uint failure;
        auto into = filled < room.length ? room[filled .. $] : extra[];
        auto count = next(into, failure);
        if (failure != 0) return failure;
        if (count == 0) break;
        if (into.ptr == extra.ptr)
        {
            auto larger = allocate(room.length * 2 + chunk);
            if (filled > 0) memcpy(larger.ptr, room.ptr, filled);
            memcpy(larger.ptr + filled, extra.ptr, cast(size_t) count);
            room = larger;
        }
        filled += cast(size_t) count;
    }
    contents = room[0 .. filled];
    return 0;
}

version (Windows)
{
    import core.sys.windows.windows;

    /// A path as Windows' wide functions take it, with what was found there.
    private struct SystemPath
    {
        const(wchar)* name;
        DWORD attributes = INVALID_FILE_ATTRIBUTES;
        /// The error when the path couldn't be made into a wide one.
        uint failure;

        this(const(char)[] path) nothrow
        {
            name = wideName(path, failure);
            if (failure == 0) attributes = GetFileAttributesW(name);
        }

        bool exists() const nothrow => attributes != INVALID_FILE_ATTRIBUTES;
        bool isDirectory() const nothrow => exists && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;

        uint read(scope Allocate allocate, out char[] contents) nothrow
        {
            auto handle = CreateFileW(name, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null,
                OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, null);
            if (handle == INVALID_HANDLE_VALUE) return GetLastError();
            scope (exit) CloseHandle(handle);
            LARGE_INTEGER size;
            if (!GetFileSizeEx(handle, &size)) return GetLastError();
            if (cast(ulong) size.QuadPart > size_t.max) return ERROR_NOT_ENOUGH_MEMORY;
            return readAll(allocate, cast(size_t) size.QuadPart, (char[] room, out uint failure) {
                DWORD count;
                auto asked = room.length > int.max ? int.max : cast(DWORD) room.length;
                if (!ReadFile(handle, room.ptr, asked, &count, null)) failure = GetLastError();
                return cast(long) count;
            }, contents);
        }

        /// Replacing opens what's there and empties it, rather than creating it anew, which Windows
        /// refuses for a hidden file. Appending asks only to append, so each write lands at the end
        /// whatever else writes to the file.
        uint write(const(ubyte)[] data, bool append) nothrow
        {
            enum share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
            auto handle = CreateFileW(name, append ? FILE_APPEND_DATA : GENERIC_WRITE, share, null, OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL, null);
            if (handle == INVALID_HANDLE_VALUE) return GetLastError();
            bool closed;
            scope (exit) if (!closed) CloseHandle(handle);
            if (!append && !SetEndOfFile(handle)) return GetLastError();
            while (data.length > 0)
            {
                DWORD count;
                auto asked = data.length > int.max ? int.max : cast(DWORD) data.length;
                if (!WriteFile(handle, data.ptr, asked, &count, null)) return GetLastError();
                if (count == 0) return ERROR_WRITE_FAULT;
                data = data[count .. $];
            }
            closed = true;
            return CloseHandle(handle) ? 0 : GetLastError();
        }
    }

    /// `path` as a NUL-terminated wide string. One whose full form is too long for Windows' plain
    /// functions takes the `\\?\` form, which reaches any length but means exactly what it says, so a
    /// shorter one is left as written.
    private const(wchar)* wideName(const(char)[] path, out uint failure) nothrow
    {
        import std.utf : toUTF16;

        wstring wide;
        try wide = toUTF16(path);
        catch (Exception)
        {
            failure = ERROR_INVALID_NAME;
            return null;
        }
        auto plain = (wide ~ '\0').ptr;
        auto needed = GetFullPathNameW(plain, 0, null, null);
        if (needed <= MAX_PATH) return plain;
        auto full = new wchar[](needed);
        auto length = GetFullPathNameW(plain, needed, full.ptr, null);
        if (length == 0 || length >= needed) return plain;
        auto absolute = full[0 .. length];
        if (absolute.length >= 4 && (absolute[0 .. 4] == `\\?\` || absolute[0 .. 4] == `\\.\`)) return plain;
        if (absolute.length >= 2 && absolute[0 .. 2] == `\\`) return (`\\?\UNC` ~ absolute[1 .. $] ~ '\0').ptr;
        return (`\\?\` ~ absolute ~ '\0').ptr;
    }

    /// Whether the system's error `code` means there's nothing at the path, or a part of it on the way
    /// isn't a directory, or Windows can't take the name.
    private bool isMissing(uint code) nothrow
    {
        return code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND || code == ERROR_INVALID_NAME;
    }

    /// The system's words for error `code`, in the user's language, without the line break after them.
    private string systemMessage(uint code) nothrow
    {
        import std.string : stripRight;
        import std.windows.syserror : sysErrorString;

        try return sysErrorString(code).stripRight;
        catch (Exception) return "System error " ~ decimal(code);
    }
}
else version (Posix)
{
    import core.stdc.errno : EINTR, ENOENT, ENOTDIR, errno;
    import core.sys.posix.fcntl : O_APPEND, O_CLOEXEC, O_CREAT, O_RDONLY, O_TRUNC, O_WRONLY, open;
    import core.sys.posix.sys.stat : fstat, S_IFDIR, S_IFMT, stat, stat_t;
    import core.sys.posix.unistd : close, posixRead = read, posixWrite = write;

    /// A path as the system's functions take it, with what was found there.
    private struct SystemPath
    {
        const(char)* name;
        bool exists;
        bool isDirectory;
        uint failure;

        this(const(char)[] path) nothrow
        {
            name = (path ~ '\0').ptr;
            stat_t status;
            if (stat(name, &status) != 0) return;
            exists = true;
            isDirectory = (status.st_mode & S_IFMT) == S_IFDIR;
        }

        uint read(scope Allocate allocate, out char[] contents) nothrow
        {
            int file;
            do file = open(name, O_RDONLY | O_CLOEXEC);
            while (file < 0 && errno == EINTR);
            if (file < 0) return errno;
            scope (exit) close(file);
            // Only a hint: a file under /proc says 0, and any file can change while it's read.
            stat_t status;
            auto expected = fstat(file, &status) == 0 && status.st_size > 0 ? cast(size_t) status.st_size : 0;
            return readAll(allocate, expected, (char[] room, out uint failure) {
                while (true)
                {
                    auto count = posixRead(file, room.ptr, room.length);
                    if (count >= 0) return cast(long) count;
                    if (errno != EINTR)
                    {
                        failure = errno;
                        return 0L;
                    }
                }
            }, contents);
        }

        uint write(const(ubyte)[] data, bool append) nothrow
        {
            int file;
            do file = open(name, O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC), octal666);
            while (file < 0 && errno == EINTR);
            if (file < 0) return errno;
            bool closed;
            scope (exit) if (!closed) close(file);
            while (data.length > 0)
            {
                auto count = posixWrite(file, data.ptr, data.length);
                if (count < 0)
                {
                    if (errno == EINTR) continue;
                    return errno;
                }
                data = data[count .. $];
            }
            closed = true;
            // Linux has closed it even when interrupted, so it isn't tried again.
            return close(file) == 0 || errno == EINTR ? 0 : errno;
        }
    }

    private enum octal666 = 6 * 64 + 6 * 8 + 6;

    /// Whether the system's error `code` means there's nothing at the path, or a part of it on the way
    /// isn't a directory.
    private bool isMissing(uint code) nothrow
    {
        return code == ENOENT || code == ENOTDIR;
    }

    private string systemMessage(uint code) nothrow
    {
        import core.stdc.string : strerror;
        import std.string : fromStringz;

        return strerror(cast(int) code).fromStringz.idup;
    }
}

/// `n` in decimal, where `to!string` might throw.
private string decimal(uint n) nothrow
{
    char[10] digits;
    size_t at = digits.length;
    do
    {
        digits[--at] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n != 0);
    return digits[at .. $].idup;
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

@("a file something else has open to read can still be added to")
unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    import std.stdio : File;

    auto directory = scratch("shared");
    scope (exit) rmdirRecurse(directory);
    auto path = buildPath(directory, "log.txt");
    assert(writeWhole(path, cast(const(ubyte)[]) "one\n", false).status == FileStatus.done);
    {
        auto reader = File(path, "rb");
        scope (exit) reader.close();
        auto appended = writeWhole(path, cast(const(ubyte)[]) "two\n", true);
        assert(appended.status == FileStatus.done, appended.text);
        assert(readWhole(path, true).text == "one\ntwo\n");
        auto replaced = writeWhole(path, cast(const(ubyte)[]) "three\n", false);
        assert(replaced.status == FileStatus.done, replaced.text);
    }
    assert(readWhole(path, true).text == "three\n");
}

@("an empty path is nothing there to read and can't be written, and a reason never holds the path")
unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    assert(readWhole("", true) == FileOutcome(FileStatus.notFound));
    assert(readWhole("", false) == FileOutcome(FileStatus.notFound));
    assert(writeWhole("", [], false) == FileOutcome(FileStatus.failed, "The path is empty"));
    assert(!pathExists(""));

    auto directory = scratch("reasons");
    scope (exit) rmdirRecurse(directory);
    auto failed = writeWhole(buildPath(directory, "nowhere", "new.txt"), [], true);
    assert(failed.status == FileStatus.failed && failed.text.length > 0);
    assert(!failed.text.canFind("nowhere") && !failed.text.canFind("new.txt"), failed.text);
}

@("a path cut short at a NUL would name a file that's there, so the NUL is checked")
unittest
{
    import std.file : rmdirRecurse, write;
    import std.path : buildPath;

    auto directory = scratch("nul");
    scope (exit) rmdirRecurse(directory);
    auto named = buildPath(directory, "a");
    write(named, "there");
    assert(pathExists(named));
    assert(!pathExists(named ~ "\0b"));
    assert(readWhole(named ~ "\0b", true) == FileOutcome(FileStatus.failed, "The path contains a NUL character"));
    assert(writeWhole(named ~ "\0b", [], false).status == FileStatus.failed);
    assert(readWhole(named, true).text == "there");
}

@("a path ending in a separator is never a file, whether or not one is there")
unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    auto directory = scratch("separator");
    scope (exit) rmdirRecurse(directory);
    auto file = buildPath(directory, "notes.txt");
    assert(writeWhole(file, cast(const(ubyte)[]) "kept", false).status == FileStatus.done);
    enum refused = "A path ending in a separator names a directory, not a file";
    assert(readWhole(file ~ "/", true) == FileOutcome(FileStatus.failed, refused));
    assert(writeWhole(file ~ "/", [], false) == FileOutcome(FileStatus.failed, refused));
    assert(writeWhole(buildPath(directory, "new") ~ "/", [], true) == FileOutcome(FileStatus.failed, refused));
    assert(!pathExists(file ~ "/"));
    assert(!pathExists(buildPath(directory, "new")));
    assert(pathExists(directory ~ "/"));
    assert(readWhole(directory ~ "/", true) == FileOutcome(FileStatus.failed, "Is a directory"));
    version (Windows) assert(readWhole(file ~ `\`, true) == FileOutcome(FileStatus.failed, refused));
    assert(readWhole(file, true).text == "kept");
}

version (Windows)
@("a hidden file can be replaced")
unittest
{
    import core.sys.windows.windows : FILE_ATTRIBUTE_HIDDEN, SetFileAttributesW;
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    import std.utf : toUTF16z;

    auto directory = scratch("hidden");
    scope (exit) rmdirRecurse(directory);
    auto path = buildPath(directory, "hidden.txt");
    assert(writeWhole(path, cast(const(ubyte)[]) "old", false).status == FileStatus.done);
    assert(SetFileAttributesW(path.toUTF16z, FILE_ATTRIBUTE_HIDDEN));
    auto replaced = writeWhole(path, cast(const(ubyte)[]) "new", false);
    assert(replaced.status == FileStatus.done, replaced.text);
    assert(readWhole(path, true).text == "new");
}

version (linux)
@("a file that says it's empty is read to its end")
unittest
{
    auto read = readWhole("/proc/self/cmdline", false);
    assert(read.status == FileStatus.done && read.text.length > 0);
}

@("a file longer than one read is read whole, through the room it's given")
unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    auto directory = scratch("chunks");
    scope (exit) rmdirRecurse(directory);
    auto path = buildPath(directory, "big.bin");
    auto data = new ubyte[](200_000);
    foreach (i, ref b; data) b = cast(ubyte) i;
    assert(writeWhole(path, data, false).status == FileStatus.done);
    size_t asked;
    auto read = readWhole(path, false, (size_t size) nothrow { asked += size; return new char[](size); });
    assert(read.status == FileStatus.done && cast(const(ubyte)[]) read.text == data);
    assert(asked == data.length);
}

@("a path longer than 260 characters reaches its file")
unittest
{
    import std.array : replicate;
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    auto directory = scratch("long");
    // The prefix that lets Windows' own functions take a long path, for setting up and clearing away.
    version (Windows) auto reach = `\\?\` ~ directory;
    else auto reach = directory;
    scope (exit) rmdirRecurse(reach);
    auto name = "d".replicate(50);
    auto deep = buildPath(name, name, name, name, name, name);
    mkdirRecurse(buildPath(reach, deep));
    write(buildPath(reach, deep, "f.txt"), "old");

    auto path = buildPath(directory, deep, "f.txt");
    assert(path.length > 260);
    assert(pathExists(path), "exists is false for a file that's there");
    auto read = readWhole(path, true);
    assert(read.status == FileStatus.done && read.text == "old", "reading a file that's there is notFound");
    auto written = writeWhole(path, cast(const(ubyte)[]) "new", false);
    assert(written.status == FileStatus.done, written.text);
}

version (Windows)
@("adding to a file past 4 GB works, and a write that fails leaves the file free")
unittest
{
    import core.sys.windows.windows;
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    import std.utf : toUTF16z;

    auto directory = scratch("large");
    // Sparse, so it takes no room. Removing it fails if a failed write kept it open.
    scope (exit) rmdirRecurse(directory);
    auto path = buildPath(directory, "large.bin");
    auto handle = CreateFileW(path.toUTF16z, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    assert(handle != INVALID_HANDLE_VALUE);
    enum setSparse = 0x900C4;
    DWORD returned;
    immutable sparse = DeviceIoControl(handle, setSparse, null, 0, null, 0, &returned, null) != 0;
    LARGE_INTEGER size;
    size.QuadPart = 5L << 30;
    immutable sized = sparse && SetFilePointerEx(handle, size, null, FILE_BEGIN) && SetEndOfFile(handle);
    CloseHandle(handle);
    // A file system without sparse files would have to fill 5 GB.
    if (!sized) return;

    auto first = writeWhole(path, cast(const(ubyte)[]) "tail", true);
    auto second = writeWhole(path, cast(const(ubyte)[]) "tail", true);
    assert(second.status == FileStatus.done || second.text == first.text,
        "the failed write left the file open: " ~ second.text);
    assert(first.status == FileStatus.done, first.text);
}
