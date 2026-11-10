module silver.core.lower;

import std.sumtype : match;

import ast = silver.ast;
import silver.ast : Span;
import silver.core.nodes;
import silver.sema : Analysis, SymbolId, Type, TypeTable;

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
            (const ast.UnitLiteral _) => ExprKind(UnitLit()),
            (const ast.BoolLiteral literal) => ExprKind(BoolLit(literal.value)),
            (const ast.IntLiteral literal) => ExprKind(IntLit(literal.value)),
            (const ast.Identifier _) => ExprKind(LocalRef(localFor(e))),
            (const ast.UnaryExpr unary) => ExprKind(lowerUnary(unary)),
            (const ast.BinaryExpr binary) => ExprKind(lowerBinary(binary)),
            (const ast.IfExpr if_) => ExprKind(lowerIf(if_, e.span)),
            (const ast.BlockExpr block) => ExprKind(lowerBlock(block)),
            (const ast.WhileExpr while_) => ExprKind(lowerWhile(while_, e.span)),
            (const ast.ForExpr for_) => ExprKind(lowerFor(for_, e.span)),
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

    private Prim lowerUnary(const ast.UnaryExpr unary)
    {
        if (unary.op != ast.UnaryOp.Not) notLowered("operator " ~ unary.op);
        return Prim(PrimOp.Not, [lowerExpr(*unary.operand)]);
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
            case ast.BinaryOp.Less: return PrimOp.Less;
            case ast.BinaryOp.Greater: return PrimOp.Greater;
            case ast.BinaryOp.Equal: return PrimOp.Equal;
            default: notLowered("operator " ~ op);
        }
        assert(0);
    }

    private If lowerIf(const ast.IfExpr if_, Span span)
    {
        if (if_.binding !is null) notLowered("if val");
        auto otherwise = if_.falseBody is null ? unit(span) : lowerExpr(*if_.falseBody);
        return If(boxed(lowerExpr(*if_.condition)), boxed(lowerExpr(*if_.trueBody)), boxed(otherwise));
    }

    private Block lowerBlock(const ast.BlockExpr block)
    {
        Stmt[] statements;
        foreach (ref statement; block.statements)
        {
            statements ~= lowerStmt(statement);
        }
        return Block(statements, block.value is null ? null : boxed(lowerExpr(*block.value)));
    }

    private Stmt lowerStmt(const ast.Stmt statement)
    {
        return Stmt(statement.span, statement.kind.match!(
            (const ast.VarDecl decl) => StmtKind(lowerVar(decl)),
            (const ast.AssignStmt assign) => StmtKind(lowerAssign(assign)),
            (const ast.ExprStmt stmt) => StmtKind(Eval(lowerExpr(stmt.expr))),
            (const ast.BreakStmt _) => StmtKind(Eval(breakExpr(statement.span))),
            (const ast.ContinueStmt _) => StmtKind(Eval(continueExpr(statement.span))),
            (other) => notLowered!StmtKind(typeof(other).stringof),
        ));
    }

    private Let lowerVar(const ast.VarDecl decl)
    {
        // The value goes first: `val x = x` can't see the new `x`.
        auto value = lowerExpr(decl.value);
        auto local = new Local(decl.name, _analysis.typeOf(decl.id), decl.mutable);
        _locals[SymbolId(decl.id)] = local;
        return Let(local, value);
    }

    private Assign lowerAssign(const ast.AssignStmt assign)
    {
        auto isLocal = assign.target.kind.match!((const ast.Identifier _) => true, _ => false);
        if (!isLocal) notLowered!Assign("assignment to anything but a local");
        return Assign(localFor(assign.target), lowerExpr(assign.value));
    }

    /// `while c { body }` is `loop { if (!c) break; body }`, so `continue` re-checks `c`.
    private Loop lowerWhile(const ast.WhileExpr while_, Span span)
    {
        if (while_.binding !is null) notLowered("while val");
        auto body = [breakUnless(lowerExpr(*while_.condition))] ~ statementsOf(lowerExpr(*while_.body));
        return Loop(boxed(block(span, body)));
    }

    private Block lowerFor(const ast.ForExpr for_, Span span)
    {
        auto range = ast.asRange(&for_.binding.value);
        if (range is null) notLowered("for over an array");
        auto start = lowerExpr(*range.start);
        auto end = lowerExpr(*range.end);

        auto type = _analysis.typeOf(for_.binding.id);

        auto next = temp("next", type, true);
        auto last = temp("end", type);

        auto bindingVar = temp(for_.binding.name, type);
        _locals[SymbolId(for_.binding.id)] = bindingVar;
        auto forBody = lowerExpr(*for_.body);
        auto finalBlock = Block([
            let(next, start),
            let(last, end),
            eval(loop(boxed(block(span, [
                breakUnless(prim(PrimOp.Less, types.bool_, use(next, span), use(last, span))),
                let(bindingVar, use(next, span)),
                assign(next, prim(PrimOp.Add, type, use(next, span), intLiteral(type, 1, span))),
            ] ~ statementsOf(forBody))), span)),
            ], null);
        return finalBlock;
    }

    // Helpers for building Core. The nodes lowering makes up have no AST node to ask sema about,
    // so these supply the types.

    private const(TypeTable) types()
    {
        return _analysis.types;
    }

    /// A local no declaration in the source stands behind.
    private Local temp(string name, Type type, bool mutable = false)
    {
        return new Local(name, type, mutable);
    }

    private Expr use(Local local, Span span)
    {
        return Expr(local.type, span, ExprKind(LocalRef(local)));
    }

    private Expr prim(PrimOp op, Type type, Expr[] args...)
    {
        return Expr(type, args[0].span, ExprKind(Prim(op, args.dup)));
    }

    private Expr not(Expr operand)
    {
        return prim(PrimOp.Not, types.bool_, operand);
    }

    private Expr unit(Span span)
    {
        return Expr(types.unit, span, ExprKind(UnitLit()));
    }

    private Expr intLiteral(Type type, ulong value, Span span)
    {
        return Expr(type, span, ExprKind(IntLit(value)));
    }

    private Expr breakExpr(Span span)
    {
        return Expr(types.never, span, ExprKind(Break()));
    }

    private Expr continueExpr(Span span)
    {
        return Expr(types.never, span, ExprKind(Continue()));
    }

    /// `if (condition) then else ()`, for when only one arm does anything.
    private Expr when(Expr condition, Expr then)
    {
        return Expr(types.unit, condition.span, ExprKind(If(boxed(condition), boxed(then), boxed(unit(condition.span)))));
    }

    private Expr loop(Expr* body, Span span)
    {
        return Expr(types.unit, span, ExprKind(Loop(body)));
    }

    /// Leaves the enclosing loop when `condition` is false.
    private Stmt breakUnless(Expr condition)
    {
        return eval(when(not(condition), breakExpr(condition.span)));
    }

    /// A block of `statements` with no value.
    private Expr block(Span span, Stmt[] statements)
    {
        return Expr(types.unit, span, ExprKind(Block(statements, null)));
    }

    /// `e` as statements to splice into another block: a block's own statements when it has no
    /// value, so loops don't print a block inside a block. Splicing can't change what a name
    /// means, since Core's locals are objects rather than names.
    private Stmt[] statementsOf(Expr e)
    {
        return e.kind.match!(
            (Block b) => b.result is null ? b.statements : [eval(e)],
            _ => [eval(e)],
        );
    }

    private Stmt let(Local local, Expr value)
    {
        return Stmt(value.span, StmtKind(Let(local, value)));
    }

    private Stmt assign(Local local, Expr value)
    {
        assert(local.mutable, "only a mutable local is assigned");
        return Stmt(value.span, StmtKind(Assign(local, value)));
    }

    private Stmt eval(Expr e)
    {
        return Stmt(e.span, StmtKind(Eval(e)));
    }

    private Expr* boxed(Expr value)
    {
        auto p = new Expr;
        *p = value;
        return p;
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

@("a while loop checks its condition at the top, so continue re-checks it")
unittest
{
    auto result = loweredFunction(`
def f(n: Int): Int {
    mutable val i = 0
    mutable val total = 0
    while i < n {
        i += 1
        if i == 2 { continue }
        if i > 5 { break }
        total += i
    }
    total
}
`, "f");

    print(result.func, result.analysis.types).should.equal(
`def f(n: Int): Int {
    let mutable i: Int = 0
    let mutable total: Int = 0
    loop {
        if (Not(Less(i, n))) break else ()
        i = Add(i, 1)
        if (Equal(i, 2)) {
            continue
        } else ()
        if (Greater(i, 5)) {
            break
        } else ()
        total = Add(total, i)
    }
    total
}`);
}

// The obvious lowering puts `next = next + 1` at the end of the body, where `continue` skips it,
// and compares against `b` itself, which evaluates it on every pass. Both break control-flow.md.
@("a for over a range steps before the body and evaluates its end once")
unittest
{
    auto result = loweredFunction(`
def f(n: Int): Int {
    mutable val total = 0
    for i in 0..n + 1 {
        if i == 2 { continue }
        total += i
    }
    total
}
`, "f");

    print(result.func, result.analysis.types).should.equal(
`def f(n: Int): Int {
    let mutable total: Int = 0
    {
        let mutable next: Int = 0
        let end: Int = Add(n, 1)
        loop {
            if (Not(Less(next, end))) break else ()
            let i: Int = next
            next = Add(next, 1)
            if (Equal(i, 2)) {
                continue
            } else ()
            total = Add(total, i)
        }
    }
    total
}`);
}

@("a for's temporaries take the range's type")
unittest
{
    auto result = loweredFunction(`
def f(a: UInt8, b: UInt8): UInt8 {
    mutable val last = a
    for i in a..b {
        last = i
    }
    last
}
`, "f");

    print(result.func, result.analysis.types).should.equal(
`def f(a: UInt8, b: UInt8): UInt8 {
    let mutable last: UInt8 = a
    {
        let mutable next: UInt8 = a
        let end: UInt8 = b
        loop {
            if (Not(Less(next, end))) break else ()
            let i: UInt8 = next
            next = Add(next, 1)
            last = i
        }
    }
    last
}`);
}
