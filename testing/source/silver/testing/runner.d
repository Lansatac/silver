/// `silver test`: running the tests a file declares on either backend, or both, and reporting
/// what happened. Each backend runs a test on its own, so a panic ends only that test; this
/// module turns what each one says into the same results, so they're reported alike.
module silver.testing.runner;

import std.algorithm : all, any, canFind, filter, map, sort, sum;
import std.array : array, join;
import std.conv : to;
import std.file : dirEntries, exists, isDir, readText, remove, SpanMode, write;
import std.format : format;
import std.path : baseName, buildPath, dirName, extension, stripExtension;
import std.string : lineSplitter, strip;

import silver.ast : DiagnosticException, formatDiagnostic, Program, SourceContext, SourceMap, Span;
import silver.codegen : executablePath, findingLibraries, findToolchain, generate, linkExecutable, Optimization,
    sharedLibrariesOf, Toolchain;
import silver.core : lowerTests, CoreProgram = Program;
import silver.interpreter.evaluator : Evaluator;
import silver.loader : companionModuleFile, companionOf, isCompanionFile, load, NativeFiles, nativesOf, Packages, standardPrelude,
    withStandardLibrary;
import silver.sema : analyze, Analysis, Target;

/// How `silver test` runs the tests.
enum TestBackend
{
    interpreter,
    llvm,
    /// Both, reporting a test the two don't agree on as a failure.
    both,
}

/// What happened to one test.
struct TestResult
{
    string name;
    /// Where the test is declared.
    string file;
    size_t line, column;
    /// Each failure in order, each saying where it happened. A panic, or `?` on `None`, is last.
    string[] failures;
    /// What the test printed.
    string output;
    /// With `-b both`, when the backends disagree: what each found, the interpreter's first.
    TestResult[] backends;

    bool passed() const => failures.length == 0;

    /// Where the test is declared, as `file(line,column)`.
    string location() const => "%s(%s,%s)".format(file, line, column);
}

/// The tests of one file.
struct FileRun
{
    string file;
    TestResult[] results;
    /// What loading and checking the file reported, formatted for showing.
    string[] diagnostics;
    /// Why the tests couldn't run, when they couldn't.
    string problem;
    /// How many of its tests no filter selected.
    size_t unselected;
}

/// Whether `--filter` with `filters` selects the test named `name`: any of them is part of the
/// name, matched case-sensitively, and no filters select every test.
bool selects(const string[] filters, string name)
{
    return filters.length == 0 || filters.any!(f => name.canFind(f));
}

/// Every `.ag` file at `path`: the file itself, or each one under the directory, in order, other
/// than those under a directory of `skipped`, which isn't looked into. A companion test file is run
/// with its module, so it's left out when the module is there.
string[] testFiles(string path, const string[] skipped = null)
{
    import std.path : buildNormalizedPath, absolutePath, filenameCmp;

    if (!isDir(path)) return [path];
    auto left = skipped.map!(s => buildNormalizedPath(absolutePath(s))).array;
    string[] files;
    void walk(string directory)
    {
        if (left.any!(s => filenameCmp(s, buildNormalizedPath(absolutePath(directory))) == 0)) return;
        foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            if (entry.isDir) walk(entry.name);
            else if (extension(entry.name) == ".ag") files ~= entry.name;
        }
    }
    walk(path);
    return files.filter!(f => !isCompanionFile(f) || !exists(companionModuleFile(f))).array.sort.release;
}

