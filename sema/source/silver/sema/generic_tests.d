/// Tests of generic functions and types: their declarations, what's known inside them, and how a
/// use finds its type arguments.
module silver.sema.generic_tests;

version (unittest):

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType, shouldHaveType;
import silver.sema.resolution_tests;

private enum declarations = `
type Box<T>(value: T)
type Pair<A, B>(left: A, right: B)
type Result<T, E> = Good(value: T) | Bad(error: E)
type List<T> = Cons(head: T, rest: List<T>) | Nil
def identity<T>(x: T): T => x
def first<T>(values: [T]): T? => if length(values) == 0 => None else values[0]
def empty<T>(): [T] => []
def pair<T>(a: T, b: T): (T, T) => (a, b)
def larger<T>(a: T, b: T, less: (T, T) -> Bool): T => if less(a, b) => b else a
def apply<T, U>(value: T, f: (T) -> U): U => f(value)
def wrap<T>(value: T?): T? => value
def exchange<T>(mutable slot: T, value: T): T => value
def setTo<T>(value: T, mutable slot: T): Unit => ()
def pushed<T>(values: [T?], value: T): [T?] => values ~ [value]
`;

/// `body` in `main`, after the declarations above.
private Analyzed analyzedGeneric(string body, string more = "")
{
    return analyzed(declarations ~ more ~ "def main(): Unit {\n" ~ body ~ "\n}");
}

/// `source` at module level, with an empty `main`.
private Analyzed analyzedModule(string source)
{
    return analyzed(source ~ "\ndef main(): Unit => ()");
}

// Declarations

@("a type parameter is in scope in the whole declaration, nested lambdas and defs included")
unittest
{
    auto a = analyzedModule(`
def f<T>(x: T): T {
    val g = (y: T) => y
    def h(z: T): T => z
    h(g(x))
}
type Node<T>(value: T, next: Node<T>?)`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("x", 1), "T");
}

@("type parameters can't share a name, or take one a built-in or this module's type has")
unittest
{
    analyzedModule("def f<T, T>(x: T): T => x").shouldReport(DiagnosticCode.DuplicateDeclaration, At("T", 2));
    analyzedModule("def f<Int>(x: Int): Int => x").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Int", 1));
    analyzedModule("type Item(n: Int)\ntype Box<Item>(value: Item)").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Item", 2));
    analyzedModule("def f<None>(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("None", 1));
}

@("a type parameter hides an imported type of its name")
unittest
{
    enum lib = "module lib\ntype Item(n: Int)\n";
    analyzed("import lib\ndef f(x: Item): Int => x.n\ndef main(): Unit => ()", ["lib.ag": lib]).shouldHaveNoDiagnostics();
    analyzed("import lib\ndef f<Item>(x: Item): Int => x.n\ndef main(): Unit => ()", ["lib.ag": lib])
        .shouldReport(DiagnosticCode.UnknownMember, At("x", 2));
}

@("main can't be generic")
unittest
{
    analyzed("def main<T>(): Unit => ()").shouldReport(DiagnosticCode.MainInvalidDefinition, At("T", 1));
}

@("a private type can't be a type argument in a public signature")
unittest
{
    analyzedModule("type Box<T>(value: T)\nprivate type Secret\ndef f(b: Box<Secret>): Unit => ()")
        .shouldReport(DiagnosticCode.PrivateTypeExposed, At("Secret", 2));
}

@("a generic type needs all of its type arguments, a type that isn't generic takes none, and Any isn't one")
unittest
{
    enum box = "type Box<T>(value: T)\n";
    analyzedModule(box ~ "def f(b: Box): Unit => ()").shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("Box", 2));
    analyzedModule(box ~ "def f(b: Box<Int, Int>): Unit => ()").shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("Box", 2));
    analyzedModule("def f(b: Int<Int>): Unit => ()").shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("Int", 1));
    analyzedModule(box ~ "def f(b: Box<Any>): Unit => ()").shouldReport(DiagnosticCode.InvalidTypeArgument, At("Any", 1));
    analyzedModule(box ~ "def f(a: Box<Unit>, b: Box<Never>, c: Box<Box<[Int?]>>): Unit => ()").shouldHaveNoDiagnostics();
}

