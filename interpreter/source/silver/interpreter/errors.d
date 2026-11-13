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
