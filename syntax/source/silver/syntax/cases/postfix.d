module silver.syntax.cases.postfix;

version (unittest):

import silver.syntax.cases.core;

/// Calls and member access, which fold left.
immutable Case[] postfix = [
    parsesAs("f()", "(call f)"),
    parsesAs("val x = a(b)", "(val x (call a b))"),
    parsesAs("a(b,c)", "(call a b c)"),
    parsesAs("a(b())", "(call a (call b))"),
    parsesAs("a(b(),c())", "(call a (call b) (call c))"),
    parsesAs("f()()", "(call (call f))"),
    parsesAs("a=b()", "(assign a Assign (call b))"),
    parsesAs("a.b.c", "(. (. a b) c)"),
    parsesAs("val r = read()", "(val r (call read))"),
    parsesAs("f(1, x)()\nval y = m.x.f(2) + 1", [
        "(call (call f 1 x))",
        "(val y (Add (call (. (. m x) f) 2) 1))",
    ]),
];

/// Grammar only: IndexArgs isn't lowered yet.
immutable Case[] indexing = [
    accepts("a = xs[0]"),
    accepts("a = xs[i + 1][j]"),
    accepts("a = m[k] ?? 0"),
    accepts("xs[0] = 1"),
    accepts("a = [1, 2][0]"),
];

/// Grammar only: SafeMemberAccess and PropagateNone aren't lowered yet.
immutable Case[] optionalChaining = [
    accepts("a = b?.c"),
    accepts("a = b?.c?.d ?? 0"),
    accepts("a = b?.c()"),
    accepts("a = b?"),
    accepts("a = b?.c? + 1"),
    accepts("a = f()? ?? 0"),
];
