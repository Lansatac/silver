/// Tests of interfaces: their declarations, bounds, what a bound supplies inside a generic function,
/// and how a use finds the functions that make its type arguments conform.
module silver.sema.interface_tests;

version (unittest):

import fluent.asserts;
import std.algorithm : map;
import std.array : array;

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType, shouldHaveType;
import silver.sema.resolution_tests;
import silver.sema.target : Target;

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

/// The conformances of the declarations above. They come after everything else, so a test's
/// `At` counts occurrences from the declarations as written.
private enum declared = "\nconform Int: Json\nconform Point: Json\nconform Box<T>: Json when T: Json\nconform T?: Json when T: Json\n"
    ~ "conform [T]: Range<T>\nconform Vec: Add<Vec> & Add<Float>";

/// `body` in `main`, after the declarations above.
private Analyzed analyzedWith(string body, string more = "")
{
    return analyzed(declarations ~ more ~ "def main(): Unit {\n" ~ body ~ "\n}" ~ declared);
}

/// `source` at module level, with an empty `main`, and the conformances of `ranges` when it
/// starts with those.
private Analyzed analyzedModule(string source)
{
    import std.algorithm : startsWith;
    auto conforming = source.startsWith(ranges) ? "\nconform [T]: Range<T> & Sized" : "";
    return analyzed(source ~ "\ndef main(): Unit => ()" ~ conforming);
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

@("two functions with the same parameter types are duplicates, whatever their bounds")
unittest
{
    enum interfaces = `
interface A { def a(x: Self): Int }
interface B { def b(x: Self): Int }
interface Range<T> { def next(range: Self): (T, Self)? }
`;
    analyzedModule(interfaces ~ "def f<T: A>(x: T): Int => 1\ndef f<T: A & B>(x: T): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedModule(interfaces ~ "def f<T>(x: T): Int => 0\ndef f<T: A>(x: T): Int => 1")
        .onlyMessage(DiagnosticCode.DuplicateOverload).should.contain("whatever their bounds");
    analyzedModule(interfaces ~ "def f<T: A>(x: T): Int => 1\ndef f<T: B>(x: T): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedModule(interfaces ~ "def f(x: A): Int => 1\ndef f<T: A & B>(x: T): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedModule(interfaces ~ "def f(x: A): Int => 1\ndef f(x: B): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    analyzedModule(interfaces ~ "def f<R: Range<Int>>(x: R): Int => 1\ndef f<R: Range<String>>(x: R): Int => 2")
        .shouldReport(DiagnosticCode.DuplicateOverload, At("f", 2));
    // Parameter types still tell them apart.
    analyzedModule(interfaces ~ "def f<T: A>(x: T): Int => 1\ndef f<T: A>(x: [T]): Int => 2").shouldHaveNoDiagnostics();
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

@("for steps a value of a type parameter with the next its Range bound supplies")
unittest
{
    enum loop = " {\n    mutable val n = 0\n    for item in range { n += 1 }\n    n\n}";
    analyzedModule("def count<T>(range: Range<T>): Int" ~ loop).shouldHaveNoDiagnostics();
    // An interface with the same function isn't the `Range` a `for` loops over.
    analyzedModule("interface Steps<T> { def next(r: Self): (T, Self)? }\ndef count<R: Steps<Int>>(range: R): Int" ~ loop)
        .onlyMessage(DiagnosticCode.InvalidOperand).should.equal("`for` loops over a `Range` or an `Iterable`, and `R` is neither: nothing `R` is bounded by says it is");
}

// Conformance

@("a type satisfies a bound through its declared conformance, a conditional one too")
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

@("a type with no conformance doesn't satisfy a bound, and the error says when a conform line is all that's missing")
unittest
{
    analyzedWith("val a = encode(Plain(1))").onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.equal("`encode` needs `T` to be a `Json`, and `Plain` isn't one: no conformance says so");
    analyzedWith("val a = encode(Plain(1))", "def toJson(p: Plain): String => \"plain\"\n").onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.equal("`encode` needs `T` to be a `Json`, and `Plain` isn't one: no conformance says so; it has the functions, "
            ~ "so `conform Plain: Json` is all that's missing");
    // A conditional conformance whose `when` doesn't hold.
    analyzedWith("val a = encode(Box(Plain(1)))").onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.equal("`encode` needs `T` to be a `Json`, and `Box<Plain>` isn't one: the conformance for `Box<T>` needs `T` "
            ~ "to be a `Json`, and `Plain` isn't one: no conformance says so");
}

@("a conformance's functions are chosen by their arguments, and the result then has to be the interface's exactly")
unittest
{
    analyzedWith("val a = 1", "def toJson(p: Plain): Int => 1\nconform Plain: Json\n").onlyMessage(DiagnosticCode.UnmetConformance)
        .should.contain("`toJson(Plain)` returns `Int`, where `String` is needed");
    analyzedWith("val a = 1", "def toJson(p: Plain): String? => None\nconform Plain: Json\n").onlyMessage(DiagnosticCode.UnmetConformance)
        .should.contain("`toJson(Plain)` returns `String?`, where `String` is needed");
}

@("a conformance's argument is promoted to fit, as a call's is")
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
conform Circle: HasArea
`).shouldHaveNoDiagnostics();
}

@("a function is chosen by its arguments, whatever its bounds")
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

@("a chosen function whose bound fails is an error at the call, and no other is chosen instead")
unittest
{
    enum put = `
def put<T: Json>(x: T): String => "json"
def put<T>(x: T?): String => "option"
`;
    auto a = analyzedWith("val p = put(Point(1, 2))\n    val s = put(Some(\"text\"))", put);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("put(Point(1, 2))", "String");
    analyzedWith("val t = put(\"text\")", put).onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.contain("needs `T` to be a `Json`, and `String` isn't one");
    analyzedWith("val a = show(Plain(1))", "def show<T: Json>(item: T): Int => 1\ndef show(item: String): Int => 2\n")
        .onlyMessage(DiagnosticCode.UnsatisfiedBound).should.contain("`Plain` isn't one");
}

@("a literal doesn't adapt through a bound")
unittest
{
    enum small = `
interface Json { def toJson(value: Self): String }
def toJson(x: UInt8): String => "u8"
def encode<T: Json>(item: T): String => toJson(item)
conform UInt8: Json
`;
    analyzedModule(small ~ "def f(): String => toJson(1) ~ encode<UInt8>(1)").shouldHaveNoDiagnostics();
    analyzedModule(small ~ "def f(): String => encode(1)").onlyMessage(DiagnosticCode.UnsatisfiedBound)
        .should.startWith("`encode` needs `T` to be a `Json`, and `Int` isn't one");
}

@("a conformance uses the functions where it's declared, whatever the module using it declares or imports")
unittest
{
    enum lib = "module lib\ninterface Json { def toJson(value: Self): String }\ntype Foo(id: Int)\n"
        ~ "def toJson(f: Foo): String => \"lib\"\ndef toJson<T: Json>(x: T?): String => \"option\"\n"
        ~ "def encode<T: Json>(item: T): String => toJson(item)\nconform Foo: Json\nconform T?: Json when T: Json\n";
    analyzed("import lib\ndef toJson(f: Foo): String => \"mine\"\ndef main(): Unit {\n    val a = encode(Foo(1))\n}", ["lib.ag": lib])
        .shouldHaveNoDiagnostics();
    analyzed("import lib : encode, Foo\ndef main(): Unit {\n    val a = encode(Foo(1))\n    val b = encode(Some(Foo(1)))\n}",
        ["lib.ag": lib]).shouldHaveNoDiagnostics();
}

@("a conformance's functions are found where it's declared, and the error says what to import")
unittest
{
    enum json = "module json\ninterface Json { def toJson(value: Self): String }\ndef encode<T: Json>(item: T): String => toJson(item)\n";
    enum foo = "module foo\ntype Foo(id: Int)\ndef toJson(f: Foo): String => \"foo\"\n";
    analyzed("import json\nimport foo\nconform Foo: Json\ndef main(): Unit {\n    val a = encode(Foo(1))\n}",
        ["json.ag": json, "foo.ag": foo]).shouldHaveNoDiagnostics();
    auto message = analyzed("import json\nimport foo : Foo\nconform Foo: Json\ndef main(): Unit => ()",
        ["json.ag": json, "foo.ag": foo]).onlyMessage(DiagnosticCode.UnmetConformance);
    message.should.contain("no `toJson` in scope takes `Foo`");
    message.should.contain("`foo` has a `toJson(Foo)` that would fit; list it in the import of `foo` to use that one");
}

@("two imported modules whose functions fit a conformance equally well are an error at the declaration")
unittest
{
    enum json = "module json\ninterface Json { def toJson(value: Self): String }\ndef encode<T: Json>(item: T): String => toJson(item)\n";
    enum foo = "module foo\ntype Foo(id: Int)\n";
    enum one = "module one\nimport foo\ndef toJson(f: Foo): String => \"one\"\n";
    enum two = "module two\nimport foo\ndef toJson(f: Foo): String => \"two\"\n";
    auto files = ["json.ag": json, "foo.ag": foo, "one.ag": one, "two.ag": two];
    analyzed("import json\nimport foo\nimport one\nimport two\nconform Foo: Json\ndef main(): Unit => ()", files)
        .onlyMessage(DiagnosticCode.UnmetConformance).should.contain("more than one `toJson` takes `Foo` equally well: `one.toJson(Foo)` and `two.toJson(Foo)`; declare one in this module");
    analyzed("import json\nimport foo\nimport one\nimport two\ndef toJson(f: Foo): String => one.toJson(f)\nconform Foo: Json\n"
        ~ "def main(): Unit {\n    val a = encode(Foo(1))\n}", files).shouldHaveNoDiagnostics();
}

@("a conformance that would need itself to find its functions isn't one")
unittest
{
    analyzedModule(`
interface Json { def toJson(value: Self): String }
def toJson<T: Json>(x: T?): String => "option"
conform Int: Json`).onlyMessage(DiagnosticCode.UnmetConformance).should.startWith("`Int` can't be a `Json`");
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
        .should.equal("`total` needs a `Range<Int>`, and `[String]` isn't one: it's a `Range<String>` instead");
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
        .should.equal("`plus` needs `T` to be an `Add<String>`, and `Vec` isn't one: it's an `Add<Vec>` and an `Add<Float>` instead");
}

@("an unknown parameter is bound by the one function that fits what's known")
unittest
{
    auto a = analyzedWith("val a = scale(Shift(1), s => 2)", `
type Shift(by: Int)
def add(a: Shift, b: Int): Shift => a
conform Shift: Add<Int>
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
conform Point: FromText
conform Int: FromText
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
    auto a = analyzedModule(ranges ~ "def rows(xs: [Int]): Range<Range<Int>> & Sized => [xs]");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("rows", 1), "([Int]) -> [[Int]]");
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
    val kept: [Int] ! Missing = find([1])
    val plain: [Int] ! Missing = [1]
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
    val kept: [Int] ! Float = if length([1]) == 0 => Error(2) else Ok([7])
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
    enum steps = ranges ~ "private type Steps(n: Int)\nprivate def next(s: Steps): (Int, Steps)? => None\nconform Steps: Range<Int>\n";
    analyzedModule(steps ~ "def f(): Range<Int> => Steps(1)").onlyMessage(DiagnosticCode.PrivateTypeExposed)
        .should.equal("`Steps` is private, so it can't appear in a public function's signature, and `f` returns `Steps`; "
            ~ "make `f` private or `Steps` public");
    analyzedModule(steps ~ "def f(): (Int, Range<Int>)? => (1, Steps(1))").onlyMessage(DiagnosticCode.PrivateTypeExposed)
        .should.startWith("`Steps` is private, so it can't appear in a public function's signature, and `f` returns `(Int, Steps)?`");
    analyzedModule(steps ~ "def f(): Box<Range<Int>> => Box(Steps(1))").shouldReport(DiagnosticCode.PrivateTypeExposed, At("Box", 2));
    analyzedModule(steps ~ "private def f(): Range<Int> => Steps(1)\ndef g(): Unit {\n    val s = f()\n}")
        .shouldHaveNoDiagnostics();
}

@("an error about a floor is the only one, and says something that can be done")
unittest
{
    // Its own type isn't known inside its body, so the example is another's.
    analyzedModule(ranges ~ "def over(b: Box<Int>): Range<Int> {
    val f = over
    [1]
}
def over(xs: [Int]): Range<Int> => xs").onlyMessage(DiagnosticCode.AmbiguousOverload)
        .should.equal("`over` is overloaded, so as a value it needs a function type to choose by, as in `val f: ([Int]) -> [Int] = over`");

    analyzedModule(ranges ~ "def f(): Range<Int> => []").onlyMessage(DiagnosticCode.TypeMismatch)
        .should.equal("`f` returns `[]`, which doesn't say what type `Range<Int>` stands for; write the type out");

    // A literal beside a floor has its default type.
    analyzedModule(ranges ~ "def f(xs: [Int]): (Float, Range<Int>) => (1, xs)").onlyMessage(DiagnosticCode.TypeMismatch)
        .should.startWith("`f` returns `(Int, [Int])`, where `(Float, Range<Int>)` is written");
}

@("a floored function's body is checked as a body whatever needed its result first")
unittest
{
    // A test's body allows `expect`, and a function it needs the result of still doesn't.
    analyzed(ranges ~ "test \"t\" {\n    val r = helper([1])\n}\ndef helper(xs: [Int]): Range<Int> {\n    expect(true)\n    xs\n}\nconform [T]: Range<T>",
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

@("an interface as a lambda's or nested def's result is a floor, and a val's annotation can't name one")
unittest
{
    auto a = analyzedModule(ranges ~ "def f(): Unit {
    def nested(xs: [Int]): Range<Int> => xs
    val lambda = (xs: [Int]): Range<Int> => xs
    val n = nested([5])[0] + lambda([6])[0]
}");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("nested", 1), "([Int]) -> [Int]");

    analyzedModule(ranges ~ "def f(): Unit {
    val x: Range<Int> = [1]
}")
        .shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(): Unit {
    mutable val x: Range<Int> = [1]
}")
        .shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(): Unit {
    def g(): Unit {
        val x: (Int, Range<Int> & Sized)? = None
    }
}")
        .shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(): Unit {
    val g: (Int) -> Range<Int> = (n: Int) => [n]
}")
        .shouldReport(DiagnosticCode.InterfaceIsNotAType, At("Range", 2));
    analyzedModule(ranges ~ "def f(): Unit {
    val g = (n: Int): Range<Int> => n
}")
        .shouldReport(DiagnosticCode.UnsatisfiedBound, At("Range", 2));
}

@("review: choosing an overload doesn't work out the result of a candidate it doesn't choose")
unittest
{
    // `h(Int)` is chosen; settling `h(Int?)`'s result during the trial reached `f`, still being worked out.
    analyzedModule(ranges ~ "def f(n: Int): Range<Int> {
    val xs: [Int] = h(n)
    xs
}
def h(x: Int): [Int] => [x]
def h(x: Int?): Range<Int> => f(1)").shouldHaveNoDiagnostics();
}

@("review: what the expected type rules out doesn't depend on whether a candidate's result was worked out yet")
unittest
{
    enum gen = "def g<T>(x: T): Range<T> => [x]\n";
    enum plain = "def g(x: Int?): [String] => []\n";
    enum use = "def use(): Unit {\n    val s: [String] = g(1)\n}\n";
    // A trial doesn't work out `g<T>`'s result, and `Range<T>` gives `[String]` nothing to bind, so
    // the expected type never rules it out: it wins on steps either way, and its result is the error.
    analyzedModule(ranges ~ plain ~ gen ~ use).onlyMessage(DiagnosticCode.TypeMismatch);
    analyzedModule(ranges ~ plain ~ use ~ gen).onlyMessage(DiagnosticCode.TypeMismatch);
}

// Declared conformance

private enum conformances = `
interface Json { def toJson(value: Self): String }
interface Sized { def size(value: Self): Int }
interface Indexed<T>: Sized { def at(value: Self, i: Int): T }
type Box<T>(value: T)
type Grid(n: Int)
def toJson(value: Int): String => "int"
def toJson<T: Json>(b: Box<T>): String => toJson(b.value)
def size(g: Grid): Int => g.n
def at(g: Grid, i: Int): Int => i
def size<T: Sized>(b: Box<T>): Int => size(b.value)
def at<T: Indexed<Int>>(b: Box<T>, i: Int): Int => at(b.value, i)
`;

@("a conformance finds each function as a call where it's written would, with exactly the interface's result")
unittest
{
    analyzedModule(conformances ~ "conform Int: Json\nconform Grid: Sized & Indexed<Int>").shouldHaveNoDiagnostics();
    analyzedModule(conformances ~ "conform String: Json").onlyMessage(DiagnosticCode.UnmetConformance)
        .should.startWith("`String` can't be a `Json`: no `toJson` in scope takes `String`");
    analyzedModule(conformances ~ "def size(x: Float): UInt8 => 1\nconform Float: Sized").onlyMessage(DiagnosticCode.UnmetConformance)
        .should.contain("`size(Float)` returns `UInt8`, where `Int` is needed");
}

@("a name in the conforming type that isn't a type is a type parameter the conformance introduces")
unittest
{
    analyzedModule(conformances ~ "conform Int: Json\nconform Box<T>: Json when T: Json").shouldHaveNoDiagnostics();
    analyzedModule(conformances ~ "conform Int: Json\ndef toJson(b: Box<Int>): String => \"\"\nconform Box<Int>: Json")
        .shouldHaveNoDiagnostics();
    // Every type that meets a bound, which the interface's own module can say and no other.
    enum everySized = "def toJson<T: Sized>(x: T): String => \"sized\"\nconform T: Json when T: Sized\n";
    analyzedModule(conformances ~ everySized).shouldHaveNoDiagnostics();
    analyzedModule(conformances ~ "conform T: Ord").onlyMessage(DiagnosticCode.ConformsTypeParameter)
        .should.startWith("`T` isn't a type, so this would conform every type that meets its `when` bounds");
    analyzedModule(conformances ~ everySized ~ "def toJson(g: Grid): String => \"grid\"\nconform Grid: Sized\nconform Grid: Json")
        .onlyMessage(DiagnosticCode.OverlappingConformance).should.startWith("`Grid` conforms to `Json` already, as every `Sized` does");
    analyzedModule(conformances ~ "conform Int: Json\nconform Box<T>: Json when T: Json, U: Json")
        .shouldReport(DiagnosticCode.UnknownWhenParameter, At("U: Json", 1));
    analyzedModule(conformances ~ "conform Int: Json\nconform Box<Int>: Json when Int: Json").onlyMessage(DiagnosticCode.UnknownWhenParameter)
        .should.contain("`Int` is a type");
}

@("the bounds of a function a conformance finds have to follow from its when clause")
unittest
{
    analyzedModule(conformances ~ "conform Int: Json\nconform Box<T>: Json").onlyMessage(DiagnosticCode.UnmetConformance)
        .should.contain("needs `T` to be a `Json`, and `T` isn't one");
}

@("conforming to an interface needs a conformance to each one it requires, which when bounds can give")
unittest
{
    analyzedModule(conformances ~ "conform Grid: Indexed<Int>").onlyMessage(DiagnosticCode.MissingRequiredConformance)
        .should.equal("`Indexed<Int>` requires a `Sized`, and no conformance makes `Grid` one; declare it too, on this line or another");
    // On another line, before or after.
    analyzedModule(conformances ~ "conform Grid: Indexed<Int>\nconform Grid: Sized").shouldHaveNoDiagnostics();
    analyzedModule(conformances ~ "conform Grid: Sized & Indexed<Int>\nconform Box<T>: Indexed<Int> when T: Indexed<Int>\n"
        ~ "conform Box<T>: Sized when T: Sized").shouldHaveNoDiagnostics();
    analyzedModule(conformances ~ "conform Grid: Sized & Indexed<Int>\nconform Box<T>: Indexed<Int> when T: Indexed<Int>")
        .shouldReport(DiagnosticCode.MissingRequiredConformance, At("Indexed<Int> when", 1));
}

@("a bound on an interface supplies the functions of those it requires")
unittest
{
    analyzedModule(conformances ~ "def last<R: Indexed<T>, T>(r: R): T => at(r, size(r) - 1)\n"
        ~ "def both<R: Indexed<Int> & Sized>(r: R): Int => size(r)").shouldHaveNoDiagnostics();
}

@("an interface can't require itself, directly or through others")
unittest
{
    analyzedModule("interface A: A { def a(x: Self): Int }").onlyMessage(DiagnosticCode.RequiresItself)
        .should.equal("`A` requires itself");
    analyzedModule("interface A: B { def a(x: Self): Int }\ninterface B: A { def b(x: Self): Int }")
        .collector.diagnostics.map!(d => d.message).array.should.equal(["`A` requires itself, through `B`", "`B` requires itself, through `A`"]);
}

@("two conformances that could apply to the same type and interface are an error, wherever they are")
unittest
{
    analyzedModule(conformances ~ "conform Int: Json\nconform Int: Json").onlyMessage(DiagnosticCode.OverlappingConformance)
        .should.equal("`Int` already conforms to `Json`; a type has one conformance to an interface");
    analyzedModule(conformances ~ "def toJson<T: Json>(xs: [T]): String => \"\"\nconform Int: Json\nconform [T]: Json when T: Json\n"
        ~ "conform [Int]: Json").onlyMessage(DiagnosticCode.OverlappingConformance)
        .should.contain("this conformance would apply to `[Int]` too");
    // A type argument in a parameter of the interface's functions says what a conformance is for.
    analyzedModule("interface Add<Rhs> { def add(a: Self, b: Rhs): Self }\ntype Vec(x: Float)\n"
        ~ "def add(a: Vec, b: Vec): Vec => a\ndef add(a: Vec, b: Float): Vec => a\nconform Vec: Add<Vec> & Add<Float>")
        .shouldHaveNoDiagnostics();
    auto files = ["lib.ag": "module lib\ninterface Measured { def size(value: Self): Int }\ntype Grid(n: Int)\n"
        ~ "def size(g: Grid): Int => g.n\nconform Grid: Measured"];
    analyzed("import lib\nconform Grid: Measured\ndef main(): Unit => ()", files).onlyMessage(DiagnosticCode.OverlappingConformance)
        .should.equal("`Grid` already conforms to `Measured` in `lib`; a type has one conformance to an interface");
}
