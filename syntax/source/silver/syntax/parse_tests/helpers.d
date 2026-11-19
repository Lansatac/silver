module silver.syntax.parse_tests.helpers;

version (unittest):

import fluent.asserts;
import silver.ast : BlockExpr, FunctionDecl, Module, NodeIds, printDecl, printExpr, printModuleDeclaration, printNativeLibrary,
    printStmt;
import silver.syntax.parse : parseWith, ParseException, ParserChoice;
import silver.syntax.cases.core;

/// Adds one unittest per case in `tables`, checking what each parser produces.
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

/// Failures are reported at the case's line in its table, naming the parser.
void checkAst(Case c)
{
    import std.traits : EnumMembers;

    static foreach (parser; EnumMembers!ParserChoice)
    {
        checkAst(c, parser);
    }
}

private void checkAst(Case c, ParserChoice parser)
{
    import std.conv : to;

    final switch (c.outcome)
    {
    case Outcome.parsesAs:
        should(printCase(parseCase(c, parser), c), c.file, c.line).equal(c.ast).because(parser.to!string);
        break;
    case Outcome.accepts:
        parseCase(c, parser);
        break;
    case Outcome.rejects:
        try
        {
            parseWith(parser, moduleSource(c), "test", new NodeIds, "test");
        }
        catch (ParseException)
        {
            return;
        }
        throw new Exception(parser.to!string ~ ": expected a parse error", c.file, c.line);
    }
}

/// Rethrows any parse failure from the case's line, naming the stage.
private Module parseCase(Case c, ParserChoice parser)
{
    import std.conv : to;

    try
    {
        return parseWith(parser, moduleSource(c), "test", new NodeIds, "test");
    }
    catch (ParseException e)
    {
        throw new Exception(parser.to!string ~ " rejected it: " ~ e.msg, c.file, c.line);
    }
    catch (Exception e)
    {
        throw new Exception(parser.to!string ~ " failed: " ~ e.msg, c.file, c.line, e);
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
        auto header = m.declaration is null ? [] : [printModuleDeclaration(*m.declaration)];
        if (m.library !is null) header ~= printNativeLibrary(*m.library);
        return header ~ m.declarations.map!printDecl.array;
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
