module silver.syntax.cases.layout;

version (unittest):

import silver.syntax.cases.core;

/// Statement separators, blank lines and whitespace.
immutable Case[] layout = [
    parsesAs("print(a)", "(call print a)"),
    parsesAs("mutable val a = 0\n    print(a)", ["(mutable val a 0)", "(call print a)"]),
    rejects("mutable val a = 0 print(a)"), // two statements need a separator
    parsesAs("mutable val a = 1; print(a)", ["(mutable val a 1)", "(call print a)"]),
    parsesAs("if true { a = 1; print(a) }", "(if true (block (assign a Assign 1) => (call print a)))"),

    parsesAs("mutable val a = 1\n\n", "(mutable val a 1)"),
    parsesAs("\nmutable val a = 1", "(mutable val a 1)"),
    parsesAs("mutable val a = 1\n\nprint(a)", ["(mutable val a 1)", "(call print a)"]),
    parsesAs("mutable val a = 1\n\n\nprint(a)", ["(mutable val a 1)", "(call print a)"]),

    // Escaped so editors don't strip the trailing spaces
    parsesAs("if true {  \n    print(1)\n}", "(if true (block => (call print 1)))"),
    parsesAs("if true {\n    print(1)\n} else {  \n    print(2)\n}",
        "(if true (block => (call print 1)) (block => (call print 2)))"),
];

immutable Case[] comments = [
    parsesAs("// leading comment\na = 1", "(assign a Assign 1)"),
    parsesAs("a = 1 // trailing comment\nb = 2", ["(assign a Assign 1)", "(assign b Assign 2)"]),
    parsesAs("a = 1\n// between statements\nb = 2", ["(assign a Assign 1)", "(assign b Assign 2)"]),
    parsesAs("a = 1 // comment at end of input", "(assign a Assign 1)"),
    parsesAs("// only a comment", noStatements),
    parsesAs("a = 4 / 2 // division is not a comment", "(assign a Assign (Divide 4 2))"),

    parsesAs("a = /* inline */ 1", "(assign a Assign 1)"),
    parsesAs("/* leading */ a = 1", "(assign a Assign 1)"),
    parsesAs("a = 1\n/* spans\n   lines */\nb = 2", ["(assign a Assign 1)", "(assign b Assign 2)"]),
    parsesAs("/* only a comment */", noStatements),
    parsesAs("a = 1 /* outer /* inner */ still outer */", "(assign a Assign 1)"),
    rejects("a = 1 /* outer /* inner */"),
    rejects("a = 1 /*\n*/ b = 2"), // newlines inside a block comment aren't separators
];