@("an instance is described with its type arguments, and two instances are different types")
unittest
{
    auto a = analyzedGeneric("    val qb = Box(1)\n    val r: Result<Int, String> = Good(1)\n    val l: List<Bool> = Nil");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("qb", 1), "Box<Int>");
    a.shouldDeclareType(At("r", 1), "Result<Int, String>");
    a.shouldDeclareType(At("l", 1), "List<Bool>");
    analyzedGeneric(`    val b: Box<Int> = Box("s")`).shouldReport(DiagnosticCode.TypeMismatch, At("Box", 3));
}

@("an inline member takes the parameters of its sum that it mentions")
unittest
{
    auto a = analyzedGeneric("    val o: Good<Int> = Good(1)\n    val e: Bad<String> = Bad(\"no\")\n    val n: Nil = Nil");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("Good(1)", "Good<Int>");
    a.shouldHaveType(`Bad("no")`, "Bad<String>");
    analyzedGeneric("    val n: List<Int> = Nil<Int>").shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("Nil", 2));
}

@("a type parameter can't be a sum member by itself, and members can't become one type in an instance")
unittest
{
    analyzedModule("type Maybe<T> = :T | Nothing").shouldReport(DiagnosticCode.InvalidSumMember, At("T", 2));
    analyzedModule("type Box<T>(value: T)\ntype S<A, B> = :Box<A> | :Box<B>").shouldReport(DiagnosticCode.InvalidSumMember, At("Box", 3));
    analyzedModule("type Box<T>(value: T)\ntype S<T> = :Box<T> | :Box<[T]>").shouldHaveNoDiagnostics();
}

@("a generic type is buildable when it would be with every type parameter buildable")
unittest
{
    analyzedModule("type A<T>(a: A<T>)").shouldReport(DiagnosticCode.UninhabitedType, At("A", 1));
    analyzedModule("type List<T> = Cons(head: T, rest: List<T>) | Nil\ntype Tree(kids: List<Tree>)").shouldHaveNoDiagnostics();
    analyzedModule("type Tag<T>\ntype U(tag: Tag<U>)").shouldHaveNoDiagnostics();
    analyzedModule("type Box<T>(value: T)\ntype U(box: Box<U>)").shouldReport(DiagnosticCode.UninhabitedType, At("U", 1));
}

// What's known about a type parameter

@("a value of a type parameter can be bound, passed, returned, captured, wrapped and taken apart")
unittest
{
    analyzedModule(`
type Box<T>(value: T)
type Result<T, E> = Good(value: T) | Bad(error: E)
def f<T, E>(x: T, xs: [T], o: T?, b: Box<T>, r: Result<T, E>): (T, [T]) {
    val y = x
    val g = () => y
    val maybe: T? = x
    val fallback = o ?? g()
    val more = xs ~ [x] ~ xs[0..1]
    for each in more {
        _ = each
    }
    val again = b with (value = xs[0])
    val chosen = match r {
        Good(value) => value
        Bad(_) => again.value
    }
    if val some = maybe { _ = some }
    (chosen, [fallback])
}`).shouldHaveNoDiagnostics();
}

@("generic code compares and prints a type parameter's values, but can't order or convert them")
unittest
{
    analyzedModule("def f<T>(a: T, b: T): Bool => a == b").shouldHaveNoDiagnostics();
    analyzedModule("def f<T>(a: [T]): Bool => a != a").shouldHaveNoDiagnostics();
    analyzedModule("type Box<T>(v: T)\ndef f<T>(a: Box<T>): Bool => a == a").shouldHaveNoDiagnostics();
    analyzedModule("def f<T>(a: T): Unit => printl(a)").shouldHaveNoDiagnostics();
    analyzedModule("def f<T>(a: T?): String => String(a)").shouldHaveNoDiagnostics();
    analyzedModule("def f<T>(a: T): String => \"{a}\"").shouldHaveNoDiagnostics();
    analyzedModule("def f<T>(a: T, b: T): Bool => a < b").shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a", 2));
    analyzedModule("def f<T>(a: T): Int => Int(a)").shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a", 2));
}

