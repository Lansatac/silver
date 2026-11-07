/// `String(x)` and string holes for the primitive types; generated code composes these for the
/// rest. Values are formatted with `to!string`, as `print` and the interpreter do. The text is GC
/// memory, which the caller's stack slots keep alive.
module silver.runtime.format;

import std.conv : to;

import silver.runtime.panic : panic;

extern (C) nothrow:

void silver_format_int(long value, const(char)** data, size_t* length) { format(value, data, length); }
void silver_format_uint(ulong value, const(char)** data, size_t* length) { format(value, data, length); }
void silver_format_float(double value, const(char)** data, size_t* length) { format(value, data, length); }
void silver_format_bool(bool value, const(char)** data, size_t* length) { format(value, data, length); }

private void format(T)(T value, const(char)** data, size_t* length)
{
    try
    {
        auto text = value.to!string;
        *data = text.ptr;
        *length = text.length;
    }
    catch (Exception e)
    {
        panic("couldn't format a value: " ~ e.msg);
    }
}
