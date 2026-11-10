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

immutable Case[] natives = [
    declaresAs("native def sqrt(x: Float): Float", "(native def sqrt (x: Float): Float)"),
    declaresAs(`native("atan2") def angle(y: Float, x: Float): Float`, `(native("atan2") def angle (y: Float, x: Float): Float)`),
    declaresAs(`native ( "SDL_Init" ) def init(flags: UInt32): Int32`, `(native("SDL_Init") def init (flags: UInt32): Int32)`),
    declaresAs(`native("f") def f(): Int`, "(native def f (): Int)"),
    declaresAs("native\n(\"f\") def g(): Int", `(native("f") def g (): Int)`),
    rejectsDeclaration(`native("f")` ~ "\ndef g(): Int"), // `)` can end a statement
    rejectsDeclaration(`native(f) def g(): Int`),
    rejectsDeclaration(`native("f") def g(): Int => 1`),
    declaresAs(`private native("f") def g(): Int`, `(private (native("f") def g (): Int))`),

    declaresAs("intrinsic def panic(message: String): Never", "(intrinsic def panic (message: String): Never)"),
    declaresAs("intrinsic\ndef\nlength(values: Any): Int", "(intrinsic def length (values: Any): Int)"),
    declaresAs("private intrinsic def f(): Int", "(private (intrinsic def f (): Int))"),
    rejectsDeclaration("intrinsic def f(): Int => 1"),
    rejectsDeclaration(`intrinsic("f") def f(): Int`),
    rejects("val intrinsic = 1"),
    parsesAs("val library = 1", "(val library 1)"),

    declaresAs("intrinsic alias CLong", "(intrinsic alias CLong)"),
    declaresAs("intrinsic\nalias\nCLong", "(intrinsic alias CLong)"),
    declaresAs("private intrinsic alias CLong", "(private (intrinsic alias CLong))"),
    rejectsDeclaration("intrinsic alias CLong = Int"),
    rejectsDeclaration("intrinsic alias cLong"),

    declaresAs(`native library "SDL2"`, `(native library "SDL2")`),
    declaresAs("module sdl.video\nnative library \"SDL2\"\nnative(\"SDL_Init\") def init(flags: UInt32): Int32", [
        "(module sdl.video)",
        `(native library "SDL2")`,
        `(native("SDL_Init") def init (flags: UInt32): Int32)`,
    ]),
    declaresAs("native\nlibrary\n\"m\"", `(native library "m")`),
    rejectsDeclaration("native library SDL2"),
    rejectsDeclaration(`private native library "SDL2"`),
];
