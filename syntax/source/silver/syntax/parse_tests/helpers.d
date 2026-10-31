module silver.syntax.parse_tests.helpers;

version (unittest):

import fluent.asserts;
import silver.ast : printStmt;
import silver.syntax.parse : parse, ParseException;
import silver.syntax.cases.core;

/// Adds one unittest per case in `tables`, checking what `parse` produces.
/// Tests are named `table: source`.
mixin template AstCases(tables...)
{
    import silver.syntax.parse_tests.helpers : checkAst;
    import silver.syntax.cases.core : caseName;

    static foreach (table; tables)
    {
        static foreach (c; table)
        {
            @(caseName(__traits(identifier, table), c))
            unittest
            {
                checkAst(c);
            }
        }
    }
}

/// Failures are reported at the case's line in its table.
void checkAst(Case c)
{
    import std.algorithm : map;
    import std.array : array;

    final switch (c.outcome)
    {
    case Outcome.parsesAs:
        should(parseStatements(c).map!(printStmt).array, c.file, c.line).equal(c.ast);
        break;
    case Outcome.accepts:
        parseStatements(c);
        break;
    case Outcome.rejects:
        try
        {
            parse(c.source, "test", "test");
        }
        catch (ParseException)
        {
            return;
        }
        throw new Exception("expected a parse error", c.file, c.line);
    }
}

/// Rethrows any parse failure from the case's line, naming the stage.
private auto parseStatements(Case c)
{
    try
    {
        return parse(c.source, "test", "test").statements;
    }
    catch (ParseException e)
    {
        throw new Exception("grammar rejected it: " ~ e.msg, c.file, c.line);
    }
    catch (Exception e)
    {
        throw new Exception("lowering failed: " ~ e.msg, c.file, c.line);
    }
}
