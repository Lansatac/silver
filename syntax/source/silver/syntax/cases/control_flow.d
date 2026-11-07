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

    // Binding an option's payload
    parsesAs("if val x = a => x else 0", "(if (val x a) x 0)"),
    parsesAs("if val x = f() { x }", "(if (val x (call f)) (block => x))"),
    parsesAs("if val x = a { x } else if val y = b { y }",
        "(if (val x a) (block => x) (if (val y b) (block => y)))"),
    parsesAs("if val x = a ?? b => x", "(if (val x (Coalesce a b)) x)"),
    rejects("if val X = a => 1"),
    rejects("if mutable val x = a => 1"),

    // As an expression
    parsesAs("a = if b => 1 else 2", "(assign a (if b 1 2))"),
    parsesAs("a = if b => 1 else if c => 2 else 3", "(assign a (if b 1 (if c 2 3)))"),
    parsesAs("a = if b { 1 } else { 2 }", "(assign a (if b (block => 1) (block => 2)))"),
    parsesAs("a = if b => 1 else { 2 }", "(assign a (if b 1 (block => 2)))"),
    parsesAs("a = if b { 1 } else 2", "(assign a (if b (block => 1) 2))"),
    parsesAs("a = if b =>\n    1\nelse 2", "(assign a (if b 1 2))"),
    parsesAs("\na =  if b {\n        val a = 1\n        a\n     }\n     else 2\n    ",
        "(assign a (if b (block (val a 1) => a) 2))"),
    parsesAs("val a = if b => 1 else 2", "(val a (if b 1 2))"),

    // Statements can follow an if expression
    parsesAs("a = if b => 1 else 2\nc = 3", ["(assign a (if b 1 2))", "(assign c 3)"]),
    parsesAs("a = if b {\n    1\n} else {\n    2\n}\nc = 3",
        ["(assign a (if b (block => 1) (block => 2)))", "(assign c 3)"]),

    // If binds loosest: the else branch extends as far right as it can,
    // and an if is only an operand inside parentheses or as an argument
    parsesAs("val x = if a => 1 else 2 + 3", "(val x (if a 1 (Add 2 3)))"),
    parsesAs("x = (if a => 1 else 2) + 3", "(assign x (Add (if a 1 2) 3))"),
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
        "(val b (block (assign x 1)))",
        "(val c (block (call f) => (call g)))",
    ]),
    parsesAs("{\n    val scoped = 1\n}", "(block (val scoped 1))"),
    rejects("{ import io }"),

    parsesAs("if true {}", "(if true (block))"),
    parsesAs("if true { } else {\n    }", "(if true (block) (block))"),
    declaresAs("def f(): Unit {}", "(def f (): Unit (block))"),
    parsesAs("val a = {}", "(val a (block))"),
];

immutable Case[] loops = [
    parsesAs("while val x = f() { x }", "(while (val x (call f)) (block => x))"),
    parsesAs("while true { 1 }", "(while true (block => 1))"),
    parsesAs("while a() { b(); c() }", "(while (call a) (block (call b) => (call c)))"),
    parsesAs("while a() {\n        b()\n        c()\n    }", "(while (call a) (block (call b) => (call c)))"),

    parsesAs("for x in xs { x }", "(for x xs (block => x))"),
    parsesAs("for _ in xs { }", "(for _ xs (block))"),
    parsesAs("for i in 0..n { i }", "(for i (.. 0 n) (block => i))"),
    parsesAs("for i in (0..n) { i }", "(for i (.. 0 n) (block => i))"),
    parsesAs("for i in { 0..n } { i }", "(for i (block => (.. 0 n)) (block => i))"),
    parsesAs("val a = { 0..n }", "(val a (block => (.. 0 n)))"),
    parsesAs("val c = { a ?? b }", "(val c (block => (Coalesce a b)))"),
    parsesAs("a ?? b", "(Coalesce a b)"),
    parsesAs("val c = { a?..b }", "(val c (block => (.. (? a) b)))"),
    parsesAs("for x in [1, 2] { x }", "(for x (array 1 2) (block => x))"),
    parsesAs("for x in f(a)[1..2] { x }", "(for x (index (call f a) (.. 1 2)) (block => x))"),
    parsesAs("val a = for x in xs { }", "(val a (for x xs (block)))"),
    parsesAs("for x in xs { for y in x { y } }", "(for x xs (block => (for y x (block => y))))"),
    rejects("for x in xs => x"),
    rejects("for X in xs { }"),
    rejects("for x xs { }"),
    rejects("for mutable val x in xs { }"),

    parsesAs("while a { break }", "(while a (block (break)))"),
    parsesAs("while a { continue }", "(while a (block (continue)))"),
    parsesAs("for x in xs {\n    if x { break }\n    continue\n}",
        "(for x xs (block (if x (block (break))) (continue)))"),
    parsesAs("breaking = continued", "(assign breaking continued)"),
    rejects("break 1"),
    rejects("val for = 1"),
    rejects("val break = 1"),
    rejects("val continue = 1"),
];
