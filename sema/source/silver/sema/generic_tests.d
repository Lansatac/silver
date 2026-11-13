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
    analyzedModule("type Maybe<T> = T | Nothing").shouldReport(DiagnosticCode.InvalidSumMember, At("T", 2));
    analyzedModule("type Box<T>(value: T)\ntype S<A, B> = Box<A> | Box<B>").shouldReport(DiagnosticCode.InvalidSumMember, At("Box", 3));
    analyzedModule("type Box<T>(value: T)\ntype S<T> = Box<T> | Box<[T]>").shouldHaveNoDiagnostics();
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

@("generic code can't compare, order or print a type parameter's values")
unittest
{
    analyzedModule("def f<T>(a: T, b: T): Bool => a == b").shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a", 2));
    analyzedModule("def f<T>(a: [T]): Bool => a != a").shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a", 2));
    analyzedModule("type Box<T>(v: T)\ndef f<T>(a: Box<T>): Bool => a == a").shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a", 2));
    analyzedModule("def f<T>(a: T, b: T): Bool => a < b").shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a", 2));
    analyzedModule("def f<T>(a: T): Unit => printl(a)").shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a", 2));
    analyzedModule("def f<T>(a: T?): String => String(a)").shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a", 2));
    analyzedModule("def f<T>(a: T): String => \"{a}\"").shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a", 2));
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

@("an alias of an instance is a type, but its name can't build a value, which would lose the type arguments")
unittest
{
    enum aliases = "type Box<T>(value: T)\nalias IntBox = Box<Int>\nalias Also = IntBox\n";
    analyzed(aliases ~ "def f(b: Also): Int => match b {\n    Also(v) => v\n}\ndef main(): Unit {\n    val b: IntBox = Box(1)\n}")
        .shouldHaveNoDiagnostics();
    analyzed(aliases ~ "def main(): Unit {\n    val c = Also(2)\n}").shouldReport(DiagnosticCode.AliasIsNotAValue, At("Also", 2));
}
