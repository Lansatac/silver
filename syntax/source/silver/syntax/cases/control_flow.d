module silver.syntax.cases.control_flow;

version (unittest):

import silver.syntax.cases.core;

immutable Case[] ifs = [
    parsesAs("if true {\n    print(1)\n}", "(if true (block => (call print 1)))"),
    parsesAs("if true {\n    print(1)\n} else {\n    print(2)\n}",
        "(if true (block => (call print 1)) (block => (call print 2)))"),
    parsesAs("if true {\n    print(1)\n} else if true {\n    print(2)\n}",
        "(if true (block => (call print 1)) (if true (block => (call print 2))))"),
    parsesAs("if true {\n    print(1)\n} else if true {\n    print(2)\n} else {\n    print(3)\n}",
        "(if true (block => (call print 1)) (if true (block => (call print 2)) (block => (call print 3))))"),
    parsesAs("if a => 1 else if b => 2 else if c { val x = 3 } else { 4 }",
        "(if a 1 (if b 2 (if c (block (val x 3)) (block => 4))))"),
    parsesAs("if true { print(1) }", "(if true (block => (call print 1)))"),
    parsesAs("if true { print(1) } else { print(2) }", "(if true (block => (call print 1)) (block => (call print 2)))"),
    parsesAs("if true => f() else g()", "(if true (call f) (call g))"),
    parsesAs("if a {}\nif a => b", ["(if a (block))", "(if a b)"]),

    // As an expression
    parsesAs("a = if b => 1 else 2", "(assign a Assign (if b 1 2))"),
    parsesAs("a = if b => 1 else if c => 2 else 3", "(assign a Assign (if b 1 (if c 2 3)))"),
    parsesAs("a = if b { 1 } else { 2 }", "(assign a Assign (if b (block => 1) (block => 2)))"),
    parsesAs("a = if b => 1 else { 2 }", "(assign a Assign (if b 1 (block => 2)))"),
    parsesAs("a = if b { 1 } else 2", "(assign a Assign (if b (block => 1) 2))"),
    parsesAs("a = if b =>\n    1\nelse 2", "(assign a Assign (if b 1 2))"),
    parsesAs("\na =  if b {\n        val a = 1\n        a\n     }\n     else 2\n    ",
        "(assign a Assign (if b (block (val a 1) => a) 2))"),
    parsesAs("val a = if b => 1 else 2", "(val a (if b 1 2))"),

    // Statements can follow an if expression
    parsesAs("a = if b => 1 else 2\nc = 3", ["(assign a Assign (if b 1 2))", "(assign c Assign 3)"]),
    parsesAs("a = if b {\n    1\n} else {\n    2\n}\nc = 3",
        ["(assign a Assign (if b (block => 1) (block => 2)))", "(assign c Assign 3)"]),

    // If binds loosest: the else branch extends as far right as it can,
    // and an if is only an operand inside parentheses or as an argument
    parsesAs("val x = if a => 1 else 2 + 3", "(val x (if a 1 (Add 2 3)))"),
    parsesAs("x = (if a => 1 else 2) + 3", "(assign x Assign (Add (if a 1 2) 3))"),
    parsesAs("f(if a => 1 else 2)", "(call f (if a 1 2))"),
    rejects("x = 1 + if a => 2 else 3"),
    rejects("x = if a { 1 } else { 2 } + 3"), // a braced else branch ends at its brace

    // A dangling else binds to the nearest if
    parsesAs("if a => if b => 1 else 2", "(if a (if b 1 2))"),
];

immutable Case[] blocks = [
    // A block's value is its last statement only if that's an expression
    parsesAs("val a = {\n    val b = 1\n    b + 1\n}", "(val a (block (val b 1) => (Add b 1)))"),
    parsesAs("val a = { val x = 1\nx }\nval b = { x = 1 }\nval c = { f()\ng() }", [
        "(val a (block (val x 1) => x))",
        "(val b (block (assign x Assign 1)))",
        "(val c (block (call f) => (call g)))",
    ]),
    parsesAs("{\n    val scoped = 1\n}", "(block (val scoped 1))"),
    rejects("{ import io }"),

    parsesAs("if true {}", "(if true (block))"),
    parsesAs("if true { } else {\n    }", "(if true (block) (block))"),
    parsesAs("def f(): Unit {}", "(def f (): Unit (block))"),
    parsesAs("val a = {}", "(val a (block))"),
];

immutable Case[] loops = [
    parsesAs("while true { 1 }", "(while true (block => 1))"),
    parsesAs("while a() { b(); c() }", "(while (call a) (block (call b) => (call c)))"),
    parsesAs("while a() {\n        b()\n        c()\n    }", "(while (call a) (block (call b) => (call c)))"),
];
