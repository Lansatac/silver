module conformance;

version (unittest)
{
    import std.file : dirEntries, exists, readText, SpanMode;
    import std.path : absolutePath, baseName, buildPath, dirName, stripExtension;
    import std.string : replace;
    import silver.ast : SourceMap;
    import silver.interpreter.context : Context;
    import silver.loader : load, standardLibraryPath;
}

@("Conformance programs match their expected output")
unittest
{
    auto packageDirectory = absolutePath(buildPath(dirName(__FILE__), ".."));
    auto conformanceDirectory = buildPath(packageDirectory, "tests");
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
        auto context = new Context(program);
        context.run();

        auto expected = readText(expectedPath).replace("\r\n", "\n");
        assert(context.ProgramOutput == expected,
            "Conformance output did not match for " ~ sourcePath);
        filesTested++;
    }

    assert(filesTested > 0, "No conformance .silver files were found");
}
