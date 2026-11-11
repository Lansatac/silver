/// Tests of `Ref<T>` from `std.ref`: an intrinsic type, which has a constructor but no fields.
module silver.sema.ref_tests;

version (unittest):

import silver.ast : DiagnosticCode;
import silver.sema.check_tests : shouldDeclareType;
import silver.sema.resolution_tests;

/// `body` in `main`, in a module that imports `std.ref`, after `more`.
private Analyzed analyzedRef(string body, string more = "")
{
    return analyzed("import std.ref\n" ~ more ~ "def main(): Unit {\n" ~ body ~ "\n}");
}

@("Ref infers its type argument, and get, set and update are ordinary generic functions")
unittest
{
    auto a = analyzedRef(`    val counter = Ref(0)
    counter.set(2)
    counter.update(n => n + 1)
    val now = counter.get()
    val names: Ref<[String]> = Ref([])
    val cells = [Ref(1), Ref(2)]
    val read = cells.map(get<Int>)
    val made = [1, 2].map(Ref<Int>)`, "def map<T, U>(values: [T], f: (T) -> U): [U] => []\n");
    a.shouldHaveNoDiagnostics();
    a.shouldDeclareType(At("counter", 1), "Ref<Int>");
    a.shouldDeclareType(At("now", 1), "Int");
    a.shouldDeclareType(At("read", 1), "[Int]");
    a.shouldDeclareType(At("made", 1), "[Ref<Int>]");
}

@("Ref isn't in the prelude")
unittest
{
    analyzed("def main(): Unit {\n    val r = Ref(0)\n}").shouldReport(DiagnosticCode.UnknownName, At("Ref", 1));
}

@("a Ref has no fields, so they can't be read, written or updated with `with`")
unittest
{
    analyzedRef("    val r = Ref(1)\n    val v = r.value").shouldReport(DiagnosticCode.UnknownMember, At("r", 2));
    analyzedRef("    mutable val r = Ref(1)\n    r.value = 2").shouldReport(DiagnosticCode.UnknownMember, At("r", 2));
    analyzedRef("    val r = Ref(1)\n    val s = r with (value = 2)").shouldReport(DiagnosticCode.UnknownMember, At("value", 1));
}

@("a Ref isn't taken apart by a pattern")
unittest
{
    analyzedRef("    val r = Ref(1)\n    val v = match r {\n        Ref(x) => x\n    }")
        .shouldReport(DiagnosticCode.PatternMismatch, At("Ref", 2));
    analyzedRef("    val r = Ref(1)\n    val v = match r {\n        c => c.get()\n    }").shouldHaveNoDiagnostics();
}

@("a Ref isn't comparable, and neither is a type holding one")
unittest
{
    analyzedRef("    val r = Ref(1)\n    val same = r == r").shouldReport(DiagnosticCode.InvalidOperand, At("r", 2));
    analyzedRef("    val h = Holder(Ref(1))\n    val same = h == h", "type Holder(cell: Ref<Int>)\n")
        .shouldReport(DiagnosticCode.InvalidOperand, At("h", 2));
}

@("a Ref of a type needs a value of it to build, so a type holding a Ref of itself needs an option")
unittest
{
    analyzedRef("", "type Node(next: Ref<Node>)\n").shouldReport(DiagnosticCode.UninhabitedType, At("Node", 1));
    analyzedRef("    val n = Node(Ref(None))\n    n.next.set(Some(n))", "type Node(next: Ref<Node?>)\n").shouldHaveNoDiagnostics();
}

@("a constant can't be a Ref")
unittest
{
    analyzedRef("", "val cell: Ref<Int> = Ref(0)\n").shouldReport(DiagnosticCode.InvalidConstantType, At("Ref", 1));
}

@("update's change takes and returns the cell's type")
unittest
{
    analyzedRef(`    val r = Ref(1)
    r.update(n => "a")`).shouldReport(DiagnosticCode.TypeMismatch, At(`"a"`, 1));
    analyzedRef("    val r = Ref(1)\n    r.set(true)").shouldReport(DiagnosticCode.TypeMismatch, At("true", 1));
}

@("an intrinsic type is only for the standard library, and only one the compiler implements")
unittest
{
    analyzed("intrinsic type Ref<T>(value: T)\ndef main(): Unit => ()")
        .shouldReport(DiagnosticCode.IntrinsicOutsideStandardLibrary, At("Ref", 1));
    analyzed("import std.mine\ndef main(): Unit => ()", ["std/mine.ag": "module std.mine\nintrinsic type Cell<T>(value: T)"])
        .shouldReport(DiagnosticCode.UnknownIntrinsic, At("Cell", 1, "std.mine"));
}
