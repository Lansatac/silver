module conformance;

version (unittest)
{
    import std.algorithm : canFind, filter, map, sort;
    import std.array : array, join;
    import std.conv : to;
    import std.file : dirEntries, exists, mkdirRecurse, readText, rmdirRecurse, SpanMode, tempDir, write;
    import std.parallelism : taskPool;
    import std.path : baseName, buildNormalizedPath, buildPath, dirName, dirSeparator, stripExtension;
    import std.process : environment, pipeProcess, Redirect, thisProcessID, wait;
    import std.range : chunks;
    import std.stdio : File, stdin, writeln;
    import std.string : lineSplitter, replace, startsWith, strip;
    import silver.ast : DiagnosticException, formatDiagnostic, Program, SourceContext;
    import silver.codegen : executablePath, findToolchain, generate, linkExecutable, Toolchain;
    import silver.core : lowerProgram, CoreProgram = Program;
    import silver.interpreter.evaluator : Evaluator;
    import silver.loader : load, standardLibraryPath;
    import silver.sema : analyze, Analysis, Target;
    import silver.testing : report, runFile, TestBackend;

    string conformanceDirectory()
    {
        return buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..");
    }

    struct Case
    {
        string name;
        string sourcePath;
        /// What the program prints; for a panic case, what it prints before panicking.
        string expected;
        /// The panic message, from `.panic`. Only `panics/` cases have one.
        string panicMessage;
        /// The program's standard input, from `.stdin`. Null when the case has none.
        string inputPath;
    }

    /// Every `*.ag` in `directory` under conformance/ with its `.expected` output, sorted by name.
    Case[] casesIn(string directory)
    {
        auto casesDirectory = buildPath(conformanceDirectory, directory);
        Case[] result;
        foreach (entry; dirEntries(casesDirectory, "*.ag", SpanMode.shallow))
        {
            auto name = baseName(entry.name).stripExtension;
            auto expectedPath = buildPath(casesDirectory, name ~ ".expected");
            assert(exists(expectedPath), "Missing expected output file for " ~ entry.name);
            auto panicPath = buildPath(casesDirectory, name ~ ".panic");
            auto panicMessage = exists(panicPath) ? readText(panicPath).strip : null;
            auto inputPath = buildPath(casesDirectory, name ~ ".stdin");
            result ~= Case(name, entry.name, readText(expectedPath).normalizeNewlines, panicMessage,
                exists(inputPath) ? inputPath : null);
        }
        assert(result.length > 0, "No conformance .ag files were found in " ~ directory);
        return result.sort!((a, b) => a.name < b.name).release;
    }

    /// Programs that run to the end.
    Case[] cases()
    {
        return casesIn("tests");
    }

    /// Programs that fail at runtime. Both backends must report the same message and stop
    /// with a failing status, after printing the same output.
    Case[] panicCases()
    {
        return casesIn("panics");
    }

    /// Programs run for their tests, whose `.expected` is what `silver test` reports, with each
    /// location relative to testing/.
    Case[] testingCases()
    {
        return casesIn("testing");
    }

    /// Runs the tests of `c` on `backend`, and returns why the report isn't the expected one, or null.
    string runTesting(Case c, TestBackend backend, string workDirectory)
    {
        auto text = report([runFile(c.sourcePath, [], backend, workDirectory)]);
        return compareOutput(c, text.replace(dirName(c.sourcePath) ~ dirSeparator, "").normalizeNewlines);
    }

    string normalizeNewlines(string text)
    {
        return text.replace("\r\n", "\n");
    }

    /// Loads and analyzes `c`. Returns why that failed, or null if it worked.
    string loadAndAnalyze(Case c, SourceContext context, out Program program, out Analysis analysis)
    {
        program = load(readText(c.sourcePath), c.sourcePath, [standardLibraryPath(), dirName(c.sourcePath)], context);
        if (!context.collector.hasErrors)
        {
            analysis = analyze(program, context.collector, Target.host);
        }
        if (!context.collector.hasErrors)
        {
            return null;
        }
        return "loading or analyzing reported errors:\n"
            ~ context.collector.errors.map!(d => formatDiagnostic(d, context.sources)).join("\n");
    }

    /// Loads, analyzes and lowers `c` to Core. Returns why that failed, or null if it worked.
    string prepare(Case c, SourceContext context, out Program program, out CoreProgram lowered)
    {
        Analysis analysis;
        if (auto failure = loadAndAnalyze(c, context, program, analysis))
        {
            return failure;
        }
        try
        {
            lowered = lowerProgram(program, analysis);
        }
        catch (DiagnosticException e)
        {
            return "lowering failed: " ~ formatDiagnostic(e.diagnostic, context.sources);
        }
        // Throwable, so a failed assertion counts against its case alone.
        catch (Throwable e)
        {
            return "lowering threw: " ~ e.msg ~ " (" ~ e.file ~ ":" ~ e.line.to!string ~ ")";
        }
        return null;
    }

    /// The cases a backend isn't expected to pass yet, from `file` in conformance/. Each passing
    /// case is removed from its list, and one that passes while still listed is a failure.
    string[] pendingCases(string file)
    {
        auto path = buildPath(conformanceDirectory, file);
        if (!exists(path))
        {
            return [];
        }
        return readText(path).lineSplitter
            .map!(line => line.strip)
            .filter!(line => line.length > 0 && !line.startsWith("#"))
            .array;
    }

    enum interpretedPending = "interpreted-pending.txt";
    enum compiledPending = "compiled-pending.txt";

    /// Why each case in `items` failed, by name, from `results` in the same order.
    string[string] failuresByName(Case[] items, string[] results)
    {
        string[string] failures;
        foreach (i, c; items)
        {
            if (results[i] !is null)
            {
                failures[c.name] = results[i];
            }
        }
        return failures;
    }

    /// What's wrong with a run of `all` that had `failed` against the pending list `file`, or
    /// null if nothing is: every failure is pending, and every pending case failed.
    string pendingProblems(string what, Case[] all, string[string] failed, string file)
    {
        auto pending = pendingCases(file);
        string[] failures;
        foreach (name; failed.keys.sort)
        {
            if (!pending.canFind(name))
            {
                failures ~= name ~ ": " ~ failed[name];
            }
        }
        auto unexpectedPasses = all.map!(c => c.name).filter!(name => pending.canFind(name) && name !in failed).array;

        string message;
        if (failures.length > 0)
        {
            message ~= what ~ " failures:\n\n" ~ failures.join("\n\n") ~ "\n\n";
        }
        if (unexpectedPasses.length > 0)
        {
            message ~= "These now pass; remove them from " ~ file ~ ": " ~ unexpectedPasses.join(", ");
        }
        return message.length == 0 ? null : message;
    }

    struct CompiledRun
    {
        int status;
        string output;
    }

    /// Compiles `c` in `workDirectory` and runs it. Returns why it couldn't, or null with `run` set.
    string compileAndRun(Case c, const Toolchain toolchain, string workDirectory, out CompiledRun run)
    {
        auto context = new SourceContext();
        Program program;
        CoreProgram lowered;
        if (auto failure = prepare(c, context, program, lowered))
        {
            return failure;
        }

        string ir;
        try
        {
            ir = generate(lowered, program.sources);
        }
        catch (DiagnosticException e)
        {
            return "codegen failed: " ~ formatDiagnostic(e.diagnostic, context.sources);
        }
        // Throwable, so a failed assertion in codegen counts against its case alone.
        catch (Throwable e)
        {
            return "codegen threw: " ~ e.msg ~ " (" ~ e.file ~ ":" ~ e.line.to!string ~ ")";
        }

        auto irPath = buildPath(workDirectory, c.name ~ ".ll");
        auto exePath = executablePath(buildPath(workDirectory, c.name));
        write(irPath, ir);
        auto linked = linkExecutable(toolchain, irPath, exePath, lowered.libraries);
        if (!linked.succeeded)
        {
            return "linking failed (IR kept at " ~ irPath ~ "):\n" ~ linked.output;
        }

        auto process = pipeProcess([exePath], Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout);
        if (c.inputPath !is null)
        {
            process.stdin.rawWrite(readText(c.inputPath).normalizeNewlines);
        }
        process.stdin.close();
        auto output = process.stdout.byChunk(4096).join;
        auto status = wait(process.pid);
        run = CompiledRun(status, (cast(string) output).normalizeNewlines);
        return null;
    }

    /// Runs `evaluator` with `c`'s input as standard input.
    void runWithInput(Case c, Evaluator evaluator)
    {
        if (c.inputPath is null)
        {
            evaluator.run();
            return;
        }
        // Standard input is global, and cases run concurrently.
        synchronized
        {
            auto original = stdin;
            stdin = File(c.inputPath, "r");
            scope (exit) stdin = original;
            evaluator.run();
        }
    }

    /// `run` applied to every item concurrently, in the order of `items`.
    string[] inParallel(T)(T[] items, string delegate(T) run)
    {
        auto results = new string[](items.length);
        foreach (i, item; taskPool.parallel(items, 1))
        {
            results[i] = run(item);
        }
        return results;
    }


    enum bundleSize = 12;
    enum bundleEntry = "conformanceEntry";

    struct Bundle
    {
        /// A generated program running every member in turn.
        Case program;
        Case[] members;
    }

    /// Whether `c` can run as an imported module, in a process shared with other cases.
    bool isBundleable(Case c)
    {
        bool importsSibling(string line)
        {
            auto statement = line.startsWith("public ") ? line["public ".length .. $] : line;
            return statement.startsWith("import ") && !statement.startsWith("import std");
        }

        if (c.inputPath !is null)
        {
            return false;
        }
        auto lines = readText(c.sourcePath).lineSplitter.map!(line => line.strip).array;
        return lines.canFind!(line => line.startsWith("def main("))
            && !lines.canFind!(line => line.startsWith("module ") || importsSibling(line));
    }

    /// Writes `members` to `directory` as modules, and a program there that runs each of them.
    Bundle makeBundle(string name, Case[] members, string directory)
    {
        mkdirRecurse(directory);
        string imports;
        string calls;
        string expected;
        foreach (c; members)
        {
            auto moduleName = "t_" ~ c.name.replace("-", "_");
            auto source = ("module " ~ moduleName ~ "\n" ~ readText(c.sourcePath))
                .replace("\ndef main(", "\ndef " ~ bundleEntry ~ "(");
            write(buildPath(directory, moduleName ~ ".ag"), source);
            imports ~= "import " ~ moduleName ~ "\n";
            calls ~= "    " ~ moduleName ~ "." ~ bundleEntry ~ "()\n";
            expected ~= c.expected;
        }
        auto path = buildPath(directory, "bundle.ag");
        write(path, imports ~ "def main(): Unit {\n" ~ calls ~ "}\n");
        return Bundle(Case(name, path, expected, null, null), members);
    }

    /// Why each case in `all` failed when compiled, by name; a case that passed has no entry.
    /// A bundle that fails has its members rerun alone, so failures are reported per case.
    string[string] compiledFailures(Case[] all, const string[] pending, const Toolchain toolchain, string workDirectory)
    {
        Case[] alone;
        Case[] grouped;
        auto bundling = environment.get("SILVER_CONFORMANCE_UNBUNDLED") is null;
        foreach (c; all)
        {
            if (bundling && !pending.canFind(c.name) && isBundleable(c))
            {
                grouped ~= c;
            }
            else
            {
                alone ~= c;
            }
        }

        Bundle[] bundles;
        foreach (members; grouped.chunks(bundleSize))
        {
            auto name = "bundle-" ~ bundles.length.to!string;
            bundles ~= makeBundle(name, members, buildPath(workDirectory, name ~ ".src"));
        }
        auto programs = bundles.map!(b => b.program).array;
        auto bundleResults = inParallel(programs, (Case c) => runCompiled(c, toolchain, workDirectory));
        foreach (i, bundle; bundles)
        {
            if (bundleResults[i] !is null)
            {
                alone ~= bundle.members;
            }
        }

        auto results = inParallel(alone, (Case c) => runCompiled(c, toolchain, workDirectory));
        string[string] failures;
        foreach (i, c; alone)
        {
            if (results[i] !is null)
            {
                failures[c.name] = results[i];
            }
        }
        foreach (i, bundle; bundles)
        {
            if (bundleResults[i] !is null && !bundle.members.canFind!(c => (c.name in failures) !is null))
            {
                failures[bundle.program.name] = "failed, though its members pass alone ("
                    ~ bundle.members.map!(c => c.name).join(", ") ~ "): " ~ bundleResults[i];
            }
        }
        return failures;
    }

    /// Compiles and runs `c`, and returns why its output didn't match, or null if it did.
    string runCompiled(Case c, const Toolchain toolchain, string workDirectory)
    {
        CompiledRun run;
        if (auto failure = compileAndRun(c, toolchain, workDirectory, run))
        {
            return failure;
        }
        if (run.status != 0)
        {
            return "the program exited with status " ~ run.status.to!string ~ ":\n" ~ run.output;
        }
        return compareOutput(c, run.output);
    }

    /// Compiles and runs the panic case `c`, and returns why it didn't panic as expected, or null.
    string runCompiledPanic(Case c, const Toolchain toolchain, string workDirectory)
    {
        CompiledRun run;
        if (auto failure = compileAndRun(c, toolchain, workDirectory, run))
        {
            return failure;
        }
        if (run.status != 1)
        {
            return "expected exit status 1, got " ~ run.status.to!string ~ ":\n" ~ run.output;
        }
        if (!run.output.startsWith(c.expected ~ "panic: ") || !run.output.canFind(c.panicMessage))
        {
            return "output differs.\n--- expected\n" ~ c.expected ~ "panic: ... " ~ c.panicMessage
                ~ "\n--- actual\n" ~ run.output;
        }
        return null;
    }

    /// Interprets the panic case `c`, and returns why it didn't fail as expected, or null.
    string runInterpretedPanic(Case c)
    {
        auto context = new SourceContext();
        Program program;
        CoreProgram lowered;
        if (auto failure = prepare(c, context, program, lowered))
        {
            return failure;
        }

        auto evaluator = new Evaluator(lowered);
        try
        {
            runWithInput(c, evaluator);
        }
        catch (DiagnosticException e)
        {
            if (e.diagnostic.message != c.panicMessage)
            {
                return "expected the error `" ~ c.panicMessage ~ "`, got `" ~ e.diagnostic.message ~ "`";
            }
            return compareOutput(c, evaluator.output);
        }
        return "expected the error `" ~ c.panicMessage ~ "`, but the program finished";
    }

    /// Interprets `c` and returns why its output didn't match, or null if it did.
    string runInterpreted(Case c)
    {
        auto context = new SourceContext();
        Program program;
        CoreProgram lowered;
        if (auto failure = prepare(c, context, program, lowered))
        {
            return failure;
        }

        auto evaluator = new Evaluator(lowered);
        try
        {
            runWithInput(c, evaluator);
        }
        catch (DiagnosticException e)
        {
            return "the program failed at runtime: " ~ formatDiagnostic(e.diagnostic, context.sources)
                ~ "\n--- output so far\n" ~ evaluator.output;
        }
        return compareOutput(c, evaluator.output);
    }

    /// Why `actual` isn't `c`'s expected output, or null if it is.
    string compareOutput(Case c, string actual)
    {
        if (actual == c.expected)
        {
            return null;
        }
        return "output differs.\n--- expected\n" ~ c.expected ~ "\n--- actual\n" ~ actual;
    }
}

