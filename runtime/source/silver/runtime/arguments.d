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

/// Takes the arguments that follow the program's name before `main` runs, or returns the place,
/// counting from 1, of the first one that isn't UTF-8, and 0 when there's none. On Windows they're
/// read as the system holds them, in UTF-16, since druntime's own conversion would replace an unpaired
/// surrogate rather than refuse it. Elsewhere they're `given`, druntime's, which are the bytes as passed.
size_t takeArguments(string[] given)
{
    import std.utf : UTFException, validate;

    version (Windows)
    {
        import core.sys.windows.shellapi : CommandLineToArgvW;
        import core.sys.windows.winbase : GetCommandLineW, LocalFree;
        import core.stdc.wchar_ : wcslen;
        import std.conv : to;

        int count;
        auto wide = CommandLineToArgvW(GetCommandLineW(), &count);
        scope (exit) LocalFree(wide);
        string[] each;
        foreach (i; 1 .. count)
        {
            auto argument = wide[i][0 .. wcslen(wide[i])];
            try validate(argument);
            catch (UTFException) return i;
            each ~= argument.to!string;
        }
    }
    else
    {
        auto each = given.length > 0 ? given[1 .. $] : null;
        foreach (i, argument; each)
        {
            try validate(argument);
            catch (UTFException) return i + 1;
        }
    }
    if (each.length == 0) return 0;
    // In a buffer of its own, as every array on the heap has to be.
    const(void)* data;
    size_t length;
    silver_array_append(null, 0, null, each.length, Slice.sizeof, false, &data, &length);
    arguments = (cast(Slice*) data)[0 .. length];
    foreach (i, argument; each) newString(argument, &arguments[i].data, &arguments[i].length);
    return 0;
}

/// The arguments, for the entry point lowering makes for a `main` that takes them. Every call
/// gives the same array, so an append to it copies or writes past what this one holds.
extern (C) void silver_arguments(const(void)** data, size_t* length) nothrow @nogc
{
    *data = arguments.ptr;
    *length = arguments.length;
}
