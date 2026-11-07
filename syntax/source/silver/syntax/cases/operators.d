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
    rejects("a = b == c == d"),
    rejects("a = b != c == d"),
    parsesAs("a = (b == c) == d", "(assign a (Equal (Equal b c) d))"),

    parsesAs("a = b ?? 0", "(assign a (Coalesce b 0))"),

    parsesAs("a = b ~ c", "(assign a (Concat b c))"),
    parsesAs("a = b ~ ~c", "(assign a (Concat b (BitNot c)))"),
    parsesAs("a = ~b ~ c", "(assign a (Concat (BitNot b) c))"),
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

    // Concatenation is additive and left-associative
    parsesAs("val x = a ~ b ~ c", "(val x (Concat (Concat a b) c))"),
    parsesAs("val x = a + b ~ c - d", "(val x (Subtract (Concat (Add a b) c) d))"),
    parsesAs("val x = a * b ~ c", "(val x (Concat (Multiply a b) c))"),
    parsesAs("val x = a ~ b << c", "(val x (ShiftLeft (Concat a b) c))"),
    parsesAs("val x = a ~ b < c ~ d", "(val x (Less (Concat a b) (Concat c d)))"),

    // Bit operators bind tighter than comparison, from loose to tight: | ^ & shifts
    parsesAs("val x = a & b == c", "(val x (Equal (BitAnd a b) c))"),
    parsesAs("val x = a | b < c", "(val x (Less (BitOr a b) c))"),
    parsesAs("val x = a | b ^ c & d << e", "(val x (BitOr a (BitXor b (BitAnd c (ShiftLeft d e)))))"),
    parsesAs("val x = a + b << c * d", "(val x (ShiftLeft (Add a b) (Multiply c d)))"),
    parsesAs("val x = a >> b + c", "(val x (ShiftRight a (Add b c)))"),
    parsesAs("val x = a ?? b | c", "(val x (Coalesce a (BitOr b c)))"),

    // Wrapping operators bind like what they wrap
    parsesAs("val x = a &+ b &* c", "(val x (WrappingAdd a (WrappingMultiply b c)))"),
    parsesAs("val x = a &* b + c", "(val x (Add (WrappingMultiply a b) c))"),
    parsesAs("val x = a &- b", "(val x (WrappingSubtract a b))"),

    // Spacing tells these apart: `& -b` is a bitwise and of a negation
    parsesAs("val x = a & -b", "(val x (BitAnd a (Minus b)))"),
    parsesAs("val x = a && b", "(val x (And a b))"),
    parsesAs("val x = a || b", "(val x (Or a b))"),

    parsesAs("val x = ~a & b", "(val x (BitAnd (BitNot a) b))"),
    parsesAs("val x = -a ^ b", "(val x (BitXor (Minus a) b))"),

];

immutable Case[] associativity = [
    parsesAs("val x = 1+2+3", "(val x (Add (Add 1 2) 3))"),
    parsesAs("val x = 1 - 2 - 3\nval y = a == b", ["(val x (Subtract (Subtract 1 2) 3))", "(val y (Equal a b))"]),
    parsesAs("a = b ?? c ?? 0", "(assign a (Coalesce b (Coalesce c 0)))"), // right
    parsesAs("val x = a ^ b ^ c", "(val x (BitXor (BitXor a b) c))"),
    parsesAs("val x = a << b >> c", "(val x (ShiftRight (ShiftLeft a b) c))"),
];
