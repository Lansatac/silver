module silver.sema.analysis;

import silver.ast;

import std.sumtype : SumType;

alias SymbolId = SumType!(Id!FunctionDecl, Id!Param, Id!VarDecl, Id!Module);

version (unittest) import fluent.asserts;

/// Everything sema learned about a Program.
final class Analysis
{
    this(SymbolId[Id!Expr] resolutions, Id!FunctionDecl[Id!Expr] callees)
    {
        _resolutions = resolutions;
        _callees = callees;
    }

    private SymbolId[Id!Expr] _resolutions;
    const(SymbolId[Id!Expr]) resolutions() const
    {
        return _resolutions;
    }

    private Id!FunctionDecl[Id!Expr] _callees;
    /// The function each direct call invokes, keyed by the call expression. Calls through a
    /// value (e.g. a function-typed param) have no entry. Kept apart from `resolutions` so
    /// that overloading, if added, only changes who picks the entry: the type checker.
    const(Id!FunctionDecl[Id!Expr]) callees() const
    {
        return _callees;
    }
}

/// Analyzes every module in `program`, reporting problems to `collector`.
Analysis analyze(const ref Program program, Collector collector)
{
    import silver.sema.entry : checkEntryPoint;
    import silver.sema.resolve : resolveNames;

    checkEntryPoint(program, collector);
    auto resolution = resolveNames(program, collector);
    return new Analysis(resolution.resolutions, resolution.callees);
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
    collector.diagnostics.length.should.equal(0);
}
