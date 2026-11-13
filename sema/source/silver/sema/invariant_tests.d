/// Tests of type invariants: what an invariant can say, the error union building a value yields,
/// the fields only `with` can change, and which constructions are known to break one before the
/// program runs.
module silver.sema.invariant_tests;

version (unittest):

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType, shouldHaveType;
import silver.sema.resolution_tests;

/// `body` in `main`, after `declarations`.
private Analyzed analyzedWith(string declarations, string body)
{
    return analyzed(declarations ~ "\ndef main(): Unit {\n" ~ body ~ "\n}");
}

private enum spans = "type Reversed(low: Int, high: Int)\n"
    ~ "type Span(low: Int, high: Int) invariant low <= high else Reversed(low, high)\n"
    ~ "type TooEarly\n"
    ~ "type Meeting(time: Span, title: String) invariant time.low >= 0 else TooEarly\n";

@("an invariant is a Bool over the fields, and can use the module's private functions and constants")
unittest
{
    analyzedWith("private val top: Int = 100\nprivate def low(x: Int): Bool => x >= 0\n"
        ~ "type Percent(value: Int) invariant low(value) && value <= top else \"out of range\"\n"
        ~ "type S = C(r: Float) invariant (r > 0.0) else (r) | N",
        "    val p = Percent(5)\n    val c = C(1.0)").shouldHaveNoDiagnostics();
    analyzedWith("type A(x: Int) invariant x + 1 else x", "").shouldReport(DiagnosticCode.TypeMismatch, At("x + 1", 1));
    analyzedWith("type A(x: Int) invariant y > 0 else x", "").shouldReport(DiagnosticCode.UnknownName, At("y", 1));
    analyzedWith("type A(x: Int) invariant x > 0 else y", "").shouldReport(DiagnosticCode.UnknownName, At("y", 1));
}

@("a field in an invariant hides anything of the same name")
unittest
{
    auto a = analyzedWith("val limit: Int = 3\ndef size(x: Int): Int => x\n"
        ~ "type A(size: Int, limit: Int) invariant size < limit else size", "    val a = A(1, 2)");
    a.shouldHaveNoDiagnostics();
    // The condition compares the field with `limit`, which the function `size` couldn't be, and the
    // `else` sees the field too. Its function's parameters share the fields' spans.
    a.shouldResolve(At("size", 4), At("size", 2));
}

@("a generic type's invariant is checked once, so it can't order a value of a type parameter")
unittest
{
    auto a = analyzedWith("type Empty\ntype NonEmpty<T>(items: [T]) invariant length(items) > 0 else Empty\n"
        ~ "type Bad<T>(items: [T])\ntype Listed<T>(items: [T]) invariant length(items) > 1 else Bad(items)",
        "    val n = NonEmpty([1])\n    val l = Listed([\"a\"])");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("NonEmpty([1])", "NonEmpty<Int> ! Empty");
    a.shouldHaveType(`Listed(["a"])`, "Listed<String> ! Bad<String>");
    analyzedWith("type Ordered<T>(a: T, b: T) invariant a < b else 0", "")
        .shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a < b", 1));
}

@("building a value of a type with an invariant yields an error union of the error its else gives")
unittest
{
    auto a = analyzedWith(spans ~ "type Shape = Circle(r: Float) invariant (r > 0.0) else (\"not positive\") | Nothing\n"
        ~ "alias Range = Span",
        "    val s = Span(1, 2)\n    val r = Range(1, 2)\n    val c = Circle(1.0)\n    val make = Span\n    val plain = Span(1, 2)!");
    a.shouldHaveNoDiagnostics();
    a.shouldHaveType("Span(1, 2)", "Span ! Reversed");
    a.shouldHaveType("Range(1, 2)", "Span ! Reversed");
    a.shouldHaveType("Circle(1.0)", "Shape ! String");
    a.shouldDeclareType(At("make", 1), "(Int, Int) -> Span ! Reversed");
    a.shouldDeclareType(At("plain", 1), "Span");
    analyzedWith(spans, "    val s: Span = Span(1, 2)").shouldReport(DiagnosticCode.TypeMismatch, At("Span(1, 2)", 1));
}

@("an invariant's else has to give a value")
unittest
{
    analyzedWith("type A(x: Int) invariant x > 0 else panic(\"no\")", "")
        .shouldReport(DiagnosticCode.InvalidErrorType, At("panic(\"no\")", 1));
    analyzedWith("type A(x: Int) invariant x > 0 else None", "").shouldReport(DiagnosticCode.UntypedNone, At("None", 1));
    analyzedWith("type A(x: Int) invariant x > 0 else B(x)\ntype B(x: Int) invariant x > 0 else x", "")
        .shouldReport(DiagnosticCode.NotSupportedYet, At("B(x)", 1));
    analyzedWith("type B(x: Int) invariant x > 0 else x\ntype A(x: Int) invariant x > 0 else B(x)", "")
        .shouldHaveNoDiagnostics();
}