/// Runs the tests that `file` and its companion test file declare, though not those of the
/// modules it imports, loaded with `packages`. A companion is run as its module. A compiled run
/// keeps its files in `workDirectory` while it runs, and is optimized as `optimization` says.
/// Only the tests that `filters` selects run, and the file is loaded and checked even if none is.
FileRun runFile(string file, const Packages packages, TestBackend backend, string workDirectory,
    Optimization optimization = Optimization.none, const string[] filters = null)
{
    if (isCompanionFile(file) && exists(companionModuleFile(file))) file = companionModuleFile(file);
    auto run = FileRun(file);
    auto context = new SourceContext;
    Program program;
    Analysis analysis;
    NativeFiles natives;
    try
    {
        program = load(readText(file), file, packages, standardPrelude, context, companionOf(file));
        if (!context.collector.hasErrors) natives = nativesOf(program, packages, context);
        if (!context.collector.hasErrors) analysis = analyze(program, context.collector, Target.host, true);
    }
    catch (DiagnosticException e)
    {
        context.collector.report(e.diagnostic);
    }
    run.diagnostics = context.collector.diagnostics.map!(d => formatDiagnostic(d, context.sources)).array;
    if (context.collector.hasErrors)
    {
        run.problem = "it has errors";
        return run;
    }

    CoreProgram lowered;
    try
    {
        lowered = lowerTests(program, analysis);
    }
    catch (DiagnosticException e)
    {
        run.diagnostics ~= formatDiagnostic(e.diagnostic, context.sources);
        run.problem = "it can't be lowered yet";
        return run;
    }
    auto selected = lowered.tests.filter!(t => selects(filters, t.name)).array;
    run.unselected = lowered.tests.length - selected.length;
    lowered.tests = selected;
    if (lowered.tests.length == 0) return run;

    TestResult[] compiledResults;
    if (backend != TestBackend.interpreter)
    {
        run.problem = compiled(lowered, context.sources, file, workDirectory, optimization, natives, compiledResults);
        if (run.problem !is null) return run;
    }
    TestResult[] interpretedResults;
    if (backend != TestBackend.llvm)
    {
        try interpretedResults = interpreted(lowered, context.sources, natives);
        catch (DiagnosticException e)
        {
            run.diagnostics ~= formatDiagnostic(e.diagnostic, context.sources);
            run.problem = "a native it calls can't be found";
            return run;
        }
    }
    final switch (backend)
    {
        case TestBackend.interpreter:
            run.results = interpretedResults;
            break;
        case TestBackend.llvm:
            run.results = compiledResults;
            break;
        case TestBackend.both:
            run.results = agreed(interpretedResults, compiledResults);
            break;
    }
    return run;
}

private TestResult[] interpreted(CoreProgram lowered, const SourceMap sources, const NativeFiles natives)
{
    auto runs = new Evaluator(lowered, false, null, null, natives.load).runTests();
    TestResult[] results;
    foreach (i, test; lowered.tests)
    {
        auto run = runs[i];
        auto failures = run.failures.dup;
        if (run.panic !is null) failures ~= "panic: %s: %s".format(located(run.panic.span, sources), run.panic.message);
        if (run.crash !is null) failures ~= "The interpreter failed: " ~ run.crash;
        auto result = declared(test.name, test.span, sources);
        result.failures = failures;
        result.output = run.output;
        results ~= result;
    }
    return results;
}

