module silver.syntax.detached;

import pegged.peg : ParseTree;
static import pegged.peg;

/// Works around a bug in Pegged 0.4.9: when a sequence fails, `failedChildFixup` rewrites the
/// child that failed furthest, writing through children arrays shared with the memo table, so a
/// failed AssignmentStatement leaks its last PostfixOp attempt into the Postfix that
/// ExpressionStatement reuses when `..` or `??` follows. The generated grammar gets every
/// sequence's children through `detached`, which copies the arrays the fixup can reach first
/// (see `syntax/tools/generate_grammar.d`). This can go once Pegged no longer writes through them.
package template detachedAnd(rules...)
{
    import std.meta : staticMap;

    alias detachedAnd = pegged.peg.and!(staticMap!(detached, rules));
}

/// The fixup only rewrites a child whose failed attempt went past its match, and inside it only
/// the nodes that failed that far.
private template detached(alias rule)
{
    ParseTree detached(ParseTree p)
    {
        auto tree = rule(p);
        return tree.failEnd > tree.end ? detach(tree, tree.failEnd) : tree;
    }
}

private ParseTree detach(ParseTree tree, size_t failEnd) @safe pure nothrow
{
    tree.children = tree.children.dup;
    foreach (ref child; tree.children)
    {
        if (child.failEnd == failEnd) child = detach(child, failEnd);
    }
    return tree;
}