@("a with that updates a field the invariant names yields an error union, and one that doesn't is plain")
unittest
{
    auto a = analyzedWith(spans, "    val span = Span(1, 2)!\n    val meeting = Meeting(span, \"a\")!\n"
        ~ "    val moved = span with (low = 0, high = 3)\n    val renamed = meeting with (title = \"b\")\n"
        ~ "    val later = meeting with (time = span)");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("moved", 1), "Span ! Reversed");
    a.shouldDeclareType(At("renamed", 1), "Meeting");
    a.shouldDeclareType(At("later", 1), "Meeting ! TooEarly");
    // `time.high` changes `time`, which `Meeting`'s invariant names, but `TooEarly` and `Reversed` differ.
    analyzedWith(spans, "    val meeting = Meeting(Span(1, 2)!, \"a\")!\n    val x = meeting with (time.high = 4)")
        .shouldReport(DiagnosticCode.NotSupportedYet, At("meeting with (time.high = 4)", 1));
}

@("a field an invariant names can't be assigned, assigned through, or passed as mutable")
unittest
{
    enum mutables = "def shift(mutable s: Span): Unit {}\ndef bump(mutable n: Int): Unit {}\n";
    analyzedWith(spans ~ mutables, "    mutable val m = Meeting(Span(1, 2)!, \"a\")!\n    m.title = \"b\"\n"
        ~ "    m = (m with (time = Span(0, 1)!)) ?? m").shouldHaveNoDiagnostics();
    analyzedWith(spans ~ mutables, "    mutable val s = Span(1, 2)!\n    s.low = 0")
        .shouldReport(DiagnosticCode.InvariantFieldChanged, At("s.low", 1));
    analyzedWith(spans ~ mutables, "    mutable val s = Span(1, 2)!\n    s.high += 1")
        .shouldReport(DiagnosticCode.InvariantFieldChanged, At("s.high", 1));
    analyzedWith(spans ~ mutables, "    mutable val m = Meeting(Span(1, 2)!, \"a\")!\n    m.time.high = 5")
        .shouldReport(DiagnosticCode.InvariantFieldChanged, At("m.time.high", 1));
    analyzedWith(spans ~ mutables, "    mutable val m = Meeting(Span(1, 2)!, \"a\")!\n    shift(mutable m.time)")
        .shouldReport(DiagnosticCode.InvariantFieldChanged, At("m.time", 1));
    analyzedWith(spans ~ mutables, "    mutable val s = Span(1, 2)!\n    bump(mutable s.low)")
        .shouldReport(DiagnosticCode.InvariantFieldChanged, At("s.low", 1));
    analyzedWith(spans ~ mutables, "    mutable val s = Span(1, 2)!\n    shift(mutable s)\n    s = (s with (low = 0))!")
        .shouldHaveNoDiagnostics();
}

@("! on a construction from literals that breaks a constant invariant is an error")
unittest
{
    enum declarations = "val top: Int = 100\ntype Percent(value: Int) invariant 0 <= value && value <= top else value\n"
        ~ "type Span(low: Float, high: Float) invariant low <= high else low\n"
        ~ "type S = C(r: Float, name: String) invariant (r > 0.0 && name != \"\") else (name) | N";
    analyzedWith(declarations, "    val p = Percent(150)!").shouldReport(DiagnosticCode.InvariantViolated, At("Percent(150)", 1));
    analyzedWith(declarations, "    val p = Percent(-1)!").shouldReport(DiagnosticCode.InvariantViolated, At("Percent(-1)", 1));
    analyzedWith(declarations, "    val s = Span(2.0, -1.5)!").shouldReport(DiagnosticCode.InvariantViolated, At("Span(2.0, -1.5)", 1));
    analyzedWith(declarations, "    val c = C(1.0, \"\")!").shouldReport(DiagnosticCode.InvariantViolated, At("C(1.0, \"\")", 1));
    analyzedWith(declarations, "    val p = Percent(100)!\n    val s = Span(1.0, 1.0)!\n    val c = C(1.0, \"c\")!")
        .shouldHaveNoDiagnostics();
    // Without `!`, it's an error value like any other.
    analyzedWith(declarations, "    val p = Percent(150)").shouldHaveNoDiagnostics();
}

@("a construction is only checked before the program runs when its arguments are literals and the invariant is constant")
unittest
{
    analyzedWith("type Percent(value: Int) invariant value <= 100 else value", "    val n = 150\n    val p = Percent(n)!")
        .shouldHaveNoDiagnostics();
    analyzedWith("def small(x: Int): Bool => x <= 100\ntype Percent(value: Int) invariant small(value) else value",
        "    val p = Percent(150)!").shouldHaveNoDiagnostics();
}

@("an invariant that would fail to evaluate for literals is left to the program")
unittest
{
    analyzedWith("type Tiny(x: UInt8) invariant x + 1 > 0 else x", "    val t = Tiny(255)!").shouldHaveNoDiagnostics();
}
