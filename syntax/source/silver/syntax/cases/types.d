module silver.syntax.cases.types;

version (unittest):

import silver.syntax.cases.core;

immutable Case[] typeDeclarations = [
    rejectsDeclaration("type Point(mutable x: Int)"),
    declaresAs("type Point(x: Int, y: Int)", "(type Point (x: Int, y: Int))"),
    declaresAs("type Wrapper(value: Int?, f: (Int) -> Int)", "(type Wrapper (value: Int?, f: (Int) -> Int))"),
    declaresAs("type Marker", "(type Marker)"),
    declaresAs("type Marker()", "(type Marker ())"), // sema rejects the empty parens
    declaresAs("type Point(x: Int)\ndef f(): Int => 1", ["(type Point (x: Int))", "(def f (): Int 1)"]),
    rejectsDeclaration("type point(x: Int)"),
    rejectsDeclaration("type Point(X: Int)"),
    rejectsDeclaration("type Point(x)"),
    rejectsDeclaration("type Point(x: Int,)"),
    rejects("type Point(x: Int)"), // only at module level for now
    rejects("val type = 1"),
];

/// Sema decides what an uppercase name means, so lowering treats it as a plain name.
immutable Case[] typeConstruction = [
    parsesAs("val p = Point(1, 2)", "(val p (call Point 1 2))"),
    parsesAs("val o = Origin", "(val o Origin)"),
    parsesAs("val l = Line(Point(1), Point(2))", "(val l (call Line (call Point 1) (call Point 2)))"),
    parsesAs("val p = geo.Point(1)", "(val p (call (. geo Point) 1))"),
    parsesAs("val o = geo.Origin", "(val o (. geo Origin))"),
    parsesAs("val v = Point(1, 2).x", "(val v (. (call Point 1 2) x))"),
    parsesAs("val v = line.start.x", "(val v (. (. line start) x))"),
    parsesAs("p.x = 1", "(assign (. p x) 1)"),
];

immutable Case[] tupleTypes = [
    parsesAs("val a: (mutable Int) -> Int = f", "(val a: (mutable Int) -> Int f)"),
    parsesAs("val a: (Int, mutable (Int, Int)?) -> Unit = f", "(val a: (Int, mutable (Int, Int)?) -> Unit f)"),
    rejects("val a: (mutable Int) = f"),
    parsesAs("val a: (Int, String) = b", "(val a: (Int, String) b)"),
    parsesAs("val a: ((Int, Int), Bool) = b", "(val a: ((Int, Int), Bool) b)"),
    parsesAs("val a: (Int, Int)? = b", "(val a: (Int, Int)? b)"),
    parsesAs("val a: (Int?, [Int]) = b", "(val a: (Int?, [Int]) b)"),
    parsesAs("val a: [(Int, Int)] = b", "(val a: [(Int, Int)] b)"),
    parsesAs("val a: (Int, Int) -> Int = f", "(val a: (Int, Int) -> Int f)"),
    parsesAs("val a: ((Int, Int)) -> Int = f", "(val a: ((Int, Int)) -> Int f)"),
    parsesAs("val a: () -> (Int, Int) = f", "(val a: () -> (Int, Int) f)"),
    parsesAs("val a: (Int,\n    Int) = b", "(val a: (Int, Int) b)"),
    parsesAs("val a: (Int) = b", "(val a: Int b)"),
    declaresAs("def f(p: (Int, Int)): (Int, Int) => p", "(def f (p: (Int, Int)): (Int, Int) p)"),
    declaresAs("type Pair(value: (Int, String))", "(type Pair (value: (Int, String)))"),
    rejects("val a: (Int,) = b"),
];

immutable Case[] sumDeclarations = [
    declaresAs("type Peg = Literal(text: String) | Sequence(parts: [Peg]) | Empty",
        ["(type Literal (text: String))", "(type Sequence (parts: [Peg]))", "(type Peg = Literal | Sequence | Empty)", "(type Empty)"]),
    declaresAs("type Color = Red | Green", ["(type Color = Red | Green)", "(type Red)", "(type Green)"]),
    declaresAs("type P2\ntype Point = P2 | geo.P3 | Int8 | [Int] | Int?", ["(type P2)", "(type Point = P2 | geo.P3 | Int8 | [Int] | Int?)"]),
    declaresAs("type Peg =\n    Literal(text: String)\n    | Empty\n    | Other",
        ["(type Literal (text: String))", "(type Peg = Literal | Empty | Other)", "(type Empty)", "(type Other)"]),
    declaresAs("type A = B |\n    C", ["(type A = B | C)", "(type B)", "(type C)"]),
    rejectsDeclaration("type A ="),
    rejectsDeclaration("type A = B |"),
    rejectsDeclaration("type A = b"),
    rejectsDeclaration("type A(x: Int) = B"),
];

immutable Case[] matches = [
    parsesAs("val r = match p {\n    Literal(text) => text\n    q: Point3D => q\n    Empty => 1\n    _ => 2\n}",
        "(val r (match p (Literal(text) text) (q: Point3D q) (Empty 1) (_ 2)))"),
    parsesAs("val r = match p { a => 1; b => 2 }", "(val r (match p (a 1) (b 2)))"),
    parsesAs("val r = match\n    p\n{\n\n    x =>\n        1\n\n}", "(val r (match p (x 1)))"),
    parsesAs("val r = match p { Some(x) => 1\n None => 2 }", "(val r (match p (Some(x) 1) (None 2)))"),
    parsesAs("val r = match p { (true, 1) => 1\n (\"a\", -1) => 2 }", `(val r (match p ((true, 1) 1) (("a", (Minus 1)) 2)))`),
    parsesAs("val r = match p { geo.Point(Inner(a), _) => { 1 } }", "(val r (match p (geo.Point(Inner(a), _) (block => 1))))"),
    parsesAs("val r = match f(x).y { a => a }", "(val r (match (. (call f x) y) (a a)))"),
    parsesAs("if val Literal(t) = p => t else 2", "(match p (Literal(t) t) (_ 2))"),
    parsesAs("if val None = p { 1 }", "(match p (None (block => 1)) (_ ()))"),
    parsesAs("if val x = p => x", "(if (val x p) x)"),
    rejects("val r = match p { a }"),
    rejects("val r = match p { a => }"),
    rejects("val r = match p { a + 1 => 2 }"),
    rejects("val match = 1"),
];
