/// The prelude's `print`, `printl`, `eprint` and `eprintl`, the `readLine` under `read`, and `lang.file`'s
/// intrinsics. Lowering formats what the printing ones are given, so they write a String.
module silver.runtime.io;

import core.exception : OutOfMemoryError;
import core.stdc.stdio : FILE;
import std.stdio : readln;

import silver.runtime.buffer : newString;
import silver.runtime.registers : SavedRegisters, silver_save_registers;
import silver.runtime.outputerror : describeOutputError, systemError;
import silver.runtime.panic : outOfMemory, panic;
import silver.runtime.testing : testing, testOutput;

extern (C) nothrow:

void silver_print(const(char)* data, size_t length) { output(data[0 .. length], false); }
void silver_printl(const(char)* data, size_t length) { output(data[0 .. length], true); }
void silver_eprint(const(char)* data, size_t length) { errorOutput(data[0 .. length], false); }
void silver_eprintl(const(char)* data, size_t length) { errorOutput(data[0 .. length], true); }

/// A line from stdin, as `readLine` in `lang.io` takes it: 0 and the line without its `\n`
/// or `\r\n`, 1 at the end of input, 2 for a line that isn't UTF-8 (consumed), or 3 and the OS's
/// message. The String is copied into a buffer (see `silver.runtime.buffer`), since every String
/// on the heap must be in one.
int silver_readLine(const(char)** data, size_t* length)
{
    import std.stdio : StdioException;
    import std.utf : UTFException, validate;

    enum line = 0, end = 1, notUtf8 = 2, failed = 3;
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    *data = null;
    *length = 0;
    // A test has no input.
    if (testing) return end;
    try
    {
        string text;
        while (true)
        {
            try
            {
                text = readln();
                break;
            }
            catch (StdioException e)
            {
                enum interrupted = 4;
                if (e.errno != interrupted)
                {
                    newString(e.msg, data, length);
                    return failed;
                }
            }
        }
        if (text.length == 0) return end;
        text = withoutEnding(text);
        try validate(text);
        catch (UTFException) return notUtf8;
        newString(text, data, length);
        return line;
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
    catch (Exception e)
    {
        panic("couldn't read input: " ~ e.msg);
    }
    return failed;
}

/// `readWhole` in `lang.file`: a `FileStatus`, with the file or the system's message through the
/// out slots.
int silver_readWhole(const(char)* path, size_t pathLength, bool text, const(char)** data, size_t* length)
{
    import silver.runtime.buffer : silver_array_append;
    import silver.runtime.files : FileStatus, readWhole;

    SavedRegisters saved = void;
    silver_save_registers(&saved);
    *data = null;
    *length = 0;
    try
    {
        // Read straight into a buffer of Silver's, so the file is held once.
        auto outcome = readWhole(path[0 .. pathLength], text, (size_t size) {
            char* room;
            size_t made;
            silver_array_append(null, 0, null, size, 1, false, cast(const(void)**) &room, &made);
            return room[0 .. made];
        });
        if (outcome.status == FileStatus.done)
        {
            *data = outcome.text.ptr;
            *length = outcome.text.length;
        }
        else
        {
            newString(outcome.text, data, length);
        }
        return outcome.status;
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
    return FileStatus.failed;
}

/// `writeWhole` in `lang.file`: a `FileStatus`, with the system's message through the out slots
/// when it failed.
int silver_writeWhole(const(char)* path, size_t pathLength, const(ubyte)* data, size_t dataLength, bool append,
    const(char)** message, size_t* messageLength)
{
    import silver.runtime.files : FileStatus, writeWhole;

    SavedRegisters saved = void;
    silver_save_registers(&saved);
    *message = null;
    *messageLength = 0;
    try
    {
        auto outcome = writeWhole(path[0 .. pathLength], data[0 .. dataLength], append);
        newString(outcome.text, message, messageLength);
        return outcome.status;
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
    return FileStatus.failed;
}

bool silver_exists(const(char)* path, size_t length)
{
    import silver.runtime.files : pathExists;

    SavedRegisters saved = void;
    silver_save_registers(&saved);
    try return pathExists(path[0 .. length]);
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
    return false;
}

// With C's linkage a helper takes its name from the C library: `write` here was the one files.d's
// `write` called on Linux.
extern (D):

/// `text` without the `\n` or `\r\n` that ends it.
private string withoutEnding(string text)
{
    if (text.length == 0 || text[$ - 1] != '\n') return text;
    text = text[0 .. $ - 1];
    if (text.length > 0 && text[$ - 1] == '\r') text = text[0 .. $ - 1];
    return text;
}

/// Writes to C's `stdout`, the stream a native's `puts` writes to, so the two come out in the order they were
/// made, and C's library decides the buffering, as it did through `std.stdio`: in blocks to a file or a pipe, by
/// line to a terminal on glibc, and not at all to a character device on Windows (a console or `NUL`), where a
/// line under `room` bytes is one write. Flushed by `flushOutput` where the program ends, which ends it if it
/// fails, and before a panic or an error from `main` is reported. Unlocked except where that costs a write: no other thread writes to stdout (`notes/runtime.md`).
private void output(const(char)[] text, bool newline)
{
    import core.stdc.string : memcpy;

    if (testing)
    {
        testedOutput(text, newline);
        return;
    }
    enum room = 256;
    if (newline && text.length < room)
    {
        char[room] line = void;
        memcpy(line.ptr, text.ptr, text.length);
        line[text.length] = '\n';
        write(line[0 .. text.length + 1]);
        return;
    }
    write(text);
    if (newline) write("\n");
}

/// Writes to C's `stderr`, which C leaves unbuffered, so each write reaches the descriptor at once: it
/// doesn't wait for stdout's buffer, and what stdout holds comes out after it. A line under `room` bytes
/// is one write. A failure is ignored. Stdout isn't flushed first, as a panic's report does.
private void errorOutput(const(char)[] text, bool newline)
{
    import core.stdc.stdio : fwrite, stderr;
    import core.stdc.string : memcpy;

    enum room = 256;
    if (newline && text.length < room)
    {
        char[room] line = void;
        memcpy(line.ptr, text.ptr, text.length);
        line[text.length] = '\n';
        fwrite(line.ptr, 1, text.length + 1, stderr);
        return;
    }
    if (text.length > 0) fwrite(text.ptr, 1, text.length, stderr);
    if (newline) fwrite("\n".ptr, 1, 1, stderr);
}

private void testedOutput(const(char)[] text, bool newline)
{
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    try testOutput(newline ? text ~ "\n" : text);
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
}

private void write(const(char)[] text)
{
    import core.stdc.errno : errno;
    import core.stdc.stdio : stdout;

    if (text.length == 0 || writeOut(text.ptr, text.length, stdout) == text.length) return;
    endAfterFailedWrite(errno, systemError);
}

/// Flushes C's `stdout`, as the program ends, and ends it as a failed write does if that fails: what
/// the buffer held is written here, so a failure of an earlier `print` can come out now.
void flushOutput() nothrow @nogc
{
    import core.stdc.errno : errno;
    import core.stdc.stdio : fflush, stdout;

    if (fflush(stdout) != 0) endAfterFailedWrite(errno, systemError);
}

/// A failed write to standard output ends the program: a closed pipe with status 1 and no message, since
/// the reader has what it asked for, anything else with the system's message and status 1. The runtime
/// ignores SIGPIPE so that the write fails with EPIPE rather than the system killing the process.
/// `outputerror.d` says what counts as closed.
private noreturn endAfterFailedWrite(int error, uint system) nothrow @nogc
{
    import core.stdc.stdio : fprintf, stderr;
    import core.stdc.stdlib : exit;

    auto failure = describeOutputError(error, system);
    if (!failure.closedPipe)
        fprintf(stderr, "error: couldn't write output: %.*s\n", cast(int) failure.message.length, failure.message.ptr);
    exit(1);
}

version (CRuntime_Microsoft)
{
    private extern (C) size_t _fwrite_nolock(const(void)* data, size_t size, size_t count, FILE* stream) @nogc;
    private extern (C) int _fileno(FILE* stream) @nogc;
    private extern (C) int _isatty(int descriptor) @nogc;

    /// Whether stdout is a character device, to which the UCRT gives no buffer. Its `fwrite` then buffers
    /// for the length of the call, so the call is one write, where `_fwrite_nolock` makes two. 0 until known.
    private __gshared byte characterDevice;

    private size_t writeOut(const(char)* data, size_t length, FILE* stream) @nogc
    {
        import core.stdc.stdio : fwrite;

        if (characterDevice == 0) characterDevice = _isatty(_fileno(stream)) ? 1 : -1;
        if (characterDevice > 0) return fwrite(data, 1, length, stream);
        return _fwrite_nolock(data, 1, length, stream);
    }
}
else version (CRuntime_Glibc)
{
    private extern (C) size_t fwrite_unlocked(const(void)* data, size_t size, size_t count, FILE* stream) @nogc;

    private size_t writeOut(const(char)* data, size_t length, FILE* stream) @nogc
    {
        return fwrite_unlocked(data, 1, length, stream);
    }
}
else
{
    private size_t writeOut(const(char)* data, size_t length, FILE* stream) @nogc
    {
        import core.stdc.stdio : fwrite;

        return fwrite(data, 1, length, stream);
    }
}
