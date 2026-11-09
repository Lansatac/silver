module silver.syntax.cases.functions;

version (unittest):

import silver.syntax.cases.core;

immutable Case[] functions = [
    declaresAs("def a() : Int => 1", "(def a (): Int 1)"),
    declaresAs("def a() : Int { 1 }", "(def a (): Int (block => 1))"),
    declaresAs("def a(a : Int, b : Int) : Int => 1", "(def a (a: Int, b: Int): Int 1)"),
    declaresAs("def a() : Int =>\n    1", "(def a (): Int 1)"),
    declaresAs("def a() : Int => {\n    1\n}", "(def a (): Int (block => 1))"),
    declaresAs("def h(p : Int, q:Int) : Int {\nval z = p\nz + q\n}\ndef k() : Int =>\n    1", [
        "(def h (p: Int, q: Int): Int (block (val z p) => (Add z q)))",
        "(def k (): Int 1)",
    ]),
    rejectsDeclaration("def a() => 1"), // the return type is required
    declaresAs("def a(mutable x: Int): Int => x", "(def a (mutable x: Int): Int x)"),
    declaresAs("def a(y: Int, mutable x: Int, mutable z: Int): Unit { }", "(def a (y: Int, mutable x: Int, mutable z: Int): Unit (block))"),
    declaresAs("def a(mutable\n    x: Int): Int => x", "(def a (mutable x: Int): Int x)"),
    rejectsDeclaration("def a(x: mutable Int): Int => x"),

    declaresAs("native def print(value : Any) : Unit", "(native def print (value: Any): Unit)"),
    declaresAs("native def now() : Int", "(native def now (): Int)"),
    rejectsDeclaration("native def f() : Int => 1"), // natives have no body
    rejectsDeclaration("native val a = 1"),

    declaresAs("def a() : Int {\n    return 1\n}", "(def a (): Int (block (return 1)))"),
    declaresAs("def a() : Unit {\n    return\n}", "(def a (): Unit (block (return ())))"),
    declaresAs("def a() : Int {\n    if b { return 1 }\n    2\n}", "(def a (): Int (block (if b (block (return 1))) => 2))"),

    // Lambdas, in every spelling.
    parsesAs("val f = x => x", "(val f (lambda (x) x))"),
    parsesAs("val f = () => 1", "(val f (lambda () 1))"),
    parsesAs("val f = (x) => x", "(val f (lambda (x) x))"),
    parsesAs("val f = (x: Int, y): Int => x", "(val f (lambda (x y) x))"),
    parsesAs("val f = (mutable x) => 1", "(val f (lambda (x) 1))"),
    parsesAs("val f = x => y => x", "(val f (lambda (x) (lambda (y) x)))"),
    parsesAs("f(x => x, 1)", "(call f (lambda (x) x) 1)"),
    parsesAs("val f = (x) => x + 1", "(val f (lambda (x) (Add x 1)))"),
    parsesAs("val f = ((x)) + 1", "(val f (Add x 1))"),
    parsesAs("val f = (x => x)(1)", "(val f (call (lambda (x) x) 1))"),
    rejects("val f = x: Int => x"), // parentheses are needed for a type

    // Neither of these newlines can end a statement.
    parsesAs("val f = x =>\n    x", "(val f (lambda (x) x))"),
    parsesAs("val f = (x)\n    => x", "(val f (lambda (x) x))"),

    // A condition is below lambda level, so an arrow after it belongs to the `if`.
    parsesAs("if a => 1 else 2", "(if a 1 2)"),
    parsesAs("if (a) => 1 else 2", "(if a 1 2)"),
    parsesAs("if val b = a => 1 else 2", "(if (val b a) 1 2)"),
];
