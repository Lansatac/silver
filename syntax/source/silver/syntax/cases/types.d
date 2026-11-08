module silver.syntax.cases.types;

version (unittest):

import silver.syntax.cases.core;

immutable Case[] typeDeclarations = [
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
