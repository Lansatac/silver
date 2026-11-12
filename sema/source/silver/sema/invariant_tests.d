/// Tests of type invariants: what an invariant can say, and which constructions are known to break
/// one before the program runs.
module silver.sema.invariant_tests;

version (unittest):

import silver.ast : DiagnosticCode;
import silver.sema.resolution_tests;

/// `body` in `main`, after `declarations`.
private Analyzed analyzedWith(string declarations, string body)
{
    return analyzed(declarations ~ "\ndef main(): Unit {\n" ~ body ~ "\n}");
}

@("an invariant is a Bool over the fields, and can use the module's private functions and constants")
unittest
{
    analyzedWith("private val top: Int = 100\nprivate def low(x: Int): Bool => x >= 0\n"
        ~ "type Percent(value: Int) invariant low(value) && value <= top\n"
        ~ "type S = C(r: Float) invariant (r > 0.0) | N",
        "    val p = Percent(5)\n    val c = C(1.0)").shouldHaveNoDiagnostics();
    analyzedWith("type A(x: Int) invariant x + 1", "").shouldReport(DiagnosticCode.TypeMismatch, At("x + 1", 1));
    analyzedWith("type A(x: Int) invariant y > 0", "").shouldReport(DiagnosticCode.UnknownName, At("y", 1));
}

@("a field in an invariant hides anything of the same name")
unittest
{
    auto a = analyzedWith("val limit: Int = 3\ndef size(x: Int): Int => x\n"
        ~ "type A(size: Int, limit: Int) invariant size < limit", "    val a = A(1, 2)");
    a.shouldHaveNoDiagnostics();
    a.shouldResolve(At("size", 3), At("size", 2));
}

@("a generic type's invariant is checked once, so it can't order a value of a type parameter")
unittest
{
    analyzedWith("type NonEmpty<T>(items: [T]) invariant length(items) > 0", "    val n = NonEmpty([1])")
        .shouldHaveNoDiagnostics();
    analyzedWith("type Ordered<T>(a: T, b: T) invariant a < b", "")
        .shouldReport(DiagnosticCode.OpaqueTypeParameter, At("a < b", 1));
}

@("a construction from literals that breaks a constant invariant is an error")
unittest
{
    enum declarations = "val top: Int = 100\ntype Percent(value: Int) invariant 0 <= value && value <= top\n"
        ~ "type Span(low: Float, high: Float) invariant low <= high\n"
        ~ "type S = C(r: Float, name: String) invariant (r > 0.0 && name != \"\") | N";
    analyzedWith(declarations, "    val p = Percent(150)").shouldReport(DiagnosticCode.InvariantViolated, At("Percent(150)", 1));
    analyzedWith(declarations, "    val p = Percent(-1)").shouldReport(DiagnosticCode.InvariantViolated, At("Percent(-1)", 1));
    analyzedWith(declarations, "    val s = Span(2.0, -1.5)").shouldReport(DiagnosticCode.InvariantViolated, At("Span(2.0, -1.5)", 1));
    analyzedWith(declarations, "    val c = C(1.0, \"\")").shouldReport(DiagnosticCode.InvariantViolated, At("C(1.0, \"\")", 1));
    analyzedWith(declarations, "    val p = Percent(100)\n    val s = Span(1.0, 1.0)\n    val c = C(1.0, \"c\")")
        .shouldHaveNoDiagnostics();
}

@("a construction is only checked before the program runs when its arguments are literals and the invariant is constant")
unittest
{
    analyzedWith("type Percent(value: Int) invariant value <= 100", "    val n = 150\n    val p = Percent(n)")
        .shouldHaveNoDiagnostics();
    analyzedWith("def small(x: Int): Bool => x <= 100\ntype Percent(value: Int) invariant small(value)",
        "    val p = Percent(150)").shouldHaveNoDiagnostics();
}

@("an invariant that would fail to evaluate for literals is left to the program")
unittest
{
    analyzedWith("type Tiny(x: UInt8) invariant x + 1 > 0", "    val t = Tiny(255)").shouldHaveNoDiagnostics();
}
