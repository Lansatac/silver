module silver.syntax.parse_tests.helpers;

version (unittest):

import fluent.asserts;
import silver.ast : BlockExpr, FunctionDecl, Module, NodeIds, printDecl, printExpr, printStmt;
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
    final switch (c.outcome)
    {
    case Outcome.parsesAs:
        should(printCase(parseCase(c), c), c.file, c.line).equal(c.ast);
        break;
    case Outcome.accepts:
        parseCase(c);
        break;
    case Outcome.rejects:
        try
        {
            parse(moduleSource(c), "test", new NodeIds, "test");
        }
        catch (ParseException)
        {
            return;
        }
        throw new Exception("expected a parse error", c.file, c.line);
    }
}

/// Rethrows any parse failure from the case's line, naming the stage.
private Module parseCase(Case c)
{
    try
    {
        return parse(moduleSource(c), "test", new NodeIds, "test");
    }
    catch (ParseException e)
    {
        throw new Exception("grammar rejected it: " ~ e.msg, c.file, c.line);
    }
    catch (Exception e)
    {
        throw new Exception("lowering failed: " ~ e.msg, c.file, c.line, e);
    }
}

/// Prints a parsed case as its table expects: the declarations, or the statements
/// of `main`'s body followed by its value (a block's last expression is its value).
private string[] printCase(Module m, Case c)
{
    import std.algorithm : map;
    import std.array : array;
    import std.sumtype : get;

    final switch (c.level)
    {
    case Level.declarations:
        return m.declarations.map!printDecl.array;
    case Level.statements:
        auto block = m.declarations[0].kind.get!FunctionDecl.body.kind.get!BlockExpr;
        auto printed = block.statements.map!printStmt.array;
        if (block.value !is null)
        {
            printed ~= printExpr(*block.value);
        }
        return printed;
    }
}
