module silver.syntax.cases.statements;

version (unittest):

import silver.syntax.cases.core;

immutable Case[] assignments = [
    parsesAs("a=b", "(assign a b)"),

    // Compound assignment is lowered to plain assignment.
    parsesAs("a += 3", "(assign a (Add a 3))"),
    parsesAs("a -= 3", "(assign a (Subtract a 3))"),
    parsesAs("a *= 3", "(assign a (Multiply a 3))"),
    parsesAs("a /= 3", "(assign a (Divide a 3))"),
    parsesAs("a ^= 3", "(assign a (BitXor a 3))"),
    parsesAs("a &= 3", "(assign a (BitAnd a 3))"),
    parsesAs("a |= 3", "(assign a (BitOr a 3))"),
    parsesAs("a <<= 3", "(assign a (ShiftLeft a 3))"),
    parsesAs("a >>= 3", "(assign a (ShiftRight a 3))"),
    parsesAs("a &+= 3", "(assign a (WrappingAdd a 3))"),
    parsesAs("a &-= 3", "(assign a (WrappingSubtract a 3))"),
    parsesAs("a &*= 3", "(assign a (WrappingMultiply a 3))"),
    parsesAs("a.b += 3", "(assign (. a b) (Add (. a b) 3))"),
    parsesAs("a *= b + 1", "(assign a (Multiply a (Add b 1)))"),

    // Names that start with, or look like, keywords
    parsesAs("variable = 1", "(assign variable 1)"),
    parsesAs("x = reader", "(assign x reader)"),
    parsesAs("natives = 1", "(assign natives 1)"),
];

immutable Case[] declarations = [
    parsesAs("val a = 1", "(val a 1)"),
    parsesAs("val a: Int = 1", "(val a: Int 1)"),
    parsesAs("val x = 1\nval y = x\nval value = 2", ["(val x 1)", "(val y x)", "(val value 2)"]),
    rejects("val a"),
    rejects("val a: Int"),
    rejects("val while = 1"), // keywords aren't names

    parsesAs("mutable val a = 1", "(mutable val a 1)"),
    parsesAs("mutable val a: Int = 1", "(mutable val a: Int 1)"),
    rejects("mutable val a"),
    rejects("mutable a = 1"),

    // Values are lowercase, types are capitalized
    parsesAs("val point: Point = origin", "(val point: Point origin)"),
    parsesAs("val _unused = 1", "(val _unused 1)"),
    rejects("val Point = 1"),
    rejects("val a: point = 1"),
];

/// Grammar only: a declaration without an initializer isn't lowered yet.
immutable Case[] uninitializedDeclarations = [
    accepts("mutable val a: Int?"), // defaults to None
];

/// Types print as they're written, with parentheses only where they change the meaning.
immutable Case[] typeAnnotations = [
    parsesAs("val a: Int? = 1", "(val a: Int? 1)"),
    parsesAs("val a: (Int?)? = 1", "(val a: (Int?)? 1)"),
    parsesAs("val a: (Int)? = 1", "(val a: Int? 1)"),
    parsesAs("val a: math.Vector = v", "(val a: math.Vector v)"),
    parsesAs("val a: List<Int> = xs", "(val a: List<Int> xs)"),
    parsesAs("val a: math.Grid<Int> = g", "(val a: math.Grid<Int> g)"),
    parsesAs("val a: Map<String, List<Int?>> = m", "(val a: Map<String, List<Int?>> m)"),
    parsesAs("val a: () = ()", "(val a: () ())"),
    parsesAs("val a: () -> Int = f", "(val a: () -> Int f)"),
    parsesAs("val a: (Int, Int) -> Int = f", "(val a: (Int, Int) -> Int f)"),
    parsesAs("val a: (Int) -> (Int) -> Int = f", "(val a: (Int) -> (Int) -> Int f)"),
    parsesAs("val a: ((Int) -> Int)? = f", "(val a: ((Int) -> Int)? f)"),
    parsesAs("val a: (Int) -> Int? = f", "(val a: (Int) -> Int? f)"),
    parsesAs("val a: ((Int) -> Int) -> Int = f", "(val a: ((Int) -> Int) -> Int f)"),
    rejects("val a: List<> = xs"),
];

immutable Case[] moduleDeclarations = [
    declaresAs("module app", "(module app)"),
    declaresAs("module std.math\n", "(module std.math)"),
    declaresAs("module a.b\nimport c\ndef f(): Int => 1", ["(module a.b)", "(import c)", "(def f (): Int 1)"]),
    declaresAs("// Header\n\nmodule a.b; import c", ["(module a.b)", "(import c)"]),
    rejectsDeclaration("module"),
    rejectsDeclaration("module App"),
    rejectsDeclaration("module a.b import c"),
    rejectsDeclaration("import c\nmodule a.b"),
    rejectsDeclaration("module a\nmodule b"),
    rejects("module a"),
    rejects("val module = 1"),
];

immutable Case[] imports = [
    declaresAs("import module", "(import module)"),
    declaresAs("import io\nimport a.b.c", ["(import io)", "(import a.b.c)"]),
];
