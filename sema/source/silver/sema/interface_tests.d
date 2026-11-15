/// Tests of interfaces: their declarations, bounds, what a bound supplies inside a generic function,
/// and how a use finds the functions that make its type arguments conform.
module silver.sema.interface_tests;

version (unittest):

import fluent.asserts;

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType, shouldHaveType;
import silver.sema.resolution_tests;
import silver.sema.target : Target;
import silver.sema.typing : Query;
import silver.ast : FunctionDecl, Id;

private enum declarations = `
interface Json { def toJson(value: Self): String }
interface Sized { def length(value: Self): Int }
interface Range<T> { def next(range: Self): (T, Self)? }
interface Add<Rhs> { def add(a: Self, b: Rhs): Self }
type Point(x: Int, y: Int)
type Plain(n: Int)
type Box<T>(value: T)
type Vec(x: Float)
def toJson(value: Int): String => "int"
def toJson(p: Point): String => "point"
def toJson<T: Json>(b: Box<T>): String => toJson(b.value)
def toJson<T: Json>(x: T?): String => "option"
def next<T>(xs: [T]): (T, [T])? => if length(xs) == 0 => None else (xs[0], xs[1..])
def add(a: Vec, b: Vec): Vec => a
def add(a: Vec, b: Float): Vec => a
def encode<T: Json>(item: T): String => toJson(item)
def total(range: Range<Int>): Int => 0
def toArray<T>(range: Range<T>): [T] => []
def map<R: Range<T>, T, U>(source: R, transform: (T) -> U): [U] => []
def plus<T: Add<R>, R>(a: T, b: R): T => add(a, b)
`;

/// `body` in `main`, after the declarations above.
private Analyzed analyzedWith(string body, string more = "")
{
    return analyzed(declarations ~ more ~ "def main(): Unit {\n" ~ body ~ "\n}");
}

/// `source` at module level, with an empty `main`.
private Analyzed analyzedModule(string source)
{
    return analyzed(source ~ "\ndef main(): Unit => ()");
}

/// The message of the only diagnostic, which has to be `code`.
private string onlyMessage(const Analyzed a, DiagnosticCode code, string file = __FILE__, size_t line = __LINE__)
{
    import core.exception : AssertError;
    import std.format : format;

    auto diagnostics = a.collector.diagnostics;
    if (diagnostics.length != 1 || diagnostics[0].code != code)
    {
        throw new AssertError(format("Expected only %s, got %s", code, diagnostics), file, line);
    }
    return diagnostics[0].message;
}

// Declarations

@("an interface declares functions over Self and its own type parameters")
unittest
{
    analyzedModule(`
interface Indexed<T> {
    def length(value: Self): Int
    def opIndex(value: Self, index: Int): T
}
interface Anything { }`).shouldHaveNoDiagnostics();
}

@("an interface's name is taken like a type's, and Self is the language's")
unittest
{
    analyzedModule("type Json(n: Int)\ninterface Json { }").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Json", 2));
    analyzedModule("interface Int { }").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Int", 1));
    analyzedModule("type Self(n: Int)").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Self", 1));
    analyzedModule("def f<Self>(): Int => 1").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Self", 1));
    analyzedModule("def f(x: Self): Int => 1").shouldReport(DiagnosticCode.UnknownType, At("Self", 1));
}

@("every function of an interface takes a Self")
unittest
{
    analyzedModule("interface Zero { def zero(): Self }").shouldReport(DiagnosticCode.InvalidBound, At("zero", 1));
    analyzedModule("interface Zero { def zero(of: Of<Self>): Self }").shouldHaveNoDiagnostics();
    analyzedModule("interface All { def all(values: [Self]): Self }").shouldHaveNoDiagnostics();
}

@("an interface's functions can share a name when their parameter types differ")
unittest
{
    analyzedModule("interface Scale {
    def scale(a: Self, by: Int): Self
    def scale(a: Self, by: Float): Self
}")
        .shouldHaveNoDiagnostics();
    analyzedModule("interface Scale {
    def scale(a: Self, by: Int): Self
    def scale(b: Self, times: Int): Int
}")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("scale", 2));
}

@("a bound goes on a module-level def's type parameter only")
unittest
{
    enum json = "interface Json { def toJson(value: Self): String }\n";
    analyzedModule(json ~ "type Set<T: Json>(items: [T])").shouldReport(DiagnosticCode.InvalidBound, At("Json", 2));
    analyzedModule(json ~ "interface Holds<T: Json> { def held(x: Self): T }").shouldReport(DiagnosticCode.InvalidBound, At("Json", 2));
    analyzedModule(json ~ "type Both<T: Json> = Left(value: T) | Right").shouldReport(DiagnosticCode.InvalidBound, At("Json", 2));
}

@("a bound names an interface, with its type arguments")
unittest
{
    analyzedModule("def f<T: Int>(x: T): T => x").shouldReport(DiagnosticCode.NotAnInterface, At("Int", 1));
    analyzedModule("def f<T: Nope>(x: T): T => x").shouldReport(DiagnosticCode.UnknownType, At("Nope", 1));
    analyzedModule("interface Range<T> { def next(r: Self): (T, Self)? }\ndef f<R: Range>(x: R): R => x")
        .shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("Range", 2));
    analyzedModule("interface Json { def toJson(v: Self): String }\ndef f<T: Json<Int>>(x: T): T => x")
        .shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("Json", 2));
}

@("an interface stands for a type only as a def's parameter or result type, or a val's annotation")
unittest
{
    enum json = "interface Json { def toJson(value: Self): String }\n";
    analyzedModule(json ~ "def f(x: Json): String => toJson(x)").shouldHaveNoDiagnostics();
    analyzedModule(json ~ "def f(xs: [Json]): Int => 1").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "def f(x: Json?): Int => 1").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "def f(pair: (Int, Json)): Int => 1").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "type Holder(item: Json)").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "alias J = Json").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "def f(): Unit {\n    val (x: Json, y) = (1, 2)\n}").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "def f(): Unit {\n    val g = (x: Json) => 1\n}").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "def f(): Unit {\n    def g(x: Json): Int => 1\n}").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "interface Other { def other(x: Self, y: Json): Int }").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
}

@("a private interface can't be a public function's bound")
unittest
{
    analyzedModule("private interface Json { def toJson(v: Self): String }\ndef f<T: Json>(x: T): Int => 1")
        .shouldReport(DiagnosticCode.PrivateTypeExposed, At("Json", 2));
    analyzedModule("private interface Json { def toJson(v: Self): String }\nprivate def f<T: Json>(x: T): Int => 1")
        .shouldHaveNoDiagnostics();
}

