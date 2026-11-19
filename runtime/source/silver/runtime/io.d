/// The prelude's `print` and `printl`, and the `readLine` under `read`. `print` and `printl` take
/// `Any`, so there's one function per argument type, named `silver_<intrinsic>_<type>`. Values are
/// formatted with `to!string`, as the interpreter does, so both backends print the same thing.
/// Every integer type widens to `int` or `uint` first.
module silver.runtime.io;

import core.exception : OutOfMemoryError;
import std.conv : to;
import std.stdio : readln, stdout;

import silver.runtime.buffer : newString;
import silver.runtime.format : floatText;
import silver.runtime.memory : SavedRegisters, silver_save_registers;
import silver.runtime.panic : outOfMemory, panic;
import silver.runtime.testing : testing, testOutput;

extern (C) nothrow:

void silver_print_int(long value) { output(value.to!string, false); }
void silver_print_uint(ulong value) { output(value.to!string, false); }
void silver_print_float(double value) { output(floatText(value), false); }
void silver_print_bool(bool value) { output(value.to!string, false); }
void silver_print_string(const(char)* data, size_t length) { output(data[0 .. length], false); }
void silver_print_unit() { output("()", false); }
void silver_print_char(uint value) { output([cast(dchar) value].to!string, false); }

void silver_printl_int(long value) { output(value.to!string, true); }
void silver_printl_uint(ulong value) { output(value.to!string, true); }
void silver_printl_float(double value) { output(floatText(value), true); }
void silver_printl_bool(bool value) { output(value.to!string, true); }
void silver_printl_string(const(char)* data, size_t length) { output(data[0 .. length], true); }
void silver_printl_unit() { output("()", true); }
void silver_printl_char(uint value) { output([cast(dchar) value].to!string, true); }

/// A line from stdin, as `readLine` in `intrinsics.io` takes it: 0 and the line without its `\n`
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
