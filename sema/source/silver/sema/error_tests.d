/// Tests of error unions: their types and lists, promotion and widening, `Ok` and `Error`, the
/// operators that take them apart, and what's rejected.
module silver.sema.error_tests;

version (unittest):

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType, shouldHaveType;
import silver.sema.resolution_tests;

private enum declarations = `
type Negative
type Overflow
type Empty
type ParseError = Blank | BadDigit(at: Int)
type Missing(key: String)
type ConfigError = :ParseError | :Missing
def parse(text: String): Int ! ParseError => 1
def factorial(n: Int): Int ! Negative | Overflow => 1
def lookup(key: String): String? => None
`;

private Analyzed analyzedErrors(string body, string functions = "")
{
    return analyzed(declarations ~ functions ~ "def main(): Unit {\n" ~ body ~ "\n}");
}

@("type checking promotes a value and checks Ok and Error against an error union")
unittest
{
    auto a = analyzedErrors(`val a: Int ! Empty = 1
    val b: Int ! Empty = Ok(1)
    val c: Int ! Empty = Error(Empty)
    val d: UInt8 ! Empty = 255
    val e: Int ! ParseError | Missing = Error(Missing("k"))
    val f: Int ! ConfigError = Error(Missing("k"))
    val g: Int ! ParseError | Missing = Error(Blank)
    val h: Int? ! Empty = None
    val i: [Int] ! Empty = []
    val j = if true => 1 else Error(Empty)`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("if true => 1 else Error(Empty)", "Int ! Empty");
    analyzedErrors("val x: UInt8 ! Empty = 300").shouldReport(DiagnosticCode.LiteralOutOfRange, At("300", 1));
    analyzedErrors(`val x: Int ! Empty = Error(Negative)`).shouldReport(DiagnosticCode.TypeMismatch, At("Negative)", 1));
    analyzedErrors(`val x: Int ! Empty = Ok("a")`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
    analyzedErrors(`val x: Int ! Empty = Empty`).shouldReport(DiagnosticCode.TypeMismatch, At("Empty", 3));
    analyzedErrors(`val x: Int ! ParseError = Error(Missing("k"))`)
        .shouldReport(DiagnosticCode.TypeMismatch, At(`Missing("k")`, 1));
}

@("type checking reports an Ok or Error with no error union to take its type from")
unittest
{
    analyzedErrors("val x = Error(Empty)").shouldReport(DiagnosticCode.UntypedErrorUnion, At("Error(Empty)", 1));
    analyzedErrors("val x = Ok(1)").shouldReport(DiagnosticCode.UntypedErrorUnion, At("Ok(1)", 1));
    analyzedErrors("printl(Error(Empty))").shouldReport(DiagnosticCode.UntypedErrorUnion, At("Error(Empty)", 1));
    analyzedErrors("val f = Error").shouldReport(DiagnosticCode.UnknownName, At("Error", 1));
}

@("name resolution reserves Ok and Error")
unittest
{
    analyzed("type Ok\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Ok", 1));
    analyzed("type Error(x: Int)\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Error", 1));
    analyzed("alias Error = Int\ndef main(): Unit => ()").shouldReport(DiagnosticCode.DuplicateDeclaration, At("Error", 1));
}

