/// Runs a package's unittests, as silly did, but spread over worker processes rather than threads.
/// D's GC takes one lock for every allocation, so tests that allocate heavily in threads of one
/// process mostly wait on each other: sema's ran 1.6x faster on 12 threads, and 3.7x as fast
/// again in separate processes. Each worker is the test executable started again with
/// `--worker`; the parent sends it a test's index on standard input, one at a time, and it writes
/// the result on standard output in lines starting with `marker`. Anything else a test prints
/// comes through on the same pipe and is shown with its result.
module silver.testrunner;

version (unittest):

static if (!__traits(compiles, () { static import dub_test_root; }))
{
    static assert(false, "silver.testrunner finds tests through dub_test_root, which `dub test` generates");
}
else
{
    static import dub_test_root;
}

import core.runtime : Runtime, UnitTestResult;
import core.time : Duration, MonoTime;
import std.stdio : File, stderr, stdin, stdout;

shared static this()
{
    Runtime.extendedModuleUnitTester = &runTests;
}

private:

/// Starts every line of a worker's report. A control character, so no test's output starts one.
enum marker = "\x1Esilver-test ";

struct Options
{
    uint jobs;
    string include;
    string exclude;
    bool inProcess;
    bool failFast;
    uint durations;
    bool list;
    bool noColours;
    bool verbose;
    bool worker;
}

struct Test
{
    /// The module, or the aggregate the test is in.
    string scope_;
    string name;
    string file;
    size_t line;
    void function() run;
}

struct Result
{
    bool passed;
    Duration duration;
    /// The result as it's printed: the line naming the test, and why it failed.
    string report;
}

UnitTestResult runTests()
{
    import std.getopt : defaultGetoptPrinter, getopt, GetOptException;

    Options options;
    auto args = Runtime.args.dup;
    try
    {
        auto help = getopt(args,
            "t|threads|j|jobs", "Worker processes, or 0 for one per CPU (the default)", &options.jobs,
            "i|include", "Run only the tests whose module and name match this regular expression", &options.include,
            "e|exclude", "Skip the tests whose module and name match this regular expression", &options.exclude,
            "in-process", "Run the tests one at a time in this process, as under a debugger", &options.inProcess,
            "fail-fast", "Start no more tests once one fails", &options.failFast,
            "durations", "List the N slowest tests after the summary", &options.durations,
            "list", "List the tests that would run, and run none", &options.list,
            "no-colours", "Don't colour the output", &options.noColours,
            "v|verbose", "Show each test's duration and location, and whole stack traces", &options.verbose,
            "worker", "Run the tests a parent names on standard input (used by the runner itself)", &options.worker,
        );
        if (help.helpWanted)
        {
            defaultGetoptPrinter("Usage: dub test [<package>] -- [options]", help.options);
            return UnitTestResult(0, 0, false, false);
        }
        if (args.length > 1)
        {
            throw new GetOptException("Unexpected argument " ~ args[1]);
        }
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg);
        return UnitTestResult(1, 0, false, false);
    }

    auto tests = allTests();
    if (options.worker)
    {
        colours = !options.noColours;
        serveParent(tests, options);
        return UnitTestResult(0, 0, false, false);
    }
    colours = !options.noColours && stdoutIsTerminal();

    auto selected = select(tests, options);
    if (selected.length == 0 && (options.include.length > 0 || options.exclude.length > 0))
    {
        stderr.writeln("No tests matched the filters");
        return UnitTestResult(1, 0, false, false);
    }
    if (options.list)
    {
        foreach (index; selected)
        {
            stdout.writeln(tests[index].scope_, " ", tests[index].name);
        }
        return UnitTestResult(0, 0, false, false);
    }

    auto started = MonoTime.currTime;
    auto run = new Run(tests, options);
    if (options.inProcess || selected.length <= 1)
    {
        foreach (index; selected)
        {
            if (run.stopping) break;
            run.record(index, execute(tests[index], options.verbose), null);
        }
    }
    else
    {
        runInWorkers(run, selected, options);
    }
    run.summarize(MonoTime.currTime - started);
    return UnitTestResult(run.passed + run.failed, run.passed, false, false);
}