/// Compiles the tests in `lowered` and runs them, setting `results`. Returns why that couldn't
/// be done, or null. A test that crashes is reported as one, and the run carries on after it.
private string compiled(const CoreProgram lowered, const SourceMap sources, string file, string workDirectory,
    Optimization optimization, const NativeFiles natives, out TestResult[] results)
{
    import std.parallelism : task;
    import std.process : Config, pipe, spawnProcess, thisProcessID, wait;
    import std.stdio : File;

    Toolchain toolchain;
    if (auto missing = findToolchain(toolchain)) return missing;
    string ir;
    try
    {
        ir = generate(lowered, sources);
    }
    catch (DiagnosticException e)
    {
        return "it can't be compiled yet: " ~ formatDiagnostic(e.diagnostic, sources);
    }

    auto base = buildPath(workDirectory, "silver-test-%s-%s".format(thisProcessID, baseName(file).stripExtension));
    auto irPath = base ~ ".ll", exePath = executablePath(base);
    write(irPath, ir);
    scope (exit) remove(irPath);
    auto linked = linkExecutable(toolchain, irPath, exePath, lowered.libraries, optimization, natives.link);
    if (!linked.succeeded) return "linking failed:\n" ~ linked.output;
    scope (exit) remove(exePath);

    results = lowered.tests.map!(t => declared(t.name, t.span, sources)).array;
    auto finding = findingLibraries(sharedLibrariesOf(lowered.libraries, natives.load));
    size_t next = 0;
    while (next < results.length)
    {
        auto output = pipe();
        auto errors = pipe();
        auto environment = finding.dup;
        environment["SILVER_TEST_FROM"] = next.to!string;
        auto pid = spawnProcess([exePath], File(nullDevice), output.writeEnd, errors.writeEnd, environment, Config.none);
        output.writeEnd.close();
        errors.writeEnd.close();
        // A pipe rather than a temp file: on Windows a handle to a file open here can leak into a child
        // spawned by another thread and keep the file locked. Reading both pipes at once avoids a deadlock.
        auto errorReader = task({ return cast(string) errors.readEnd.byChunk(4096).join; });
        errorReader.executeInNewThread();
        auto records = cast(string) output.readEnd.byChunk(4096).join;
        auto errorText = errorReader.yieldForce;
        auto status = wait(pid);

        auto unfinished = readRecords(records, results);
        if (unfinished == size_t.max && status == 0) break;
        // A test that never ended crashed, and if none started, the first one to run did.
        auto crashed = unfinished == size_t.max ? next : unfinished;
        if (crashed < next || crashed >= results.length) return "the test program failed:\n" ~ errorText;
        auto said = errorText.strip;
        auto how = status < 0 ? "signal %s".format(-status) : "exit status %s".format(status);
        results[crashed].failures ~= "The test crashed, with %s%s".format(how, said.length > 0 ? ": " ~ said : "");
        next = crashed + 1;
    }
    return null;
}

private enum nullDevice = () {
    version (Windows) return "NUL";
    else return "/dev/null";
}();

/// Reads the records a compiled test program wrote into `results`, as the runtime's
/// `silver.runtime.testing` describes them. Returns the index of a test that started and never
/// ended, or `size_t.max` if every one that started ended.
private size_t readRecords(string records, TestResult[] results)
{
    import std.string : indexOf;

    size_t current = size_t.max;
    while (records.length > 0)
    {
        auto newline = records.indexOf('\n');
        if (newline < 2) break;
        auto kind = records[0];
        auto length = records[2 .. newline].to!size_t;
        if (newline + 1 + length + 1 > records.length) break;
        auto text = records[newline + 1 .. newline + 1 + length];
        records = records[newline + 1 + length + 1 .. $];
        switch (kind)
        {
            case 'T': current = text.to!size_t; break;
            case 'F', 'S': results[current].failures ~= text; break;
            case 'P': results[current].failures ~= "panic: " ~ text; break;
            case 'O': results[current].output ~= text; break;
            case 'E': current = size_t.max; break;
            default: assert(0, "the runtime writes no record of kind " ~ kind);
        }
    }
    return current;
}

/// The results of running each test on both backends, with any the two disagree on failing.
private TestResult[] agreed(TestResult[] interpreted, TestResult[] compiled)
{
    TestResult[] results;
    foreach (i, test; interpreted)
    {
        auto other = compiled[i];
        if (test.failures == other.failures && test.output == other.output)
        {
            results ~= test;
            continue;
        }
        auto failures = ["The backends disagree."]
            ~ described("Interpreted", test) ~ described("Compiled", other);
        results ~= TestResult(test.name, test.file, test.line, test.column, failures, null, [test, other]);
    }
    return results;
}

private string[] described(string backend, const TestResult result)
{
    auto heading = backend ~ (result.passed ? ", it passed" : ":");
    auto lines = [heading] ~ result.failures.map!(f => indented(f)).array;
    if (result.output.length > 0) lines ~= "    Output:\n" ~ indented(indented(result.output));
    return [lines.join("\n")];
}

/// A result for the test named `name` declared at `span`, which hasn't failed yet.
private TestResult declared(string name, Span span, const SourceMap sources)
{
    auto location = sources.locate(span);
    return TestResult(name, span.file, location.line, location.column);
}

