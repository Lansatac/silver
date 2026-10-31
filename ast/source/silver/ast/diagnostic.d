module silver.ast.diagnostic;

import silver.ast.span;

/// A message about a range of Silver source, shared by parse and runtime errors.
struct Diagnostic
{
    Span span;
    string message;
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

    /// "file:line:column: message" when the file is known, otherwise "file: message".
    string format(Diagnostic diagnostic) const
    {
        import std.conv : to;

        auto file = diagnostic.span.file;
        if (!has(file))
        {
            return file ~ ": " ~ diagnostic.message;
        }
        auto location = locate(diagnostic.span);
        return file ~ ":" ~ location.line.to!string ~ ":" ~ location.column.to!string
            ~ ": " ~ diagnostic.message;
    }
}

@("SourceMap locates a span on the first line")
unittest
{
    auto sources = new SourceMap;
    sources.add("a.silver", "val a = 1");
    auto location = sources.locate(Span("a.silver", 4, 5));
    assert(location == Location(1, 5));
}

@("SourceMap locates a span after newlines")
unittest
{
    auto sources = new SourceMap;
    sources.add("a.silver", "val a = 1\n    a = 2");
    // The second line starts at offset 10 and its `a` is at offset 14.
    auto location = sources.locate(Span("a.silver", 14, 15));
    assert(location == Location(2, 5));
}

@("SourceMap formats a diagnostic with a known and an unknown file")
unittest
{
    auto sources = new SourceMap;
    sources.add("a.silver", "val a = 1\n    a = 2");
    assert(sources.has("a.silver"));
    assert(!sources.has("b.silver"));
    assert(sources.format(Diagnostic(Span("a.silver", 14, 15), "boom")) == "a.silver:2:5: boom");
    assert(sources.format(Diagnostic(Span("b.silver", 0, 0), "boom")) == "b.silver: boom");
}
