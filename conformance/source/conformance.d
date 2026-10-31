module conformance;

version (unittest)
{
    import std.file : dirEntries, exists, readText, SpanMode;
    import std.path : baseName, buildNormalizedPath, buildPath, dirName, stripExtension;
    import std.string : replace;
    import silver.ast : SourceMap;
    import silver.interpreter.evaluator : Evaluator;
    import silver.loader : load, standardLibraryPath;
}

@("Conformance programs match their expected output")
unittest
{
    auto conformanceDirectory = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "tests");
    auto standardLibraryDirectory = standardLibraryPath();
    size_t filesTested;

    foreach (entry; dirEntries(conformanceDirectory, "*.silver", SpanMode.shallow))
    {
        auto sourcePath = entry.name;
        auto expectedPath = buildPath(conformanceDirectory,
            baseName(sourcePath).stripExtension ~ ".expected");
        assert(exists(expectedPath),
            "Missing expected output file for " ~ sourcePath);

        auto source = readText(sourcePath);
        auto program = load(source, sourcePath, [standardLibraryDirectory], new SourceMap);
        auto evaluator = new Evaluator(program);
        evaluator.run();

        auto expected = readText(expectedPath).replace("\r\n", "\n");
        assert(evaluator.output == expected,
            "Conformance output did not match for " ~ sourcePath);
        filesTested++;
    }

    assert(filesTested > 0, "No conformance .silver files were found");
}
