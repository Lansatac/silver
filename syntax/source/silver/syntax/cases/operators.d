module silver.syntax.cases.operators;

version (unittest):

import silver.syntax.cases.core;

immutable Case[] operators = [
    parsesAs("val x = 1+2", "(val x (Add 1 2))"),
    parsesAs("val x = true && true", "(val x (And true true))"),
    parsesAs("val x = (1)", "(val x 1)"),

    parsesAs("val x = -1\nval y = !a", ["(val x (Minus 1))", "(val y (Not a))"]),
    parsesAs("a = -b", "(assign a (Minus b))"),
    parsesAs("a = -(1 + 2)", "(assign a (Minus (Add 1 2)))"),

    parsesAs("a = b < c", "(assign a (Less b c))"),
    parsesAs("a = b <= c", "(assign a (LessEqual b c))"),
    parsesAs("a = b > c", "(assign a (Greater b c))"),
    parsesAs("a = b >= c", "(assign a (GreaterEqual b c))"),
    rejects("a = b < c < d"), // comparisons don't chain

    parsesAs("a = b ?? 0", "(assign a (Coalesce b 0))"),
];

immutable Case[] precedence = [
    parsesAs("val x = 1+2*3", "(val x (Add 1 (Multiply 2 3)))"),
    parsesAs("val x = 1 + 2 * 3 + 4", "(val x (Add (Add 1 (Multiply 2 3)) 4))"),
    parsesAs("val x = 1 + (2 * 3) + 4", "(val x (Add (Add 1 (Multiply 2 3)) 4))"),
    parsesAs("val x = (1 + 2) * 3", "(val x (Multiply (Add 1 2) 3))"),
    parsesAs("val x = (1 + y) * 2", "(val x (Multiply (Add 1 y) 2))"),

    parsesAs("val x = 1 + 2 == 1 + 2", "(val x (Equal (Add 1 2) (Add 1 2)))"),
    parsesAs("val x = a < b == c > d", "(val x (Equal (Less a b) (Greater c d)))"),
    parsesAs("a = b + 1 < c == true", "(assign a (Equal (Less (Add b 1) c) true))"),
    parsesAs("val x = a == b && c == d", "(val x (And (Equal a b) (Equal c d)))"),
    parsesAs("val x = a || b && c", "(val x (Or a (And b c)))"),

    // Coalesce sits between addition and comparison
    parsesAs("val x = a ?? b + 1 < c ?? d ?? e",
        "(val x (Less (Coalesce a (Add b 1)) (Coalesce c (Coalesce d e))))"),

    // Power binds tighter than multiply and unary
    parsesAs("val a = 2 * 3 ^ 2\nval c = -2 ^ 2\nval d = 2 ^ -1", [
        "(val a (Multiply 2 (Power 3 2)))",
        "(val c (Minus (Power 2 2)))",
        "(val d (Power 2 (Minus 1)))",
    ]),
];

immutable Case[] associativity = [
    parsesAs("val x = 1+2+3", "(val x (Add (Add 1 2) 3))"),
    parsesAs("val x = 1 - 2 - 3\nval y = a == b", ["(val x (Subtract (Subtract 1 2) 3))", "(val y (Equal a b))"]),
    parsesAs("a = b ?? c ?? 0", "(assign a (Coalesce b (Coalesce c 0)))"), // right
    parsesAs("val b = 2 ^ 3 ^ 2", "(val b (Power 2 (Power 3 2)))"), // right
];