@("a pattern on a type parameter's value can only bind it")
unittest
{
    analyzedModule("def f<T>(a: T): Int => match a {\n    1 => 1\n    _ => 2\n}")
        .shouldReport(DiagnosticCode.OpaqueTypeParameter, At("1", 1));
    analyzedModule("def f<T>(a: (T, Int)): Int => match a {\n    (Some(x), _) => 1\n    _ => 2\n}")
        .shouldReport(DiagnosticCode.OpaqueTypeParameter, At("Some", 1));
    analyzedModule("def f<T>(a: T?): Int => match a {\n    Some(x) => 1\n    None => 2\n}").shouldHaveNoDiagnostics();
}

@("a literal can't be a type parameter's value")
unittest
{
    analyzedModule("def f<T>(): T => 1").shouldReport(DiagnosticCode.TypeMismatch, At("1", 1));
}

// Inference

@("typed arguments come first, then the expected type, then literals, lambdas, None and []")
unittest
{
    auto a = analyzedGeneric(`    val small: UInt8 = 3
    val ints = [1, 2]
    val m = larger(1, small, (x, y) => x < y)
    val maybe: Int? = first(ints)
    val made: [String]? = empty()
    val one = identity(1)
    val applied = apply(2, k => k > 1)
    val named = identity((j: Int) => j)`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("m", 1), "UInt8");
    a.shouldHaveType("1", 2, "UInt8");
    a.shouldHaveType("first(ints)", "Int?");
    a.shouldHaveType("empty()", "[String]");
    a.shouldDeclareType(At("one", 1), "Int");
    a.shouldDeclareType(At("applied", 1), "Bool");
    a.shouldDeclareType(At("named", 1), "(Int) -> Int");
}

@("a lambda waits for the argument that says what its parameters are")
unittest
{
    analyzedGeneric("    val r = flipped(n => n + 1, 5)", "def flipped<T, U>(f: (T) -> U, value: T): U => f(value)\n")
        .shouldHaveNoDiagnostics();
    analyzedGeneric("    val r = apply(Box(2), b => b.value)").shouldHaveNoDiagnostics();
}

@("a lambda's inferred result is promoted to the option its parameter returns")
unittest
{
    enum decls = "def unfold<S, T>(state: S, step: (S) -> (T, S)?): T? => None\n"
        ~ "def lift<T>(x: Int, f: (Int) -> T?): T? => f(x)\n";
    auto a = analyzedGeneric(`    val pairs = unfold(0, n => (n, n + 1))
    val early = unfold(0, n => if n > 3 => None else (n, n + 1))
    val already = lift(1, x => Some(x))
    val plain = lift(1, x => "a")
    val nested = lift(1, x => lift(x, y => y))`, decls);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("pairs", 1), "Int?");
    a.shouldDeclareType(At("early", 1), "Int?");
    a.shouldDeclareType(At("already", 1), "Int?");
    a.shouldDeclareType(At("plain", 1), "String?");
    a.shouldDeclareType(At("nested", 1), "Int?");
}

