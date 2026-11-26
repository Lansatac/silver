/// The prelude's `print` and `printl`, the `readLine` under `read`, and `lang.file`'s intrinsics.
/// Lowering formats what `print` and `printl` are given, so they write a String.
module silver.runtime.io;

import core.exception : OutOfMemoryError;
import std.stdio : readln, stdout;

import silver.runtime.buffer : newString;
import silver.runtime.registers : SavedRegisters, silver_save_registers;
import silver.runtime.panic : outOfMemory, panic;
import silver.runtime.testing : testing, testOutput;

extern (C) nothrow:

void silver_print(const(char)* data, size_t length) { output(data[0 .. length], false); }
void silver_printl(const(char)* data, size_t length) { output(data[0 .. length], true); }

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

/// `text` without the `\n` or `\r\n` that ends it.
private string withoutEnding(string text)
{
    if (text.length == 0 || text[$ - 1] != '\n') return text;
    text = text[0 .. $ - 1];
    if (text.length > 0 && text[$ - 1] == '\r') text = text[0 .. $ - 1];
    return text;
}

private void output(lazy const(char)[] text, bool newline)
{
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    try
    {
        if (testing)
        {
            testOutput(newline ? text ~ "\n" : text);
            return;
        }
        stdout.write(text);
        if (newline) stdout.write('\n');
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
    catch (Exception e)
    {
        panic("couldn't write output: " ~ e.msg);
    }
}
