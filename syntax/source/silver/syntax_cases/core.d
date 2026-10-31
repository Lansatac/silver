module silver.syntax_cases.core;

version (unittest):

enum Outcome
{
    /// The grammar accepts it, and it lowers to exactly `Case.ast`.
    parsesAs,
    /// The grammar accepts it, and it lowers without error.
    accepts,
    /// The grammar rejects it.
    rejects,
}

struct Case
{
    string source;
    Outcome outcome;
    /// The expected top-level statements, as printed by printStmt.
    string[] ast;
    /// Where the case was written, so failures point at the table row.
    string file;
    size_t line;
}

/// For source that parses to no statements at all, e.g. just a comment.
enum string[] noStatements = [];

Case parsesAs(string source, string ast, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.parsesAs, [ast], file, line);
}

Case parsesAs(string source, string[] ast, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.parsesAs, ast, file, line);
}

Case accepts(string source, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.accepts, null, file, line);
}

Case rejects(string source, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.rejects, null, file, line);
}

/// The test name for one case: `table: source`, on one line.
string caseName(string table, Case c)
{
    import std.array : replace;

    return table ~ ": " ~ c.source.replace("\n", `\n`);
}
