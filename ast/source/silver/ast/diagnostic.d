module silver.ast.diagnostic;

import silver.ast.span;

enum Severity
{
    Hint,
    Warning,
    Error,
}

/// A message about a range of Silver source, shared by parse and runtime errors.
struct Diagnostic
{
    Span span;
    string message;
    Severity severity;

    this(Span span, string message, Severity severity)
    {
        this.span = span;
        this.message = message;
        this.severity = severity;
    }
}

/// Base class for errors that point at Silver source.
class DiagnosticException : Exception
{
    Diagnostic diagnostic;

    this(Diagnostic diagnostic, string file = __FILE__, size_t line = __LINE__)
    {
        super(diagnostic.message, file, line);
        this.diagnostic = diagnostic;
    }
}

class Collector
{
    import std.algorithm : filter;

    private Diagnostic[] _diagnostics;

    const(Diagnostic)[] diagnostics() const
    {
        return _diagnostics;
    }

    void reportError(Span span, string message)
    {
        _diagnostics ~= Diagnostic(span, message, Severity.Error);
    }

    void reportWarning(Span span, string message)
    {
        _diagnostics ~= Diagnostic(span, message, Severity.Warning);
    }

    auto errors() const
    {
        return _diagnostics.filter!(d => d.severity == Severity.Error);
    }

    bool hasErrors() const
    {
        return !errors().empty;
    }

    auto warnings() const
    {
        return _diagnostics.filter!(d => d.severity == Severity.Warning);
    }

    bool hasWarnings() const
    {
        return !warnings().empty;
    }
}

@("Collector starts empty")
unittest
{
    auto collector = new Collector;
    assert(collector.diagnostics.length == 0);
    assert(collector.errors.empty);
    assert(collector.warnings.empty);
    assert(!collector.hasErrors);
    assert(!collector.hasWarnings);
}

@("Collector records an error with its span and message")
unittest
{
    auto collector = new Collector;
    collector.reportError(Span("a.ag", 4, 5), "boom");

    assert(collector.diagnostics == [Diagnostic(Span("a.ag", 4, 5), "boom", Severity.Error)]);
    assert(collector.hasErrors);
    assert(!collector.hasWarnings);
}

@("Collector with only warnings has no errors")
unittest
{
    auto collector = new Collector;
    collector.reportWarning(Span("a.ag", 0, 1), "unused");

    assert(collector.diagnostics == [Diagnostic(Span("a.ag", 0, 1), "unused", Severity.Warning)]);
    assert(collector.hasWarnings);
    assert(!collector.hasErrors);
}

@("Collector keeps report order and filters errors from warnings")
unittest
{
    import std.algorithm : equal, map;

    auto collector = new Collector;
    collector.reportError(Span("a.ag", 0, 1), "first error");
    collector.reportWarning(Span("a.ag", 2, 3), "first warning");
    collector.reportError(Span("b.ag", 0, 1), "second error");
    collector.reportWarning(Span("b.ag", 2, 3), "second warning");

    assert(collector.diagnostics.map!(d => d.message)
            .equal(["first error", "first warning", "second error", "second warning"]));
    assert(collector.errors.map!(d => d.message).equal(["first error", "second error"]));
    assert(collector.warnings.map!(d => d.message).equal(["first warning", "second warning"]));
}

/// A position in a source file. Both fields are 1-based.
struct Location
{
    size_t line;
    size_t column;
}

/// Source text by file name, for turning Spans into line and column.
class SourceMap
{
    private string[string] texts;

    /// Records `text` as the contents of `file`, replacing any earlier text for it.
    void add(string file, string text)
    {
        texts[file] = text;
    }

    /// True if the text of `file` has been added.
    bool has(string file) const
    {
        return (file in texts) !is null;
    }

    /// The line and column of `span.start`. The column counts bytes since the last
    /// newline. A span in an unknown file, or past the end of its text, is clamped
    /// to the text it has, which for an unknown file is Location(1, 1).
    Location locate(Span span) const
    {
        auto text = span.file in texts;
        string source = text is null ? "" : *text;
        auto offset = span.start < source.length ? span.start : source.length;

        size_t line = 1;
        size_t lineStart = 0;
        foreach (i, character; source[0 .. offset])
        {
            if (character == '\n')
            {
                line++;
                lineStart = i + 1;
            }
        }
        return Location(line, offset - lineStart + 1);
    }
}

class SourceContext
{
    private SourceMap _sources;
    private Collector _collector;

    this()
    {
        _sources = new SourceMap();
        _collector = new Collector();
    }

    SourceMap sources()
    {
        return _sources;
    }

    Collector collector()
    {
        return _collector;
    }
}

@("SourceMap locates a span on the first line")
unittest
{
    auto sources = new SourceMap;
    sources.add("a.ag", "val a = 1");
    auto location = sources.locate(Span("a.ag", 4, 5));
    assert(location == Location(1, 5));
}

@("SourceMap locates a span after newlines")
unittest
{
    auto sources = new SourceMap;
    sources.add("a.ag", "val a = 1\n    a = 2");
    // The second line starts at offset 10 and its `a` is at offset 14.
    auto location = sources.locate(Span("a.ag", 14, 15));
    assert(location == Location(2, 5));
}

@("SourceMap knows which files it has")
unittest
{
    auto sources = new SourceMap;
    sources.add("a.ag", "val a = 1");
    assert(sources.has("a.ag"));
    assert(!sources.has("b.ag"));
}
