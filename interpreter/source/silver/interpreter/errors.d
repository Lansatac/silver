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

/// A runtime error that knows its code but not yet its span; the evaluator adds the
/// span of the node being evaluated when it turns this into a RuntimeError.
class CodedException : Exception
{
    DiagnosticCode code;

    this(DiagnosticCode code, string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
        this.code = code;
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

/// What ends a program given `arguments` before its `main` starts, as an error from `main` would be
/// reported, or null when every argument is UTF-8. On Windows, an argument with an unpaired surrogate
/// arrives here as invalid UTF-8 too.
string argumentsMistake(const string[] arguments)
{
    import std.format : format;
    import std.utf : UTFException, validate;

    foreach (i, argument; arguments)
    {
        try validate(argument);
        catch (UTFException) return "argument %s isn't UTF-8".format(i + 1);
    }
    return null;
}

@("an argument that isn't UTF-8 is named by its place, counting from 1")
unittest
{
    assert(argumentsMistake(["a", "é", ""]) is null);
    assert(argumentsMistake(["a", "b\xff"]) == "argument 2 isn't UTF-8");
    // An unpaired surrogate, as WTF-8 writes one.
    assert(argumentsMistake(["\xed\xa0\x80"]) == "argument 1 isn't UTF-8");
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