@("Interpreted conformance programs match their expected output")
unittest
{
    auto all = cases;
    auto failed = failuresByName(all, inParallel(all, (Case c) => runInterpreted(c)));
    auto problems = pendingProblems("Interpreted conformance", all, failed, interpretedPending);
    assert(problems is null, problems);
}

@("Compiled conformance programs match their expected output")
unittest
{
    Toolchain toolchain;
    if (auto missing = findToolchain(toolchain))
    {
        writeln("    note: ", missing, " Compiled conformance was skipped.");
        return;
    }

    auto workDirectory = buildPath(tempDir, "silver-conformance-" ~ thisProcessID.to!string);
    mkdirRecurse(workDirectory);

    auto all = cases;
    auto failed = compiledFailures(all, pendingCases(compiledPending), toolchain, workDirectory);
    auto problems = pendingProblems("Compiled conformance", all, failed, compiledPending);
    // Failures keep their IR for inspection; a clean run leaves nothing behind.
    if (problems is null)
    {
        rmdirRecurse(workDirectory);
    }
    assert(problems is null, problems);
}

@("Interpreted programs that panic report the expected error")
unittest
{
    auto all = panicCases;
    auto failed = failuresByName(all, inParallel(all, (Case c) => runInterpretedPanic(c)));
    auto problems = pendingProblems("Interpreted panic", all, failed, interpretedPending);
    assert(problems is null, problems);
}

