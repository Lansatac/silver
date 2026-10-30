module silver.parseCst;

import pegged.grammar : ParseTree;
import silver.grammar : Silver;
import silver.parse : ParseException;

/// Parses Silver source code into a parse tree.
/// `sourceName` identifies the source in error messages (e.g. a module's file path).
/// Throws: ParseException if the source does not parse.
package ParseTree parseCst(string source, string sourceName = "<input>")
{
    auto tree = Silver(source);
    if(!tree.successful)
    {
        throw new ParseException(sourceName ~ ": " ~ errorMessage(tree));
    }
    return tree;
}

/// Follows the chain of failed nodes down to the deepest one and returns its failure message.
package string errorMessage(ParseTree tree)
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

    return terminal.failMsg;
}


version (unittest) import fluent.asserts;

version(unittest)
{
    /// Returns the ParseException message for `source`, or null if it parses.
    private string parseError(string source, string sourceName = "<input>")
    {
        try
        {
            parseCst(source, sourceName);
        }
        catch(ParseException e)
        {
            return e.msg;
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
    parseError("val = 1").should.not.equal(null);
}

@("parse error names the source")
unittest
{
    parseError("val = 1", "math.silver").should.startWith("math.silver: ");
}

@("parse error on a failure that isn't a child node terminates")
unittest
{
    parseError("def f(a").should.not.equal(null);
}