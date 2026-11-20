module conformance;

version (unittest)
{
    import std.algorithm : canFind, filter, map, sort;
    import std.array : array, join;
    import std.conv : to;
    import std.file : dirEntries, exists, mkdirRecurse, readBytes = read, readText, rmdirRecurse, SpanMode, tempDir, write;
    import std.parallelism : taskPool;
    import std.path : baseName, buildNormalizedPath, buildPath, dirName, dirSeparator, stripExtension;
    import std.process : environment, pipeProcess, Redirect, thisProcessID, wait;
    import std.range : chunks, front;
    import std.stdio : File, stdin, writeln;
    import std.string : lineSplitter, replace, startsWith, strip;
    import silver.ast : DiagnosticException, formatDiagnostic, Program, SourceContext;
    import silver.codegen : executablePath, findToolchain, generate, linkExecutable, Optimization, Toolchain;
    import silver.core : lowerProgram, CoreProgram = Program;
    import silver.interpreter : Evaluator, panicReport, panicStatus, ProgramFailed;
    import silver.loader : describePackages, isCompanionFile, load, Packages, standardLibraryPath, standardPrelude,
        withStandardLibrary;
    import silver.sema : analyze, Analysis, Target;
    import silver.testing : report, runFile, succeeded, TestBackend, testFiles;

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
        /// The error `main` returns, as printed, from `.error`. Only `errors/` cases have one.
        string errorMessage;
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
            // Loaded with the case it's the companion test file of.
            if (isCompanionFile(entry.name)) continue;
            auto name = baseName(entry.name).stripExtension;
            auto expectedPath = buildPath(casesDirectory, name ~ ".expected");
            assert(exists(expectedPath), "Missing expected output file for " ~ entry.name);
            auto panicPath = buildPath(casesDirectory, name ~ ".panic");
            auto panicMessage = exists(panicPath) ? readText(panicPath).strip : null;
            auto errorPath = buildPath(casesDirectory, name ~ ".error");
            auto errorMessage = exists(errorPath) ? readText(errorPath).strip : null;
            auto inputPath = buildPath(casesDirectory, name ~ ".stdin");
            result ~= Case(name, entry.name, readText(expectedPath).normalizeNewlines, panicMessage, errorMessage,
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

    /// Programs whose `main` returns an error. Both backends must print it after the same output
    /// and exit with status 1.
    Case[] errorCases()
    {
        return casesIn("errors");
    }

    /// Programs sema rejects, whose `.expected` is the first error as `code: message`. Neither
    /// backend sees them.
    Case[] rejectedCases()
    {
        return casesIn("rejected");
    }

    /// Analyzes the rejected case `c`, and returns why it wasn't rejected as expected, or null.
    string runRejected(Case c)
    {
        auto context = new SourceContext();
        Program program;
        Analysis analysis;
        if (loadAndAnalyze(c, context, program, analysis) is null) return "expected `" ~ c.expected.strip ~ "`, but it was accepted";
        auto first = context.collector.errors.front;
        auto reported = (cast(string) first.code) ~ ": " ~ first.message;
        return reported == c.expected.strip ? null : "expected `" ~ c.expected.strip ~ "`, got `" ~ reported ~ "`";
    }

    /// Programs run for their tests, whose `.expected` is what `silver test` reports, with each
    /// location relative to testing/.
    Case[] testingCases()
    {
        return casesIn("testing");
    }

    /// Runs the tests of `c` on `backend`, and returns why the report isn't the expected one, or null.
    string runTesting(Case c, TestBackend backend, string workDirectory, Optimization optimization = Optimization.none)
    {
        auto text = report([runFile(c.sourcePath, packagesFor(c), backend, workDirectory, optimization)]);
        return compareOutput(c, text.replace(dirName(c.sourcePath) ~ dirSeparator, "").normalizeNewlines);
    }

    string normalizeNewlines(string text)
    {
        return text.replace("\r\n", "\n");
    }

    /// Where `c`'s own package options would be.
    string packagesFile(Case c)
    {
        return buildPath(dirName(c.sourcePath), baseName(c.sourcePath).stripExtension ~ ".packages");
    }

    /// The packages `c` is loaded with. A case's `.packages`, when it has one, holds its command
    /// line's package options, one to a line, with directories taken from the case's own. Otherwise
    /// each `*_support` directory beside the case is a package, and the case uses them all.
    Packages packagesFor(Case c)
    {
        import std.file : isDir;
        import std.string : indexOf;

        auto directory = dirName(c.sourcePath);
        auto described = packagesFile(c);
        string[][string] options;
        if (exists(described))
        {
            foreach (line; readText(described).lineSplitter.map!(l => l.strip).filter!(l => l.length > 0))
            {
                auto space = line.indexOf(' ');
                assert(space > 0, "A line of " ~ described ~ " isn't an option and its value: " ~ line);
                options[line[0 .. space]] ~= line[space + 1 .. $].strip;
            }
        }
        else
        {
            string[] support;
            foreach (entry; dirEntries(directory, "*_support", SpanMode.shallow))
            {
                if (!entry.isDir) continue;
                auto name = baseName(entry.name);
                support ~= name;
                options["--package"] ~= name ~ "=" ~ name;
            }
            if (support.length > 0) options["--uses"] ~= support.sort.release.join(",");
        }
        Packages packages;
        auto mistake = describePackages(options.get("--package", null), options.get("--uses", null),
            options.get("--parts", null), directory, packages);
        assert(mistake is null, described ~ ": " ~ mistake);
        return packages;
    }

    /// Loads and analyzes `c`. Returns why that failed, or null if it worked.
    string loadAndAnalyze(Case c, SourceContext context, out Program program, out Analysis analysis)
    {
        program = load(readText(c.sourcePath), c.sourcePath, packagesFor(c), standardPrelude, context);
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

    /// How the compiled cases of one run are built.
    struct Build
    {
        Toolchain toolchain;
        Optimization optimization;
    }

    struct CompiledRun
    {
        int status;
        string output;
    }

    /// Compiles `c` in `workDirectory` and runs it. Returns why it couldn't, or null with `run` set.
    string compileAndRun(Case c, const Build build, string workDirectory, out CompiledRun run)
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
        auto linked = linkExecutable(build.toolchain, irPath, exePath, lowered.libraries, build.optimization);
        if (!linked.succeeded)
        {
            return "linking failed (IR kept at " ~ irPath ~ "):\n" ~ linked.output;
        }

        auto process = pipeProcess([exePath], Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout);
        if (c.inputPath !is null)
        {
            process.stdin.rawWrite(readBytes(c.inputPath));
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
            stdin = File(c.inputPath, "rb");
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
    /// The package beside a bundle's program that holds its members, found as a case's support is.
    enum bundlePackage = "bundle_support";

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

        // A bundle's members are loaded with the bundle's packages, not their own.
        if (c.inputPath !is null || exists(packagesFile(c)))
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
        mkdirRecurse(buildPath(directory, bundlePackage));
        string imports;
        string calls;
        string expected;
        foreach (c; members)
        {
            auto file = "t_" ~ c.name.replace("-", "_");
            auto moduleName = bundlePackage ~ "." ~ file;
            auto source = ("module " ~ moduleName ~ "\n" ~ readText(c.sourcePath))
                .replace("\ndef main(", "\ndef " ~ bundleEntry ~ "(");
            write(buildPath(directory, bundlePackage, file ~ ".ag"), source);
            imports ~= "import " ~ moduleName ~ "\n";
            // Dropped, since a `main` can return `Unit ! E`.
            calls ~= "    _ = " ~ moduleName ~ "." ~ bundleEntry ~ "()\n";
            expected ~= c.expected;
        }
        auto path = buildPath(directory, "bundle.ag");
        write(path, imports ~ "def main(): Unit {\n" ~ calls ~ "}\n");
        return Bundle(Case(name, path, expected, null, null, null), members);
    }

    /// Why each case in `all` failed when compiled, by name; a case that passed has no entry.
    /// A bundle that fails has its members rerun alone, so failures are reported per case.
    string[string] compiledFailures(Case[] all, const string[] pending, const Build build, string workDirectory)
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
        auto bundleResults = inParallel(programs, (Case c) => runCompiled(c, build, workDirectory));
        foreach (i, bundle; bundles)
        {
            if (bundleResults[i] !is null)
            {
                alone ~= bundle.members;
            }
        }

        auto results = inParallel(alone, (Case c) => runCompiled(c, build, workDirectory));
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
    string runCompiled(Case c, const Build build, string workDirectory)
    {
        CompiledRun run;
        if (auto failure = compileAndRun(c, build, workDirectory, run))
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
    string runCompiledPanic(Case c, const Build build, string workDirectory)
    {
        CompiledRun run;
        if (auto failure = compileAndRun(c, build, workDirectory, run))
        {
            return failure;
        }
        if (run.status != panicStatus)
        {
            return "expected exit status " ~ panicStatus.to!string ~ ", got " ~ run.status.to!string ~ ":\n" ~ run.output;
        }
        if (!run.output.startsWith(c.expected ~ "panic: ") || !run.output.canFind(c.panicMessage))
        {
            return "output differs.\n--- expected\n" ~ c.expected ~ "panic: ... " ~ c.panicMessage
                ~ "\n--- actual\n" ~ run.output;
        }
        // The interpreted run reports its own failure, so only a report it gives is compared.
        auto interpreted = interpretedPanicReport(c);
        if (interpreted !is null && run.output != c.expected ~ interpreted ~ "\n")
        {
            return "the report differs from the interpreter's.\n--- interpreted\n" ~ c.expected ~ interpreted
                ~ "\n--- compiled\n" ~ run.output;
        }
        return null;
    }

    /// What the interpreter's driver reports when it runs the panic case `c`, or null if it doesn't panic.
    string interpretedPanicReport(Case c)
    {
        auto context = new SourceContext();
        Program program;
        CoreProgram lowered;
        if (prepare(c, context, program, lowered) !is null) return null;
        try
        {
            runWithInput(c, new Evaluator(lowered));
        }
        catch (DiagnosticException e)
        {
            return panicReport(e.diagnostic, context.sources);
        }
        return null;
    }

    /// Compiles and runs the error case `c`, and returns why it didn't report its error as expected, or null.
    string runCompiledError(Case c, const Build build, string workDirectory)
    {
        CompiledRun run;
        if (auto failure = compileAndRun(c, build, workDirectory, run))
        {
            return failure;
        }
        if (run.status != 1)
        {
            return "expected exit status 1, got " ~ run.status.to!string ~ ":\n" ~ run.output;
        }
        return compareOutput(c, run.output, c.expected ~ "error: " ~ c.errorMessage ~ "\n");
    }

    /// Interprets the error case `c`, and returns why `main` didn't return the expected error, or null.
    string runInterpretedError(Case c)
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
        catch (ProgramFailed e)
        {
            if (e.msg != c.errorMessage)
            {
                return "expected the error `" ~ c.errorMessage ~ "`, got `" ~ e.msg ~ "`";
            }
            return compareOutput(c, evaluator.output);
        }
        catch (DiagnosticException e)
        {
            return "the program failed at runtime: " ~ formatDiagnostic(e.diagnostic, context.sources);
        }
        return "expected the error `" ~ c.errorMessage ~ "`, but the program finished";
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
        return compareOutput(c, actual, c.expected);
    }

    string compareOutput(Case c, string actual, string expected)
    {
        if (actual == expected)
        {
            return null;
        }
        return "output differs.\n--- expected\n" ~ expected ~ "\n--- actual\n" ~ actual;
    }

    /// Every compiled case runs optimized as well, against the same expected output, which adds
    /// about half as long again. `SILVER_CONFORMANCE_UNOPTIMIZED` leaves those runs out.
    bool optimizedSkipped()
    {
        return environment.get("SILVER_CONFORMANCE_UNOPTIMIZED") !is null;
    }

    /// Sets `build` for running `what` compiled, or says why it's skipped and returns false.
    bool findBuild(string what, Optimization optimization, out Build build)
    {
        if (optimization == Optimization.full && optimizedSkipped)
        {
            writeln("    note: SILVER_CONFORMANCE_UNOPTIMIZED is set. Optimized ", what, " was skipped.");
            return false;
        }
        build.optimization = optimization;
        if (auto missing = findToolchain(build.toolchain))
        {
            writeln("    note: ", missing, " The ", what, " was skipped.");
            return false;
        }
        return true;
    }

    string described(string kind, Optimization optimization)
    {
        return (optimization == Optimization.full ? "Optimized " : "Compiled ") ~ kind;
    }

    /// A new directory for the files of one compiled run.
    string workDirectoryFor(string kind, Optimization optimization)
    {
        auto directory = buildPath(tempDir, "silver-conformance-" ~ kind
            ~ (optimization == Optimization.full ? "-optimized-" : "-") ~ thisProcessID.to!string);
        mkdirRecurse(directory);
        return directory;
    }

    /// Fails with `problems` if there are any. Failures keep their IR for inspection; a clean
    /// run leaves nothing behind.
    void finish(string problems, string workDirectory)
    {
        if (problems is null)
        {
            rmdirRecurse(workDirectory);
        }
        assert(problems is null, problems);
    }

    void checkCompiled(Optimization optimization)
    {
        Build build;
        if (!findBuild("compiled conformance", optimization, build)) return;
        auto workDirectory = workDirectoryFor("tests", optimization);
        auto all = cases;
        auto failed = compiledFailures(all, pendingCases(compiledPending), build, workDirectory);
        finish(pendingProblems(described("conformance", optimization), all, failed, compiledPending), workDirectory);
    }

    void checkCompiledPanics(Optimization optimization)
    {
        Build build;
        if (!findBuild("compiled panic conformance", optimization, build)) return;
        auto workDirectory = workDirectoryFor("panics", optimization);
        auto all = panicCases;
        auto failed = failuresByName(all, inParallel(all, (Case c) => runCompiledPanic(c, build, workDirectory)));
        finish(pendingProblems(described("panic", optimization), all, failed, compiledPending), workDirectory);
    }

    void checkCompiledErrors(Optimization optimization)
    {
        Build build;
        if (!findBuild("compiled error conformance", optimization, build)) return;
        auto workDirectory = workDirectoryFor("errors", optimization);
        auto all = errorCases;
        auto failed = failuresByName(all, inParallel(all, (Case c) => runCompiledError(c, build, workDirectory)));
        finish(pendingProblems(described("error", optimization), all, failed, compiledPending), workDirectory);
    }

    void checkCompiledTesting(Optimization optimization)
    {
        Build build;
        if (!findBuild("compiled testing conformance", optimization, build)) return;
        // Of its own, since each test program is named after its file alone.
        auto workDirectory = workDirectoryFor("testing", optimization);
        auto all = testingCases;
        auto failed = failuresByName(all,
            inParallel(all, (Case c) => runTesting(c, TestBackend.llvm, workDirectory, optimization)));
        finish(pendingProblems(described("testing", optimization), all, failed, compiledPending), workDirectory);
    }

    /// Runs the standard library's tests on `backend`, and returns its report if any of them didn't pass.
    string runStandardLibrary(TestBackend backend, string workDirectory, Optimization optimization = Optimization.none)
    {
        auto files = testFiles(standardLibraryPath());
        auto packages = Packages(withStandardLibrary([]));
        auto runs = files.map!(file => runFile(file, packages, backend, workDirectory, optimization)).array;
        return succeeded(runs) ? null : report(runs);
    }

    /// Runs the standard library's tests on both backends, so that they pass and agree.
    void checkStandardLibrary(Optimization optimization)
    {
        Build build;
        if (!findBuild("standard library's compiled tests", optimization, build)) return;
        auto workDirectory = workDirectoryFor("stdlib", optimization);
        auto problems = runStandardLibrary(TestBackend.both, workDirectory, optimization);
        finish(problems is null ? null : described("standard library tests", optimization)
            ~ " failed or differed from the interpreter's:\n" ~ problems, workDirectory);
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
    checkCompiled(Optimization.none);
}

@("Optimized conformance programs match their expected output")
unittest
{
    checkCompiled(Optimization.full);
}

@("Interpreted programs that panic report the expected error")
unittest
{
    auto all = panicCases;
    auto failed = failuresByName(all, inParallel(all, (Case c) => runInterpretedPanic(c)));
    auto problems = pendingProblems("Interpreted panic", all, failed, interpretedPending);
    assert(problems is null, problems);
}

@("Compiled programs that panic report what the interpreter does and exit with the panic status")
unittest
{
    checkCompiledPanics(Optimization.none);
}

@("Optimized programs that panic report what the interpreter does and exit with the panic status")
unittest
{
    checkCompiledPanics(Optimization.full);
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
    checkCompiledTesting(Optimization.none);
}

@("Optimized tests report what the expected report says")
unittest
{
    checkCompiledTesting(Optimization.full);
}

@("The standard library's tests pass interpreted")
unittest
{
    auto problems = runStandardLibrary(TestBackend.interpreter, tempDir);
    assert(problems is null, "Interpreted standard library tests failed:\n" ~ problems);
}

@("The standard library's tests pass compiled and agree with the interpreter")
unittest
{
    checkStandardLibrary(Optimization.none);
}

@("The standard library's tests pass optimized and agree with the interpreter")
unittest
{
    checkStandardLibrary(Optimization.full);
}

@("Interpreted programs whose main returns an error report it")
unittest
{
    auto all = errorCases;
    auto failed = failuresByName(all, inParallel(all, (Case c) => runInterpretedError(c)));
    auto problems = pendingProblems("Interpreted error", all, failed, interpretedPending);
    assert(problems is null, problems);
}

@("Compiled programs whose main returns an error print it and exit with status 1")
unittest
{
    checkCompiledErrors(Optimization.none);
}

@("Optimized programs whose main returns an error print it and exit with status 1")
unittest
{
    checkCompiledErrors(Optimization.full);
}

@("Programs that sema rejects report the expected error")
unittest
{
    auto all = rejectedCases;
    auto failed = failuresByName(all, inParallel(all, (Case c) => runRejected(c)));
    auto problems = pendingProblems("Rejected", all, failed, interpretedPending);
    assert(problems is null, problems);
}