@("Compiled programs that panic report the expected error and exit with status 1")
unittest
{
    Toolchain toolchain;
    if (auto missing = findToolchain(toolchain))
    {
        writeln("    note: ", missing, " Compiled panic conformance was skipped.");
        return;
    }

    auto workDirectory = buildPath(tempDir, "silver-conformance-panics-" ~ thisProcessID.to!string);
    mkdirRecurse(workDirectory);

    auto all = panicCases;
    auto failed = failuresByName(all, inParallel(all, (Case c) => runCompiledPanic(c, toolchain, workDirectory)));
    auto problems = pendingProblems("Compiled panic", all, failed, compiledPending);
    if (problems is null)
    {
        rmdirRecurse(workDirectory);
    }
    assert(problems is null, problems);
}

@("Interpreted tests report what the expected report says")
unittest
{
    auto all = testingCases;
    auto failed = failuresByName(all, inParallel(all, (Case c) => runTesting(c, TestBackend.interpreter, tempDir)));
    auto problems = pendingProblems("Interpreted testing", all, failed, interpretedPending);
    assert(problems is null, problems);
}

@("Compiled tests report what the expected report says")
unittest
{
    Toolchain toolchain;
    if (auto missing = findToolchain(toolchain))
    {
        writeln("    note: ", missing, " Compiled testing conformance was skipped.");
        return;
    }

    auto all = testingCases;
    auto failed = failuresByName(all, inParallel(all, (Case c) => runTesting(c, TestBackend.llvm, tempDir)));
    auto problems = pendingProblems("Compiled testing", all, failed, compiledPending);
    assert(problems is null, problems);
}
