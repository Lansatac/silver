/// Tests of `lang` and the standard library themselves: what they make visible without an import
/// and what a `std` module provides. These are the unit tests that name the stdlib's modules, so
/// reorganizing stdlib/ may change them; every other test uses modules of its own, except the Ref
/// tests (ref_tests.d and core's lowering test), which import std.ref because a local Ref would
/// collide with the real one.
module silver.sema.stdlib_tests;

version (unittest):

import silver.ast : DiagnosticCode;
import silver.sema.resolution_tests;
import silver.sema.target : Target;

@("lang and the prelude give printing, reading, panics, arrays, ranges and intervals without an import")
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
    analyzed("import std.c\nnative def getenv(name: CString): CString?\n"
        ~ "def main(): Unit => printl(fromCString(getenv(toCString(\"HOME\")) ?? toCString(\"\")))").shouldHaveNoDiagnostics();
    analyzed("def main(): Unit => printl(toCString(\"a\"))").shouldReport(DiagnosticCode.UnknownName, At("toCString", 1));
}

@("std.c's long is as wide as the target says, and its other types are the same everywhere")
unittest
{
    enum source = "import std.c\ndef f(x: CLong): Int64 => x\ndef g(x: CULong): UInt32 => x\ndef h(x: CInt, y: CSize): (Int32, UInt64) => (x, y)\ndef main(): Unit { }";
    analyzed(source, null, Target(64)).shouldReport(DiagnosticCode.TypeMismatch, At("x", 4));
    analyzed(source, null, Target(32)).shouldReport(DiagnosticCode.TypeMismatch, At("x", 2));
}

@("Of is std.of's, and the prelude forwards it")
unittest
{
    analyzed("def zero(of: Of<Int>): Int => 0\ndef main(): Unit => printl(zero(Of<Int>))").shouldHaveNoDiagnostics();
    analyzed("import std.of\ndef zero(of: Of<Int>): Int => 0\ndef main(): Unit => printl(zero(std.of.Of<Int>))")
        .shouldHaveNoDiagnostics();
}

/// Each public function that a module declares beside a blanket forward of a module giving a
/// function of the same name and parameters, as `facade.name hides target.name`. The facade's
/// replaces the target's for its importers, so a module importing both, as anyone importing the
/// original beside the prelude does, can't call either. `modules` are loaded from the standard
/// library and from `fixtures`, unless it's null, as a test's unnamed package, and each candidate
/// is asked of the checker as two imports listing the name, which is T0035 exactly when they bring
/// different functions of the same parameters.
private string[] hiddenByFacades(string fixtures, string[] modules)
{
    import std.algorithm : canFind, map;
    import std.array : join;
    import std.sumtype : match;
    import silver.ast;
    import silver.loader : load, Packages, standardPrelude, withStandardLibrary;
    import silver.sema.analysis : analyze;

    auto roots = Packages(withStandardLibrary(fixtures is null ? [] : [Package(null, fixtures)]));
    auto context = new SourceContext;
    auto program = load(modules.map!(m => "import " ~ m ~ "\n").join, "main.ag", roots, standardPrelude, context);
    assert(!context.collector.hasErrors, "The modules failed to load");

    string[] found;
    foreach (facade; program.sortedModules)
    {
        string[] targets;
        string[] names;
        foreach (decl; facade.declarations)
        {
            decl.kind.match!(
                (const ImportStmt i) {
                    if (i.forward && i.names.length == 0) targets ~= i.path.join(".");
                },
                (const FunctionDecl f) {
                    if (!f.isPrivate && f.testName is null && !f.invariantOf.isValid && !names.canFind(f.name))
                        names ~= f.name;
                },
                (_) {},
            );
        }
        foreach (target; targets)
        {
            foreach (name; names)
            {
                auto probe = new SourceContext;
                auto source = "import " ~ facade.name ~ " : " ~ name ~ "\nimport " ~ target ~ " : " ~ name ~ "\n";
                auto probed = load(source, "main.ag", roots, standardPrelude, probe);
                analyze(probed, probe.collector, Target.host);
                if (probe.collector.diagnostics.canFind!(d => d.code == DiagnosticCode.DuplicateOverload))
                    found ~= facade.name ~ "." ~ name ~ " hides " ~ target ~ "." ~ name;
            }
        }
    }
    return found;
}

