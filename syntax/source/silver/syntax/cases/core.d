module silver.syntax.cases.core;

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

/// Where a case's source sits in a module. Modules hold only declarations, so
/// statement cases are wrapped in `def main(): Unit { ... }`.
enum Level
{
    statements,
    declarations,
}

struct Case
{
    string source;
    Outcome outcome;
    Level level;
    /// The expected statements of `main`'s body (for statements), or the
    /// module's declarations (for declarations), as printed by printStmt or printDecl.
    string[] ast;
    /// Where the case was written, so failures point at the table row.
    string file;
    size_t line;
}

/// For source that parses to no statements at all, e.g. just a comment.
enum string[] noStatements = [];

Case parsesAs(string source, string ast, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.parsesAs, Level.statements, [ast], file, line);
}

Case parsesAs(string source, string[] ast, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.parsesAs, Level.statements, ast, file, line);
}

Case declaresAs(string source, string ast, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.parsesAs, Level.declarations, [ast], file, line);
}

Case declaresAs(string source, string[] ast, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.parsesAs, Level.declarations, ast, file, line);
}

Case accepts(string source, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.accepts, Level.statements, null, file, line);
}

Case rejects(string source, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.rejects, Level.statements, null, file, line);
}

Case rejectsDeclaration(string source, string file = __FILE__, size_t line = __LINE__)
{
    return Case(source, Outcome.rejects, Level.declarations, null, file, line);
}

/// The whole module source a case parses as.
string moduleSource(Case c)
{
    final switch (c.level)
    {
    case Level.statements:
        return "def main(): Unit {\n" ~ c.source ~ "\n}";
    case Level.declarations:
        return c.source;
    }
}

/// The test name for one case: `table: source`, on one line.
string caseName(string table, Case c)
{
    import std.array : replace;

    return table ~ ": " ~ c.source.replace("\n", `\n`);
}