/// `file(line,column)`, as a panic's location is written.
private string located(Span span, const SourceMap sources)
{
    auto location = sources.locate(span);
    return "%s(%s,%s)".format(span.file, location.line, location.column);
}

/// What `runs` found: each failure with its values and output, and a summary last. Passing tests
/// aren't listed. `filtered` says whether `--filter` chose the tests.
string report(const FileRun[] runs, bool filtered = false)
{
    string text;
    foreach (run; runs)
    {
        foreach (diagnostic; run.diagnostics) text ~= diagnostic ~ "\n";
        if (run.problem !is null) text ~= "The tests in %s didn't run: %s\n".format(run.file, run.problem);
        foreach (result; run.results.filter!(r => !r.passed))
        {
            text ~= "FAIL \"%s\" at %s\n".format(result.name, result.location);
            foreach (failure; result.failures) text ~= indented(failure) ~ "\n";
            if (result.output.length > 0) text ~= "    Output:\n" ~ indented(indented(result.output)) ~ "\n";
        }
    }

    auto total = runs.map!(r => r.results.length).sum;
    auto failed = runs.map!(r => r.results.filter!(t => !t.passed).array.length).sum;
    auto unrun = runs.filter!(r => r.problem !is null).array.length;
    auto unselected = runs.map!(r => r.unselected).sum;
    if (total == 0 && unrun == 0) return text ~ (filtered ? "No tests match the filter\n" : "No tests found\n");
    text ~= "%s passed, %s failed".format(total - failed, failed);
    if (unselected > 0) text ~= ", %s filtered out".format(unselected);
    if (unrun > 0) text ~= ", and %s %s couldn't run".format(unrun, unrun == 1 ? "file" : "files");
    return text ~ "\n";
}

/// Whether every test in `runs` ran and passed. When `--filter` chose the tests, as `filtered`
/// says, it has to have chosen at least one, so that a filter matching nothing isn't a success.
bool succeeded(const FileRun[] runs, bool filtered = false)
{
    if (filtered && runs.all!(r => r.results.length == 0)) return false;
    return runs.all!(r => r.problem is null && r.results.all!(t => t.passed));
}

/// `text` with each line indented by four spaces.
private string indented(string text)
{
    return text.lineSplitter.map!(line => line.length > 0 ? "    " ~ line : line).join("\n");
}

@("a compiled test program's records fill in each test, and a test that never ended is the one that crashed")
unittest
{
    auto results = [TestResult("a"), TestResult("b"), TestResult("c")];
    enum records = "T 1\n0\nO 3\nhi\n\nF 4\nlost\nO 1\n!\nE 0\n\nT 1\n1\nP 12\nm.ag(1,1): x\nE 0\n\nT 1\n2\nO 2\nab\n";
    assert(readRecords(records, results) == 2);
    assert(results[0].failures == ["lost"] && results[0].output == "hi\n!");
    assert(results[1].failures == ["panic: m.ag(1,1): x"] && results[1].output is null);
    assert(results[2].passed && results[2].output == "ab");
    assert(readRecords("T 1\n0\nE 0\n\n", results) == size_t.max);
}

@("the report lists only failed tests, then a summary")
unittest
{
    assert(report([FileRun("a.ag")]) == "No tests found\n");
    auto run = FileRun("a.ag", [TestResult("ok", "a.ag", 1, 6), TestResult("bad", "a.ag", 2, 6,["a.ag(2,13): x\n    left: 1"], "out\n")]);
    assert(report([run, FileRun("b.ag", null, ["b.ag(1,1): Error"], "it has errors")]) ==
        "FAIL \"bad\" at a.ag(2,6)\n    a.ag(2,13): x\n        left: 1\n    Output:\n        out\n"
        ~ "b.ag(1,1): Error\nThe tests in b.ag didn't run: it has errors\n1 passed, 1 failed, and 1 file couldn't run\n");
    assert(succeeded([FileRun("a.ag", [TestResult("ok")])]) && !succeeded([run]));
}

