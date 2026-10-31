module silver.syntax_cases.functions;

version (unittest):

import silver.syntax_cases.core;

immutable Case[] functions = [
    parsesAs("def a() : Int => 1", "(def a () : Int 1)"),
    parsesAs("def a() : Int { 1 }", "(def a () : Int (block => 1))"),
    parsesAs("def a(a : Int, b : Int) : Int => 1", "(def a (a b) : Int 1)"),
    parsesAs("def a() : Int =>\n    1", "(def a () : Int 1)"),
    parsesAs("def a() : Int => {\n    1\n}", "(def a () : Int (block => 1))"),
    parsesAs("def h(p : Int, q:Int) : Int {\nval z = p\nz + q\n}\ndef k() : Int =>\n    1", [
        "(def h (p q) : Int (block (val z p) => (Add z q)))",
        "(def k () : Int 1)",
    ]),
    rejects("def a() => 1"), // the return type is required

    parsesAs("native def print(value : Any) : Unit", "(native def print (value) : Unit)"),
    parsesAs("native def now() : Int", "(native def now () : Int)"),
    rejects("native def f() : Int => 1"), // natives have no body
    rejects("native val a = 1"),

    parsesAs("def a() : Int {\n    return 1\n}", "(def a () : Int (block (return 1)))"),
    parsesAs("def a() : Unit {\n    return\n}", "(def a () : Unit (block (return ())))"),
    parsesAs("def a() : Int {\n    if b { return 1 }\n    2\n}", "(def a () : Int (block (if b (block (return 1))) => 2))"),
];
