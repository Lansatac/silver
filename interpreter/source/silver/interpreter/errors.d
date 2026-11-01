module silver.interpreter.errors;

import silver.ast : DiagnosticCode;

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
