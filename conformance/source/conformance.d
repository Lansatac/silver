module conformance;

version (unittest)
{
    import std.file : dirEntries, exists, readText, SpanMode;
    import std.path : absolutePath, baseName, buildPath, dirName, stripExtension;
    import std.string : replace;
    import silver.context : Context;
    import silver.parse : parse;
}

@("Conformance programs match their expected output")
unittest
{
    auto packageDirectory = absolutePath(buildPath(dirName(__FILE__), ".."));
    auto conformanceDirectory = buildPath(packageDirectory, "tests");
    auto standardLibraryDirectory = buildPath(packageDirectory, "..", "stdlib");
    size_t filesTested;

    foreach (entry; dirEntries(conformanceDirectory, "*.silver", SpanMode.shallow))
    {
        auto sourcePath = entry.name;
        auto expectedPath = buildPath(conformanceDirectory,
            baseName(sourcePath).stripExtension ~ ".expected");
        assert(exists(expectedPath),
            "Missing expected output file for " ~ sourcePath);

        auto source = readText(sourcePath);
        auto moduleName = baseName(sourcePath).stripExtension;
        auto program = parse(source, moduleName, sourcePath);
        auto context = new Context(program, [standardLibraryDirectory], false, source);
        context.run();

        auto expected = readText(expectedPath).replace("\r\n", "\n");
        assert(context.ProgramOutput == expected,
            "Conformance output did not match for " ~ sourcePath);
        filesTested++;
    }

    assert(filesTested > 0, "No conformance .silver files were found");
}