@("no module of the standard library or lang replaces a function it forwards blanket")
unittest
{
    import std.algorithm : canFind, filter, map;
    import std.array : array, join;
    import std.file : dirEntries, SpanMode;
    import std.format : format;
    import std.path : pathSplitter, relativePath, stripExtension;
    import silver.ast : langPackage;
    import silver.loader : isCompanionFile, standardLibraryPath;

    import std.file : readText;
    import std.string : lineSplitter, startsWith;

    auto root = standardLibraryPath();
    // A file with no `module` line is a script, which the language allows beside modules, and not importable.
    auto modules = dirEntries(root, "*.ag", SpanMode.depth)
        .filter!(e => !isCompanionFile(e.name))
        .filter!(e => readText(e.name).lineSplitter.canFind!(line => line.startsWith("module ")))
        .map!(e => relativePath(e.name, root).stripExtension.pathSplitter.array)
        .map!(segments => (segments[$ - 1] == "package" ? segments[0 .. $ - 1] : segments).join("."))
        .array;
    assert(modules.canFind(langPackage), "lang's root module wasn't found");
    assert(modules.length > 10, "The standard library wasn't found");
    auto hidden = hiddenByFacades(null, modules);
    assert(hidden.length == 0, format("Facades replacing what they forward: %s", hidden));
}

@("a facade's own function of a forwarded one's parameters is found, and an overload isn't")
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.format : format;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import silver.loader : standardLibraryPath;

    auto directory = buildPath(tempDir(), "silver-sema-" ~ randomUUID().toString());
    mkdirRecurse(buildPath(directory, "kit"));
    scope (exit) rmdirRecurse(directory);
    write(buildPath(directory, "kit", "base.ag"), "module kit.base\ndef f(x: Int): Int => x\n"
        ~ "def g<T>(xs: [T]): Int => 0\ndef h(x: Int): Int => x\n");
    write(buildPath(directory, "kit", "middle.ag"), "module kit.middle\nforward import kit.base\n");
    write(buildPath(directory, "kit", "facade.ag"), "module kit.facade\nforward import kit.middle\n"
        ~ "def f(y: Int): Int => y\ndef g<U>(ys: [U]): Int => 1\ndef h(x: Float): Float => x\n"
        ~ "private def f(): Int => 0\n");
    auto hidden = hiddenByFacades(directory, ["kit.facade"]);
    assert(hidden == ["kit.facade.f hides kit.middle.f", "kit.facade.g hides kit.middle.g"], format("%s", hidden));
}

@("the prelude forwards every public function of std.range")
unittest
{
    import std.algorithm : canFind, filter;
    import std.array : array, join;
    import std.format : format;
    import std.sumtype : match;
    import silver.ast;
    import silver.loader : load, Packages, standardPrelude, withStandardLibrary;

    auto context = new SourceContext;
    auto program = load("import std.range
", "main.ag", Packages(withStandardLibrary([])), standardPrelude, context);
    assert(!context.collector.hasErrors, "std.range failed to load");

    string[] declared;
    string[] forwarded;
    foreach (mod; program.sortedModules)
    {
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const ImportStmt i) {
                    if (mod.name == standardPrelude && i.forward && i.path.join(".") == "std.range")
                        foreach (n; i.names) forwarded ~= n.name;
                },
                (const FunctionDecl f) {
                    if (mod.name == "std.range" && !f.isPrivate && !declared.canFind(f.name)) declared ~= f.name;
                },
                (_) {},
            );
        }
    }
    assert(declared.length > 30, "std.range's functions weren't found");
    auto missing = declared.filter!(name => !forwarded.canFind(name)).array;
    assert(missing.length == 0, format("std.range functions the prelude doesn't forward: %s", missing));
}
