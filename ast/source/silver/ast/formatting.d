module silver.ast.formatting;

import silver.ast.diagnostic : Diagnostic, SourceMap;

/// "file(line,column): Severity CODE: message" when the file's text is known,
/// otherwise "file: Severity CODE: message".
string formatDiagnostic(const Diagnostic diagnostic, const SourceMap sources)
{
    import std.format : format;

    auto file = diagnostic.span.file;
    if (!sources.has(file))
    {
        return format("%s: %s %s: %s", file, diagnostic.severity, cast(string) diagnostic.code,
            diagnostic.message);
    }
    auto location = sources.locate(diagnostic.span);
    return format("%s(%d,%d): %s %s: %s", file, location.line, location.column,
        diagnostic.severity, cast(string) diagnostic.code, diagnostic.message);
}

@("formatDiagnostic gives the line, column and severity for a known file")
unittest
{
    import silver.ast.diagnostic : Severity;
    import silver.ast.errors : DiagnosticCode;
    import silver.ast.span : Span;

    auto sources = new SourceMap;
    sources.add("a.ag", "val a = 1\n    a = 2");
    assert(formatDiagnostic(Diagnostic(DiagnosticCode.UnknownName, Span("a.ag", 14, 15), "boom",
            Severity.Error), sources) == "a.ag(2,5): Error S0002: boom");
    assert(formatDiagnostic(Diagnostic(DiagnosticCode.UnknownName, Span("a.ag", 0, 3), "unused",
            Severity.Warning), sources) == "a.ag(1,1): Warning S0002: unused");
}

@("formatDiagnostic leaves out the position for an unknown file")
unittest
{
    import silver.ast.diagnostic : Severity;
    import silver.ast.errors : DiagnosticCode;
    import silver.ast.span : Span;

    auto sources = new SourceMap;
    assert(formatDiagnostic(Diagnostic(DiagnosticCode.ParseError, Span("b.ag", 0, 0), "boom",
            Severity.Error), sources) == "b.ag: Error P0001: boom");
}
