module silver.syntax.cases.literals;

version (unittest):

import silver.syntax.cases.core;

immutable Case[] literals = [
    parsesAs("a = true", "(assign a true)"),
    parsesAs("a = 1.5", "(assign a 1.5)"),
    parsesAs("a = 1e5", "(assign a 100000)"),
    parsesAs("a = 1E-5", "(assign a 1e-05)"),
    parsesAs("a = ()", "(assign a ())"),
    parsesAs("f(())", "(call f ())"),
];

/// Grammar only: `lower` passes the `0x`/`0b` prefix to `to!long`.
immutable Case[] radixLiterals = [
    accepts("a = 0x1F"),
    accepts("a = 0xff"),
    accepts("a = 0b101"),
    accepts("a = 0b1010_0101"),
];

/// Grammar only: constructors (TypeName) aren't lowered yet.
immutable Case[] constructors = [
    accepts("a = None"),
    accepts("a = Some(1)"),
    accepts("a = Some(Some(1))"),
];

/// Grammar only: CollectionLiteral isn't lowered yet.
immutable Case[] collectionLiterals = [
    accepts("a = []"),
    accepts("a = [1]"),
    accepts("a = [1, 2, 3]"),
    accepts("a = [1, 2, 3,]"),
    accepts("a = [[1, 2], [3]]"),
    accepts("a = [f(1), b + c]"),
    rejects("a = [,]"),
    rejects("a = [1 2]"),

    accepts("a = [:]"),
    accepts("a = [1: 2]"),
    accepts("a = [1: 2, 3: 4]"),
    accepts("a = [1: 2, 3: 4,]"),
    accepts("a = [k: [1, 2], j: []]"),
    rejects("a = [1: 2, 3]"),
    rejects("a = [:,]"),
];
