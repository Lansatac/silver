/// `silver test`: running the tests a file declares on either backend, or both, and reporting
/// what happened. Each backend runs a test on its own, so a panic ends only that test; this
/// module turns what each one says into the same results, so they're reported alike.
module silver.testing.runner;

import std.algorithm : all, filter, map, sort, sum;
import std.array : array, join;
import std.conv : to;
import std.file : dirEntries, exists, isDir, readText, remove, SpanMode, write;
import std.format : format;
import std.path : baseName, buildPath, dirName, extension, stripExtension;
import std.string : lineSplitter, strip;

import silver.ast : DiagnosticException, formatDiagnostic, Program, SourceContext, SourceMap, Span;
import silver.codegen : executablePath, findToolchain, generate, linkExecutable, Toolchain;
import silver.core : lowerTests, CoreProgram = Program;
import silver.interpreter.evaluator : Evaluator;
import silver.loader : load, standardLibraryPath;
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
    /// Where the test is declared, as `file(line,column)`.
    string location;
    /// Each failure in order, each saying where it happened. A panic, or `?` on `None`, is last.
    string[] failures;
    /// What the test printed.
    string output;

    bool passed() const => failures.length == 0;
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
}

/// Every `.ag` file at `path`: the file itself, or each one under the directory, in order.
string[] testFiles(string path)
{
    if (!isDir(path)) return [path];
    return dirEntries(path, "*.ag", SpanMode.depth).map!(e => e.name).array.sort.release;
}

/// Runs the tests that `file` declares, though not those of the modules it imports, with
/// `importPaths` searched before the standard library and the file's own directory. A compiled
/// run keeps its files in `workDirectory` while it runs.
FileRun runFile(string file, const string[] importPaths, TestBackend backend, string workDirectory)
{
    auto run = FileRun(file);
    auto context = new SourceContext;
    Program program;
    Analysis analysis;
    try
    {
        program = load(readText(file), file, importPaths.dup ~ [standardLibraryPath(), dirName(file)], context);
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
    if (lowered.tests.length == 0) return run;

    TestResult[] compiledResults;
    if (backend != TestBackend.interpreter)
    {
        run.problem = compiled(lowered, context.sources, file, workDirectory, compiledResults);
        if (run.problem !is null) return run;
    }
    final switch (backend)
    {
        case TestBackend.interpreter:
            run.results = interpreted(lowered, context.sources);
            break;
        case TestBackend.llvm:
            run.results = compiledResults;
            break;
        case TestBackend.both:
            run.results = agreed(interpreted(lowered, context.sources), compiledResults);
            break;
    }
    return run;
}

private TestResult[] interpreted(CoreProgram lowered, const SourceMap sources)
{
    auto runs = new Evaluator(lowered).runTests();
    TestResult[] results;
    foreach (i, test; lowered.tests)
    {
        auto run = runs[i];
        auto failures = run.failures.dup;
        if (run.panic !is null) failures ~= "panic: %s: %s".format(located(run.panic.span, sources), run.panic.message);
        if (run.crash !is null) failures ~= "The interpreter failed: " ~ run.crash;
        results ~= TestResult(test.name, located(test.span, sources), failures, run.output);
    }
    return results;
}

/// Compiles the tests in `lowered` and runs them, setting `results`. Returns why that couldn't
/// be done, or null. A test that crashes is reported as one, and the run carries on after it.
private string compiled(const CoreProgram lowered, const SourceMap sources, string file, string workDirectory,
    out TestResult[] results)
{
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
    auto irPath = base ~ ".ll", exePath = executablePath(base), errorPath = base ~ ".stderr";
    write(irPath, ir);
    scope (exit) remove(irPath);
    auto linked = linkExecutable(toolchain, irPath, exePath, lowered.libraries);
    if (!linked.succeeded) return "linking failed:\n" ~ linked.output;
    scope (exit)
    {
        remove(exePath);
        if (exists(errorPath)) remove(errorPath);
    }

    results = lowered.tests.map!(t => TestResult(t.name, located(t.span, sources))).array;
    size_t next = 0;
    while (next < results.length)
    {
        auto output = pipe();
        auto errors = File(errorPath, "w");
        auto pid = spawnProcess([exePath], File(nullDevice), output.writeEnd, errors,
            ["SILVER_TEST_FROM": next.to!string], Config.none);
        auto records = cast(string) output.readEnd.byChunk(4096).join;
        auto status = wait(pid);
        errors.close();

        auto unfinished = readRecords(records, results);
        if (unfinished == size_t.max && status == 0) break;
        // A test that never ended crashed, and if none started, the first one to run did.
        auto crashed = unfinished == size_t.max ? next : unfinished;
        if (crashed < next || crashed >= results.length) return "the test program failed:\n" ~ readText(errorPath);
        auto said = readText(errorPath).strip;
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
        results ~= TestResult(test.name, test.location, failures, null);
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

/// `file(line,column)`, as a panic's location is written.
private string located(Span span, const SourceMap sources)
{
    auto location = sources.locate(span);
    return "%s(%s,%s)".format(span.file, location.line, location.column);
}

/// What `runs` found: each failure with its values and output, and a summary last. Passing tests
/// aren't listed.
string report(const FileRun[] runs)
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
    if (total == 0 && unrun == 0) return text ~ "No tests found\n";
    text ~= "%s passed, %s failed".format(total - failed, failed);
    if (unrun > 0) text ~= ", and %s %s couldn't run".format(unrun, unrun == 1 ? "file" : "files");
    return text ~ "\n";
}

/// Whether every test in `runs` ran and passed.
bool succeeded(const FileRun[] runs)
{
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
    auto run = FileRun("a.ag", [TestResult("ok", "a.ag(1,6)"), TestResult("bad", "a.ag(2,6)", ["a.ag(2,13): x\n    left: 1"], "out\n")]);
    assert(report([run, FileRun("b.ag", null, ["b.ag(1,1): Error"], "it has errors")]) ==
        "FAIL \"bad\" at a.ag(2,6)\n    a.ag(2,13): x\n        left: 1\n    Output:\n        out\n"
        ~ "b.ag(1,1): Error\nThe tests in b.ag didn't run: it has errors\n1 passed, 1 failed, and 1 file couldn't run\n");
    assert(succeeded([FileRun("a.ag", [TestResult("ok")])]) && !succeeded([run]));
}
