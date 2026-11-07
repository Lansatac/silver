module silver.syntax.parse;

import silver.ast : Module, NodeIds, Diagnostic, DiagnosticException;
import silver.syntax.lower : lower;
import silver.syntax.cst : parseCst;

/// Thrown when Silver source code fails to parse.
class ParseException : DiagnosticException
{
    this(Diagnostic diagnostic, string file = __FILE__, size_t line = __LINE__)
    {
        super(diagnostic, file, line);
    }
}

/// Parses Silver source into an AST, taking node IDs from `ids`.
/// Throws: ParseException if the source does not parse.
Module parse(string source, string moduleName, NodeIds ids, string file = "<input>")
{
    return lower(parseCst(source, file), moduleName, ids, file);
}

@("an empty string hole is a parse error that points at the hole and says how to write a brace")
unittest
{
    import std.algorithm : canFind;

    foreach (source; [`val a: String = "b{}"`, `val a: String = "b{ }"`])
    {
        try
        {
            parse(source, "test", new NodeIds);
            assert(false, source);
        }
        catch (ParseException e)
        {
            assert(e.diagnostic.span.start == 18, source);
            assert(e.diagnostic.message.canFind(`\{`), e.diagnostic.message);
        }
    }
}

@("parse gives every node its own ID")
unittest
{
    import std.format : format;
    import silver.ast : idProblems;

    auto source = `import math.extra
native def ask(prompt: String?): (Int, Bool) -> ()
def f(a: Int, b: List<Int?>): Int {
    mutable val x: Int = -a + 2 * 3 ^ 2
    x += 1
    a.b += f(x, 1)
    while x < 10 { x = x + 1 }
    val y = if x == 1 { return } else if true => 2.5 else ()
    x = a.c ?? 0
    { a.c }
    val s = "a{x}b{"c{y}"}"
}`;
    auto problems = idProblems(parse(source, "test", new NodeIds));
    assert(problems == [], format("%(%s
%)", problems));
}
