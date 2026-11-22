/// The program's arguments, which `main` takes as a `[String]`: what follows the executable's
/// name on its command line.
module silver.runtime.arguments;

import silver.runtime.buffer : newString, silver_array_append;

private struct Slice
{
    const(char)* data;
    size_t length;
}

/// The arguments as a `[String]`. A root for the collector, being in the data segment.
private __gshared Slice[] arguments;

/// Takes the arguments that follow the program's name before `main` runs, or returns what ends the
/// program when one isn't UTF-8. On Windows they're read as the system holds them, in UTF-16, since
/// druntime's own conversion would replace an unpaired surrogate rather than refuse it; one is written
/// as WTF-8, which isn't UTF-8. Elsewhere they're `given`, druntime's, which are the bytes as passed.
string takeArguments(string[] given)
{
    version (Windows)
    {
        import core.sys.windows.shellapi : CommandLineToArgvW;
        import core.sys.windows.winbase : GetCommandLineW, LocalFree;
        import core.stdc.wchar_ : wcslen;

        int count;
        auto wide = CommandLineToArgvW(GetCommandLineW(), &count);
        scope (exit) LocalFree(wide);
        string[] each;
        foreach (i; 1 .. count) each ~= wtf8(wide[i][0 .. wcslen(wide[i])]);
    }
    else
    {
        auto each = given.length > 0 ? given[1 .. $] : null;
    }
    if (auto mistake = argumentsMistake(each)) return mistake;
    if (each.length == 0) return null;
    // In a buffer of its own, as every array on the heap has to be.
    const(void)* data;
    size_t length;
    silver_array_append(null, 0, null, each.length, Slice.sizeof, false, &data, &length);
    arguments = (cast(Slice*) data)[0 .. length];
    foreach (i, argument; each) newString(argument, &arguments[i].data, &arguments[i].length);
    return null;
}

/// The arguments, for the entry point lowering makes for a `main` that takes them. Every call
/// gives the same array, so an append to it copies or writes past what this one holds.
extern (C) void silver_arguments(const(void)** data, size_t* length) nothrow @nogc
{
    *data = arguments.ptr;
    *length = arguments.length;
}

// Copies of the compiler's, so a compiled program says what `silverc` does. A test in the front end
// compares them: `wtf8` with source/silver/driver.d's, the others with interpreter/errors.d's.

string wtf8(const(wchar)[] text)
{
    char[] result;
    void put(uint c)
    {
        if (c < 0x80) result ~= cast(char) c;
        else if (c < 0x800) result ~= [cast(char)(0xC0 | c >> 6), cast(char)(0x80 | (c & 0x3F))];
        else if (c < 0x10000)
            result ~= [cast(char)(0xE0 | c >> 12), cast(char)(0x80 | (c >> 6 & 0x3F)), cast(char)(0x80 | (c & 0x3F))];
        else result ~= [cast(char)(0xF0 | c >> 18), cast(char)(0x80 | (c >> 12 & 0x3F)), cast(char)(0x80 | (c >> 6 & 0x3F)),
            cast(char)(0x80 | (c & 0x3F))];
    }
    for (size_t i = 0; i < text.length; i++)
    {
        uint c = text[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < text.length && text[i + 1] >= 0xDC00 && text[i + 1] < 0xE000)
        {
            c = 0x10000 + ((c - 0xD800) << 10) + (text[i + 1] - 0xDC00);
            i++;
        }
        put(c);
    }
    return result.idup;
}

string argumentsMistake(const string[] arguments)
{
    import std.format : format;
    import std.utf : UTFException, validate;

    foreach (i, argument; arguments)
    {
        try validate(argument);
        catch (UTFException) return "argument %s isn't UTF-8: %s".format(i + 1, lossy(argument));
    }
    return null;
}

string lossy(const(char)[] text)
{
    import std.format : format;
    import std.utf : decode, UTFException;

    string shown;
    size_t i = 0;
    while (i < text.length)
    {
        if (i + 2 < text.length && text[i] == 0xED && text[i + 1] >= 0xA0 && text[i + 1] <= 0xBF
            && (text[i + 2] & 0xC0) == 0x80)
        {
            shown ~= format("\\u{%X}", 0xD000 | (text[i + 1] & 0x3F) << 6 | (text[i + 2] & 0x3F));
            i += 3;
            continue;
        }
        immutable start = i;
        try
        {
            decode(text, i);
            shown ~= text[start .. i];
        }
        catch (UTFException)
        {
            shown ~= format("\\x%02X", text[start]);
            i = start + 1;
        }
    }
    return shown;
}