@("an error list names declared types, each once, in any order")
unittest
{
    auto a = analyzedErrors(`val x: Int ! Negative | Overflow = factorial(1)
    val y: Int ! Overflow | Negative = x`);
    a.shouldHaveNoDiagnostics();
    analyzed("type A\ndef f(): Int ! A | A => 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("A", 3));
    analyzed("def f(): Int ! Typo => 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.UnknownType, At("Typo", 1));
    analyzed("def f(): Int ! Never => 1\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("Never", 1));
}

@("an error union widens where each of its errors is listed, or a member of a listed sum")
unittest
{
    analyzedErrors(`val a: Int ! Negative | Overflow | Missing = factorial(1)
    val b: Int ! ConfigError = parse("1")
    val c: Int ! ParseError | Missing = parse("1")
    val d: Int ! Blank = Error(Blank)
    val e: Int ! ParseError = d
    val f: Int ! ParseError | Negative = d`).shouldHaveNoDiagnostics();
    analyzedErrors(`val a: Int ! Negative = factorial(1)`).shouldReport(DiagnosticCode.TypeMismatch, At("factorial(1)", 1));
    analyzedErrors(`val a: Int ! Blank | BadDigit = parse("1")`).shouldReport(DiagnosticCode.TypeMismatch, At(`parse("1")`, 1));
    analyzedErrors(`val a: String ! ParseError = parse("1")`).shouldReport(DiagnosticCode.TypeMismatch, At(`parse("1")`, 1));
    analyzedErrors(`val a: Int = parse("1")`).shouldReport(DiagnosticCode.TypeMismatch, At(`parse("1")`, 1));
}

@("postfix ? passes an error on to a function whose errors take it, and never to an option")
unittest
{
    analyzed(declarations ~ `def a(): Int ! ParseError | Missing => parse("1")? + 1
def b(): Int ! ConfigError => parse("1")?
def c(): Unit ! Negative | Overflow | Empty {
    _ = factorial(1)?
}
def main(): Unit => ()`).shouldHaveNoDiagnostics();
    analyzed(declarations ~ "def a(): Int ! Missing => parse(\"1\")?\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidPropagation, At(`parse("1")?`, 1));
    analyzed(declarations ~ "def a(): Int => parse(\"1\")?\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidPropagation, At(`parse("1")?`, 1));
    analyzed(declarations ~ "def a(): Int? => parse(\"1\")?\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidPropagation, At(`parse("1")?`, 1));
    analyzed(declarations ~ "def a(): String ! Missing => lookup(\"k\")?\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidPropagation, At(`lookup("k")?`, 1));
    analyzed(declarations ~ "def a(): String ! Missing => lookup(\"k\") ?? { return Error(Missing(\"k\")) }\n"
        ~ "def b(): Int? => parse(\"1\") ?? { return None }\ndef main(): Unit => ()").shouldHaveNoDiagnostics();
}

@("a lambda's return type is inferred from its ?s, listing the errors they pass on")
unittest
{
    auto a = analyzedErrors(`val f = (t: String) => parse(t)? * 2
    val g = (n: Int) => if n > 0 => factorial(n)? else Error(Negative)
    val h = (t: String) => { val x = parse(t)?
        val y = parse(t)?
        x + y }`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("(t: String) => parse(t)? * 2", "(String) -> Int ! ParseError");
    a.shouldHaveType("(n: Int) => if n > 0 => factorial(n)? else Error(Negative)", "(Int) -> Int ! Negative | Overflow");
    auto both = analyzedErrors(`val f = (t: String) => parse(t)? + factorial(1)?`);
    both.shouldHaveNoDiagnostics();
    both.shouldHaveType("(t: String) => parse(t)? + factorial(1)?", "(String) -> Int ! Negative | Overflow | ParseError");
    analyzedErrors(`val f = (k: String) => {
        val s = lookup(k)?
        parse(s)?
    }`)
        .shouldReport(DiagnosticCode.InvalidPropagation, At("lookup(k)?", 1));
    analyzedErrors(`val f = (k: String): Int ! ParseError | Negative => parse(k)? + factorial(1)? `)
        .shouldReport(DiagnosticCode.InvalidPropagation, At("factorial(1)?", 1));
}

@("branches with different errors list them together, when their values are the same type")
unittest
{
    auto a = analyzedErrors(`val c = true
    val both = if c => parse("1") else factorial(1)
    val bare = if c => parse("1") else Error(Negative)`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("both", 1), "Int ! Negative | Overflow | ParseError");
    a.shouldDeclareType(At("bare", 1), "Int ! Negative | ParseError");
    analyzedErrors(`val c = true
    val wider = if c => lookup("k") ?? None else parse("1")`)
        .shouldReport(DiagnosticCode.TypeMismatch, At("if c", 1));
}

@("an error union can't be left unused, though _ drops it")
unittest
{
    analyzedErrors(`parse("1")`).shouldReport(DiagnosticCode.UnusedValue, At(`parse("1")`, 1));
    analyzedErrors(`if true {
        parse("1")
    }`).shouldReport(DiagnosticCode.UnusedValue, At(`parse("1")`, 1));
    analyzed(declarations ~ "def f(): Unit => parse(\"1\")\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.UnusedValue, At(`parse("1")`, 1));
    analyzedErrors(`_ = parse("1")`).shouldHaveNoDiagnostics();
}

@("postfix ! takes the value of an error union or an option")
unittest
{
    auto a = analyzedErrors(`val number = parse("1")!
    val text = lookup("k")!`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("number", 1), "Int");
    a.shouldDeclareType(At("text", 2), "String");
    analyzedErrors("val x = 1!").shouldReport(DiagnosticCode.InvalidOperand, At("1!", 1));
}

@("??, if val and ?. take an error union as they do an option, and while val refuses one")
unittest
{
    auto a = analyzedErrors(`val a = parse("1") ?? 0
    val b = parse("1") ?? None
    val c = if val n = parse("1") => n else 0
    val d = if val Error(e) = parse("1") => 1 else 0`);
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType(`parse("1") ?? 0`, "Int");
    a.shouldHaveType(`parse("1") ?? None`, "Int?");
    analyzedErrors(`while val n = parse("1") { }`).shouldReport(DiagnosticCode.InvalidOperand, At(`parse("1")`, 1));

    auto access = analyzed(declarations ~ `type Point(x: Int, y: Int ! Empty)
def point(): Point ! Empty => Point(1, 2)
def main(): Unit {
    val x = point()?.x
    val y = point()?.y
}`);
    access.shouldHaveNoDiagnostics();
    access.shouldHaveType("point()?.x", "Int ! Empty");
    access.shouldHaveType("point()?.y", "Int ! Empty");
}

@("== compares an error union with a value or an Error, checking the other side against it")
unittest
{
    analyzedErrors(`printl(parse("1") == 1)
    printl(1 == parse("1"))
    printl(parse("1") == Error(Blank))
    printl(Error(BadDigit(1)) == parse("1"))
    printl(parse("1") == Ok(1))
    printl(factorial(1) != Error(Overflow))`).shouldHaveNoDiagnostics();
    analyzedErrors(`printl(parse("1") == "a")`).shouldReport(DiagnosticCode.InvalidOperand, At(`parse("1") == "a"`, 1));
    analyzedErrors(`printl(parse("1") < 2)`).shouldReport(DiagnosticCode.InvalidOperand, At(`parse("1")`, 1));
}

@("match takes Ok and Error, reaching through a sum the error list names, and must cover both")
unittest
{
    analyzed(declarations ~ `def read(): Int ! ParseError | Missing => 1
def main(): Unit {
    val a = match factorial(1) {
        Ok(v) => v
        Error(Negative) => 0
        Error(Overflow) => 1
    }
    val b = match read() {
        Ok(v) => v
        Error(Blank) => 0
        Error(BadDigit(at)) => at
        Error(Missing(key)) => 2
    }
    val c = match read() {
        Ok(_) => 0
        Error(e: ParseError) => 1
        Error(m: Missing) => 2
    }
}`).shouldHaveNoDiagnostics();
    analyzedErrors(`val a = match factorial(1) {
        Ok(v) => v
        Error(Negative) => 0
    }`).shouldReport(DiagnosticCode.NonExhaustiveMatch, At("match", 1));
    analyzed(declarations ~ `def read(): Int ! ParseError | Missing => 1
def main(): Unit {
    val b = match read() {
        Ok(v) => v
        Error(Blank) => 0
        Error(Missing(key)) => 2
    }
}`).shouldReport(DiagnosticCode.NonExhaustiveMatch, At("match", 1));
    analyzed(declarations ~ `def read(): Int ! ParseError | Missing => 1
def main(): Unit {
    val b = match read() {
        Ok(v) => v
        Error(e: ParseError) => 0
        Error(Blank) => 1
        Error(Missing(key)) => 2
    }
}`).shouldReport(DiagnosticCode.UnreachableArm, At("Error(Blank)", 1));
    analyzedErrors(`val a = match factorial(1) {
        Ok(v) => v
        Error(Missing(k)) => 0
        _ => 1
    }`).shouldReport(DiagnosticCode.PatternMismatch, At("Missing(k)", 1));
    analyzedErrors(`val x: Int? = 1
    val a = match x {
        Ok(v) => v
        _ => 1
    }`).shouldReport(DiagnosticCode.PatternMismatch, At("Ok(v)", 1));
}

@("main may return Unit ! E")
unittest
{
    analyzed("type Missing\ndef main(): Unit ! Missing => ()").shouldHaveNoDiagnostics();
    analyzed("type Missing\ndef main(): Int ! Missing => 1")
        .shouldReport(DiagnosticCode.MainInvalidDefinition, At("main", 1));
}

@("a generic function binds the parts of an error union")
unittest
{
    auto a = analyzedErrors(`val unwrapped = valueOr(parse("1"), 0)
    val reason = errorOf(factorial(1))`, `def valueOr<T, E>(r: T ! E, fallback: T): T => r ?? fallback
def errorOf<T, E>(r: T ! E): E? => match r {
    Ok(_) => None
    Error(e) => Some(e)
}
`);
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("unwrapped", 1), "Int");
    a.shouldDeclareType(At("reason", 1), "(Negative | Overflow)?");
}

@("a value that's one of the errors and could also be the success has to say which it is")
unittest
{
    enum types = "type H2 = :Missing | :Int\n";
    analyzedErrors("", types ~ "def a(): H2 ! Missing => Missing(\"k\")\n")
        .shouldReport(DiagnosticCode.ErrorOrSuccess, At("Missing", 5));
    analyzedErrors("", types ~ "def a(m: Missing): (H2 ! Missing)? => m\n")
        .shouldReport(DiagnosticCode.ErrorOrSuccess, At("m", 2));
    analyzedErrors("", "def a(m: Missing): Missing ! ConfigError => m\n")
        .shouldReport(DiagnosticCode.ErrorOrSuccess, At("m", 2));
    analyzedErrors("", types ~ "def a(): H2 ! Missing => Ok(Missing(\"k\"))\ndef b(): H2 ! Missing => Error(Missing(\"k\"))\n"
        ~ "def c(): H2 ! Missing => 1\n").shouldHaveNoDiagnostics();
}

@("an error list can't list a type beside a sum that holds it, in either order, through an alias or in a sum's member")
unittest
{
    auto sums = "type Bad(n: Int)
type Empty
type ParseError = :Bad | :Empty
";
    analyzed(sums ~ "def f(): Int ! ParseError | Bad => 1
def main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("Bad", 3));
    analyzed(sums ~ "def f(): Int ! Bad | ParseError => 1
def main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("ParseError", 2));
    analyzed("type Bad(n: Int)
type Empty
alias F = Int ! ParseError | Bad
type ParseError = :Bad | :Empty
def main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("Bad", 2));
    analyzed("type Bad(n: Int)
type Empty
type W = :String | :(Int ! ParseError | Bad)
type ParseError = :Bad | :Empty
def main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("Bad", 2));
    analyzed(sums ~ "def f(): Int ! Empty | Bad => 1
def main(): Unit => ()").shouldHaveNoDiagnostics();
}

@("type checking a generic sum with an error list member that names the sum ends")
unittest
{
    // A list's named members are known without substituting the members that aren't named types,
    // so a list at an instance doesn't ask the instance's members again.
    analyzed(`type Bad(n: Int)
type Other(s: String)
type Box<E> = :Bad | :(Int ! Box<E> | Other)
def pick<E, F>(c: Bool, x: Int ! E, y: Int ! F): Int ! E | F => if c => x else y
def a(): Int ! Box<Int> => Error(Bad(1))
def b(): Int ! Bad => Error(Bad(2))
def c(): Int ! Box<Int> => pick(true, a(), b())
def main(): Unit {
    val v: Box<Int> = Bad(1)
    printl(v)
}`).shouldHaveNoDiagnostics();
}

@("type checking a generic sum with a named member whose type argument lists the sum ends")
unittest
{
    // The member is recorded as one of the sum's direct members, and substituting it at an instance
    // rebuilds its list, which asks the instance's direct members again.
    analyzed(`type Bad(n: Int)
type Other
type Holder<T>(v: T)
type Box<E> = :Bad | :Holder<Int ! Box<E> | Other>
def main(): Unit {
    val b: Box<Int> = Bad(1)
    printl(b)
}`).shouldHaveNoDiagnostics();
}

@("a list in a sum's member's type argument knows the members of a sum whose own member has a list in its type argument, in either order")
unittest
{
    auto outer = "type Outer = :String | :Holder<Int ! Inner | Holder<Int ! Bad>>\n";
    auto inner = "type Inner = :Empty | :Holder<Int ! Bad>\n";
    auto types = "type Bad(n: Int)\ntype Empty\ntype Holder<T>(v: T)\n";
    analyzed(types ~ outer ~ inner ~ "def main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("Holder", 3));
    analyzed(types ~ inner ~ outer ~ "def main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("Holder", 4));
    analyzed(types ~ "alias Inner = Int ! Box | Holder<Int ! Bad>\ntype Box = :Empty | :H\nalias H = Holder<Int ! Bad>\n"
        ~ "def main(): Unit => ()")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("Holder", 2));
}

@("type checking a sum that names one of its own members in a list in that member's type argument ends")
unittest
{
    // Asking whether Holder<Int> is a member of Box<Int> substitutes the member's type argument,
    // which builds the same list again.
    analyzed(`type Bad(n: Int)
type Holder<T>(v: T)
type Box<E> = :Bad | :Holder<Int ! Holder<E> | Box<E>>
def f(): Int ! Holder<Int> | Box<Int> => 1
def main(): Unit {
    val b: Box<Int> = Bad(1)
    printl(b)
}`).shouldHaveNoDiagnostics();
}

@("type checking a sum that names ever larger instances of itself in a list in a member's type argument ends")
unittest
{
    // Asking whether Holder<Int> is a member of Box<Int> substitutes the member's type argument,
    // whose list asks the same of Box<Box<Int>>, and so on.
    analyzed(`type Bad(n: Int)
type Holder<T>(v: T)
type Box<E> = :Bad | :Holder<Int ! Box<Box<E>> | Holder<E>>
def f(): Int ! Holder<Int> | Box<Int> => 1
def main(): Unit => ()`).shouldReport(DiagnosticCode.PolymorphicRecursion, At("Box", 1));
}
