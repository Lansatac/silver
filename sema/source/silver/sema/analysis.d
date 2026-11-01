module silver.sema.analysis;

import silver.ast;

import std.sumtype : SumType, match;

alias SymbolId = SumType!(Id!FunctionDecl, Id!Param, Id!VarDecl, Id!Module);

version (unittest) import fluent.asserts;

/// Everything sema learned about a Program.
final class Analysis
{
}

final class Analyzer
{

    private Collector _collector;
    this(Collector collector)
    {
        _collector = collector;
    }

    Analysis analyzeProgram(const Program program)
    {
        foreach (mod; program.modules)
        {
            analyzeModule(*mod);
        }
        return new Analysis();
    }

    void analyzeModule(const Module mod)
    {
        bool[string] importTable;
        bool[string] functionTable;
        foreach (decl; mod.declarations)
        {
            analyzeDecl(decl, importTable, functionTable);
        }
    }

    void analyzeDecl(const Decl decl, ref bool[string] importTable, ref bool[string] functionTable)
    {
        import std.string : format;
        decl.kind.match!((const FunctionDecl func) {
            if (func.name in functionTable)
            {
                _collector.reportError(DiagnosticCode.DuplicateDeclaration, func.nameSpan, "'%s' is already declared in this module".format(func.name));
            }
            else
            {
                functionTable[func.name] = true;
            }
        },
        (const ImportStmt importStmt) {
            // auto importName = importStmt.path.join(".");
            // if (importName in importTable)
            // {
            //     //_collector.reportWarning(DiagnosticCode.DuplicateImport, importStmt.span, "'%s' is already imported in this module".format(importName));
            // }
            // else
            // {
            //     importTable[importName] = true;
            // }
        });
        
    }
}

/// Analyzes every module in `program`, reporting problems to `collector`.
Analysis analyze(const ref Program program, Collector collector)
{
    import silver.sema.entry : checkEntryPoint;

    checkEntryPoint(program, collector);
    auto analyzer = new Analyzer(collector);
    return analyzer.analyzeProgram(program);
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

@("analyze reports a function declared twice in the entry module, at the second name")
unittest
{
    import std.algorithm : canFind;
    import std.array : array;
    import std.string : lastIndexOf;

    auto source = "def twice(): Int => 1
def twice(): Int => 2
def main(): Unit => ()";
    auto errors = analyzeSource(source).errors.array;

    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.DuplicateDeclaration);
    errors[0].message.should.contain("'twice'");
    auto secondName = source.lastIndexOf("twice");
    errors[0].span.should.equal(Span("main.ag", secondName, secondName + "twice".length));
}