@("the first thing that determines a type parameter decides it, with no search for a common type")
unittest
{
    analyzedGeneric(`    val p = pair(1.5, "a")`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
    analyzedGeneric(`    val p = pair(Box(1), Box(true))`).shouldReport(DiagnosticCode.TypeMismatch, At("Box", 3));
}

@("a type parameter nothing determines asks for the type arguments")
unittest
{
    analyzedGeneric("    val e = empty()").shouldReport(DiagnosticCode.CannotInferTypeArgument, At("empty", 2));
    analyzedGeneric("    val w = wrap(None)").shouldReport(DiagnosticCode.UntypedNone, At("None", 2));
    analyzedGeneric("    val i = identity(x => x)").shouldReport(DiagnosticCode.CannotInferTypeArgument, At("identity", 2));
    analyzedGeneric(`    val f = first("abc")`).shouldReport(DiagnosticCode.TypeMismatch, At(`"abc"`, 1));
}

@("written type arguments skip inference, and have to be all of them")
unittest
{
    auto a = analyzedGeneric("    val e = empty<Int>()\n    val qb = Box<UInt8>(1)\n    val p = pair<Int?>(1, None)");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("e", 1), "[Int]");
    a.shouldDeclareType(At("qb", 1), "Box<UInt8>");
    a.shouldDeclareType(At("p", 1), "(Int?, Int?)");
    analyzedGeneric("    val e = empty<Int, Int>()").shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("empty", 2));
    analyzedGeneric("    val e = printl<Int>(1)").shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("printl", 1));
    analyzedGeneric("    val qx = 1\n    val e = qx<Int>").shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("qx", 2));
}