version (unittest)
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.uuid : randomUUID;
    import silver.ast : Package;

    /// The standard library, and `directory` as a test's unnamed package.
    Packages fixtures(string directory)
    {
        return Packages(withStandardLibrary([Package(null, directory)]));
    }

    /// A fresh directory under the temp dir holding `files` (path to text). The caller removes it.
    private string testDirectory(string name, string[string] files)
    {
        auto directory = buildPath(tempDir, "silver-runner-" ~ name ~ "-" ~ randomUUID().toString());
        foreach (path, text; files)
        {
            mkdirRecurse(dirName(buildPath(directory, path)));
            write(buildPath(directory, path), text);
        }
        return directory;
    }

    /// The codes of what running the tests of `file` reported, which has to stop them running.
    private string[] reportedCodes(string file)
    {
        import std.regex : matchFirst;

        auto run = runFile(file, fixtures(dirName(file)), TestBackend.interpreter, tempDir);
        assert(run.problem == "it has errors", run.problem);
        return run.diagnostics.map!(d => d.matchFirst(`Error ([A-Z]\d{4})`)[1]).array;
    }
}

@("a native that can't be found keeps the file's tests from running interpreted, and says which")
unittest
{
    import std.algorithm : canFind;

    auto directory = testDirectory("missing-native", ["calls.ag":
        "native def silver_no_such_function(): Int\ntest \"t\" => expect(silver_no_such_function() == 1)"]);
    scope (exit) rmdirRecurse(directory);

    auto run = runFile(buildPath(directory, "calls.ag"), fixtures(directory), TestBackend.interpreter, tempDir);
    assert(run.problem == "a native it calls can't be found", run.problem);
    assert(run.results.length == 0);
    auto shown = run.diagnostics.join("\n");
    assert(shown.canFind("calls.ag(2,20): Error R0002: `silver_no_such_function` can't be called when interpreting"), shown);
}

