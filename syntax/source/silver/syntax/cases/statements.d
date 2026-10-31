module silver.syntax.cases.statements;

version (unittest):

import silver.syntax.cases.core;

immutable Case[] assignments = [
    parsesAs("a=b", "(assign a Assign b)"),
    parsesAs("a.b += 3", "(assign (. a b) AddAssign 3)"),

    // Names that start with, or look like, keywords
    parsesAs("variable = 1", "(assign variable Assign 1)"),
    parsesAs("x = reader", "(assign x Assign reader)"),
    parsesAs("natives = 1", "(assign natives Assign 1)"),
];

immutable Case[] declarations = [
    parsesAs("val a = 1", "(val a 1)"),
    parsesAs("val a: Int = 1", "(val a 1)"),
    parsesAs("val x = 1\nval y = x\nval value = 2", ["(val x 1)", "(val y x)", "(val value 2)"]),
    rejects("val a"),
    rejects("val a: Int"),

    parsesAs("mutable val a = 1", "(mutable val a 1)"),
    parsesAs("mutable val a: Int = 1", "(mutable val a 1)"),
    rejects("mutable val a"),
    rejects("mutable a = 1"),

    // Values are lowercase, types are capitalized
    parsesAs("val point: Point = origin", "(val point origin)"),
    parsesAs("val _unused = 1", "(val _unused 1)"),
    rejects("val Point = 1"),
    rejects("val a: point = 1"),
];

/// Grammar only: a declaration without an initializer isn't lowered yet.
immutable Case[] uninitializedDeclarations = [
    accepts("mutable val a: Int?"), // defaults to None
];

/// The AST doesn't record types yet, so these only check the annotation parses.
immutable Case[] typeAnnotations = [
    parsesAs("val a: Int? = 1", "(val a 1)"),
    parsesAs("val a: Int?? = 1", "(val a 1)"),
    parsesAs("val a: math.Vector = v", "(val a v)"),
    parsesAs("val a: List<Int> = xs", "(val a xs)"),
    parsesAs("val a: Map<String, List<Int?>> = m", "(val a m)"),
    parsesAs("val a: () = ()", "(val a ())"),
    parsesAs("val a: () -> Int = f", "(val a f)"),
    parsesAs("val a: (Int, Int) -> Int = f", "(val a f)"),
    parsesAs("val a: (Int) -> (Int) -> Int = f", "(val a f)"),
    parsesAs("val a: ((Int) -> Int)? = f", "(val a f)"),
    rejects("val a: List<> = xs"),
];

immutable Case[] imports = [
    parsesAs("import module", "(import module)"),
    parsesAs("import io\nimport a.b.c", ["(import io)", "(import a.b.c)"]),
];