@("a constructor of an owned member builds its sum, whose type arguments all have to be found")
unittest
{
    auto a = analyzedGeneric(`    val r: Result<Int, String> = Good(1)
    val s: Result<Bool, Int> = Good<Bool>(true)
    val l: List<String> = Cons("a", Nil)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("Good(1)", "Result<Int, String>");
    a.shouldHaveType("Good<Bool>(true)", "Result<Bool, Int>");
    a.shouldHaveType("Nil", 2, "List<String>");
    analyzedGeneric("    val r = Good(1)").shouldReport(DiagnosticCode.CannotInferTypeArgument, At("Good", 2));
    analyzedGeneric("    val n = Nil").shouldReport(DiagnosticCode.CannotInferTypeArgument, At("Nil", 2));
}

@("a generic function or constructor as a value takes its type arguments as written, or from its expected type")
unittest
{
    auto a = analyzedGeneric(`    val qf: (Int) -> Int = identity
    val qg = identity<String>
    val qh = Box<Int>
    val qk: ([Bool]) -> Bool? = first`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("qg", 1), "(String) -> String");
    a.shouldDeclareType(At("qh", 1), "(Int) -> Box<Int>");
    analyzedGeneric("    val qf = identity").shouldReport(DiagnosticCode.CannotInferTypeArgument, At("identity", 2));
}

@("a generic function can call itself with its type parameters passed along or swapped, but not with ones that grow")
unittest
{
    analyzedModule(`
def same<T>(x: T, n: Int): Int => if n == 0 => 0 else same(x, n - 1)
def swap<A, B>(a: A, b: B, n: Int): Int => if n == 0 => 0 else swap(b, a, n - 1)
def fixed<T>(x: T, n: Int): Int => if n == 0 => 0 else fixed([1], n - 1)`).shouldHaveNoDiagnostics();
    analyzedModule("def grow<T>(x: T): Unit => grow([x])").shouldReport(DiagnosticCode.PolymorphicRecursion, At("grow", 2));
    analyzedModule("def f<T>(x: T): Unit => g((x, x))\ndef g<U>(u: U): Unit => f([u])")
        .shouldReport(DiagnosticCode.PolymorphicRecursion, At("g", 1));
    // An argument that's already an error isn't growth as well.
    analyzedModule("def grow<T>(x: T): Unit => grow((x, None))").shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
}

@("a generic type can hold itself at its type parameters passed along or swapped, but not at ones that grow")
unittest
{
    analyzedModule(`
type List<T> = Cons(head: T, rest: List<T>) | Nil
type Tree<T>(kids: [Tree<T>], value: T)
type Flip<A, B>(next: Flip<B, A>?, value: A)
type Fixed<T>(next: Fixed<Int>?, value: T)`).shouldHaveNoDiagnostics();
    analyzedModule("type Grow<T> = More(rest: Grow<(T, T)>, head: T) | Stop")
        .shouldReport(DiagnosticCode.PolymorphicRecursion, At("Grow", 2));
    analyzedModule("type Nest<T>(next: Nest<[T]>?)").shouldReport(DiagnosticCode.PolymorphicRecursion, At("Nest", 2));
    analyzedModule("type A<T>(b: B<[T]>?)\ntype B<U>(a: A<U>?)").shouldReport(DiagnosticCode.PolymorphicRecursion, At("B", 1));
    analyzedModule("type F<T>(f: (T) -> F<[T]>?)").shouldReport(DiagnosticCode.PolymorphicRecursion, At("(T)", 1));
}

@("an error list that adds to a type parameter's absorbs repeats, so calling itself with one doesn't grow")
unittest
{
    analyzedModule(`
type Oops(code: Int)
def tries<E>(r: Int ! E, n: Int): Int ! E | Oops {
    if n == 0 { return r? }
    val widened: Int ! E | Oops = r
    tries(widened, n - 1)
}`).shouldHaveNoDiagnostics();
}

@("a generic function that needs itself at a larger type through what a loop's indexing finds for each instance")
unittest
{
    analyzedModule(`
interface Steps<T> { def next(r: Self): (T, Self)? }
interface Counted { def size(r: Self): Int }
type Doubled<R>(source: R)
def next<R: Steps<Int>>(d: Doubled<R>): (Int, Doubled<R>)? {
    val (item, rest) = next(d.source)?
    (item * 2, Doubled(rest))
}
def size<R: Counted>(d: Doubled<R>): Int => size(d.source)
def length<R: Steps<Int> & Counted>(d: Doubled<R>): Int => count(d) + size(d.source)
def opIndex<R: Steps<Int> & Counted>(d: Doubled<R>, i: Int): Int => i
def count<R: Steps<Int>>(r: R): Int {
    mutable val k = 0
    for _ in Doubled(r) { k += 1 }
    k
}`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("count", 1));
}

@("a generic function that builds a larger instance of a type whose invariant calls it needs endlessly many instances")
unittest
{
    analyzedModule(`
type Bad
type W<T>(items: [T]) invariant ok(items) else Bad
def ok<U>(xs: [U]): Bool {
    if length(xs) > 0 { return true }
    match W([xs]) {
        Ok(_) => true
        Error(_) => false
    }
}`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("W", 2));
}

@("a constructor used as a value builds the instance it returns, not one its parameters mention")
unittest
{
    analyzedModule(`
type Bad
type W<T>(fixed: W<Int>?, items: [T]) invariant ok(items) else Bad
def ok<U>(xs: [U]): Bool {
    if length(xs) > 0 { return true }
    val mk: (W<Int>?, [[U]]) -> W<[U]> ! Bad = W
    match mk(None, [xs]) {
        Ok(_) => true
        Error(_) => false
    }
}`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("W", 5));
    analyzedModule(`
type Bad
type W<T>(items: [T]) invariant ok(items) else Bad
def ok<U>(xs: [U]): Bool {
    if length(xs) > 0 { return true }
    val mk: ([[U]]) -> W<[U]> ! Bad = W
    match mk([xs]) {
        Ok(_) => true
        Error(_) => false
    }
}`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("W", 3));
}

@("a `with` that a type's invariant checks needs the invariant at the instance it changes")
unittest
{
    analyzedModule(`
type Bad
type W<T>(items: [T], n: Int) invariant ok(items, n) else Bad
type Holder<T>(w: W<[T]>?)
def ok<U>(xs: [U], n: Int): Bool => n > 0 || poke(Holder<U>(None))
def poke<U>(h: Holder<U>): Bool => match h.w {
    None => false
    Some(w) => match w with (n = 0) {
        Ok(_) => true
        Error(_) => false
    }
}`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("w with", 1));
}

@("the invariant of a member a generic sum declares inline is needed at the sum's arguments it mentions")
unittest
{
    analyzedModule(`
type Bad
type S<A, B> = M(b: [B]) invariant (ok(b)) else (Bad) | Stop(a: A)
def ok<U>(xs: [U]): Bool {
    if length(xs) > 0 { return true }
    val s: S<Int, [U]> ! Bad = M([xs])
    match s {
        Ok(_) => true
        Error(_) => false
    }
}`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("M([xs])", 1));
    // Growing only the parameter the member doesn't mention needs no larger invariant.
    analyzedModule(`
type Bad
type S<A, B> = M(b: [B]) invariant (ok(b)) else (Bad) | Stop(a: A)
def ok<U>(xs: [U]): Bool => true
def grows<A>(a: A, n: Int): Int {
    if n == 0 { return 0 }
    val s: S<[A], Int> ! Bad = M([1])
    grows(a, n - 1)
}`).shouldHaveNoDiagnostics();
}

@("an error list grows when it holds a type parameter inside another member")
unittest
{
    analyzedModule(`
type Box<T>(v: T)
def grows<E>(r: Int ! E, n: Int): Int {
    if n == 0 { return 0 }
    val o: Int ! E | Box<E> = r
    grows(o, n - 1)
}`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("grows(o", 1));
}

@("growth through a loop's indexing is found however deep the loop's type and wherever the loop is")
unittest
{
    enum base = `
interface Steps<T> { def next(r: Self): (T, Self)? }
interface Counted { def size(r: Self): Int }
type Doubled<R>(source: R)
def next<R: Steps<Int>>(d: Doubled<R>): (Int, Doubled<R>)? {
    val (item, rest) = next(d.source)?
    (item * 2, Doubled(rest))
}
def size<R: Counted>(d: Doubled<R>): Int => size(d.source)
def length<R: Steps<Int> & Counted>(d: Doubled<R>): Int => count(d) + size(d.source)
def opIndex<R: Steps<Int> & Counted>(d: Doubled<R>, i: Int): Int => i
`;
    analyzedModule(base ~ `
def count<R: Steps<Int>>(r: R): Int {
    mutable val k = 0
    for _ in Doubled(Doubled(r)) { k += 1 }
    k
}`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("count", 1));
    analyzedModule(base ~ `
def count<R: Steps<Int>>(r: R): Int {
    val f = (x: R) => {
        mutable val k = 0
        for _ in Doubled(x) { k += 1 }
        k
    }
    f(r)
}`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("count", 1));
}

@("a method call's receiver is its first argument for inference, and isn't converted")
unittest
{
    auto a = analyzedGeneric("    val qf = [1, 2].first()\n    val qg = 3.identity()\n    val l = [1].length()");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("qf", 1), "Int?");
    a.shouldDeclareType(At("qg", 1), "Int");
    analyzedGeneric("    val xs = [1]\n    val p = xs.pushed(2)").shouldReport(DiagnosticCode.TypeMismatch, At("xs", 2));
    analyzedGeneric("    val qq = 1\n    val r = qq.length()").shouldReport(DiagnosticCode.TypeMismatch, At("qq", 2));
}

@("a mutable argument has to be exactly its parameter's type once the type arguments are known")
unittest
{
    analyzedGeneric("    mutable val s: Int8 = 1\n    _ = exchange(mutable s, 2)").shouldHaveNoDiagnostics();
    analyzedGeneric("    val v: Int8 = 1\n    mutable val o: Int8? = None\n    setTo(v, mutable o)")
        .shouldReport(DiagnosticCode.TypeMismatch, At("o", 2));
    analyzedGeneric("    mutable val r = [1]\n    _ = length(mutable r)").shouldReport(DiagnosticCode.MutabilityMismatch, At("r", 2));
}

@("an intrinsic is a value like any function, unless it takes an Any")
unittest
{
    analyzedGeneric("    val qf = length<Int>").shouldHaveNoDiagnostics();
    analyzedGeneric("    val qf: ([Bool]) -> Int = length").shouldHaveNoDiagnostics();
    analyzedGeneric("    val qf = printl").shouldReport(DiagnosticCode.NotSupportedYet, At("printl", 1));
}

@("a constructor pattern sees an instance's fields, and coverage works on instances")
unittest
{
    auto a = analyzedGeneric(`    val r: Result<Int, String> = Good(1)
    val n = match r {
        Good(v) => v
        Bad(message) => 0
    }`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("v", 1), "Int");
    a.shouldDeclareType(At("message", 1), "String");
    analyzedGeneric("    val l: List<Int> = Nil\n    val n = match l {\n        Nil => 0\n    }")
        .shouldReport(DiagnosticCode.NonExhaustiveMatch, At("match", 1));
}

@("an alias of an instance builds it, and is a function value, with the alias's type arguments")
unittest
{
    enum aliases = "type Box<T>(value: T)\nalias IntBox = Box<Int>\nalias Also = IntBox\n";
    auto a = analyzed(aliases ~ "def f(b: Also): Int => match b {\n    Also(v) => v\n}\n"
        ~ "def main(): Unit {\n    val c = Also(2)\n    val make = IntBox\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("Also(2)", "Box<Int>");
    a.shouldDeclareType(At("make", 1), "(Int) -> Box<Int>");
    analyzed(aliases ~ "def main(): Unit {\n    val c = Also<Int>(2)\n}")
        .shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("Also", 2));
    analyzed(aliases ~ "def main(): Unit {\n    val c = Also(\"no\")\n}").shouldReport(DiagnosticCode.TypeMismatch, At(`"no"`, 1));
}

@("an alias of an instance in a constructor pattern takes apart only that instance")
unittest
{
    enum aliases = "type Box<T>(value: T)\nalias IntBox = Box<Int>\nalias Also = IntBox\n";
    analyzed(aliases ~ "def main(): Unit {\n    val n = match Box(\"s\") {\n        Also(v) => 0\n    }\n}")
        .shouldReport(DiagnosticCode.PatternMismatch, At("Also", 2));
    analyzed(aliases ~ "def main(): Unit {\n    if val IntBox(v) = Box(\"s\") => printl(v)\n}")
        .shouldReport(DiagnosticCode.PatternMismatch, At("IntBox", 3));
    auto a = analyzed(aliases ~ "alias StrBox = Box<String>\ntype Held = :IntBox | :StrBox\n"
        ~ "def f(h: Held): String => match h {\n    IntBox(n) => \"int\"\n    StrBox(s) => s\n}\ndef main(): Unit {\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("n", 1), "Int");
    a.shouldDeclareType(At("s", 1), "String");
}

@("a constructor pattern with type arguments takes apart only that instance")
unittest
{
    enum types = "type Box<T>(value: T)\ntype Held = :Box<Int> | :Box<String>\n"
        ~ "type Outcome<T> = Done(value: T) | Failed(reason: String)\ntype Pair<A, B>(left: A, right: B)\n";
    auto a = analyzed(types ~ "def f(h: Held): String => match h {\n    Box<Int>(n) => \"int\"\n    Box<String>(s) => s\n}\n"
        ~ "def g(o: Outcome<Int>): Int => match o {\n    Done<Int>(d) => d\n    Failed(_) => 0\n}\n"
        ~ "def k(p: Pair<Box<UInt8>, Outcome<Int>>): Int => match p {\n"
        ~ "    Pair<Box<UInt8>, Outcome<Int>>(Box<UInt8>(1), Done<Int>(e)) => e\n    _ => 0\n}\n"
        ~ "def main(): Unit {\n    if val Box<String>(t) = Box(\"s\") => printl(t)\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("n", 1), "Int");
    a.shouldDeclareType(At("s", 1), "String");
    a.shouldDeclareType(At("d", 1), "Int");
    a.shouldDeclareType(At("e", 1), "Int");
    a.shouldDeclareType(At("t", 1), "String");

    analyzed(types ~ "def f(h: Held): Int => match h {\n    Box<Int>(n) => n\n}\ndef main(): Unit {\n}")
        .shouldReport(DiagnosticCode.NonExhaustiveMatch, At("match", 1));
    analyzed(types ~ "def f(h: Held): Int => match h {\n    Box<Bool>(n) => 0\n    _ => 1\n}\ndef main(): Unit {\n}")
        .shouldReport(DiagnosticCode.PatternMismatch, At("Box", 4));
    analyzed(types ~ "def main(): Unit {\n    if val Box<String>(t) = Box(1) => printl(t)\n}")
        .shouldReport(DiagnosticCode.PatternMismatch, At("Box", 4));
    analyzed(types ~ "def f(o: Outcome<Int>): Int => match o {\n    Done<String>(d) => 0\n    _ => 1\n}\ndef main(): Unit {\n}")
        .shouldReport(DiagnosticCode.PatternMismatch, At("Done", 2));
}

@("a constructor pattern's type arguments are checked as a type's are")
unittest
{
    enum types = "type Box<T>(value: T)\ntype Point(x: Int, y: Int)\nalias IntBox = Box<Int>\n";
    string matching(string pattern) => types ~ "def f(b: Box<Int>): Int => match b {\n    "
        ~ pattern ~ " => 0\n    _ => 1\n}\ndef main(): Unit {\n}";
    analyzed(matching("Box<Int, String>(v)")).shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("Box", 4));
    analyzed(types ~ "def f(b: Box<Int>): Int => match b {\n    Box<Nope>(v) => 0\n}\ndef main(): Unit {\n}")
        .shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    analyzed(matching("IntBox<Int>(v)")).shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("IntBox", 2));
    analyzed(types ~ "def f(p: Point): Int => match p {\n    Point<Int>(x, y) => x\n}\ndef main(): Unit {\n}")
        .shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("Point", 3));
    analyzed(types ~ "def f(o: Int?): Int => match o {\n    Some<Int>(x) => x\n}\ndef main(): Unit {\n}")
        .shouldReport(DiagnosticCode.UnknownType, At("Some", 1));
}

@("a constructor pattern with type arguments reaches through a sum an error list names")
unittest
{
    enum types = "type Box<T>(value: T)\ntype Held = :Box<Int> | :Box<String>\ntype Other\n";
    auto a = analyzed(types ~ "def f(r: Int ! Held | Other): Int => match r {\n    Ok(v) => v\n"
        ~ "    Error(Box<Int>(n)) => n\n    Error(Box<String>(_)) => 0\n    Error(Other) => 1\n}\ndef main(): Unit {\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("n", 1), "Int");
}

@("a reserved name with type arguments doesn't make the arms after it unreachable")
unittest
{
    analyzed("def f(o: Int?): Int => match o {\n    Some<Int>(x) => x\n    None => 0\n}\ndef main(): Unit {\n}")
        .shouldReport(DiagnosticCode.UnknownType, At("Some", 1));
    analyzed("def f(r: Int ! String): Int => match r {\n    Ok<Int>(x) => x\n    Error(_) => 0\n}\ndef main(): Unit {\n}")
        .shouldReport(DiagnosticCode.UnknownType, At("Ok", 1));
    analyzed("def f(r: Int ! String): Int => match r {\n    Error<String>(_) => 0\n    Ok(x) => x\n}\ndef main(): Unit {\n}")
        .shouldReport(DiagnosticCode.UnknownType, At("Error", 1));
}

@("a pattern whose type didn't resolve leaves the match's coverage unchecked")
unittest
{
    enum types = "type Box<T>(value: T)\ntype Held = :Box<Int> | :Box<String>\n";
    string matching(string arms) => types ~ "def f(h: Held): Int => match h {\n" ~ arms ~ "}\ndef main(): Unit {\n}";
    analyzed(matching("    Box<Nope>(v) => 0\n    _ => 1\n")).shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    analyzed(matching("    Box<Nope>(v) => 0\n")).shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    analyzed(matching("    Nope(v) => 0\n    Box<Int>(n) => n\n    _ => 1\n")).shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    analyzed(matching("    v: Nope => 0\n    _ => 1\n")).shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    // Only the match with the broken pattern is left unchecked.
    import std.algorithm : map;
    import std.array : array;
    auto a = analyzed(matching("    Box<Int>(n) => match n {\n        Nope(_) => 0\n        _ => 1\n    }\n    Box<Int>(m) => m\n    _ => 2\n"));
    assert(a.collector.diagnostics.map!(d => d.code).array == [DiagnosticCode.UnknownType, DiagnosticCode.UnreachableArm]);
}
