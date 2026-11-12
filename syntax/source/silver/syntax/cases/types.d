module silver.syntax.cases.types;

version (unittest):

import silver.syntax.cases.core;

immutable Case[] typeDeclarations = [
    rejectsDeclaration("type Point(mutable x: Int)"),
    declaresAs("type Point(x: Int, y: Int)", "(type Point (x: Int, y: Int))"),
    declaresAs("type Wrapper(value: Int?, f: (Int) -> Int)", "(type Wrapper (value: Int?, f: (Int) -> Int))"),
    declaresAs("type Marker", "(type Marker)"),
    declaresAs("alias Meters = Float", "(alias Meters = Float)"),
    declaresAs("alias Grid = [[Int?]]", "(alias Grid = [[Int?]])"),
    declaresAs("alias F = (Int) -> geo.Point", "(alias F = (Int) -> geo.Point)"),
    declaresAs("alias\nA =\nB", "(alias A = B)"),
    declaresAs("private alias A = Int", "(private (alias A = Int))"),
    rejectsDeclaration("alias meters = Float"),
    rejectsDeclaration("alias A"),
    rejectsDeclaration("alias A == B"),
    rejects("alias A = Int"), // only at module level, like `type`
    declaresAs("type Marker()", "(type Marker ())"), // sema rejects the empty parens
    declaresAs("type Point(x: Int)\ndef f(): Int => 1", ["(type Point (x: Int))", "(def f (): Int 1)"]),
    rejectsDeclaration("type point(x: Int)"),
    rejectsDeclaration("type Point(X: Int)"),
    rejectsDeclaration("type Point(x)"),
    rejectsDeclaration("type Point(x: Int,)"),
    rejects("type Point(x: Int)"), // only at module level for now
    rejects("val type = 1"),
    declaresAs("type Key(privateKey: Int)", "(type Key (privateKey: Int))"),
    declaresAs("private type Detail(value: Int)", "(private (type Detail (value: Int)))"),
    declaresAs("private type S = A(x: Int) | B", ["(private (type A (x: Int)))", "(private (type S = A | B))", "(private (type B))"]),
    declaresAs("type Span(low: Int, high: Int) invariant low <= high", ["(type Span (low: Int, high: Int))", "(private (def invariant Span (low: Int, high: Int): Bool (LessEqual low high)))"]),
    declaresAs("type P(v: Int)\n    invariant\n    v > 0 &&\n    v < 9", ["(type P (v: Int))", "(private (def invariant P (v: Int): Bool (And (Greater v 0) (Less v 9))))"]),
    declaresAs("type P(v: Int) invariant ok(v)\ndef f(): Int => 1", ["(type P (v: Int))", "(private (def invariant P (v: Int): Bool (call ok v)))", "(def f (): Int 1)"]),
    declaresAs("type S = C(r: Float) invariant (r > 0.0) | N", ["(type C (r: Float))", "(private (def invariant C (r: Float): Bool (Greater r 0)))", "(type S = C | N)", "(type N)"]),
    declaresAs("type S =\n    C(r: Float)\n    invariant (\n        r > 0.0\n    )\n    | N", ["(type C (r: Float))", "(private (def invariant C (r: Float): Bool (Greater r 0)))", "(type S = C | N)", "(type N)"]),
    rejectsDeclaration("type S = C(r: Float) invariant r > 0.0 | N"),
    rejectsDeclaration("type M invariant true"),
    rejectsDeclaration("type S = A | B invariant true"),
    rejects("val invariant = 1"),
    declaresAs("private def f(): Int => 1", "(private (def f (): Int 1))"),
    declaresAs("private\ndef f(): Int => 1", "(private (def f (): Int 1))"),
    declaresAs("private native def f(): Int", "(private (native def f (): Int))"),
    declaresAs("private val limit: Int = 10", "(private (val limit: Int 10))"),
    rejectsDeclaration("private import a"),
    rejects("private val a = 1"),
    rejects("val private = 1"),
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

immutable Case[] generics = [
    declaresAs("def first<T>(values: [T]): T? => values[0]", "(def first<T> (values: [T]): T? (index values 0))"),
    declaresAs("def pair<A, B>(a: A, b: B): (A, B) => (a, b)", "(def pair<A, B> (a: A, b: B): (A, B) (tuple a b))"),
    declaresAs("intrinsic def length<T>(values: [T]): Int", "(intrinsic def length<T> (values: [T]): Int)"),
    declaresAs("type Box<T>(value: T)", "(type Box<T> (value: T))"),
    declaresAs("type Tag<T>", "(type Tag<T>)"),
    declaresAs("private type Box<T>(value: T)", "(private (type Box<T> (value: T)))"),
    declaresAs("type Result<T, E> = Ok(value: T) | Error(error: E)",
        ["(type Ok<T> (value: T))", "(type Error<E> (error: E))", "(type Result<T, E> = Ok<T> | Error<E>)"]),
    declaresAs("type List<T> = Cons(head: T, rest: List<T>) | Nil",
        ["(type Cons<T> (head: T, rest: List<T>))", "(type List<T> = Cons<T> | Nil)", "(type Nil)"]),
    declaresAs("type Pairs<A, B> = Both(b: B, a: [A?]) | Neither",
        ["(type Both<A, B> (b: B, a: [A?]))", "(type Pairs<A, B> = Both<A, B> | Neither)", "(type Neither)"]),
    // Sema reports a bare parameter as a member, which isn't a marker named `T`.
    declaresAs("type Maybe<T> = T | Nothing", ["(type Maybe<T> = T | Nothing)", "(type Nothing)"]),
    declaresAs("def f(b: Box<Pair<Int, [String]>>): Box<Int> => g(b)", "(def f (b: Box<Pair<Int, [String]>>): Box<Int> (call g b))"),
    rejectsDeclaration("def f<t>(x: t): Int => 1"),
    rejectsDeclaration("def f<>(): Int => 1"),
    rejectsDeclaration("def f<T,>(): Int => 1"),
    rejectsDeclaration("type Box<T: Eq>(value: T)"),
    rejectsDeclaration("native def f<T>(x: Int): Int"),
    rejectsDeclaration("alias Two<T> = (T, T)"),
    rejects("def f<T>(x: T): T => x"),

    parsesAs("val e = empty<Int>()", "(val e (call empty<Int>))"),
    parsesAs("val e = std.x.empty<Int>()", "(val e (call (. (. std x) empty<Int>)))"),
    parsesAs("val b = Box<UInt8>(1)", "(val b (call Box<UInt8> 1))"),
    parsesAs("val w = Box<Int>", "(val w Box<Int>)"),
    parsesAs("val p = convert<Box<Int>, [String?]>(x)", "(val p (call convert<Box<Int>, [String?]> x))"),
    parsesAs("val f = apply<(Int) -> Int, ()>(g)", "(val f (call apply<(Int) -> Int, ()> g))"),
    parsesAs("val m = xs.map<Int>(f)", "(val m (call (. xs map<Int>) f))"),
    parsesAs("val n = Box<Int>(1).value", "(val n (. (call Box<Int> 1) value))"),
    rejects("val x = f(1)<Int>"),
    rejects("val x = 1<Int>"),
    rejects("val x = f<Int><Int>()"),

    // Values and constants are lowercase, so a comparison against a type name is never well typed.
    parsesAs("val x = a < b", "(val x (Less a b))"),
    parsesAs("val x = a < B", "(val x (Less a B))"),
    parsesAs("val x = a < B(1)", "(val x (Less a (call B 1)))"),
    parsesAs("val x = a <= B", "(val x (LessEqual a B))"),
    parsesAs("val x = x < y && z > w", "(val x (And (Less x y) (Greater z w)))"),
    parsesAs("val x = a << B", "(val x (ShiftLeft a B))"),
    parsesAs("f(a < b, c > (d))", "(call f (Less a b) (Greater c d))"),
    parsesAs("f(a < B, C > (d))", "(call f (call a<B, C> d))"),
    rejects("val x = a < b > c"),
];
