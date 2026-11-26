module silver.interpreter.errors;

import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException, SourceMap;

/// A failure while running a program, located at the node that was being evaluated.
class RuntimeError : DiagnosticException
{
    this(Diagnostic diagnostic)
    {
        super(diagnostic);
    }
}

/// `main` returned an error, which `message` is, formatted. The program ends with it reported.
class ProgramFailed : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

/// The program called `exit`. It ends with `status`, after what it printed is written out.
class ProgramExited : Exception
{
    ubyte status;

    this(ubyte status, string file = __FILE__, size_t line = __LINE__)
    {
        super("exit", file, line);
        this.status = status;
    }
}

/// Writing to standard output failed, which ends the program with status 1. A closed pipe is the reader having
/// what it asked for, so it has no message; any other failure's `msg` is what follows `error: `.
class OutputFailed : Exception
{
    /// Whether the reader closed the pipe.
    bool closedPipe;

    this(bool closedPipe, string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
        this.closedPipe = closedPipe;
    }

    /// The failure `error`, a C `errno`, was.
    static OutputFailed of(int error)
    {
        import core.stdc.errno : EINVAL, EPIPE;
        import core.stdc.string : strerror;
        import std.string : fromStringz;

        // The C library reports a write to a closed pipe on Windows as EPIPE or EINVAL.
        version (Windows) bool closed = error == EPIPE || error == EINVAL;
        else bool closed = error == EPIPE;
        return new OutputFailed(closed, "couldn't write output: " ~ strerror(error).fromStringz.idup);
    }
}

/// What ends a program given `arguments` before its `main` starts, as an error from `main` would be
/// reported, or null when every argument is UTF-8. On Windows, an argument with an unpaired surrogate
/// arrives here as invalid UTF-8 too. The front end and the runtime keep copies, which a test compares.
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

/// `text` as it can be shown: what's UTF-8 as it is, each other byte as `\xHH`, and an unpaired
/// surrogate, as WTF-8 writes one, as `\u{D800}`.
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

@("an argument that isn't UTF-8 is named by its place, counting from 1, and shown with what isn't UTF-8 escaped")
unittest
{
    assert(argumentsMistake(["a", "é", ""]) is null);
    assert(argumentsMistake(["a", "caf\xe9.txt"]) == `argument 2 isn't UTF-8: caf\xE9.txt`);
    // An unpaired surrogate, as WTF-8 writes one.
    assert(argumentsMistake(["x\xed\xa0\x80y"]) == `argument 1 isn't UTF-8: x\u{D800}y`);
    assert(lossy("é\xff\xfe😀\xed\xbf\xbf") == `é\xFF\xFE😀\u{DFFF}`);
    assert(lossy("\xe2\x82") == `\xE2\x82`);
}

/// The exit status of a program that panics, on both backends: the driver exits with it, and the
/// runtime has its own copy. An error returned from `main` exits with 1.
enum panicStatus = 101;

/// How a panic is reported on standard error, by the interpreter's driver as by compiled programs.
string panicReport(const Diagnostic diagnostic, const SourceMap sources)
{
    import std.format : format;

    auto at = sources.locate(diagnostic.span);
    return "panic: %s(%s,%s): %s".format(diagnostic.span.file, at.line, at.column, diagnostic.message);
}