/// What the tests of one run came to, recorded from the threads that feed the workers.
final class Run
{
    Test[] tests;
    Options options;
    size_t passed;
    size_t failed;
    bool stopping;
    size_t workers;
    struct Timing
    {
        Duration duration;
        size_t index;
    }
    Timing[] timings;

    this(Test[] tests, Options options)
    {
        this.tests = tests;
        this.options = options;
    }

    /// Prints the result of the test at `index`, with what the test printed.
    void record(size_t index, Result result, const string[] output)
    {
        synchronized (this)
        {
            stdout.write(result.report);
            foreach (line; output)
            {
                stdout.writeln("    | ", line);
            }
            stdout.flush();
            if (result.passed) ++passed;
            else ++failed;
            timings ~= Timing(result.duration, index);
            if (!result.passed && options.failFast) stopping = true;
        }
    }

    void summarize(Duration elapsed)
    {
        import std.algorithm : min, sort;
        import std.format : format;

        auto how = workers > 0 ? format(" on %s worker processes", workers) : "";
        stdout.writefln("\n%s: %s passed, %s failed in %d ms%s", emphasis("Summary"),
            colour(passed, Colour.ok), colour(failed, failed > 0 ? Colour.failed : Colour.none),
            elapsed.total!"msecs", how);
        if (options.durations > 0)
        {
            timings.sort!((a, b) => a.duration > b.duration);
            stdout.writeln("\nSlowest:");
            foreach (timing; timings[0 .. min(options.durations, timings.length)])
            {
                auto test = tests[timing.index];
                stdout.writefln("  %8.0f ms  %s %s", timing.duration.total!"usecs" / 1000.0, test.scope_, test.name);
            }
        }
    }
}

void runInWorkers(Run run, const size_t[] selected, Options options)
{
    import core.atomic : atomicOp;
    import core.thread : Thread;
    import std.algorithm : min;
    import std.file : thisExePath;
    import std.parallelism : totalCPUs;

    auto command = [thisExePath, "--worker"];
    if (!colours) command ~= "--no-colours";
    if (options.verbose) command ~= "--verbose";

    shared size_t next;
    void feed()
    {
        Worker worker;
        scope (exit) worker.stop();
        while (true)
        {
            bool stopping;
            synchronized (run) stopping = run.stopping;
            if (stopping) break;
            auto n = atomicOp!"+="(next, 1) - 1;
            if (n >= selected.length) break;

            auto index = selected[n];
            if (!worker.running) worker.start(command);
            string[] output;
            auto result = worker.run(index, output);
            if (!worker.running)
            {
                result = Result(false, Duration.zero, failureLine(run.tests[index], options.verbose, Duration.zero)
                    ~ "    The test's worker process " ~ worker.exitDescription ~ ".\n");
            }
            run.record(index, result, output);
        }
    }

    run.workers = min(options.jobs > 0 ? options.jobs : totalCPUs, selected.length);
    Thread[] threads;
    foreach (_; 0 .. run.workers)
    {
        threads ~= new Thread(&feed).start();
    }
    foreach (thread; threads)
    {
        thread.join();
    }
}

/// A worker process, and the pipes the parent talks to it through.
struct Worker
{
    import std.process : ProcessPipes;

    ProcessPipes pipes;
    bool running;
    string exitDescription;

    void start(string[] command)
    {
        import std.process : pipeProcess, Redirect;

        pipes = pipeProcess(command, Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout);
        running = true;
    }

