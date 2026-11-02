module silver.codegen.gen;

import silver.ast;
import silver.sema : Analysis;

/// Textual LLVM IR for `program`, which must have passed sema without errors.
/// Anything the backend can't compile yet is reported to `collector` as an internal error.
string generate(const ref Program program, const Analysis analysis, Collector collector)
{
    collector.reportError(DiagnosticCode.InternalError, Span.init,
        "The LLVM backend isn't implemented yet");
    return null;
}
