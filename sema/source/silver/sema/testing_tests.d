/// Tests of `test` declarations: where `expect` can be used, what `?` does in a test, and that a
/// program run for its tests needn't have a `main`.
module silver.sema.testing_tests;

version (unittest):

import silver.ast : DiagnosticCode;
import silver.sema.resolution_tests;
import silver.sema.target : Target;

/// `declarations`, as a program run for its tests.
private Analyzed tested(string declarations)
{
    return analyzed(declarations, null, Target.host, true);
}

@("a test is checked as a function returning Unit, and needs no main to run")
unittest
{
    tested("def double(x: Int): Int => x * 2\ntest \"doubles\" {\n    val x = double(2)\n    x\n}\ntest \"short\" => double(1)")
        .shouldHaveNoDiagnostics();
    tested("test \"a\" => undefined()").shouldReport(DiagnosticCode.UnknownName, At("undefined", 1));
    analyzed("test \"a\" => ()").shouldReport(DiagnosticCode.MissingMain, At("test", 1));
}

@("expect takes a Bool and optionally a String message, only in test code, and can only be called")
unittest
{
    tested("test \"a\" {\n    expect(1 < 2)\n    expect(true, \"m\")\n    (1 == 1).expect()\n"
        ~ "    val check = (n: Int) => expect(n > 0)\n    def nested(): Unit => expect(false)\n}").shouldHaveNoDiagnostics();
    tested("test \"a\" => expect(7)").shouldReport(DiagnosticCode.TypeMismatch, At("7", 1));
    tested("def check(): Unit => expect(true)").shouldReport(DiagnosticCode.ExpectOutsideTest, At("expect", 1));
    tested("def check(): Unit => true.expect()").shouldReport(DiagnosticCode.ExpectOutsideTest, At("true", 1));
    tested("test \"a\" {\n    val f: (Bool) -> Unit = expect\n}").shouldReport(DiagnosticCode.InvalidOperand, At("expect", 1));
}

@("? in a test's own body stops the test, and in a lambda or nested def it still returns from that")
unittest
{
    enum find = "def find(): Int? => None\n";
    tested(find ~ "test \"a\" {\n    val x = find()?\n    expect(x > 0)\n}").shouldHaveNoDiagnostics();
    tested(find ~ "test \"a\" {\n    val f = (): Int => find()?\n}").shouldReport(DiagnosticCode.InvalidPropagation, At("find", 2));
    tested(find ~ "test \"a\" {\n    def g(): Int => find()?\n}").shouldReport(DiagnosticCode.InvalidPropagation, At("find", 2));
    tested(find ~ "test \"a\" {\n    val f = () => find()?\n}").shouldHaveNoDiagnostics();
}

@("two tests in a module can't share a name")
unittest
{
    tested("test \"same\" => ()\ntest \"same\" => ()\ntest \"other\" => ()")
        .shouldReport(DiagnosticCode.DuplicateDeclaration, At("\"same\"", 2));
}
