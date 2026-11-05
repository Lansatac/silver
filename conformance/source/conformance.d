module conformance;

version (unittest)
{
    import std.algorithm : canFind, filter, map, sort;
    import std.array : array, join;
    import std.conv : to;
    import std.file : dirEntries, exists, mkdirRecurse, readText, rmdirRecurse, SpanMode, tempDir, write;
    import std.path : baseName, buildNormalizedPath, buildPath, dirName, stripExtension;
    import std.process : execute, thisProcessID;
    import std.stdio : writeln;
    import std.string : lineSplitter, replace, startsWith, strip;
    import silver.ast : formatDiagnostic, Program, SourceContext;
    import silver.codegen : executablePath, findToolchain, generate, linkExecutable, Toolchain;
    import silver.interpreter.evaluator : Evaluator;
    import silver.loader : load, standardLibraryPath;
    import silver.sema : analyze, Analysis;

    string conformanceDirectory()
    {
        return buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..");
    }

    struct Case
    {
        string name;
        string sourcePath;
        string expected;
    }

    /// Every `tests/*.ag` with its `.expected` output, sorted by name.
    Case[] cases()
    {
        auto testsDirectory = buildPath(conformanceDirectory, "tests");
        Case[] result;
        foreach (entry; dirEntries(testsDirectory, "*.ag", SpanMode.shallow))
        {
            auto name = baseName(entry.name).stripExtension;
            auto expectedPath = buildPath(testsDirectory, name ~ ".expected");
            assert(exists(expectedPath), "Missing expected output file for " ~ entry.name);
            result ~= Case(name, entry.name, readText(expectedPath).normalizeNewlines);
        }
        assert(result.length > 0, "No conformance .ag files were found");
        return result.sort!((a, b) => a.name < b.name).release;
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
            analysis = analyze(program, context.collector);
        }
        if (!context.collector.hasErrors)
        {
            return null;
        }
        return "loading or analyzing reported errors:\n"
            ~ context.collector.errors.map!(d => formatDiagnostic(d, context.sources)).join("\n");
    }

    /// Names of the cases the compiler isn't expected to pass yet, from `compiled-pending.txt`.
    string[] pendingCompiledCases()
    {
        auto path = buildPath(conformanceDirectory, "compiled-pending.txt");
        if (!exists(path))
        {
            return [];
        }
        return readText(path).lineSplitter
            .map!(line => line.strip)
            .filter!(line => line.length > 0 && !line.startsWith("#"))
            .array;
    }

    /// Compiles `c` in `workDirectory`, runs it, and returns why its output didn't match,
    /// or null if it did.
    string runCompiled(Case c, const Toolchain toolchain, string workDirectory)
    {
        auto context = new SourceContext();
        Program program;
        Analysis analysis;
        if (auto failure = loadAndAnalyze(c, context, program, analysis))
        {
            return failure;
        }

        string ir;
        try
        {
            ir = generate(program, analysis, context.collector);
        }
        // Throwable, so a failed assertion in codegen counts against its case alone.
        catch (Throwable e)
        {
            return "codegen threw: " ~ e.msg ~ " (" ~ e.file ~ ":" ~ e.line.to!string ~ ")";
        }
        if (context.collector.hasErrors)
        {
            return "codegen reported errors:\n"
                ~ context.collector.errors.map!(d => formatDiagnostic(d, context.sources)).join("\n");
        }

        auto irPath = buildPath(workDirectory, c.name ~ ".ll");
        auto exePath = executablePath(buildPath(workDirectory, c.name));
        write(irPath, ir);
        auto linked = linkExecutable(toolchain, irPath, exePath);
        if (!linked.succeeded)
        {
            return "linking failed (IR kept at " ~ irPath ~ "):\n" ~ linked.output;
        }

        auto run = execute([exePath]);
        if (run.status != 0)
        {
            return "the program exited with status " ~ run.status.to!string ~ ":\n" ~ run.output;
        }
        return compareOutput(c, run.output.normalizeNewlines);
    }

    /// Interprets `c` and returns why its output didn't match, or null if it did.
    string runInterpreted(Case c)
    {
        import silver.ast : DiagnosticException;

        auto context = new SourceContext();
        Program program;
        Analysis analysis;
        if (auto failure = loadAndAnalyze(c, context, program, analysis))
        {
            return failure;
        }

        auto evaluator = new Evaluator(program);
        try
        {
            evaluator.run();
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
    string[] failures;
    foreach (c; cases)
    {
        if (auto failure = runInterpreted(c))
        {
            failures ~= c.name ~ ": " ~ failure;
        }
    }
    assert(failures.length == 0, "Interpreted conformance failures:\n\n" ~ failures.join("\n\n"));
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

    auto pending = pendingCompiledCases();
    string[] failures;
    string[] unexpectedPasses;
    foreach (c; cases)
    {
        auto failure = runCompiled(c, toolchain, workDirectory);
        if (failure is null && pending.canFind(c.name))
        {
            unexpectedPasses ~= c.name;
        }
        else if (failure !is null && !pending.canFind(c.name))
        {
            failures ~= c.name ~ ": " ~ failure;
        }
    }

    string message;
    if (failures.length > 0)
    {
        message ~= "Compiled conformance failures:\n\n" ~ failures.join("\n\n") ~ "\n\n";
    }
    if (unexpectedPasses.length > 0)
    {
        message ~= "These now pass when compiled; remove them from compiled-pending.txt: "
            ~ unexpectedPasses.join(", ");
    }
    // Failures keep their IR for inspection; a clean run leaves nothing behind.
    if (message.length == 0)
    {
        rmdirRecurse(workDirectory);
    }
    assert(message.length == 0, message);
}