@("a companion test file's helpers and imports reach neither its module's own code nor its module's importers")
unittest
{
    import std.algorithm : canFind;

    auto directory = testDirectory("companion-hidden", [
        "app/shape.ag": "module app.shape\nimport app.user\ndef area(): Int => helper() + e()\ntest \"t\" => expect(use() == 2)",
        "app/shape.test.ag": "import extra\ndef helper(): Int => e()\nval answer: Int = 3\ntest \"u\" => expect(helper() == 1)",
        "app/user.ag": "module app.user\nimport app.shape\ndef use(): Int => helper() + app.shape.answer",
        "extra.ag": "module extra\ndef e(): Int => 1",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto run = runFile(buildPath(directory, "app", "shape.ag"), fixtures(directory), TestBackend.interpreter, tempDir);
    assert(run.problem == "it has errors");
    auto shown = run.diagnostics.join("\n");
    assert(shown.canFind("shape.ag(3,20): Error S0002: Unknown name 'helper'"), shown);
    assert(shown.canFind("shape.ag(3,31): Error S0002: Unknown name 'e'"), shown);
    assert(shown.canFind("user.ag(3,19): Error S0002: Unknown name 'helper'"), shown);
    assert(shown.canFind("user.ag(3,30): Error S0004: Module 'app.shape' has no 'answer'"), shown);
    assert(run.diagnostics.length == 4, shown);
}

@("a companion test file can't declare a function named like one of its module's, and its constant, type or test of a module's name is a duplicate")
unittest
{
    auto directory = testDirectory("companion-duplicates", [
        "shape.ag": "def area(x: Int): Int => x\nval side: Int = 1\ntype Box(n: Int)\ntest \"t\" => expect(true)",
        "shape.test.ag": "def area(y: Int): Int => y\ndef area(x: Float): Float => x\nval side: Int = 2\ntype Box(m: Int)\n"
            ~ "test \"t\" => expect(true)",
    ]);
    scope (exit) rmdirRecurse(directory);

    assert(reportedCodes(buildPath(directory, "shape.ag")) == ["S0033", "S0033", "S0001", "S0001", "S0001"]);
}

@("a companion test file runs with its module, whether its module or it is named, and only by silver test")
unittest
{
    auto directory = testDirectory("companion-named", [
        "shape.ag": "private def area(): Int => 1\ntest \"inline\" => expect(area() == 1)",
        "shape.test.ag": "test \"companion\" => expect(area() == 2)",
        "orphan.test.ag": "test \"lost\" => expect(true)",
    ]);
    scope (exit) rmdirRecurse(directory);

    assert(testFiles(directory) == [buildPath(directory, "orphan.test.ag"), buildPath(directory, "shape.ag")]);
    foreach (named; ["shape.ag", "shape.test.ag"])
    {
        auto run = runFile(buildPath(directory, named), fixtures(directory), TestBackend.interpreter, tempDir);
        assert(run.file == buildPath(directory, "shape.ag"));
        assert(run.results.map!(r => r.name).array == ["inline", "companion"]);
        assert(run.results.map!(r => r.passed).array == [true, false]);
    }
    assert(reportedCodes(buildPath(directory, "orphan.test.ag")) == ["L0006"]);
}

@("a conformance in a module only the companion test file imports doesn't change what its module's code means")
unittest
{
    auto directory = testDirectory("companion-conformance", [
        "shape.ag": "module shape\ninterface Named {\n    def name(value: Self): String\n}\n"
            ~ "def describe<T>(x: T): String => if type T: Named => name(x) else \"plain\"\n"
            ~ "test \"as built\" => expect(describe(1) == \"plain\")",
        "shape.test.ag": "import fakes\ntest \"companion\" => expect(true)",
        "fakes.ag": "module fakes\nimport shape\ndef name(value: Int): String => \"named\"\nconform Int: Named",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto run = runFile(buildPath(directory, "shape.ag"), fixtures(directory), TestBackend.interpreter, tempDir);
    // Either the conformance is refused, or the module's own test sees what a build would.
    assert(run.problem !is null || run.results.all!(r => r.passed), run.results.map!(r => r.failures.join("\n")).join("\n"));
}

@("a companion test file reaches its module's private members qualified, as the module itself can")
unittest
{
    auto directory = testDirectory("companion-qualified", [
        "app/shape.ag": "module app.shape\nimport app.shape\nprivate def hidden(): Int => 1\nprivate type Secret(n: Int)\n"
            ~ "test \"own\" => expect(app.shape.hidden() == 1)",
        "app/shape.test.ag": "import app.shape\n"
            ~ "test \"companion\" => expect(app.shape.hidden() == app.shape.Secret(1).n)",
    ]);
    scope (exit) rmdirRecurse(directory);

    auto run = runFile(buildPath(directory, "app", "shape.ag"), fixtures(directory), TestBackend.interpreter, tempDir);
    assert(run.problem is null, run.diagnostics.join("\n"));
    assert(run.results.all!(r => r.passed));
}

@("a directory named as a companion test file is reported or ignored, not thrown")
unittest
{
    import std.exception : assertNotThrown;
    import std.file : mkdir;

    auto directory = testDirectory("companion-directory", ["shape.ag": "test \"t\" => expect(true)"]);
    scope (exit) rmdirRecurse(directory);
    mkdir(buildPath(directory, "shape.test.ag"));

    assertNotThrown(runFile(buildPath(directory, "shape.ag"), fixtures(directory), TestBackend.interpreter, tempDir));
    assertNotThrown(testFiles(directory).map!(f => runFile(f, fixtures(directory), TestBackend.interpreter, tempDir)).array);
}

@("a companion test file that isn't UTF-8 is reported, not thrown")
unittest
{
    auto directory = testDirectory("companion-unreadable", ["shape.ag": "test \"t\" => expect(true)", "shape.test.ag": "\xFF\xFE"]);
    scope (exit) rmdirRecurse(directory);

    assert(reportedCodes(buildPath(directory, "shape.ag")) == ["L0009"]);
}
