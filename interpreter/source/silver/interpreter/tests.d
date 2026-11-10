module silver.interpreter.tests;

version (unittest)
{
    import fluent.asserts;

    import silver.ast : formatDiagnostic, SourceContext;
    import silver.core : lowerProgram;
    import silver.interpreter.evaluator : Evaluator;
    import silver.loader : load, standardLibraryPath;
    import silver.sema : analyze;

    /// Runs `source` as the driver does, failing on anything the loader or sema reports.
    private string run(string source)
    {
        import std.algorithm : map;
        import std.array : join;

        auto context = new SourceContext;
        auto program = load(source, "test", [standardLibraryPath()], context);
        auto analysis = analyze(program, context.collector);
        assert(!context.collector.hasErrors, context.collector.errors
                .map!(d => formatDiagnostic(d, context.sources)).join("\n"));
        auto evaluator = new Evaluator(lowerProgram(program, analysis));
        evaluator.run();
        return evaluator.output;
    }

    /// Runs `body` as the body of `main`.
    private string runMain(string body)
    {
        return run("def main(): Unit {\n" ~ body ~ "\n}");
    }
}

@("a let binds its value, and a let reusing a name in a sibling block is a local of its own")
unittest
{
    runMain(`
    val a = 1
    val b = a + 2
    printl(b)
    {
        val c = 10
        printl(c)
    }
    {
        val c = b * 2
        printl(c)
    }
`).should.equal("3\n10\n6\n");
}

@("a native from the standard library is called by its symbol")
unittest
{
    run("import std.math\nimport std.time\ndef main(): Unit {\n    printl(sqrt(16))\n    printl(pow(2, 10))\n"
        ~ "    val now = nowNanos()\n    printl(now > 1600000000000000000)\n}").should.equal("4\n1024\ntrue\n");
}

@("calling a native the interpreter doesn't have is a diagnostic, not a crash")
unittest
{
    import std.exception : collectException;
    import silver.ast : DiagnosticCode;
    import silver.interpreter.errors : RuntimeError;

    auto error = collectException!RuntimeError(run("native def cbrt(x: Float): Float\ndef main(): Unit {\n    printl(cbrt(8.0))\n}"));
    assert(error !is null);
    error.diagnostic.code.should.equal(DiagnosticCode.MissingNativeBinding);
    error.diagnostic.message.should.contain("cbrt");
}
