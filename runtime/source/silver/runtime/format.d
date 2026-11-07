/// `String(x)` and string holes for the primitive types; generated code composes these for the
/// rest. Values are formatted with `to!string`, as `print` and the interpreter do, and the text is
/// copied into a buffer (see `silver.runtime.buffer`), since every String on the heap must be in one.
module silver.runtime.format;

import std.conv : to;

import silver.runtime.buffer : newString, silver_array_append;
import silver.runtime.panic : panic;

extern (C) nothrow:

void silver_format_int(long value, const(char)** data, size_t* length) { format(value, data, length); }
void silver_format_uint(ulong value, const(char)** data, size_t* length) { format(value, data, length); }
void silver_format_float(double value, const(char)** data, size_t* length) { format(value, data, length); }
void silver_format_bool(bool value, const(char)** data, size_t* length) { format(value, data, length); }

/// One String per element, already formatted, as `[a, b]`.
void silver_array_format(const(Formatted)* parts, size_t count, const(char)** data, size_t* length)
{
    enum separator = ", ";
    auto total = 2 + (count == 0 ? 0 : (count - 1) * separator.length);
    foreach (part; parts[0 .. count])
    {
        total += part.length;
    }

    const(void)* buffer;
    silver_array_append(null, 0, null, total, 1, false, &buffer, length);
    auto text = cast(char[]) buffer[0 .. total];
    *data = text.ptr;

    size_t at = 0;
    void put(const(char)[] piece)
    {
        text[at .. at + piece.length] = piece;
        at += piece.length;
    }
    put("[");
    foreach (i, part; parts[0 .. count])
    {
        if (i > 0) put(separator);
        put(part.data[0 .. part.length]);
    }
    put("]");
}

/// A String as generated code lays one out in memory.
private struct Formatted
{
    const(char)* data;
    size_t length;
}

private void format(T)(T value, const(char)** data, size_t* length)
{
    try
    {
        newString(value.to!string, data, length);
    }
    catch (Exception e)
    {
        panic("couldn't format a value: " ~ e.msg);
    }
}
