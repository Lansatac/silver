module silver.sema.analysis;

import silver.ast;

/// Everything sema learned about a Program.
final class Analysis
{
}

/// Analyzes every module in `program`, reporting problems to `collector`.
Analysis analyze(const ref Program program, Collector collector)
{
    auto analysis = new Analysis;
    return analysis;
}

version (unittest)
{
    import silver.loader : load, standardLibraryPath;

    /// Loads `source` as the entry module (with the real stdlib) and analyzes it.
    /// Load errors fail the test, so a test only ever sees sema's diagnostics.
    Collector analyzeSource(string source)
    {
        auto context = new SourceContext;
        auto program = load(source, "main.ag", [standardLibraryPath()], context);
        assert(!context.collector.hasErrors, "The test program failed to load");
        analyze(program, context.collector);
        return context.collector;
    }
}

@("analyze accepts a minimal program")
unittest
{
    auto collector = analyzeSource("def main(): Unit => ()");
    assert(collector.diagnostics.length == 0);
}
