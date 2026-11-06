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

immutable Case[] stringLiterals = [
    parsesAs(`a = "hello"`, `(assign a "hello")`),
    parsesAs(`a = ""`, `(assign a "")`),
    parsesAs(`a = "  two  spaces  "`, `(assign a "  two  spaces  ")`),
    parsesAs(`a = "a\nb\tc\rd\0e"`, `(assign a "a\nb\tc\rd\0e")`),
    parsesAs(`a = "say \"hi\""`, `(assign a "say \"hi\"")`),
    parsesAs(`a = "back\\slash"`, `(assign a "back\\slash")`),
    parsesAs(`a = "// not a comment"`, `(assign a "// not a comment")`),
    parsesAs(`a = "/* nor this */"`, `(assign a "/* nor this */")`),
    parsesAs(`a = "{braces} and $dollars"`, `(assign a "{braces} and $dollars")`),
    parsesAs(`a = "héllo ☃"`, `(assign a "héllo ☃")`),
    parsesAs(`f("a", "b")`, `(call f "a" "b")`),
    parsesAs(`a = "x" == "y"`, `(assign a (Equal "x" "y"))`),
    rejects(`a = "unterminated`),
    rejects(`a = "unknown \q escape"`),
    rejects(`a = "\(reserved)"`),
    rejects("a = \"two\nlines\""),
];

immutable Case[] radixLiterals = [
    parsesAs("a = 0x1F", "(assign a 31)"),
    parsesAs("a = 0xff", "(assign a 255)"),
    parsesAs("a = 0b101", "(assign a 5)"),
    parsesAs("a = 0b1010_0101", "(assign a 165)"),
    parsesAs("a = 0xFFFFFFFFFFFFFFFF", "(assign a 18446744073709551615)"),
    parsesAs("a = 0x8000000000000000", "(assign a 9223372036854775808)"),
    parsesAs("a = 18446744073709551615", "(assign a 18446744073709551615)"),
];

/// Grammar only: `Some` and `None` don't have their own AST nodes yet.
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
