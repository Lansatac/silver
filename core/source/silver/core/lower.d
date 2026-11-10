module silver.core.lower;

import std.algorithm : canFind;
import std.format : format;
import std.sumtype : match;
import std.typecons : rebindable;

import ast = silver.ast;
import silver.ast : Span;
import silver.core.nodes;
import silver.ast : Id;
import silver.sema : Analysis, Primitive, SymbolId, Type, TypeTable;

/// `program` as Core, starting from its `main`. `analysis` must have no errors.
/// Throws: DiagnosticException (`NotImplemented`) at the first construct that isn't lowered yet.
Program lowerProgram(const ref ast.Program program, const Analysis analysis)
{
    auto mains = ast.mainFunctions(program);
    assert(mains.length == 1, "sema reports a program without exactly one `main`");
    return lowerFrom(mains[0].id, analysis);
}

/// `root` and every function it calls, directly or not, as a Program whose entry point is
/// `root`.
Program lowerFrom(Id!(ast.FunctionDecl) root, const Analysis analysis)
{
    auto lowering = new Lowering(analysis);
    auto entry = lowering.slotFor(root);
    lowering.lowerPending();
    return Program(rebindable(analysis.types), lowering.functions, entry, lowering.libraries);
}

private final class Lowering
{
    private const Analysis _analysis;
    private Local[SymbolId] _locals;
    /// The node being lowered, for reporting what isn't lowered yet.
    private Span _span;

    /// What becomes `Program.functions`. A function gets its slot when a call first names it,
    /// and is lowered later from `_pending`, so recursion never lowers a function twice.
    Function[] functions;
    private size_t[Id!(ast.FunctionDecl)] _slots;
    private Id!(ast.FunctionDecl)[] _pending;
    /// Each `native library` a call has needed, in the order first needed.
    string[] libraries;

    this(const Analysis analysis)
    {
        _analysis = analysis;
    }

    /// Where `func` is in `functions`, giving it a slot and queueing it the first time.
    size_t slotFor(Id!(ast.FunctionDecl) func)
    {
        if (auto existing = func in _slots) return *existing;
        auto slot = functions.length;
        functions ~= Function.init;
        _slots[func] = slot;
        _pending ~= func;
        return slot;
    }

    void lowerPending()
    {
        while (_pending.length > 0)
        {
            auto func = _pending[0];
            _pending = _pending[1 .. $];
            auto lowered = lowerFunction(*_analysis.declarationOf(func));
            functions[_slots[func]] = lowered;
        }
    }

    private Function lowerFunction(const ast.FunctionDecl func)
    {
        assert(func.kind == ast.FunctionKind.ordinary, "a call to a native or an intrinsic has a node of its own, so they never get a slot");
        _span = func.nameSpan;
        auto signature = _analysis.signatureOf(func.id);
        Local[] params;
        foreach (i, ref param; func.params)
        {
            auto local = new Local(param.name, signature.params[i], signature.isMutable(i));
            _locals[SymbolId(param.id)] = local;
            params ~= local;
        }
        return Function(func.name, _analysis.moduleOf(func.id), params, signature.ret, lowerExpr(*func.body));
    }