@("two functions differing in bounds are overloads when one's ask for every function the other's do and more")
unittest
{
    enum interfaces = `
interface A { def a(x: Self): Int }
interface B { def b(x: Self): Int }
interface C { def c(x: Self): Int }
interface AB { def a(x: Self): Int
    def b(x: Self): Int }
interface Other { def a(x: Self): String }
interface Range<T> { def next(range: Self): (T, Self)? }
`;
    analyzedModule(interfaces ~ "def f<T: A>(x: T): Int => 1\ndef f<U: A & B>(x: U): Int => 2\ndef f<T: C & B & A>(x: T): Int => 3\ndef f<T>(x: T): Int => 0")
        .shouldHaveNoDiagnostics();
    // By the functions asked for, whatever the interfaces are named.
    analyzedModule(interfaces ~ "def f<T: A>(x: T): Int => 1\ndef f<T: AB>(x: T): Int => 2").shouldHaveNoDiagnostics();
    analyzedModule(interfaces ~ "def f(x: A): Int => 1\ndef f<T: A & B>(x: T): Int => 2").shouldHaveNoDiagnostics();
    analyzedModule(interfaces ~ "def f<R: Range<T>, T>(x: R): Int => 1\ndef f<S: Range<E> & A, E>(x: S): Int => 2").shouldHaveNoDiagnostics();

    analyzedModule(interfaces ~ "def f<T: A & B>(x: T): Int => 1\ndef f<T: AB>(x: T): Int => 2").shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedModule(interfaces ~ "def f<T: A & B>(x: T): Int => 1\ndef f<T: B & A>(x: T): Int => 2").shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedModule(interfaces ~ "def f<T: A & B>(x: T): Int => 1\ndef f<T: A & C>(x: T): Int => 2").shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    // A function of the same name with another result isn't the same function.
    analyzedModule(interfaces ~ "def f<T: A>(x: T): Int => 1\ndef f<T: Other & B>(x: T): Int => 2").shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedModule(interfaces ~ "def f<R: Range<Int>>(x: R): Int => 1\ndef f<R: Range<String> & A>(x: R): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    // The bounds have to be on the same parameters.
    analyzedModule(interfaces ~ "def f<T: A, U>(x: T, y: U): Int => 1\ndef f<T: B, U: A>(x: T, y: U): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedModule(interfaces ~ "def f<T: A>(x: T): Int => 1\ndef f<T: A & B>(x: T): Int => 2\ndef f<T: A & C>(x: T): Int => 3")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 3));
    analyzedModule(interfaces ~ "def f<T: A>(mutable x: T): Int => 1\ndef f<T: A & B>(x: T): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    // A concrete interface argument isn't counted as the generic one.
    analyzedModule(interfaces ~ "def f<R: Range<T>, T>(x: R): Int => 1\ndef f<R: Range<Int> & A>(x: R): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
}

@("where both fit, the function whose bounds ask for more is chosen")
unittest
{
    enum declared = `
interface A { def a(x: Self): Int }
interface B { def b(x: Self): Int }
type Both(n: Int)
type OnlyA(n: Int)
def a(x: Both): Int => 1
def b(x: Both): Int => 1
def a(x: OnlyA): Int => 1
def f<T: A>(x: T): Int => 1
def f<T: A & B>(x: T): String => "more"
def weak<T: A>(x: T): Int => f(x)
def strong<T: B & A>(x: T): String => f(x)
`;
    auto a = analyzed(declared ~ "def main(): Unit {\n val p = f(Both(1))\n val q = f(OnlyA(1))\n val g: (Both) -> String = f\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("f(Both(1))", "String");
    a.shouldHaveType("f(OnlyA(1))", "Int");
}

@("what the expected type binds has to suit a literal argument for a function to fit")
unittest
{
    enum declared = `
interface A { def a(x: Self): Int }
interface B { def b(x: Self): Int }
def a(x: Int): Int => 1
def a(x: [Int]): Int => 1
def b(x: [Int]): Int => 1
def a(x: String): Int => 1
def b(x: String): Int => 1
def conv<T: A>(x: T): [T] => [x]
def conv<T: A & B>(x: T): T => x
def sel<T: A>(x: T): T? => x
def sel<T: A & B>(x: T): T? => x
`;
    auto a = analyzed(declared ~ "def main(): Unit {\n val xs: [Int] = conv(1)\n}");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("conv(1)", "[Int]");
    // When it leaves nothing that fits, the choice is made without it, and the literal is the error.
    analyzed(declared ~ "def main(): Unit {\n val s: String? = sel(1)\n}")
        .onlyMessage(DiagnosticCode.TypeMismatch).should.equal("Type `Int` is not assignable to type `String`");
}

@("a bound only the expected type decides is checked while an overload is chosen")
unittest
{
    enum declared = `
interface A { def a(x: Self): Int }
interface B { def b(x: Self): Int }
type Box(n: Int)
def a(x: Int): Int => 1
def a(x: Float): Int => 1
def b(x: Float): Int => 1
def pick<T: A>(): T? => None
def pick<T: A & B>(): T? => None
`;
    analyzed(declared ~ "def main(): Unit {\n val i: Int? = pick()\n val f: Float? = pick()\n}").shouldHaveNoDiagnostics();
    // A failure is a reason to choose another, so none holding is the call that fits nothing.
    analyzed(declared ~ "def main(): Unit {\n val x: Box? = pick()\n}")
        .onlyMessage(DiagnosticCode.NoMatchingOverload).should.contain("`Box` isn't one");
}

@("a function the expected type rules out by its bounds isn't chosen again when nothing fits")
unittest
{
    enum declared = `
interface A { def a(x: Self): Int }
interface B { def b(x: Self): Int }
type Box(n: Int)
def a(x: Int): Int => 1
def b(x: Int): Int => 1
def a(x: Box): Int => 1
def mk<T: B>(n: Int): T? => None
def mk<T: A & B>(x: T): T? => Some(x)
def conv<T: A>(x: T): [T] => [x]
def conv<T: A & B>(x: T): T => x
`;
    auto message = analyzed(declared ~ "def main(): Unit {\n val v: Box? = mk(1)\n}")
        .onlyMessage(DiagnosticCode.NoMatchingOverload);
    message.should.contain("`Box` isn't one");
    message.should.contain("argument 1 can't be `Box`, which the expected type gives `T`");
    // Each fails on the literal, and a `[Box]` isn't an `A`, so the first isn't chosen without the expected type.
    message = analyzed(declared ~ "def main(): Unit {\n val q: [Box] = conv(1)\n}")
        .onlyMessage(DiagnosticCode.NoMatchingOverload);
    message.should.contain("argument 1 can't be `Box`");
    message.should.contain("argument 1 can't be `[Box]`");
}

@("a function that fails on an argument whatever the expected type is doesn't keep the others from being chosen without it")
unittest
{
    enum declared = `
interface A { def a(x: Self): Int }
interface B { def b(x: Self): Int }
type Box(n: Int)
def a(x: Int): Int => 1
def b(x: Int): Int => 1
def a(x: Box): Int => 1
def a(x: [Box]): Int => 1
def b(x: [Box]): Int => 1
def conv<T: A>(x: T): [T] => [x]
def conv<T: A & B>(x: T): T => x
`;
    // Each fails only on the literal, so the choice is made without the expected type, and the
    // literal is the error against the one chosen, with or without a function that takes a `Bool`.
    enum call = "def main(): Unit {\n val q: [Box] = conv(1)\n}";
    analyzed(declared ~ call).onlyMessage(DiagnosticCode.TypeMismatch);
    analyzed(declared ~ "def conv(x: Bool): Int => 0\n" ~ call).onlyMessage(DiagnosticCode.TypeMismatch);
}

@("two functions whose bounds ask for different things are duplicates")
unittest
{
    analyzedModule(`
interface A { def a(x: Self): Int }
interface B { def b(x: Self): Int }
def f<T: A>(x: T): Int => 1
def f<T: B>(x: T): Int => 2`).shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedModule(`
interface A { def a(x: Self): Int }
interface B { def b(x: Self): Int }
def f(x: A): Int => 1
def f(x: B): Int => 2`).shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
}

// Inside a generic function

@("a bound's function is called on a value of the type parameter, by name or as a method")
unittest
{
    auto a = analyzedModule(`
interface Json { def toJson(value: Self): String }
def encode<T: Json>(item: T): String => toJson(item) ~ item.toJson()`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("toJson(item)", "String");
    a.shouldHaveType("item.toJson()", "String");
}

@("a bound's function takes only its own type parameter, and other functions of its name are still reached")
unittest
{
    enum json = "interface Json { def toJson(value: Self): String }\ndef toJson(x: Int): String => \"int\"\n";
    analyzedModule(json ~ "def f<T: Json, U>(a: T, b: U): String => toJson(a) ~ toJson(1)").shouldHaveNoDiagnostics();
    analyzedModule(json ~ "def f<T: Json, U>(a: T, b: U): String => toJson(b)").shouldReport(DiagnosticCode.NoMatchingOverload, At("toJson", 3));
    analyzedModule("interface Json { def toJson(value: Self): String }\ndef f<T: Json, U>(a: T, b: U): String => toJson(b)")
        .shouldReport(DiagnosticCode.TypeMismatch, At("b", 2));
}

@("a bound's function fits its type parameter better than the function it's called in")
unittest
{
    analyzedModule(`
interface Json { def toJson(value: Self): String }
def toJson<T: Json>(x: T?): String => match x {
    None => "null"
    Some(v) => toJson(v)
}`).shouldHaveNoDiagnostics();
}

@("two bounds that declare the same function supply one")
unittest
{
    analyzedModule(`
interface A { def render(value: Self): String }
interface B { def render(value: Self): String }
def both<T: A & B>(x: T): String => render(x) ~ x.render()`).shouldHaveNoDiagnostics();
}

@("a bound's function is a value of its function type")
unittest
{
    auto a = analyzedModule(`
interface Json { def toJson(value: Self): String }
def encoder<T: Json>(item: T): (T) -> String => toJson`);
    a.shouldHaveNoDiagnostics();
}

@("a generic passes its bound on, and a type built from its parameter is searched where it's written")
unittest
{
    analyzedWith("", `
def twice<T: Json>(item: T): String => encode(item) ~ encode(Box(item))
def unbounded<T>(item: T): String => "none"
`).shouldHaveNoDiagnostics();
    analyzedWith("", "def loose<T>(item: T): String => encode(item)\n").onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.startWith("`encode` needs `T` to be a `Json`, and `T` isn't one");
}

@("an interface's parameter is opaque inside the function, and the bound's function returns it")
unittest
{
    auto a = analyzedWith("", `
def step<R: Range<T>, T>(range: R): (T, R)? => next(range)
def firstOf<R: Range<T>, T>(range: R): T? {
    val (item, rest) = next(range)?
    item
}
`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("next(range)", "(T, R)?");
}

@("for steps a value of a type parameter with the bound's next")
unittest
{
    analyzedWith("", `
def count<T>(range: Range<T>): Int {
    mutable val n = 0
    for item in range { n += 1 }
    n
}
`).shouldHaveNoDiagnostics();
}

// Conformance

@("a type conforms through a function a call would choose")
unittest
{
    auto a = analyzedWith(`
    val a = encode(1)
    val b = encode(Point(1, 2))
    val c = encode(Box(Box(Point(1, 2))))
    val d = encode(Some(1))
    val e = Point(1, 2).encode()`);
    a.shouldHaveNoDiagnostics();
}

@("a type with no function doesn't conform, and the error says what was tried")
unittest
{
    auto message = analyzedWith("val a = encode(Plain(1))").onlyMessage(DiagnosticCode.UnsatisfiedBound);
    message.should.startWith("`encode` needs `T` to be a `Json`, and `Plain` isn't one: no `toJson` in scope takes `Plain`");
    message.should.contain("toJson(Int) takes `Int` there, not `Plain`");
    message.should.contain("toJson<T: Json>(T?) needs `T` to be a `Json`, and `Plain` isn't one: that would need `Plain: Json` to hold already");
}

@("a bound that needs itself fails")
unittest
{
    analyzedModule(`
interface Json { def toJson(value: Self): String }
def toJson<T: Json>(x: T?): String => "option"
def encode<T: Json>(item: T): String => toJson(item)
def f(): String => encode(1)`).onlyMessage(DiagnosticCode.UnsatisfiedBound).should.contain("that would need `Int: Json` to hold already");
}

@("the function is chosen by its arguments, and its result then has to be the interface's exactly")
unittest
{
    auto message = analyzedWith("val a = encode(Plain(1))", "def toJson(p: Plain): Int => 1\n").onlyMessage(DiagnosticCode.UnsatisfiedBound);
    message.should.contain("`toJson(Plain)` returns `Int`, where `String` is needed");
    analyzedWith("val a = encode(Plain(1))", "def toJson(p: Plain): String? => None\n").onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.contain("`toJson(Plain)` returns `String?`, where `String` is needed");
}

@("an argument is promoted to fit, as a call's is")
unittest
{
    analyzedWith(`
    val a = area(Circle(1))
    val b = measure(Circle(1))`, `
interface HasArea { def area(shape: Self): Int }
type Circle(r: Int)
type Square(side: Int)
type Shape = :Circle | :Square
def area(s: Shape): Int => 1
def measure<T: HasArea>(shape: T): Int => area(shape)
`).shouldHaveNoDiagnostics();
}

@("a function whose bound fails doesn't fit, so another overload is chosen")
unittest
{
    auto a = analyzedWith(`
    val json = show(Point(1, 2))
    val plain = show(Plain(1))
    val other = show(["text"])`, `
def show<T: Json>(item: T): Int => 1
def show(item: Plain): Bool => true
def show<T>(item: [T]): Float => 1.0
`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("json", 1), "Int");
    a.shouldDeclareType(At("plain", 1), "Bool");
    a.shouldDeclareType(At("other", 1), "Float");
}

@("when no overload fits, the error says which bound failed")
unittest
{
    auto message = analyzedWith("val a = show(Plain(1))", `
def show<T: Json>(item: T): Int => 1
def show(item: String): Int => 2
`).onlyMessage(DiagnosticCode.NoMatchingOverload);
    message.should.contain("show<T: Json>(T) needs `T` to be a `Json`, and `Plain` isn't one");
    message.should.contain("show(String) argument 1 is `Plain`, not `String`");
}

@("a literal doesn't adapt through a bound")
unittest
{
    enum small = `
interface Json { def toJson(value: Self): String }
def toJson(x: UInt8): String => "u8"
def encode<T: Json>(item: T): String => toJson(item)
`;
    analyzedModule(small ~ "def f(): String => toJson(1) ~ encode<UInt8>(1)").shouldHaveNoDiagnostics();
    analyzedModule(small ~ "def f(): String => encode(1)").onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.startWith("`encode` needs `T` to be a `Json`, and `Int` isn't one");
}

@("the current module's function comes before an imported one, and a bound finds the one a call does")
unittest
{
    enum lib = "module lib\ninterface Json { def toJson(value: Self): String }\ntype Foo(id: Int)\n"
        ~ "def toJson(f: Foo): String => \"lib\"\ndef toJson<T: Json>(x: T?): String => \"option\"\n"
        ~ "def encode<T: Json>(item: T): String => toJson(item)\n";
    analyzed("import lib\ndef toJson(f: Foo): String => \"mine\"\ndef main(): Unit {\n    val a = encode(Foo(1))\n}", ["lib.ag": lib])
        .shouldHaveNoDiagnostics();
    analyzed("import lib\ndef main(): Unit {\n    val a = encode(Foo(1))\n    val b = encode(Some(Foo(1)))\n}", ["lib.ag": lib])
        .shouldHaveNoDiagnostics();
}

@("only what the caller's module sees is searched, and the error says what to import")
unittest
{
    enum json = "module json\ninterface Json { def toJson(value: Self): String }\ndef encode<T: Json>(item: T): String => toJson(item)\n";
    enum foo = "module foo\ntype Foo(id: Int)\ndef toJson(f: Foo): String => \"foo\"\n";
    analyzed("import json\nimport foo\ndef main(): Unit {\n    val a = encode(Foo(1))\n}", ["json.ag": json, "foo.ag": foo])
        .shouldHaveNoDiagnostics();
    auto message = analyzed("import json\nimport foo : Foo\ndef main(): Unit {\n    val a = encode(Foo(1))\n}",
        ["json.ag": json, "foo.ag": foo]).onlyMessage(DiagnosticCode.UnsatisfiedBound);
    message.should.contain("no `toJson` in scope takes `Foo`");
    message.should.contain("`foo` has a `toJson(Foo)` that would fit; import it to use that one");
}

@("two imported modules that fit a bound equally well are an error")
unittest
{
    enum json = "module json\ninterface Json { def toJson(value: Self): String }\ndef encode<T: Json>(item: T): String => toJson(item)\n";
    enum foo = "module foo\ntype Foo(id: Int)\n";
    enum one = "module one\nimport foo\ndef toJson(f: Foo): String => \"one\"\n";
    enum two = "module two\nimport foo\ndef toJson(f: Foo): String => \"two\"\n";
    auto files = ["json.ag": json, "foo.ag": foo, "one.ag": one, "two.ag": two];
    analyzed("import json\nimport foo\nimport one\nimport two\ndef main(): Unit {\n    val a = encode(Foo(1))\n}", files)
        .onlyMessage(DiagnosticCode.UnsatisfiedBound).should.contain("a `toJson` in more than one imported module (one, two) takes `Foo`");
    analyzed("import json\nimport foo\nimport one\nimport two\ndef toJson(f: Foo): String => one.toJson(f)\n"
        ~ "def main(): Unit {\n    val a = encode(Foo(1))\n}", files).shouldHaveNoDiagnostics();
}

@("a search that keeps needing a larger type stops with an error of its own")
unittest
{
    analyzedModule(`
interface Grow { def grow(value: Self): Int }
interface Next<U> { def step(value: Self): U }
type Wrap<T>(value: T)
def step<T>(x: T): Wrap<T> => Wrap(x)
def grow<T: Next<U>, U: Grow>(x: T): Int => 1
def needsGrow<T: Grow>(x: T): Int => 1
def f(): Int => needsGrow(1)`).onlyMessage(DiagnosticCode.BoundSearchTooDeep).should.contain("`Int: Grow`, then `Wrap<Int>: Grow`");
}

// Interface parameters

@("a parameter that's only in a result is what the function found returns")
unittest
{
    auto a = analyzedWith(`
    val ints = toArray([1, 2])
    val strings = toArray(["a"])
    val sum = total([1, 2])`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("ints", 1), "[Int]");
    a.shouldDeclareType(At("strings", 1), "[String]");
    analyzedWith(`val a = total(["a"])`).onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.equal("`total` needs a `Range<Int>`, and `[String]` isn't one: `next<T>([T])` returns `(String, [String])?`, "
            ~ "where `(Int, [String])?` is needed");
}

@("a bound is solved before lambdas, so a lambda's parameter is known from it")
unittest
{
    auto a = analyzedWith("val flags = [1, 2].map(element => element > 1)");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("flags", 1), "[Bool]");
}

@("a parameter in an argument takes part in choosing the function")
unittest
{
    auto a = analyzedWith(`
    val a = plus(Vec(1.0), Vec(2.0))
    val b = plus(Vec(1.0), 2.0)`);
    a.shouldHaveNoDiagnostics();
    analyzedWith(`val a = plus(Vec(1.0), "a")`).onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.startWith("`plus` needs `T` to be an `Add<String>`, and `Vec` isn't one: no `add` in scope takes `(Vec, String)`");
}

@("an unknown parameter is bound by the one function that fits what's known")
unittest
{
    auto a = analyzedWith("val a = scale(Shift(1), s => 2)", `
type Shift(by: Int)
def add(a: Shift, b: Int): Shift => a
def scale<T: Add<R>, R>(a: T, f: (T) -> R): T => add(a, f(a))
`);
    a.shouldHaveNoDiagnostics();
    // With two functions the lambda has to say, since neither is chosen by half a call.
    auto b = analyzedWith("val a = scale(Vec(1.0), (v: Vec) => 2.0)", "def scale<T: Add<R>, R>(a: T, f: (T) -> R): T => add(a, f(a))\n");
    b.shouldHaveNoDiagnostics();
}

@("Self only in a result goes through a marker parameter")
unittest
{
    auto a = analyzedWith(`
    val parsed = fromText<Point>("x")
    val number: Int? = fromText("1")`, `
interface FromText { def fromText(of: Of<Self>, text: String): Self? }
def fromText(of: Of<Point>, text: String): Point? => None
def fromText(of: Of<Int>, text: String): Int? => None
def fromText<T: FromText>(text: String): T? => fromText(Of<T>, text)
`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("parsed", 1), "Point?");
}

// An interface name as a parameter type

@("an interface-typed parameter takes any type that conforms, and isn't a type argument")
unittest
{
    auto a = analyzedWith(`
    val a = toArray<Int>([1])
    val b = [1].toArray()
    val f: ([Int]) -> [Int] = toArray`);
    a.shouldHaveNoDiagnostics();
    analyzedWith("val a = toArray<Int, [Int]>([1])").shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("toArray", 2));
    analyzedWith("val a = total<Int>([1])").shouldReport(DiagnosticCode.WrongTypeArgumentCount, At("total", 2));
    analyzedWith("val a = toArray<String>([1])").onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.startWith("`toArray` needs a `Range<String>`, and `[Int]` isn't one");
}

@("an interface-typed parameter's argument needs a type of its own")
unittest
{
    analyzedWith("val a = total([])").onlyMessage(DiagnosticCode.UntypedEmptyArray).should.startWith("This `[]` has no type to take here");
    analyzedWith("val f = toArray").onlyMessage(DiagnosticCode.CannotInferTypeArgument)
        .should.startWith("`toArray` takes any `Range<T>`, so as a value it needs a function type to say which");
}

private enum ranges = "interface Range<T> { def next(range: Self): (T, Self)? }
interface Sized { def length(value: Self): Int }
def next<T>(items: [T]): (T, [T])? => None
type Box<T>(value: T)
";

@("an interface as a result type is the body's type, which has to satisfy it")
unittest
{
    auto generic = analyzedModule(ranges ~ "def f<R: Range<Int>>(r: R): Range<Int> => r");
    generic.shouldHaveNoDiagnostics();
    generic.shouldDeclareType(At("f", 1), "(R) -> R");
    auto joined = analyzedModule(ranges ~ "def f(xs: [Int]): Range<Int> & Sized => xs");
    joined.shouldHaveNoDiagnostics();
    joined.shouldDeclareType(At("f", 1), "([Int]) -> [Int]");
    auto sugared = analyzedModule(ranges ~ "def f<T>(xs: Range<T>): Range<T> => xs");
    sugared.shouldHaveNoDiagnostics();
    sugared.shouldDeclareType(At("f", 1), "(Range<T>) -> Range<T>");

    analyzedModule(ranges ~ "def f(xs: [Int]): Range<Int> => 1").shouldReport(DiagnosticCode.UnsatisfiedBound, At("Range", 2));
    analyzedModule(ranges ~ "def f(xs: [String]): Range<Int> => xs").shouldReport(DiagnosticCode.UnsatisfiedBound, At("Range", 2));
    analyzedModule(ranges ~ "def f(xs: [Int]): Range<Int> & Sized => Box(xs)")
        .shouldReport(DiagnosticCode.UnsatisfiedBound, At("Range", 2));
    analyzedModule(ranges ~ "def f(c: Bool, xs: [Int]): Range<Int> => if c => xs else Box(xs)")
        .shouldReport(DiagnosticCode.TypeMismatch, At("if", 1));
    analyzedModule(ranges ~ "def f(): Range<Int> => panic(\"no\")").shouldReport(DiagnosticCode.TypeMismatch, At("panic", 1));
}

@("a caller sees the type a floor stands for, whichever of the two is checked first")
unittest
{
    auto a = analyzedModule(ranges ~ "def early(): Int => length(late([1]))
def late(xs: [Int]): Range<Int> => xs
def value(): ([Int]) -> [Int] => late
def chosen(): ([Int]) -> [Int] => over
def over(xs: [Int]): Range<Int> => xs
def over(n: Int): Int => n");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("late([1])", "[Int]");
}

@("a floor can be inside a tuple, an option, an array or a type argument, and nowhere else")
unittest
{
    auto a = analyzedModule(ranges ~ "def pair(xs: [Int]): (Int, Range<Int>)? => (1, xs)
def boxed(xs: [Int]): Box<Range<Int>> => Box(xs)
def each(xs: [Int]): [Range<Int>] => [xs]
def rows(xs: [Int]): Range<Range<Int>> => [xs]
def maybe(xs: [Int]): Range<Int>? => xs");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("pair", 1), "([Int]) -> (Int, [Int])?");
    a.shouldDeclareType(At("boxed", 1), "([Int]) -> Box<[Int]>");
    a.shouldDeclareType(At("each", 1), "([Int]) -> [[Int]]");
    a.shouldDeclareType(At("rows", 1), "([Int]) -> [[Int]]");
    a.shouldDeclareType(At("maybe", 1), "([Int]) -> [Int]?");

    analyzedModule(ranges ~ "def f(xs: [Int]): Range<Range<String>> => [xs]")
        .shouldReport(DiagnosticCode.UnsatisfiedBound, At("Range", 3));
    analyzedModule(ranges ~ "def f(xs: [Int]): (Int, Range<Int>) => xs").shouldReport(DiagnosticCode.TypeMismatch, At("xs", 2));
    analyzedModule(ranges ~ "def f(): () -> Range<Int> => () => [1]").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(): (Int, Range<Int> ! String) => (1, [1])")
        .shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(): [Int] ! Range<Int> => [1]").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "native def f(): Range<Int>").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "val top: Range<Int> = 1").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "val top: Range<Int> & Sized = 1").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(): Unit {\n    val (a: Range<Int>, b) = ([1], 2)\n}")
        .shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "interface Source { def items(s: Self): Range<Int> }")
        .shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(xs: [Int]): Range<Int> & Int => xs").shouldReport(DiagnosticCode.NotAnInterface, At("Int", 4));
    analyzedModule(ranges ~ "def f(xs: [Range<Int> & Sized]): Int => 1").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "type Holder(items: Range<Int> & Sized)").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(xs: [Int]): Range<Int> & Range<Int> => xs").shouldReport(DiagnosticCode.InvalidBound, At("Range", 3));
}

@("a type argument of a part of A & B is a floor's place too")
unittest
{
    auto a = analyzedModule(ranges ~ "def rows(xs: [Int]): Range<Range<Int>> & Sized => [xs]
def f(): Unit {
    val grid: Range<Range<Int>> & Sized = [[1]]
}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("rows", 1), "([Int]) -> [[Int]]");
    a.shouldDeclareType(At("grid", 1), "[[Int]]");
}

@("A & B as a parameter's whole type is a hidden type parameter with both bounds")
unittest
{
    auto a = analyzedModule(ranges ~ "def size(xs: Range<Int> & Sized): Int => length(xs)
def use(): Int => size([1])");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("size", 1), "(Range<Int> & Sized) -> Int");
    analyzedModule(ranges ~ "def size(xs: Range<Int> & Sized): Int => 1\ndef use(): Int => size(Box([1]))")
        .shouldReport(DiagnosticCode.UnsatisfiedBound, At("size", 2));
    analyzedModule(ranges ~ "def f(): Unit {\n    val g = (xs: Range<Int> & Sized) => 1\n}")
        .shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
}

private enum failing = ranges ~ "type Missing\ntype Other\ndef find(xs: [Int]): [Int] ! Missing => xs\n";

@("a floor can be the success side of an error union that's the whole type")
unittest
{
    auto a = analyzedModule(failing ~ "def passed(xs: [Int]): Range<Int> ! Missing {
    val found = find(xs)?
    found
}
def direct(xs: [Int]): Range<Int> ! Missing | Other => find(xs)
def either(xs: [Int]): Range<Int> & Sized ! Other {
    if length(xs) == 0 { return Error(Other) }
    xs
}
def option(xs: [Int]): Range<Int>? ! Missing {
    if length(xs) == 0 { return None }
    find(xs)?
}
def f(): Unit {
    val kept: Range<Int> ! Missing = find([1])
    val plain: Range<Int> ! Missing = [1]
    val lambda = (xs: [Int]): Range<Int> ! Missing => find(xs)?
}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("passed", 1), "([Int]) -> [Int] ! Missing");
    a.shouldDeclareType(At("direct", 1), "([Int]) -> [Int] ! Missing | Other");
    a.shouldDeclareType(At("either", 1), "([Int]) -> [Int] ! Other");
    a.shouldDeclareType(At("option", 1), "([Int]) -> [Int]? ! Missing");
    a.shouldDeclareType(At("kept", 1), "[Int] ! Missing");
    a.shouldDeclareType(At("plain", 1), "[Int] ! Missing");

    // With no errors written, the error says where they go.
    analyzedModule(failing ~ "def f(xs: [Int]): Range<Int> => find(xs)?").onlyMessage(DiagnosticCode.InvalidPropagation)
        .should.equal("This `?` passes on `Missing`, so the function returns an error union; write the errors after the "
            ~ "result type, as in `Range<Int> ! Missing`");
    analyzedModule(failing ~ "def f(xs: [Int]): Range<Int> ! Other => find(xs)?")
        .shouldReport(DiagnosticCode.InvalidPropagation, At("find(xs)?", 1));
    analyzedModule(failing ~ "def f(xs: [Int]): Range<Int> ! Other => find(xs)").shouldReport(DiagnosticCode.TypeMismatch, At("find(xs)", 1));
    analyzedModule(failing ~ "def f(xs: [Int]): Range<Int> ! Other => Error(Missing)")
        .shouldReport(DiagnosticCode.TypeMismatch, At("Missing", 3));
    analyzedModule(failing ~ "def f(xs: [Int]): Range<Int> ! Other => Error(Other)").onlyMessage(DiagnosticCode.TypeMismatch)
        .should.equal("`f` returns only errors, so nothing gives the type `Range<Int>` stands for; write the type out");
    analyzedModule(failing ~ "def f(): Unit {
    val x: Range<Int> ! Other = Error(Other)
}").onlyMessage(DiagnosticCode.TypeMismatch)
        .should.startWith("`x` is only an error, so nothing gives the type `Range<Int>` stands for");
    analyzedModule(failing ~ "def f(xs: [Int]?): Range<Int> ! Other => xs?").shouldReport(DiagnosticCode.InvalidPropagation, At("xs?", 1));
    analyzedModule(failing ~ "def f(xs: [Int]): Range<Int> ! Other => 1").shouldReport(DiagnosticCode.UnsatisfiedBound, At("Range", 2));
}

@("what's beside a floor in an error union is checked against the errors as written")
unittest
{
    auto a = analyzedModule(failing ~ "def whole(xs: [Int]): Range<Int> ! Missing => Ok(xs)
def arms(xs: [Int]): Range<Int> ! Missing | Other => match length(xs) {
    0 => Error(Missing)
    1 => Error(Other)
    _ => xs
}
def either(xs: [Int], first: Bool): Range<Int> ! Missing | Other => if first => find(xs) else Error(Other)
def adapted(xs: [Int]): Range<Int> ! Float {
    if length(xs) == 0 { return Error(23) }
    Ok(xs)
}
def f(): Unit {
    val kept: Range<Int> ! Float = if length([1]) == 0 => Error(2) else Ok([7])
}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("whole", 1), "([Int]) -> [Int] ! Missing");
    a.shouldDeclareType(At("arms", 1), "([Int]) -> [Int] ! Missing | Other");
    a.shouldDeclareType(At("either", 1), "([Int], Bool) -> [Int] ! Missing | Other");
    a.shouldDeclareType(At("adapted", 1), "([Int]) -> [Int] ! Float");
    a.shouldDeclareType(At("kept", 1), "[Int] ! Float");

    analyzedModule(failing ~ "def f(xs: [Int], c: Bool): Range<Int> ! Other => if c => find(xs) else xs")
        .shouldReport(DiagnosticCode.TypeMismatch, At("find(xs)", 1));
}

@("a floor's place that isn't one says why where it's written, once")
unittest
{
    analyzedModule(ranges ~ "native def f(xs: Range<Int> & Sized): Int").onlyMessage(DiagnosticCode.InterfaceIsNotAType)
        .should.startWith("`Range<Int> & Sized` joins interfaces, and only a module-level `def` with a body can take");
    analyzedModule(ranges ~ "native def f(xs: Sized): Int").onlyMessage(DiagnosticCode.InterfaceIsNotAType)
        .should.startWith("`Sized` is an interface, and only a module-level `def` with a body can take");
    analyzedModule(ranges ~ "interface Zip { def zip(a: Self, b: Range<Int> & Sized): Int }").onlyMessage(DiagnosticCode.InterfaceIsNotAType)
        .should.startWith("`Range<Int> & Sized` joins interfaces, and a function of an interface can't take");
    analyzedModule(ranges ~ "def f(xs: [Int]): Range<Int> & Sized? => xs").onlyMessage(DiagnosticCode.NotAnInterface)
        .should.endWith("write `(Range<Int> & Sized)?`");

    // A private type that's written is reported where it's written, and not again for the result.
    analyzedModule(ranges ~ "private type Inner(n: Int)
def f(n: Int): Range<Box<Inner>> => [Box(Inner(n))]")
        .onlyMessage(DiagnosticCode.PrivateTypeExposed).should.equal("`Inner` is private, so it can't appear in a public function's signature");
}

@("a public function can't return a private type through a floor")
unittest
{
    enum steps = ranges ~ "private type Steps(n: Int)\nprivate def next(s: Steps): (Int, Steps)? => None\n";
    analyzedModule(steps ~ "def f(): Range<Int> => Steps(1)").onlyMessage(DiagnosticCode.PrivateTypeExposed)
        .should.equal("`Steps` is private, so it can't appear in a public function's signature, and `f` returns `Steps`; "
            ~ "make `f` private or `Steps` public");
    analyzedModule(steps ~ "def f(): (Int, Range<Int>)? => (1, Steps(1))").onlyMessage(DiagnosticCode.PrivateTypeExposed)
        .should.startWith("`Steps` is private, so it can't appear in a public function's signature, and `f` returns `(Int, Steps)?`");
    analyzedModule(steps ~ "def f(): Box<Range<Int>> => Box(Steps(1))").shouldReport(DiagnosticCode.PrivateTypeExposed, At("Box", 2));
    analyzedModule(steps ~ "private def f(): Range<Int> => Steps(1)\ndef g(): Unit {\n    val s: Range<Int> = f()\n}")
        .shouldHaveNoDiagnostics();
}

@("an error about a floor is the only one, and says something that can be done")
unittest
{
    // The function a bound finds is the one being worked out.
    analyzedModule(ranges ~ "interface Source<R> { def contents(s: Self): R }
def pull<S: Source<R>, R>(s: S): R => contents(s)
def contents(b: Box<Int>): Range<Int> => pull(b)").shouldReport(DiagnosticCode.RecursiveResultType, At("Range", 2));

    // Its own type isn't known inside its body, so the example is another's.
    analyzedModule(ranges ~ "def over(b: Box<Int>): Range<Int> {
    val f = over
    [1]
}
def over(xs: [Int]): Range<Int> => xs").onlyMessage(DiagnosticCode.AmbiguousOverload)
        .should.equal("`over` is overloaded, so as a value it needs a function type to choose by, as in `val f: ([Int]) -> [Int] = over`");

    analyzedModule(ranges ~ "def f(): Unit {\n    mutable val x: (Int, Range<Int>)?\n}").onlyMessage(DiagnosticCode.TypeMismatch)
        .should.equal("`x` is `None`, which doesn't say what type `Range<Int>` stands for in `(Int, Range<Int>)?`; write the type out");
    analyzedModule(ranges ~ "def f(): Range<Int> => []").onlyMessage(DiagnosticCode.TypeMismatch)
        .should.equal("`f` returns `[]`, which doesn't say what type `Range<Int>` stands for; write the type out");

    // A literal beside a floor has its default type.
    analyzedModule(ranges ~ "def f(): Unit {\n    val a: Range<Float> = [1, 2]\n}").onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.endWith("write it as the type that's meant, as in `1.0` or `Float(1)`");
    analyzedModule(ranges ~ "def f(xs: [Int]): (Float, Range<Int>) => (1, xs)").onlyMessage(DiagnosticCode.TypeMismatch)
        .should.startWith("`f` returns `(Int, [Int])`, where `(Float, Range<Int>)` is written");
}

@("a floored function's body is checked as a body whatever needed its result first")
unittest
{
    // An invariant's `else` reaches `pick`, whose body builds a type whose `else` comes later.
    enum pick = "\ndef pick(xs: [Int]): Range<Int> {\n    val built = Even(2)\n    val maker = Even\n    xs\n}";
    enum small = "type Small(n: Int) invariant n < 10 else Bad(pick([n])[0])\n";
    enum even = "type Even(n: Int) invariant n % 2 == 0 else Bad(n)\n";
    foreach (order; [small ~ even, even ~ small])
    {
        auto a = analyzedModule(ranges ~ "type Bad(n: Int)\n" ~ order ~ pick);
        a.shouldHaveNoDiagnostics();
        a.shouldDeclareType(At("built", 1), "Even ! Bad");
        a.shouldDeclareType(At("maker", 1), "(Int) -> Even ! Bad");
    }
    // One that leads back to its own type has nothing to go on.
    analyzedModule(ranges ~ "type Bad(n: Int)\n" ~ small ~ "def pick(xs: [Int]): Range<Int> {\n    val s = Small(1)\n    xs\n}")
        .shouldReport(DiagnosticCode.NotSupportedYet, At("Small(1)", 1));
    analyzedModule(ranges ~ "type Bad(n: Int)
" ~ small ~ "def pick(xs: [Int]): Range<Int> {
    val build = Small
    xs
}")
        .onlyMessage(DiagnosticCode.NotSupportedYet).should.endWith("that `else` leads to `pick`, whose result type is worked out "
            ~ "from this body; write the type `pick` returns in place of `Range<Int>`, so the `else` doesn't need its body");
    analyzedModule(ranges ~ "type Bad(n: Int)
" ~ small ~ "def pick(xs: [Int]): [Int] {
    val s = Small(1)
    xs
}")
        .shouldHaveNoDiagnostics();

    // A test's body allows `expect`, and a function it needs the result of still doesn't.
    analyzed(ranges ~ "test \"t\" {\n    val r = helper([1])\n}\ndef helper(xs: [Int]): Range<Int> {\n    expect(true)\n    xs\n}",
        null, Target.host, true).shouldReport(DiagnosticCode.ExpectOutsideTest, At("expect(true)", 1));
}

@("a nested def that needs its own result is reported once, from a lambda inside it too")
unittest
{
    analyzedModule(ranges ~ "def f(): Unit {
    def walk(n: Int): Range<Int> {
        val again = () => walk(n - 1)
        val more = walk(n - 2)
        [n]
    }
}").shouldReport(DiagnosticCode.RecursiveResultType, At("Range", 2));
    // An enclosing one that's still being worked out, used from the one inside it.
    analyzedModule(ranges ~ "def f(): Unit {
    def outer(n: Int): Range<Int> {
        def inner(m: Int): Range<Int> => outer(m)
        [n]
    }
}").shouldReport(DiagnosticCode.RecursiveResultType, At("Range", 2));
}

@("a function whose result type is a floor can't need its own result")
unittest
{
    analyzedModule(ranges ~ "def f(n: Int): Range<Int> => if n == 0 => [0] else f(n - 1)")
        .shouldReport(DiagnosticCode.RecursiveResultType, At("Range", 2));
    analyzedModule(ranges ~ "def f(n: Int): Range<Int> => g(n)\ndef g(n: Int): Range<Int> => f(n)")
        .shouldReport(DiagnosticCode.RecursiveResultType, At("Range", 2));
    analyzedModule(ranges ~ "def f(): Unit {\n    def g(n: Int): Range<Int> => if n == 0 => [0] else g(n - 1)\n}")
        .shouldReport(DiagnosticCode.RecursiveResultType, At("Range", 2));
    // Another function of the same name isn't the function itself.
    analyzedModule(ranges ~ "def first(b: Box<[Int]>): Range<Int> => first(b.value)\ndef first(xs: [Int]): [Int] => xs")
        .shouldHaveNoDiagnostics();
}

@("an interface on a val, or as a lambda's or nested def's result, is a floor too")
unittest
{
    auto a = analyzedModule(ranges ~ "def f(): Unit {
    val whole: Range<Int> = [1]
    val inside: (Int, Range<Int> & Sized)? = (1, [2])
    mutable val changed: Range<Int> = [3]
    changed = [4]
    def nested(xs: [Int]): Range<Int> => xs
    val lambda = (xs: [Int]): Range<Int> => xs
    val n = whole[0] + nested([5])[0] + lambda([6])[0]
}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("whole", 1), "[Int]");
    a.shouldDeclareType(At("inside", 1), "(Int, [Int])?");
    a.shouldDeclareType(At("nested", 1), "([Int]) -> [Int]");

    analyzedModule(ranges ~ "def f(): Unit {\n    val x: Range<Int> = 1\n}").shouldReport(DiagnosticCode.UnsatisfiedBound, At("Range", 2));
    analyzedModule(ranges ~ "def f(): Unit {\n    mutable val x: Range<Int> = [1]\n    x = Box([2])\n}")
        .shouldReport(DiagnosticCode.TypeMismatch, At("Box", 2));
    analyzedModule(ranges ~ "def f(): Unit {\n    val g: (Int) -> Range<Int> = (n: Int) => [n]\n}")
        .shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(): Unit {\n    val g = (n: Int): Range<Int> => n\n}")
        .shouldReport(DiagnosticCode.UnsatisfiedBound, At("Range", 2));
}

// Capability queries

/// What the function declared at `declaration` asks of its callers.
private const(Query)[] queriesAt(const Analyzed a, At declaration)
{
    import std.sumtype : match;
    auto symbol = declaration.offsetIn(a) in a.names[declaration.moduleName].declarations;
    assert(symbol !is null, declaration.toString ~ " isn't a declaration");
    return (*symbol).match!((const Id!FunctionDecl f) => a.analysis.queriesOf(f), _ => (const(Query)[]).init);
}

@("a generic function asks what a more demanding overload it calls needs, and its callers ask it in turn")
unittest
{
    auto a = analyzed("interface Sized { def size(x: Self): Int }
def count<T>(x: T): String => \"any\"
def count<T: Sized>(x: T): String => \"sized\"
def busy<T>(x: T): String => count(x)
def outer<U>(x: U): String => busy(x)
def known<V: Sized>(x: V): String => count(x)
def boxed<W>(x: W): String => count([x])
def main(): Unit => ()");
    a.shouldHaveNoDiagnostics();
    a.queriesAt(At("busy", 1)).length.should.equal(1);
    a.queriesAt(At("outer", 1)).length.should.equal(1);
    // Its bound answers the question where the call is written.
    a.queriesAt(At("known", 1)).length.should.equal(0);
    // Whether a `[W]` is `Sized` is settled where the call is written: nothing says it is.
    a.queriesAt(At("boxed", 1)).length.should.equal(0);
    a.queriesAt(At("count", 1)).length.should.equal(0);
}

@("a function asking more that returns another type isn't asked about inside a generic function")
unittest
{
    auto a = analyzed("interface Sized { def size(x: Self): Int }
def count<T>(x: T): String => \"any\"
def count<T: Sized>(x: T): Int => 1
def busy<T>(x: T): String => count(x)
def main(): Unit => ()");
    a.shouldHaveNoDiagnostics();
    a.queriesAt(At("busy", 1)).length.should.equal(0);
}
