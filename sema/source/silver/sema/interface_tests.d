/// Tests of interfaces: their declarations, bounds, what a bound supplies inside a generic function,
/// and how a use finds the functions that make its type arguments conform.
module silver.sema.interface_tests;

version (unittest):

import fluent.asserts;

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType, shouldHaveType;
import silver.sema.resolution_tests;

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

@("an interface is a type only as the whole type of a module-level def's parameter")
unittest
{
    enum json = "interface Json { def toJson(value: Self): String }\n";
    analyzedModule(json ~ "def f(x: Json): String => toJson(x)").shouldHaveNoDiagnostics();
    analyzedModule(json ~ "def f(xs: [Json]): Int => 1").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "def f(x: Json?): Int => 1").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "def f(x: Int): Json => x").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "type Holder(item: Json)").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "alias J = Json").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
    analyzedModule(json ~ "def f(): Unit {\n    val x: Json = 1\n}").shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Json", 2));
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

@("two functions that differ only in their bounds are duplicates")
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
type Shape = Circle | Square
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
        .should.startWith("`plus` needs `T` to be a `Add<String>`, and `Vec` isn't one: no `add` in scope takes `(Vec, String)`");
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
