module silver.syntax.cases.postfix;

version (unittest):

import silver.syntax.cases.core;

/// Calls and member access, which fold left.
immutable Case[] postfix = [
    parsesAs("f(mutable x)", "(call f mutable x)"),
    parsesAs("f(a, mutable b.c, d)", "(call f a mutable (. b c) d)"),
    parsesAs("f(mutable\n    x)", "(call f mutable x)"),
    parsesAs("p with (x = 1)", "(with p (x 1))"),
    parsesAs("p with (x = 1, a.b = 2)", "(with p (x 1) (a.b 2))"),
    parsesAs("p with (x = 1) with (y = 2)", "(with (with p (x 1)) (y 2))"),
    parsesAs("f() with (x = 1).x", "(. (with (call f) (x 1)) x)"),
    parsesAs("p\n    with (x = 1)", "(with p (x 1))"),
    parsesAs("p with\n    (x = 1)", "(with p (x 1))"),
    parsesAs("p with (\n    x = 1,\n    y = 2\n)", "(with p (x 1) (y 2))"),
    parsesAs("val a = 1 + p with (x = 1)", "(val a (Add 1 (with p (x 1))))"),
    rejects("p with ()"),
    rejects("p with (x == 1)"),
    rejects("val with = 1"),
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
    parsesAs("a = xs[0]", "(assign a (index xs 0))"),
    parsesAs("a = xs[i + 1][j]", "(assign a (index (index xs (Add i 1)) j))"),
    parsesAs("a = m[k] ?? 0", "(assign a (Coalesce (index m k) 0))"),
    parsesAs("xs[0] = 1", "(assign (index xs 0) 1)"),
    parsesAs("a = [1, 2][0]", "(assign a (index (array 1 2) 0))"),
    parsesAs("a = xs[1..2]", "(assign a (index xs (.. 1 2)))"),
    parsesAs("a = xs[i + 1..n * 2]", "(assign a (index xs (.. (Add i 1) (Multiply n 2))))"),
    parsesAs("a = xs[b.c..d.e]", "(assign a (index xs (.. (. b c) (. d e))))"),
    parsesAs("a = xs[b?..c]", "(assign a (index xs (.. (? b) c)))"),
    parsesAs("a = xs[b ?? 0..c]", "(assign a (index xs (.. (Coalesce b 0) c)))"),
    parsesAs("a = xs[1.5..2]", "(assign a (index xs (.. 1.5 2)))"),
    parsesAs("a = xs[1..]", "(assign a (index xs (.. 1 _)))"),
    parsesAs("a = xs[..n]", "(assign a (index xs (.. _ n)))"),
    parsesAs("a = xs[i + 1..]", "(assign a (index xs (.. (Add i 1) _)))"),
    parsesAs("a = xs[..n - 1]", "(assign a (index xs (.. _ (Subtract n 1))))"),
    parsesAs("a = xs[b ?? 0..]", "(assign a (index xs (.. (Coalesce b 0) _)))"),
    parsesAs("a = xs[1..][..2]", "(assign a (index (index xs (.. 1 _)) (.. _ 2)))"),
    parsesAs("a = xs[\n    1..\n]", "(assign a (index xs (.. 1 _)))"),
    rejects("a = xs[..]"),
    rejects("a = xs[1.. ..2]"),
    rejects("a = 1.."),
    rejects("a = ..2"),
    rejects("for i in 0.. { }"),
    parsesAs("xs ~= [1]", "(assign xs (Append xs (array 1)))"),
    parsesAs("a.b ~= c", "(assign (. a b) (Append (. a b) c))"),
    parsesAs("a = b ~ c ~ d", "(assign a (Concat (Concat b c) d))"),
];

immutable Case[] optionalChaining = [
    parsesAs("a = b?.c", "(assign a (?. b c))"),
    parsesAs("a = b?.c?.d ?? 0", "(assign a (Coalesce (?. (?. b c) d) 0))"),
    parsesAs("a = b?.c()", "(assign a (call (?. b c)))"),
    parsesAs("a = b?", "(assign a (? b))"),
    parsesAs("a = b?.c? + 1", "(assign a (Add (? (?. b c)) 1))"),
    parsesAs("a = f()? ?? 0", "(assign a (Coalesce (? (call f)) 0))"),
];