    private Expr lowerExpr(const ast.Expr e)
    {
        auto outer = _span;
        _span = e.span;
        scope (exit) _span = outer;

        // Every promotion gets wrapped here, once both exist.
        if (_analysis.promotionOf(e.id) !is null || _analysis.constructedMemberOf(e.id) !is null)
        {
            notLowered("promotion");
        }
        auto type = _analysis.typeOf(e.id);
        return Expr(type, e.span, e.kind.match!(
            (const ast.UnitLiteral _) => ExprKind(UnitLit()),
            (const ast.BoolLiteral literal) => ExprKind(BoolLit(literal.value)),
            (const ast.IntLiteral literal) => numberLiteral(literal.value, false, type),
            (const ast.FloatLiteral literal) => ExprKind(FloatLit(literal.value)),
            (const ast.Identifier _) => ExprKind(LocalRef(localFor(e))),
            (const ast.UnaryExpr unary) => lowerUnary(unary, type),
            (const ast.BinaryExpr binary) => lowerBinary(binary, e),
            (const ast.IfExpr if_) => ExprKind(lowerIf(if_, e.span)),
            (const ast.BlockExpr block) => ExprKind(lowerBlock(block)),
            (const ast.WhileExpr while_) => ExprKind(lowerWhile(while_, e.span)),
            (const ast.ForExpr for_) => ExprKind(lowerFor(for_, e.span)),
            (const ast.CallExpr call) => lowerCall(e, call),
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

    /// A literal of `type`, which may be `Float` when an integer literal adapted to one.
    private ExprKind numberLiteral(ulong magnitude, bool negative, Type type)
    {
        if (type == types.float_)
        {
            double value = magnitude;
            return ExprKind(FloatLit(negative ? -value : value));
        }
        return ExprKind(IntLit(negative ? 0UL - magnitude : magnitude));
    }

    private ExprKind lowerUnary(const ast.UnaryExpr unary, Type type)
    {
        final switch (unary.op)
        {
            case ast.UnaryOp.Plus:
                return lowerExpr(*unary.operand).kind;
            case ast.UnaryOp.Minus:
                // A negated literal is one value: `-128` is an Int8, though `128` alone isn't.
                auto negated = unary.operand.kind.match!(
                    (const ast.IntLiteral literal) => [numberLiteral(literal.value, true, type)],
                    (const ast.FloatLiteral literal) => [ExprKind(FloatLit(-literal.value))],
                    _ => null,
                );
                if (negated !is null) return negated[0];
                return ExprKind(Prim(PrimOp.Negate, [lowerExpr(*unary.operand)]));
            case ast.UnaryOp.Not:
                return ExprKind(Prim(PrimOp.Not, [lowerExpr(*unary.operand)]));
            case ast.UnaryOp.BitNot:
                return ExprKind(Prim(PrimOp.BitNot, [lowerExpr(*unary.operand)]));
        }
    }

    private ExprKind lowerBinary(const ast.BinaryExpr binary, const ast.Expr e)
    {
        import std.algorithm : map;
        import std.array : array;

        switch (binary.op)
        {
            // Short-circuiting: the right side runs only when the left doesn't decide.
            case ast.BinaryOp.And:
                return ExprKind(If(boxed(lowerExpr(*binary.left)), boxed(lowerExpr(*binary.right)),
                    boxed(boolLiteral(false, e.span))));
            case ast.BinaryOp.Or:
                return ExprKind(If(boxed(lowerExpr(*binary.left)), boxed(boolLiteral(true, e.span)),
                    boxed(lowerExpr(*binary.right))));
            // Sema flattens a chain of `~` into one list of operands, so it's one allocation.
            case ast.BinaryOp.Concat:
                return ExprKind(Prim(PrimOp.Concat, _analysis.concatOperands(e.id).map!(o => lowerExpr(o)).array));
            case ast.BinaryOp.Coalesce:
                return notLowered("`??`");
            case ast.BinaryOp.Equal, ast.BinaryOp.NotEqual, ast.BinaryOp.Less, ast.BinaryOp.LessEqual,
                ast.BinaryOp.Greater, ast.BinaryOp.GreaterEqual:
                auto operandType = _analysis.valueTypeOf(binary.left.id);
                if (!isPrimitive(operandType))
                {
                    notLowered("`%s` on `%s`".format(cast(string) binary.op, types.describe(operandType)));
                }
                goto default;
            default:
                return ExprKind(Prim(primOp(binary.op), [lowerExpr(*binary.left), lowerExpr(*binary.right)]));
        }
    }

    private PrimOp primOp(ast.BinaryOp op)
    {
        final switch (op)
        {
            case ast.BinaryOp.Add: return PrimOp.Add;
            case ast.BinaryOp.Subtract: return PrimOp.Subtract;
            case ast.BinaryOp.Multiply: return PrimOp.Multiply;
            case ast.BinaryOp.Divide: return PrimOp.Divide;
            case ast.BinaryOp.Modulo: return PrimOp.Modulo;
            case ast.BinaryOp.WrappingAdd: return PrimOp.WrappingAdd;
            case ast.BinaryOp.WrappingSubtract: return PrimOp.WrappingSubtract;
            case ast.BinaryOp.WrappingMultiply: return PrimOp.WrappingMultiply;
            case ast.BinaryOp.BitAnd: return PrimOp.BitAnd;
            case ast.BinaryOp.BitOr: return PrimOp.BitOr;
            case ast.BinaryOp.BitXor: return PrimOp.BitXor;
            case ast.BinaryOp.ShiftLeft: return PrimOp.ShiftLeft;
            case ast.BinaryOp.ShiftRight: return PrimOp.ShiftRight;
            case ast.BinaryOp.Equal: return PrimOp.Equal;
            case ast.BinaryOp.NotEqual: return PrimOp.NotEqual;
            case ast.BinaryOp.Less: return PrimOp.Less;
            case ast.BinaryOp.LessEqual: return PrimOp.LessEqual;
            case ast.BinaryOp.Greater: return PrimOp.Greater;
            case ast.BinaryOp.GreaterEqual: return PrimOp.GreaterEqual;
            case ast.BinaryOp.Append: return PrimOp.Append;
            case ast.BinaryOp.And, ast.BinaryOp.Or, ast.BinaryOp.Coalesce, ast.BinaryOp.Concat:
                assert(0, "lowered without a primitive of its own");
        }
    }

    /// Whether `type` is built in and has no structure, so comparing two is one primitive.
    private bool isPrimitive(Type type)
    {
        return types[type].match!((const Primitive _) => true, _ => false);
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
        auto outer = _span;
        _span = statement.span;
        scope (exit) _span = outer;
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

    
    /// A call to a function sema has picked. Statements that have to run before it, which a
    /// mutable field-path argument will need, make it a block; otherwise it's the call alone.
    private ExprKind lowerCall(const ast.Expr e, const ast.CallExpr call)
    {
        if (_analysis.constructionOf(e.id) !is null) return notLowered("construction");
        if (_analysis.isConversion(e.id)) return notLowered("conversion");
        if (_analysis.isArrayLength(e.id)) return notLowered("`length`");
        auto calleeId = _analysis.calleeOf(e.id);
        if (calleeId is null) return notLowered("a call through a function value");

        // `x.f(y)` is `f(x, y)`, which sema has built.
        auto method = _analysis.methodCallOf(e.id);
        auto written = method is null ? call.args : method.args;

        auto decl = _analysis.declarationOf(*calleeId);
        auto signature = _analysis.signatureOf(*calleeId);
        Stmt[] statements;
        Expr[] args;
        bool[] anyArgs;
        foreach (i, ref arg; written)
        {
            if (signature.isMutable(i)) args ~= mutableArgument(arg);
            else args ~= lowerExpr(arg);
            anyArgs ~= signature.params[i] == types.any;
            if (decl.kind == ast.FunctionKind.intrinsic && anyArgs[$ - 1]) checkAnyArgument(args[$ - 1]);
        }

        Expr lowered;
        final switch (decl.kind)
        {
            case ast.FunctionKind.ordinary:
                lowered = callExpr(signature.ret, slotFor(*calleeId), args, e.span);
                break;
            case ast.FunctionKind.native:
                if (auto library = _analysis.libraryOf(*calleeId))
                {
                    if (!libraries.canFind(library)) libraries ~= library;
                }
                lowered = Expr(signature.ret, e.span, ExprKind(ForeignCall(decl.symbol, args)));
                break;
            case ast.FunctionKind.intrinsic:
                auto intrinsic = IntrinsicCall(_analysis.intrinsicOf(*calleeId), args, anyArgs);
                lowered = Expr(signature.ret, e.span, ExprKind(intrinsic));
                break;
        }
        if (statements.length == 0) return lowered.kind;
        return ExprKind(Block(statements, boxed(lowered)));
    }

    /// The local a mutable parameter writes back to. Sema has checked it's a mutable place.
    private Expr mutableArgument(const ast.Expr arg)
    {
        auto isLocal = arg.kind.match!((const ast.Identifier _) => true, _ => false);
        if (!isLocal) notLowered("a mutable argument that isn't a local");
        return lowerExpr(arg);
    }

    /// A value passed to an intrinsic's `Any` parameter reaches the runtime as a primitive. Anything
    /// else is formatted to a String first, which waits on formatting being lowered.
    private void checkAnyArgument(const Expr arg)
    {
        if (!isPrimitive(arg.type))
        {
            notLowered("passing a `%s` to an intrinsic".format(types.describe(arg.type)));
        }
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

    private Expr boolLiteral(bool value, Span span)
    {
        return Expr(types.bool_, span, ExprKind(BoolLit(value)));
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

    private Expr callExpr(Type returnType, size_t target, Expr[] args, Span span)
    {
        return Expr(returnType, span, ExprKind(Call(target, args)));
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
        import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException;

        throw new DiagnosticException(Diagnostic(DiagnosticCode.NotImplemented, _span,
            "Not lowered to Core yet: " ~ what));
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
    import silver.sema : analyze, Intrinsic;

    alias Lowered = Tuple!(Program, "program", Analysis, "analysis");

    /// The function `name` in `source` and everything it calls, lowered, with the analysis it
    /// was lowered from.
    private Lowered loweredFunction(string source, string name)
    {
        auto context = new SourceContext;
        auto program = load(source ~ "\ndef main(): () { }", "test", [standardLibraryPath()], context);
        auto analysis = analyze(program, context.collector);
        assert(!context.collector.hasErrors, context.collector.errors
                .map!(d => formatDiagnostic(d, context.sources)).join("\n"));
        foreach (decl; program.modules["test"].declarations)
        {
            Id!(ast.FunctionDecl)[] found;
            decl.kind.match!(
                (ref const ast.FunctionDecl func) {
                    if (func.name == name) found = [func.id];
                },
                (ref _) {},
            );
            if (found.length > 0) return Lowered(lowerFrom(found[0], analysis), analysis);
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

    print(result.program).should.equal(
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

    print(result.program).should.equal(
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

    print(result.program).should.equal(
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

    print(result.program).should.equal(
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

    print(result.program).should.equal(
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

@("a negated literal is one value, so the most negative of a type doesn't overflow")
unittest
{
    auto result = loweredFunction(`
def f(a: Int8): Int8 {
    val least: Int8 = -128
    -a +% least
}
`, "f");

    print(result.program).should.equal(
`def f(a: Int8): Int8 {
    let least: Int8 = -128
    WrappingAdd(Negate(a), least)
}`);
}

@("&& and || short-circuit through an if")
unittest
{
    auto result = loweredFunction(`def f(a: Bool, b: Bool, c: Bool): Bool => a && b || !c`, "f");

    print(result.program).should.equal(
        `def f(a: Bool, b: Bool, c: Bool): Bool if (if (a) b else false) true else Not(c)`);
}

@("an integer literal that adapted to Float is a float literal")
unittest
{
    auto result = loweredFunction(`def f(x: Float): Float => -2.0 * x + 10 / 4.0`, "f");

    print(result.program).should.equal(
        `def f(x: Float): Float Add(Multiply(-2.0, x), Divide(10.0, 4.0))`);
}

@("a chain of ~ is one Concat, and ~= is an Append")
unittest
{
    auto chain = loweredFunction(`def f(a: String, b: String, c: String): String => a ~ b ~ c`, "f");
    print(chain.program).should.equal(
        `def f(a: String, b: String, c: String): String Concat(a, b, c)`);

    auto append = loweredFunction(`
def f(a: String, b: String): String {
    mutable val s = a
    s ~= b
    s
}
`, "f");
    print(append.program).should.equal(
`def f(a: String, b: String): String {
    let mutable s: String = a
    s = Append(s, b)
    s
}`);
}

@("a call names its target, which is lowered once even when it recurses")
unittest
{
    auto result = loweredFunction(`
def f(n: Int): Int {
    if n > 0 => g(n - 1) else 0
}

def g(n: Int): Int {
    f(n) + f(n)
}
`, "f");
    print(result.program).should.equal(
`def f(n: Int): Int {
    if (Greater(n, 0)) g(Subtract(n, 1)) else 0
}

def g(n: Int): Int {
    Add(f(n), f(n))
}`);
}

@("a function nothing calls isn't lowered")
unittest
{
    auto result = loweredFunction(`
def unused(): Int { 1 }

def f(): Int { 2 }
`, "f");
    result.program.functions.length.should.equal(1);
}

@("a call to an intrinsic names the operation, and marks the arguments that fill an Any")
unittest
{
    auto result = loweredFunction(`
def f(x: Int8, s: String): () {
    printl(x)
    print(s)
}
`, "f");
    print(result.program).should.equal(
`def f(x: Int8, s: String): Unit {
    intrinsic printl(x)
    intrinsic print(s)
}`);
    auto first = result.program.functions[0].body.kind.match!(
        (const Block b) => b.statements[0].kind.match!((const Eval e) => e.expr, _ => Expr.init),
        _ => Expr.init,
    );
    first.kind.match!(
        (const IntrinsicCall call) {
            call.intrinsic.should.equal(Intrinsic.printl);
            call.anyArgs.should.equal([true]);
        },
        (_) { assert(0, "expected an IntrinsicCall"); },
    );
}

@("a call to a native is a foreign call of its symbol, and its module's library is linked")
unittest
{
    auto result = loweredFunction(`
native library "m"
native def hypot(x: Float, y: Float): Float
native("atan2") def angle(y: Float, x: Float): Float
def f(x: Float): Float => hypot(x, angle(x, 1))
`, "f");
    print(result.program).should.equal(
`library "m"

def f(x: Float): Float foreign "hypot"(x, foreign "atan2"(x, 1.0))`);
}

@("a library is linked only when one of its natives is called")
unittest
{
    auto result = loweredFunction(`
native library "m"
native def hypot(x: Float, y: Float): Float
def f(x: Float): Float => x
`, "f");
    result.program.libraries.length.should.equal(0);
}

@("a method call passes its receiver first")
unittest
{
    auto result = loweredFunction(`
def twice(x: Int): Int { x * 2 }

def f(y: Int): Int { y.twice() }
`, "f");
    print(result.program).should.equal(
`def f(y: Int): Int {
    twice(y)
}

def twice(x: Int): Int {
    Multiply(x, 2)
}`);
}

@("a mutable argument is the local the callee writes back to")
unittest
{
    auto result = loweredFunction(`
def bump(mutable n: Int): () { n = n + 1 }

def f(): Int {
    mutable val count = 0
    bump(mutable count)
    count
}
`, "f");
    print(result.program).should.equal(
`def f(): Int {
    let mutable count: Int = 0
    bump(count)
    count
}

def bump(mutable n: Int): Unit {
    n = Add(n, 1)
}`);
}