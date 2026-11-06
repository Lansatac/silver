module silver.sema.analysis;

import silver.ast;
import silver.sema.check;
import silver.sema.resolve;
import silver.sema.type;

import std.sumtype : match;

version (unittest) import fluent.asserts;

/// Everything sema learned about a Program, queried by node ID.
final class Analysis
{
    package this(Resolution resolution, Typing typing, Id!FunctionDecl entryPoint)
    {
        _resolution = resolution;
        _typing = typing;
        _entryPoint = entryPoint;
    }

    private Resolution _resolution;
    private Typing _typing;
    private Id!FunctionDecl _entryPoint;

    /// The program's `main`, or null if it has none (as a library won't).
    const(Id!FunctionDecl)* entryPoint() const
    {
        return _entryPoint.isValid ? &_entryPoint : null;
    }

    /// The table every `Type` returned here belongs to.
    const(TypeTable) types() const
    {
        return _typing.types;
    }

    /// The checked type of an expression, function, param or local. After an analysis with
    /// no errors every one of these has a type, so a missing entry is a sema bug; it comes
    /// back as `types.error`, which consumers already treat as an internal error.
    Type typeOf(Id!Expr expr) const
    {
        return _typing.exprTypes.get(expr, _typing.types.error);
    }

    /// ditto
    Type typeOf(Id!FunctionDecl func) const
    {
        return typeOf(SymbolId(func));
    }

    /// ditto
    Type typeOf(Id!Param param) const
    {
        return typeOf(SymbolId(param));
    }

    /// ditto
    Type typeOf(Id!VarDecl var) const
    {
        return typeOf(SymbolId(var));
    }

    package Type typeOf(SymbolId symbol) const
    {
        return _typing.symbolTypes.get(symbol, _typing.types.error);
    }

    package bool hasType(Id!Expr expr) const
    {
        return (expr in _typing.exprTypes) !is null;
    }

    package bool hasType(SymbolId symbol) const
    {
        return (symbol in _typing.symbolTypes) !is null;
    }

    /// The declared parameter and return types of `func`.
    FunctionData signatureOf(Id!FunctionDecl func) const
    {
        return _typing.types[typeOf(func)].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "A function's type should always be a function type"),
        );
    }

    /// The declaration a name or module-rooted member chain refers to, or null if it was
    /// left unresolved (e.g. `x.f` on a value, which types decide).
    const(SymbolId)* resolutionOf(Id!Expr use) const
    {
        return use in _resolution.resolutions;
    }

    /// The function a call invokes directly, or null for a call through a value (e.g. a
    /// function-typed param). Kept apart from `resolutionOf` so that overloading, if added,
    /// only changes who picks the entry: the type checker.
    const(Id!FunctionDecl)* calleeOf(Id!Expr call) const
    {
        return call in _resolution.callees;
    }

    const(Id!TypeDecl)* constructionOf(Id!Expr call) const
    {
        return call in _resolution.constructions;
    }

    /// Whether `call` converts a number, like `UInt8(x)`. Its argument is the only thing it
    /// evaluates, and `typeOf(call)` is the type it converts to.
    bool isConversion(Id!Expr call) const
    {
        return (call in _resolution.conversions) !is null;
    }

    /// The fields of `type`, in declaration order.
    const(FieldInfo)[] fieldsOf(Id!TypeDecl type) const
    {
        return _typing.fields[type];
    }

    /// Where in `fieldsOf` the field read or assigned by the member access `access` is. Only
    /// for a member of a value: `geo.Origin` is a resolution (see `resolutionOf`) and has no index.
    size_t fieldIndexOf(Id!Expr access) const
    {
        return _typing.fieldIndexes[access];
    }

    /// The node an ID was given to. Name resolution records every declaration, so an ID
    /// from this program always has one.
    const(FunctionDecl)* declarationOf(Id!FunctionDecl func) const
    {
        return _resolution.declarations.functions[func];
    }

    /// ditto
    const(TypeDecl)* declarationOf(Id!TypeDecl type) const
    {
        return _resolution.declarations.types[type];
    }

    /// ditto
    const(VarDecl)* declarationOf(Id!VarDecl local) const
    {
        return _resolution.declarations.locals[local];
    }

    /// ditto
    const(Param)* declarationOf(Id!Param param) const
    {
        return _resolution.declarations.params[param];
    }
}

/// Analyzes every module in `program`, reporting problems to `collector`.
Analysis analyze(const ref Program program, Collector collector)
{
    import silver.sema.entry : checkEntryPoint;
    import silver.sema.resolve : resolveNames;

    auto entryPoint = checkEntryPoint(program, collector);
    auto resolution = resolveNames(program, collector);
    auto typing = checkTypes(program, resolution, collector);
    return new Analysis(resolution, typing, entryPoint);
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