    /// Runs the test at `index`, with what it printed in `output`. If the worker ends before it
    /// reports, `running` is false afterwards and the result says nothing.
    Result run(size_t index, out string[] output)
    {
        import std.conv : to;
        import std.string : chomp, indexOf, split, startsWith;
        import core.time : usecs;

        pipes.stdin.writeln(index);
        pipes.stdin.flush();
        string report;
        char[] buffer;
        while (pipes.stdout.readln(buffer) > 0)
        {
            auto line = buffer.idup.chomp;
            auto at = line.indexOf(marker);
            if (at < 0)
            {
                output ~= line;
                continue;
            }
            // A test that printed without a newline leaves the marker mid-line.
            if (at > 0) output ~= line[0 .. at];
            auto message = line[at + marker.length .. $];
            // The line the worker ends before its report, which is empty unless the test left
            // half a line.
            if (report.length == 0 && output.length > 0 && output[$ - 1].length == 0) output = output[0 .. $ - 1];
            if (message.startsWith("r "))
            {
                report ~= message[2 .. $] ~ "\n";
            }
            else if (message.startsWith("e "))
            {
                auto fields = message[2 .. $].split(' ');
                return Result(fields[0] == "1", fields[1].to!long.usecs, report);
            }
        }
        finish();
        return Result.init;
    }

    void stop()
    {
        if (!running) return;
        pipes.stdin.close();
        finish();
    }

    private void finish()
    {
        import std.conv : to;
        import std.process : wait;

        auto status = wait(pipes.pid);
        running = false;
        version (Posix)
        {
            exitDescription = status < 0 ? "was killed by signal " ~ (-status).to!string
                : "exited with status " ~ status.to!string;
        }
        else
        {
            exitDescription = "exited with status " ~ status.to!string;
        }
    }
}

/// The worker's side: runs each test whose index arrives on standard input and reports it.
void serveParent(Test[] tests, Options options)
{
    import std.conv : to;
    import std.string : lineSplitter, strip;

    // Copies, so a test that replaces stdin or stdout for a while doesn't take the pipes with it.
    auto commands = stdin;
    auto reports = stdout;
    string line;
    while ((line = commands.readln()) !is null)
    {
        auto result = execute(tests[line.strip.to!size_t], options.verbose);
        // A newline first, in case the test printed half a line.
        reports.write("\n");
        foreach (text; result.report.lineSplitter)
        {
            reports.write(marker, "r ", text, "\n");
        }
        reports.write(marker, "e ", result.passed ? "1" : "0", " ", result.duration.total!"usecs", "\n");
        reports.flush();
    }
}

Result execute(Test test, bool verbose)
{
    import std.array : appender;
    import std.format : formattedWrite;
    import std.string : lineSplitter;
    import std.algorithm : canFind;

    auto started = MonoTime.currTime;
    Throwable thrown;
    try
    {
        test.run();
    }
    catch (Throwable t)
    {
        thrown = t;
    }
    auto duration = MonoTime.currTime - started;
    if (thrown is null)
    {
        return Result(true, duration, testLine(test, true, verbose, duration));
    }

    auto report = appender!string(failureLine(test, verbose, duration));
    foreach (t; thrown)
    {
        auto lines = t.message.idup.lineSplitter;
        report.formattedWrite("    %s thrown from %s on line %d: %s\n", typeid(t).name, t.file, t.line,
            lines.empty ? "" : lines.front);
        if (!lines.empty) lines.popFront();
        foreach (line; lines) report.formattedWrite("      %s\n", line);
        if (t.info is null) continue;
        report.put("    --- Stack trace ---\n");
        foreach (frame; t.info)
        {
            // The runner's own frames, and druntime's below them, say nothing about the test.
            if (!verbose && frame.canFind(__FILE__)) break;
            report.formattedWrite("    %s\n", frame);
        }
    }
    return Result(false, duration, report[]);
}

string failureLine(Test test, bool verbose, Duration duration)
{
    return testLine(test, false, verbose, duration);
}

string testLine(Test test, bool passed, bool verbose, Duration duration)
{
    import std.format : format;

    auto line = format(" %s %s %s", passed ? colour("✓", Colour.ok) : colour("✗", Colour.failed),
        emphasis(shortened(test.scope_, verbose)), test.name);
    if (verbose)
    {
        line ~= format(" (%.3f ms) [%s:%s]", duration.total!"usecs" / 1000.0, test.file, test.line);
    }
    return line ~ "\n";
}

