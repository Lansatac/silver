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
    parsesAs("a=b()", "(assign a (call b))"),
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

immutable Case[] optionalChaining = [
    parsesAs("a = b?.c", "(assign a (?. b c))"),
    parsesAs("a = b?.c?.d ?? 0", "(assign a (Coalesce (?. (?. b c) d) 0))"),
    parsesAs("a = b?.c()", "(assign a (call (?. b c)))"),
    parsesAs("a = b?", "(assign a (? b))"),
    parsesAs("a = b?.c? + 1", "(assign a (Add (? (?. b c)) 1))"),
    parsesAs("a = f()? ?? 0", "(assign a (Coalesce (? (call f)) 0))"),
];
