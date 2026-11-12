/// The prelude's `print`, `printl` and `read`. `print` and `printl` take `Any`, so there's one
/// function per argument type, named `silver_<intrinsic>_<type>`. Values are formatted with
/// `to!string`, as the interpreter does, so both backends print the same thing.
/// Every integer type widens to `int` or `uint` first.
module silver.runtime.io;

import std.conv : to;
import std.stdio : readln, stdout;

import silver.runtime.buffer : newString;
import silver.runtime.format : floatText;
import silver.runtime.panic : panic;
import silver.runtime.testing : testing, testOutput;

extern (C) nothrow:

void silver_print_int(long value) { output(value.to!string, false); }
void silver_print_uint(ulong value) { output(value.to!string, false); }
void silver_print_float(double value) { output(floatText(value), false); }
void silver_print_bool(bool value) { output(value.to!string, false); }
void silver_print_string(const(char)* data, size_t length) { output(data[0 .. length], false); }
void silver_print_unit() { output("()", false); }

void silver_printl_int(long value) { output(value.to!string, true); }
void silver_printl_uint(ulong value) { output(value.to!string, true); }
void silver_printl_float(double value) { output(floatText(value), true); }
void silver_printl_bool(bool value) { output(value.to!string, true); }
void silver_printl_string(const(char)* data, size_t length) { output(data[0 .. length], true); }
void silver_printl_unit() { output("()", true); }

/// A line from stdin including its newline, or false at end of input. The line is copied into a
/// buffer (see `silver.runtime.buffer`), since every String on the heap must be in one.
bool silver_read(const(char)** data, size_t* length)
{
    // A test has no input.
    if (testing)
    {
        *data = null;
        *length = 0;
        return false;
    }
    try
    {
        auto line = readln();
        newString(line, data, length);
        return line.length > 0;
    }
    catch (Exception e)
    {
        panic("couldn't read input: " ~ e.msg);
        return false;
    }
}

private void output(lazy const(char)[] text, bool newline)
{
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
    catch (Exception e)
    {
        panic("couldn't write output: " ~ e.msg);
    }
}
