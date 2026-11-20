/// Tests of the standard library itself: what the prelude makes visible and what a `std` module
/// provides. These are the unit tests that name the stdlib's modules, so reorganizing stdlib/ may
/// change them; every other test uses modules of its own.
module silver.sema.stdlib_tests;

version (unittest):

import silver.ast : DiagnosticCode;
import silver.sema.resolution_tests;
import silver.sema.target : Target;

@("the prelude gives printing, reading, panics, arrays, ranges and intervals without an import")
unittest
{
    analyzed(`def main(): Unit {
    print(1)
    printl("a")
    printl()
    val line = read()
    assert(true, "m")
    val xs = [1, 2]
    val n = length(xs) + xs.at(0)
    val rest = next(xs)
    val first = next("ab")
    val r: Interval<Int> = 0..n
    for i in r { }
    val doubled = xs.map(x => x * 2).array()
    if n < 0 { panic("negative") }
}`).shouldHaveNoDiagnostics();
}

@("Ref isn't in the prelude")
unittest
{
    analyzed("def main(): Unit {\n    val r = Ref(0)\n}").shouldReport(DiagnosticCode.UnknownName, At("Ref", 1));
}

@("std.c's types have C equivalents, so a native can take and return them")
unittest
{
    analyzed("import std.c\nnative def f(x: CInt, y: CLong, z: CSize): CUChar\ndef main(): Unit { }").shouldHaveNoDiagnostics();
}

@("std.c's long is as wide as the target says, and its other types are the same everywhere")
unittest
{
    enum source = "import std.c\ndef f(x: CLong): Int64 => x\ndef g(x: CULong): UInt32 => x\ndef h(x: CInt, y: CSize): (Int32, UInt64) => (x, y)\ndef main(): Unit { }";
    analyzed(source, null, Target(64)).shouldReport(DiagnosticCode.TypeMismatch, At("x", 4));
    analyzed(source, null, Target(32)).shouldReport(DiagnosticCode.TypeMismatch, At("x", 2));
}
