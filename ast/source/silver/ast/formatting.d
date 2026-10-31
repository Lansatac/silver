module silver.ast.formatting;

import silver.ast.diagnostic : Diagnostic, SourceMap;

/// "file(line,column): Severity: message" when the file's text is known,
/// otherwise "file: Severity: message".
string formatDiagnostic(const Diagnostic diagnostic, const SourceMap sources)
{
    import std.format : format;

    auto file = diagnostic.span.file;
    if (!sources.has(file))
    {
        return format("%s: %s: %s", file, diagnostic.severity, diagnostic.message);
    }
    auto location = sources.locate(diagnostic.span);
    return format("%s(%d,%d): %s: %s", file, location.line, location.column,
        diagnostic.severity, diagnostic.message);
}

@("formatDiagnostic gives the line, column and severity for a known file")
unittest
{
    import silver.ast.diagnostic : Severity;
    import silver.ast.span : Span;

    auto sources = new SourceMap;
    sources.add("a.ag", "val a = 1\n    a = 2");
    assert(formatDiagnostic(Diagnostic(Span("a.ag", 14, 15), "boom", Severity.Error), sources)
            == "a.ag(2,5): Error: boom");
    assert(formatDiagnostic(Diagnostic(Span("a.ag", 0, 3), "unused", Severity.Warning), sources)
            == "a.ag(1,1): Warning: unused");
}

@("formatDiagnostic leaves out the position for an unknown file")
unittest
{
    import silver.ast.diagnostic : Severity;
    import silver.ast.span : Span;

    auto sources = new SourceMap;
    assert(formatDiagnostic(Diagnostic(Span("b.ag", 0, 0), "boom", Severity.Error), sources)
            == "b.ag: Error: boom");
}