/// The end of a long module name, as silly showed it.
string shortened(string name, bool verbose)
{
    import std.algorithm : max;
    import std.string : indexOf;

    if (verbose || name.length <= 30) return name;
    auto dot = name.indexOf('.', name.length - 30);
    return name[dot < 0 ? name.length - 30 : max(dot, name.length - 30) .. $];
}

/// Indices into `tests` of the ones the filters let through. A test runs if it matches the
/// include pattern, when there is one, and doesn't match the exclude pattern, when there is one.
size_t[] select(const Test[] tests, Options options)
{
    import std.regex : matchFirst, regex;

    auto include = regex(options.include);
    auto exclude = regex(options.exclude);
    size_t[] selected;
    foreach (i, test; tests)
    {
        auto name = test.scope_ ~ " " ~ test.name;
        if (options.include.length > 0 && name.matchFirst(include).empty) continue;
        if (options.exclude.length > 0 && !name.matchFirst(exclude).empty) continue;
        selected ~= i;
    }
    return selected;
}

/// Every unittest in the package's modules and in their top-level aggregates, in an order that's
/// the same in the parent and its workers.
Test[] allTests()
{
    import std.meta : Alias;

    Test[] tests;
    foreach (m; dub_test_root.allModules)
    {
        static if (__traits(isModule, m))
        {
            alias module_ = m;
        }
        else
        {
            // A module with a member of its own name.
            alias module_ = Alias!(__traits(parent, m));
        }
        foreach (test; __traits(getUnitTests, module_))
        {
            tests ~= makeTest!test;
        }
        foreach (member; __traits(derivedMembers, module_))
        {
            static if (__traits(compiles, __traits(getMember, module_, member))
                && __traits(compiles, __traits(isTemplate, __traits(getMember, module_, member)))
                && !__traits(isTemplate, __traits(getMember, module_, member))
                && __traits(compiles, __traits(parent, __traits(getMember, module_, member)))
                && __traits(isSame, __traits(parent, __traits(getMember, module_, member)), module_)
                && __traits(compiles, __traits(getUnitTests, __traits(getMember, module_, member))))
            {
                foreach (test; __traits(getUnitTests, __traits(getMember, module_, member)))
                {
                    tests ~= makeTest!test;
                }
            }
        }
    }
    return tests;
}

Test makeTest(alias test)()
{
    import std.string : lastIndexOf;
    import std.traits : fullyQualifiedName;

    string name = __traits(identifier, test);
    foreach (attribute; __traits(getAttributes, test))
    {
        static if (is(typeof(attribute) : string))
        {
            name = attribute;
            break;
        }
    }
    enum qualified = fullyQualifiedName!test;
    enum location = __traits(getLocation, test);
    return Test(qualified[0 .. qualified.lastIndexOf('.')], name, location[0], location[1], &test);
}

__gshared bool colours;

enum Colour
{
    none = 0,
    ok = 32,
    failed = 31,
}

string colour(T)(T value, Colour c)
{
    import std.conv : text;

    return colours && c != Colour.none ? text("\033[", cast(int) c, "m", value, "\033[m") : text(value);
}

string emphasis(string s)
{
    return colours ? "\033[1m" ~ s ~ "\033[m" : s;
}

bool stdoutIsTerminal()
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty, STDOUT_FILENO;

        return isatty(STDOUT_FILENO) != 0;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : GetStdHandle, STD_OUTPUT_HANDLE, INVALID_HANDLE_VALUE;
        import core.sys.windows.wincon : GetConsoleMode, SetConsoleMode, SetConsoleOutputCP;
        import core.sys.windows.windef : DWORD;
        import core.sys.windows.winnls : CP_UTF8;

        enum enableVirtualTerminalProcessing = 4;
        SetConsoleOutputCP(CP_UTF8);
        auto handle = GetStdHandle(STD_OUTPUT_HANDLE);
        DWORD mode;
        return handle != INVALID_HANDLE_VALUE && GetConsoleMode(handle, &mode)
            && SetConsoleMode(handle, mode | enableVirtualTerminalProcessing);
    }
    else
    {
        return false;
    }
}
