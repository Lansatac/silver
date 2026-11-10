module silver.core.lower;

import std.sumtype : match;

import ast = silver.ast;
import silver.core.nodes;
import silver.sema : Analysis, SymbolId;

/// `func` as Core. Panics on any construct that isn't lowered yet.
Function lowerFunction(const ast.FunctionDecl func, const Analysis analysis)
{
    return new Lowering(analysis).lowerFunction(func);
}

private final class Lowering
{
    private const Analysis _analysis;
    private Local[SymbolId] _locals;

    this(const Analysis analysis)
    {
        _analysis = analysis;
    }

    Function lowerFunction(const ast.FunctionDecl func)
    {
        Local[] params;
        foreach (ref param; func.params)
        {
            auto local = new Local(param.name, _analysis.typeOf(param.id));
            _locals[SymbolId(param.id)] = local;
            params ~= local;
        }
        auto signature = _analysis.signatureOf(func.id);
        return Function(func.name, params, signature.ret, lowerExpr(*func.body));
    }

    private Expr lowerExpr(const ast.Expr e)
    {
        // Every promotion gets wrapped here, once both exist.
        if (_analysis.promotionOf(e.id) !is null || _analysis.constructedMemberOf(e.id) !is null)
        {
            notLowered("promotion");
        }
        return Expr(_analysis.typeOf(e.id), e.span, e.kind.match!(
            (const ast.IntLiteral literal) => ExprKind(IntLit(literal.value)),
            (const ast.Identifier _) => ExprKind(LocalRef(localFor(e))),
            (const ast.BinaryExpr binary) => ExprKind(lowerBinary(binary)),
            (const ast.IfExpr if_) => ExprKind(lowerIf(if_)),
            (const ast.BlockExpr block) => ExprKind(lowerBlock(block)),
            (other) => notLowered(typeof(other).stringof),
        ));
    }

    private Local localFor(const ast.Expr use)
    {
        auto symbol = _analysis.resolutionOf(use.id);
        assert(symbol !is null, "sema resolves every identifier");
        if (auto local = *symbol in _locals) return *local;
        notLowered("a reference to something other than a local or param");
        assert(0);
    }

    private Prim lowerBinary(const ast.BinaryExpr binary)
    {
        return Prim(primOp(binary.op), [lowerExpr(*binary.left), lowerExpr(*binary.right)]);
    }

    private PrimOp primOp(ast.BinaryOp op)
    {
        switch (op)
        {
            case ast.BinaryOp.Add: return PrimOp.Add;
            case ast.BinaryOp.Greater: return PrimOp.Greater;
            default: notLowered("operator " ~ op);
        }
        assert(0);
    }

    private If lowerIf(const ast.IfExpr if_)
    {
        if (if_.binding !is null) notLowered("if val");
        if (if_.falseBody is null) notLowered("if without else");
        return If(heap(lowerExpr(*if_.condition)), heap(lowerExpr(*if_.trueBody)), heap(lowerExpr(*if_.falseBody)));
    }

    private Block lowerBlock(const ast.BlockExpr block)
    {
        Stmt[] statements;
        foreach (ref statement; block.statements)
        {
            statements ~= lowerStmt(statement);
        }
        return Block(statements, block.value is null ? null : heap(lowerExpr(*block.value)));
    }

    private Stmt lowerStmt(const ast.Stmt statement)
    {
        return Stmt(statement.span, statement.kind.match!(
            (const ast.VarDecl decl) => StmtKind(lowerVar(decl)),
            (other) => notLowered!StmtKind(typeof(other).stringof),
        ));
    }

    private Let lowerVar(const ast.VarDecl decl)
    {
        // The value goes first: `val x = x` can't see the new `x`.
        auto value = lowerExpr(decl.value);
        auto local = new Local(decl.name, _analysis.typeOf(decl.id));
        _locals[SymbolId(decl.id)] = local;
        return Let(local, value);
    }

    private Expr* heap(Expr value)
    {
        return [value].ptr;
    }

    private Result notLowered(Result = ExprKind)(string what)
    {
        assert(0, "Not lowered to Core yet: " ~ what);
    }
}

version (unittest)
{
    import fluent.asserts;
    import std.algorithm : map;
    import std.array : join;
    import std.typecons : Tuple;
    import silver.ast : formatDiagnostic, SourceContext;
    import silver.core.print : print;
    import silver.loader : load, standardLibraryPath;
    import silver.sema : analyze;

    alias Lowered = Tuple!(Function, "func", Analysis, "analysis");

    /// The function `name` in `source`, lowered, with the analysis it was lowered from.
    private Lowered loweredFunction(string source, string name)
    {
        auto context = new SourceContext;
        auto program = load(source ~ "\ndef main(): () { }", "test", [standardLibraryPath()], context);
        auto analysis = analyze(program, context.collector);
        assert(!context.collector.hasErrors, context.collector.errors
                .map!(d => formatDiagnostic(d, context.sources)).join("\n"));
        foreach (decl; program.modules["test"].declarations)
        {
            Function* found;
            decl.kind.match!(
                (ref ast.FunctionDecl func) {
                    if (func.name == name) found = [lowerFunction(func, analysis)].ptr;
                },
                (ref _) {},
            );
            if (found !is null) return Lowered(*found, analysis);
        }
        assert(0, "no function " ~ name);
    }
}

@("a function lowers to lets, primitives and an if")
unittest
{
    auto result = loweredFunction(`
def add(a: Int, b: Int): Int {
    val c = a + b
    if c > 10 { c } else { 0 }
}
`, "add");

    print(result.func, result.analysis.types).should.equal(
`def add(a: Int, b: Int): Int {
    let c: Int = Add(a, b)
    if (Greater(c, 10)) {
        c
    } else {
        0
    }
}`);
}

@("each declaration is a Local of its own, even when the name is reused")
unittest
{
    auto result = loweredFunction(`
def f(a: Int): Int {
    if a > 0 {
        val c = a
        c
    } else {
        val c = 1
        c
    }
}
`, "f");

    print(result.func, result.analysis.types).should.equal(
`def f(a: Int): Int {
    if (Greater(a, 0)) {
        let c: Int = a
        c
    } else {
        let c.1: Int = 1
        c.1
    }
}`);
}
