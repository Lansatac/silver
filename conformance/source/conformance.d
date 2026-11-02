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
    import silver.codegen : executablePath, findClang, generate, linkExecutable;
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
        program = load(readText(c.sourcePath), c.sourcePath, [standardLibraryPath()], context);
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

    /// Compiles `c` with clang in `workDirectory`, runs it, and returns why its output
    /// didn't match, or null if it did.
    string runCompiled(Case c, string clang, string workDirectory)
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
        catch (Exception e)
        {
            return "codegen threw: " ~ e.msg;
        }
        if (context.collector.hasErrors)
        {
            return "codegen reported errors:\n"
                ~ context.collector.errors.map!(d => formatDiagnostic(d, context.sources)).join("\n");
        }

        auto irPath = buildPath(workDirectory, c.name ~ ".ll");
        auto exePath = executablePath(buildPath(workDirectory, c.name));
        write(irPath, ir);
        auto linked = linkExecutable(clang, irPath, exePath);
        if (!linked.succeeded)
        {
            return "clang failed (IR kept at " ~ irPath ~ "):\n" ~ linked.output;
        }

        auto run = execute([exePath]);
        if (run.status != 0)
        {
            return "the program exited with status " ~ run.status.to!string ~ ":\n" ~ run.output;
        }
        auto output = run.output.normalizeNewlines;
        if (output != c.expected)
        {
            return "output differs.\n--- expected\n" ~ c.expected ~ "\n--- actual\n" ~ output;
        }
        return null;
    }
}

@("Interpreted conformance programs match their expected output")
unittest
{
    foreach (c; cases)
    {
        auto context = new SourceContext();
        Program program;
        Analysis analysis;
        auto failure = loadAndAnalyze(c, context, program, analysis);
        assert(failure is null, c.sourcePath ~ ": " ~ failure);

        auto evaluator = new Evaluator(program);
        evaluator.run();
        assert(evaluator.output == c.expected, "Conformance output did not match for " ~ c.sourcePath);
    }
}

@("Compiled conformance programs match their expected output")
unittest
{
    auto clang = findClang();
    if (clang is null)
    {
        writeln("    note: clang wasn't found, so compiled conformance was skipped");
        return;
    }

    auto workDirectory = buildPath(tempDir, "silver-conformance-" ~ thisProcessID.to!string);
    mkdirRecurse(workDirectory);

    auto pending = pendingCompiledCases();
    string[] failures;
    string[] unexpectedPasses;
    foreach (c; cases)
    {
        auto failure = runCompiled(c, clang, workDirectory);
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
