module silver.interpreter.errors;

import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException;

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
