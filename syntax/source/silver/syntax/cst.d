module silver.syntax.cst;

import pegged.grammar : ParseTree;
import pegged.peg : Position;
import silver.ast : Diagnostic, Span;
import silver.syntax.grammar : Silver;
import silver.syntax.parse : ParseException;

/// Parses Silver source code into a parse tree.
/// `sourceName` identifies the source in the error's span (e.g. a module's file path).
/// Throws: ParseException if the source does not parse.
package ParseTree parseCst(string source, string sourceName = "<input>")
{
    auto tree = Silver(source);
    if(!tree.successful)
    {
        auto failure = deepestFailure(tree);
        throw new ParseException(Diagnostic(Span(sourceName, failure.end, failure.end),
                failure.failMsg((Position _, string left, string right, const ParseTree node)
                    => describeFailure(left, right, node))));
    }
    return tree;
}

/// Pegged's default message, minus its 0-based "line, col" prefix: the span gives the position.
private string describeFailure(string left, string right, const ParseTree failure) @safe pure
{
    import std.format : format;

    // %(%s%) on a one-element array writes the string quoted and escaped.
    auto quoted = (string text) => format("%(%s%)", [text]);
    return (left.length > 0 ? "after " ~ quoted(left) ~ " " : "")
        ~ "expected " ~ (failure.matches.length > 0 ? quoted(failure.matches[$ - 1]) : "NO MATCH")
        ~ ", but got " ~ quoted(right);
}

/// Follows the chain of failed nodes down to the deepest one.
package ParseTree deepestFailure(ParseTree tree)
{
    ParseTree terminal = tree;

    // A failed node's children can all have succeeded, when the failure was on
    // something that isn't kept as a child (e.g. a missing ')' literal), so stop
    // as soon as there is no failed child to descend into.
    bool descended = true;
    while(descended)
    {
        descended = false;
        foreach (child; terminal.children)
        {
            if(!child.successful)
            {
                terminal = child;
                descended = true;
                break;
            }
        }
    }

    return terminal;
}


version (unittest) import fluent.asserts;

version(unittest)
{
    /// Returns the ParseException thrown for `source`, or null if it parses.
    private ParseException parseError(string source, string sourceName = "<input>")
    {
        try
        {
            parseCst(source, sourceName);
        }
        catch(ParseException e)
        {
            return e;
        }
        return null;
    }
}

@("parse returns the tree for valid source")
unittest
{
    parseCst("val a = 1").successful.should.equal(true);
}

@("parse throws on invalid source")
unittest
{
    assert(parseError("val = 1") !is null);
}

@("parse error names the source")
unittest
{
    auto error = parseError("val = 1", "math.silver");
    assert(error !is null);
    error.diagnostic.span.file.should.equal("math.silver");
}

@("parse error on a failure that isn't a child node terminates")
unittest
{
    assert(parseError("def f(a") !is null);
}