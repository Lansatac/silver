module silver.core.lower;

import std.algorithm : any, canFind, filter, map;
import std.array : array;
import std.format : format;
import std.sumtype : match;
import std.typecons : Rebindable, rebindable;

import ast = silver.ast;
import silver.ast : discardName, Id, Span;
import silver.core.nodes;
import silver.sema : Analysis, LoopFunction, LoopFunctions, ConstInt, ConstUInt, ConstUnit, ConstValue, FunctionData, Intrinsic, NominalData, Primitive,
    Substitution, SymbolId, Type, TypeTable;

/// A parameter's local name. Discarded ones get a name no Silver identifier can have, so several
/// in one function stay distinct where a backend names them.
private string paramName(string name, size_t index)
{
    return name == discardName ? "_.%s".format(index) : name;
}

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
    auto program = Program(rebindable(analysis.types), lowering.functions, entry, lowering.libraries);
    lowering.describeTypes(program);
    return program;
}

/// How deeply an instance's type arguments can nest, which only polymorphic recursion reaches.
enum instanceNestingLimit = 64;

/// A function with its type arguments, which are empty for one that isn't generic.
private struct InstanceKey
{
    Id!(ast.FunctionDecl) decl;
    immutable(Type)[] args;
}

/// The Analysis as one instance of a generic function reads it: every type it answers with has
/// the instance's type arguments filled in, so the rest of lowering only sees concrete types. What
/// it doesn't override, it answers as the Analysis does.
private struct Instance
{
    Rebindable!(const Analysis) analysis;
    Substitution substitution;

    const(Analysis) base() const => analysis;
    alias base this;

    private Type concrete(Type type) const => analysis.instantiate(type, substitution);

    private FunctionData signature(Type type) const
    {
        return analysis.types[concrete(type)].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "a function's type is a function type"),
        );
    }

    Type typeOf(Id!(ast.Expr) id) const => concrete(analysis.typeOf(id));
    Type typeOf(Id!(ast.Param) id) const => concrete(analysis.typeOf(id));
    Type typeOf(Id!(ast.VarDecl) id) const => concrete(analysis.typeOf(id));
    Type typeOf(Id!(ast.ConstDecl) id) const => analysis.typeOf(id);
    FunctionData signatureOf(Id!(ast.FunctionDecl) id) const => signature(analysis.typeOf(id));
    FunctionData signatureOf(Id!(ast.Expr) lambda) const => signature(analysis.typeOf(lambda));

    /// The signature of the instance of `func` with `typeArgs`, which are concrete already.
    FunctionData signatureOf(Id!(ast.FunctionDecl) func, immutable(Type)[] typeArgs) const
    {
        Substitution instance;
        foreach (i, param; analysis.declarationOf(func).typeParams) instance[param.id] = typeArgs[i];
        return analysis.types[analysis.instantiate(analysis.typeOf(func), instance)].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "a function's type is a function type"),
        );
    }

    const(Type)* promotionOf(Id!(ast.Expr) id) const
    {
        auto option = analysis.promotionOf(id);
        if (option is null) return null;
        auto type = new Type;
        *type = concrete(*option);
        return type;
    }

    const(Type)* constructedMemberOf(Id!(ast.Expr) id) const
    {
        auto member = analysis.constructedMemberOf(id);
        if (member is null) return null;
        auto type = new Type;
        *type = concrete(*member);
        return type;
    }

    /// The functions the `for` loop `for_` calls, with their type arguments for this instance.
    const(LoopFunctions)* loopOf(Id!(ast.Expr) for_) const
    {
        auto loop = analysis.loopOf(for_);
        if (loop is null) return null;
        auto instance = new LoopFunctions;
        *instance = LoopFunctions(concrete(loop.length), concrete(loop.at), concrete(loop.next));
        return instance;
    }

    private LoopFunction concrete(const LoopFunction f) const
    {
        return LoopFunction(f.func, f.typeArgs.map!(t => concrete(t)).array);
    }

    /// What the type parameters of the generic `name` uses stand for in this instance.
    immutable(Type)[] typeArgumentsOf(Id!(ast.Expr) name) const
    {
        return analysis.typeArgumentsOf(name).map!(t => concrete(t)).array.idup;
    }
}

/// A nested `def` inside its own body, where naming it rebuilds its closure from its captures.
private struct Self
{
    size_t slot;
    Local[] captures;
}

/// One step of a path into a value, as `p.a.b` takes: the field's index, and its type.
private struct Step
{
    size_t index;
    Type type;
}

private final class Lowering
{
    /// The Analysis as the function being lowered reads it.
    private Instance _analysis;
    /// Each local and param of the function being lowered, and each value its closure captures.
    private Local[SymbolId] _locals;
    /// The nested `def` being lowered, which can name itself.
    private Self[SymbolId] _selves;
    /// What `return` and `?` return from in the function being lowered.
    private Type _returnType;
    /// The label of the innermost loop whose body is being lowered, which `break` and `continue` leave.
    private size_t _loop = size_t.max;
    private size_t _nextLabel;
    private string _moduleName;
    /// The node being lowered, for reporting what isn't lowered yet.
    private Span _span;
    /// Expressions already lowered to these, as the index of `xs[i] += v` is.
    private Expr[Id!(ast.Expr)] _lowered;

    /// What becomes `Program.functions`. A function gets its slot when a call first names it,
    /// and is lowered later from `_pending`, so recursion never lowers a function twice. A
    /// generic function gets one per instance.
    Function[] functions;
    private size_t[InstanceKey] _slots;
    private InstanceKey[] _pending;
    /// The instance being lowered, and the one each instance was first needed by, for showing how
    /// an instance nested too deeply came about.
    private InstanceKey _current;
    private InstanceKey[InstanceKey] _neededBy;
    /// Each `native library` a call has needed, in the order first needed.
    string[] libraries;

    /// The functions lowering makes up, by what they're for, so each is made once.
    private size_t[Type] _equalities;
    private size_t[Type] _formats;
    /// A constructor used as a value, by the function type it has.
    private size_t[Type] _constructors;
    private size_t[Id!(ast.FunctionDecl)] _nativeWrappers;
    /// An intrinsic used as a value, by the instance it is.
    private size_t[InstanceKey] _intrinsicWrappers;

    this(const Analysis analysis)
    {
        _analysis = Instance(rebindable(analysis), null);
    }

    /// Where `func` with the type arguments `args` is in `functions`, giving it a slot and
    /// queueing it the first time.
    size_t slotFor(Id!(ast.FunctionDecl) func, immutable(Type)[] args = null)
    {
        auto key = InstanceKey(func, args);
        if (auto existing = key in _slots) return *existing;
        if (_current != key) _neededBy[key] = _current;
        if (args.any!(a => types.depth(a) > instanceNestingLimit)) reportNesting(key);
        auto slot = reserveSlot();
        _slots[key] = slot;
        _pending ~= key;
        return slot;
    }

    /// Stops at an instance whose type arguments nest too deeply, showing the instances that
    /// led to it.
    private void reportNesting(InstanceKey key)
    {
        import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException;

        string[] chain = [instanceName(key)];
        for (auto at = key; at in _neededBy; at = _neededBy[at])
        {
            if (!_neededBy[at].decl.isValid) break;
            chain = instanceName(_neededBy[at]) ~ chain;
        }
        enum shown = 3;
        auto elided = chain.length > 2 * shown + 1
            ? chain[0 .. shown] ~ "... %s more ...".format(chain.length - 2 * shown) ~ chain[$ - shown .. $]
            : chain;
        throw new DiagnosticException(Diagnostic(DiagnosticCode.InstanceNestingTooDeep, _span,
            "Type arguments nest more than %s deep, as a generic function that calls itself with a larger type "
                .format(instanceNestingLimit) ~ "would need endlessly many instances:\n    %-(%s\n    -> %)".format(elided)));
    }

    /// `first<Int>`, or the plain name of a function that isn't generic. An overloaded one adds its
    /// declared parameter types, as in `show(Int)`.
    private string instanceName(InstanceKey key)
    {
        import std.range : iota;

        string name = _analysis.declarationOf(key.decl).name;
        if (key.args.length > 0) name = "%s<%-(%s, %)>".format(name, key.args.map!(a => types.describe(a)));
        if (!_analysis.isOverloaded(key.decl)) return name;
        auto declared = _analysis.signatureOf(key.decl);
        auto params = declared.params.length.iota.map!(i => (declared.isMutable(i) ? "mutable " : "") ~ types.describe(declared.params[i]));
        return "%s(%-(%s, %))".format(name, params);
    }

    private size_t reserveSlot()
    {
        functions ~= Function.init;
        return functions.length - 1;
    }

    void lowerPending()
    {
        while (_pending.length > 0)
        {
            auto key = _pending[0];
            _pending = _pending[1 .. $];
            auto lowered = lowerFunction(key);
            functions[_slots[key]] = lowered;
        }
    }

    private Function lowerFunction(InstanceKey key)
    {
        auto func = _analysis.declarationOf(key.decl);
        assert(func.kind == ast.FunctionKind.ordinary, "a call to a native or an intrinsic has a node of its own, so they never get a slot");
        Substitution substitution;
        foreach (i, param; func.typeParams) substitution[param.id] = key.args[i];
        _analysis = Instance(_analysis.analysis, substitution);
        _current = key;
        _span = func.nameSpan;
        _locals = null;
        _selves = null;
        auto signature = _analysis.signatureOf(func.id);
        _returnType = signature.ret;
        _moduleName = _analysis.moduleOf(func.id);
        Local[] params;
        foreach (i, ref param; func.params)
        {
            auto local = new Local(paramName(param.name, i), signature.params[i], signature.isMutable(i));
            _locals[SymbolId(param.id)] = local;
            params ~= local;
        }
        auto body = coerce(lowerExpr(*func.body), signature.ret);
        return Function(instanceName(key), _moduleName, params, null, signature.ret, body, FunctionOrigin.declared);
    }

    /// Stops at a type nested too deeply, which a generic type whose fields hold ever larger
    /// instances of itself makes.
    private void reportTypeNesting(Type type)
    {
        import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException;

        throw new DiagnosticException(Diagnostic(DiagnosticCode.InstanceNestingTooDeep, _span,
            "Type arguments nest more than %s deep, as a generic type whose fields hold ever larger instances of itself "
                .format(instanceNestingLimit) ~ "would need endlessly many types; the deepest is `%s`".format(types.describe(type))));
    }

    /// The types of the declared types `program` uses, which backends need to lay them out.
    void describeTypes(ref Program program)
    {
        bool[Type] seen;
        void visitType(Type type)
        {
            if (type in seen) return;
            seen[type] = true;
            if (types.depth(type) > instanceNestingLimit) reportTypeNesting(type);
            types[type].match!(
                (const NominalData nominal) {
                    if (isCellType(type))
                    {
                        auto contents = cellContents(type);
                        program.cellContents[type] = contents;
                        visitType(contents);
                        return;
                    }
                    auto members = _analysis.membersOf(type);
                    if (members.length > 0)
                    {
                        program.sumMembers[type] = members;
                        foreach (member; members) visitType(member);
                        return;
                    }
                    auto fields = fieldTypes(type);
                    program.recordFields[type] = fields;
                    foreach (field; fields) visitType(field);
                },
                (const silver.sema.OptionData option) => visitType(option.inner),
                (const silver.sema.ArrayData array) => visitType(array.element),
                (const silver.sema.TupleData tuple) {
                    foreach (element; tuple.elements) visitType(element);
                },
                (const FunctionData func) {
                    foreach (param; func.params) visitType(param);
                    visitType(func.ret);
                },
                (_) {},
            );
        }

        void visitExpr(const Expr e)
        {
            visitType(e.type);
            void all(const Expr[] exprs)
            {
                foreach (ref expr; exprs) visitExpr(expr);
            }
            e.kind.match!(
                (const Call call) => all(call.args),
                (const CallClosure call) {
                    visitExpr(*call.callee);
                    all(call.args);
                },
                (const MakeClosure closure) => all(closure.captures),
                (const ForeignCall call) => all(call.args),
                (const IntrinsicCall call) => all(call.args),
                (const Prim prim) => all(prim.args),
                (const Convert convert) => visitExpr(*convert.value),
                (const If if_) {
                    visitExpr(*if_.condition);
                    visitExpr(*if_.trueBody);
                    visitExpr(*if_.falseBody);
                },
                (const Block block) {
                    foreach (ref statement; block.statements)
                    {
                        statement.kind.match!(
                            (const Let let) {
                                visitType(let.local.type);
                                visitExpr(let.value);
                            },
                            (const Assign assign) => visitExpr(assign.value),
                            (const AssignElement assign) {
                                visitExpr(assign.index);
                                visitExpr(assign.value);
                            },
                            (const Eval eval) => visitExpr(eval.expr),
                        );
                    }
                    if (block.result !is null) visitExpr(*block.result);
                },
                (const Loop loop) => visitExpr(*loop.body),
                (const Return return_) => visitExpr(*return_.value),
                (const Construct construct) => all(construct.fields),
                (const Field field) => visitExpr(*field.object),
                (const Update update) {
                    visitExpr(*update.object);
                    visitExpr(*update.value);
                },
                (const Inject inject) {
                    if (inject.payload !is null) visitExpr(*inject.payload);
                },
                (const IsMember test) => visitExpr(*test.subject),
                (const Payload payload) => visitExpr(*payload.subject),
                (const ArrayLit literal) => all(literal.elements),
                (const Index index) {
                    visitExpr(*index.array);
                    visitExpr(*index.index);
                },
                (const Slice slice) {
                    visitExpr(*slice.array);
                    visitExpr(*slice.start);
                    visitExpr(*slice.end);
                },
                (const Length length) => visitExpr(*length.array),
                (const Cell cell) => all(cell.args),
                (_) {},
            );
        }

        foreach (ref func; program.functions)
        {
            foreach (local; func.params ~ func.captures) visitType(local.type);
            visitType(func.returnType);
            visitExpr(func.body);
        }
    }

    // Expressions

    private Expr lowerExpr(const ast.Expr e)
    {
        if (auto lowered = e.id in _lowered) return *lowered;
        auto outer = _span;
        _span = e.span;
        scope (exit) _span = outer;

        auto type = _analysis.typeOf(e.id);
        // A constructor of a member its sum owns builds the member, then becomes the sum.
        auto member = _analysis.constructedMemberOf(e.id);
        auto built = member is null ? type : *member;
        auto value = lowerRaw(e, built);
        if (member !is null) value = inject(_analysis.memberIndexFor(type, built), value, type);
        if (auto option = _analysis.promotionOf(e.id)) value = promote(value, type, *option);
        return value;
    }

    /// `e` as a value of `type`, before anything sema records on top of it is applied.
    private Expr lowerRaw(const ast.Expr e, Type type)
    {
        auto span = e.span;
        Expr make(ExprKind kind)
        {
            return Expr(type, span, kind);
        }

        return e.kind.match!(
            (const ast.UnitLiteral _) => make(ExprKind(UnitLit())),
            (const ast.BoolLiteral literal) => make(ExprKind(BoolLit(literal.value))),
            (const ast.IntLiteral literal) => make(numberLiteral(literal.value, false, type)),
            (const ast.FloatLiteral literal) => make(ExprKind(FloatLit(literal.value))),
            (const ast.StringLiteral literal) => make(ExprKind(StringLit(literal.value))),
            (const ast.InterpolatedString interpolated) => lowerInterpolated(interpolated, span),
            (const ast.Identifier _) => symbolValue(resolved(e), type, span, e.id),
            (const ast.UnaryExpr unary) => make(lowerUnary(unary, type)),
            (const ast.BinaryExpr binary) => lowerBinary(binary, e, type),
            (const ast.IfExpr if_) => lowerIf(if_, type, span),
            (const ast.BlockExpr block) => lowerBlock(block, type, span),
            (const ast.WhileExpr while_) => lowerWhile(while_, span),
            (const ast.ForExpr for_) => lowerFor(e, for_, span),
            (const ast.CallExpr call) => lowerCall(e, call, type),
            (const ast.MemberAccess access) => lowerMember(e, access, type),
            (const ast.SomeExpr some) => make(ExprKind(Inject(1, boxed(lowerExpr(*some.value))))),
            // A `None` whose value is used is promoted to the option it lands in, which replaces
            // this; one that's dropped is nothing.
            (const ast.NoneLiteral _) => Expr(types.unit, span, ExprKind(UnitLit())),
            (const ast.PropagateExpr propagate) => lowerPropagate(propagate, type, span),
            (const ast.SafeMemberAccess access) => lowerSafeMember(e, access, type),
            (const ast.ArrayLiteral literal) => make(ExprKind(ArrayLit(literal.elements.map!(el => lowerExpr(el)).array))),
            (const ast.IndexExpr index) => lowerIndex(index, type, span),
            (const ast.TupleLiteral literal) => make(ExprKind(Construct(literal.elements.map!(el => lowerExpr(el)).array))),
            (const ast.WithExpr with_) => lowerWith(e, with_, type),
            (const ast.MatchExpr match_) => lowerMatch(match_, type, span),
            (const ast.Lambda lambda) => lowerLambda(e, lambda, type),
            (const ast.MapLiteral _) => notLowered!Expr("a map"),
            (const ast.RangeExpr _) => notLowered!Expr("a range outside a slice or `for`"),
        );
    }

    private SymbolId resolved(const ast.Expr use)
    {
        auto symbol = _analysis.resolutionOf(use.id);
        assert(symbol !is null, "sema resolves every identifier");
        return *symbol;
    }

    /// The value a name refers to, as an expression of `type`. `name` is the name's own node, which
    /// says what a generic function's type arguments are.
    private Expr symbolValue(SymbolId symbol, Type type, Span span, Id!(ast.Expr) name = Id!(ast.Expr).init)
    {
        if (auto local = symbol in _locals) return use(*local, span);
        if (auto self = symbol in _selves)
        {
            return Expr(type, span, ExprKind(MakeClosure(self.slot, self.captures.map!(c => use(c, span)).array)));
        }
        return symbol.match!(
            (const Id!(ast.FunctionDecl) func) => functionValue(func, type, span, _analysis.typeArgumentsOf(name)),
            (const Id!(ast.ConstDecl) constant) => constantValue(constant, span),
            (const Id!(ast.TypeDecl) decl) => typeValue(decl, type, span),
            (_) => notLowered!Expr("a reference to that kind of name"),
        );
    }

    /// A named function used as a value, with the type arguments of the instance it is.
    private Expr functionValue(Id!(ast.FunctionDecl) func, Type type, Span span, immutable(Type)[] typeArgs)
    {
        auto decl = _analysis.declarationOf(func);
        final switch (decl.kind)
        {
            case ast.FunctionKind.ordinary:
                return Expr(type, span, ExprKind(MakeClosure(slotFor(func, typeArgs), null)));
            case ast.FunctionKind.native:
                return Expr(type, span, ExprKind(MakeClosure(nativeWrapper(func), null)));
            case ast.FunctionKind.intrinsic:
                return Expr(type, span, ExprKind(MakeClosure(intrinsicWrapper(func, type, typeArgs), null)));
        }
    }

    /// A function that does what the intrinsic `func` does, for using it as a value of the
    /// function type `type`.
    private size_t intrinsicWrapper(Id!(ast.FunctionDecl) func, Type type, immutable(Type)[] typeArgs)
    {
        auto key = InstanceKey(func, typeArgs);
        if (auto existing = key in _intrinsicWrappers) return *existing;
        auto slot = reserveSlot();
        _intrinsicWrappers[key] = slot;
        auto decl = _analysis.declarationOf(func);
        auto signature = functionData(type);
        Local[] params;
        foreach (i, ref param; decl.params) params ~= new Local(paramName(param.name, i), signature.params[i]);
        auto body = intrinsicCall(_analysis.intrinsicOf(func), params.map!(p => use(p, _span)).array, signature, _span);
        functions[slot] = Function(instanceName(key), _analysis.moduleOf(func), params, null, signature.ret, body,
            FunctionOrigin.derived);
        return slot;
    }

    /// A value of `type`, a tuple or a declared type that isn't a sum, built from `fields`.
    private Expr construct(Type type, Expr[] fields, Span span)
    {
        if (isCellType(type)) return Expr(type, span, ExprKind(Cell(CellOp.New, fields)));
        return Expr(type, span, ExprKind(Construct(fields)));
    }

    /// A function that calls the native `func`, for using it as a value.
    private size_t nativeWrapper(Id!(ast.FunctionDecl) func)
    {
        if (auto existing = func in _nativeWrappers) return *existing;
        auto slot = reserveSlot();
        _nativeWrappers[func] = slot;
        auto decl = _analysis.declarationOf(func);
        auto signature = _analysis.signatureOf(func);
        Local[] params;
        foreach (i, ref param; decl.params) params ~= new Local(paramName(param.name, i), signature.params[i]);
        auto args = params.map!(p => use(p, _span)).array;
        auto body = Expr(signature.ret, _span, ExprKind(ForeignCall(decl.symbol, args)));
        noteLibrary(func);
        functions[slot] = Function(decl.name, _analysis.moduleOf(func), params, null, signature.ret, body,
            FunctionOrigin.derived);
        return slot;
    }

    /// A marker's name is its one value, and any other type's name is its constructor.
    private Expr typeValue(Id!(ast.TypeDecl) decl, Type type, Span span)
    {
        if (types.isFunction(type)) return Expr(type, span, ExprKind(MakeClosure(constructor(decl, type), null)));
        return Expr(type, span, ExprKind(Construct(null)));
    }

    /// A function that builds a value of `decl`, for using its constructor as a value of the
    /// function type `type`. For a generic type, the instance it builds is the one `type` returns,
    /// or the member of that sum which `decl` declares.
    private size_t constructor(Id!(ast.TypeDecl) decl, Type type)
    {
        if (auto existing = type in _constructors) return *existing;
        auto slot = reserveSlot();
        _constructors[type] = slot;
        auto signature = functionData(type);
        auto record = signature.ret;
        if (declOf(record) != decl)
        {
            auto members = _analysis.membersOf(record).filter!(m => declOf(m) == decl);
            assert(!members.empty, "a constructor builds its type, or a member of its sum");
            record = members.front;
        }
        Local[] params;
        foreach (field; _analysis.fieldsOf(record)) params ~= new Local(field.name, field.type);
        Expr body = construct(record, params.map!(p => use(p, _span)).array, _span);
        if (signature.ret != record) body = inject(_analysis.memberIndexFor(signature.ret, record), body, signature.ret);
        functions[slot] = Function(typeName(record) ~ typeArgumentsOf(record), _moduleName, params, null, signature.ret,
            body, FunctionOrigin.derived);
        return slot;
    }

    private Id!(ast.TypeDecl) declOf(Type type)
    {
        return types[type].match!((const NominalData nominal) => nominal.decl, _ => Id!(ast.TypeDecl).init);
    }

    /// `<Int>` for `Box<Int>`, or nothing for a type that isn't generic.
    private string typeArgumentsOf(Type type)
    {
        auto args = types[type].match!((const NominalData nominal) => nominal.args, _ => (immutable(Type)[]).init);
        return args.length == 0 ? "" : "<%-(%s, %)>".format(args.map!(a => types.describe(a)));
    }

    private Expr constantValue(Id!(ast.ConstDecl) constant, Span span)
    {
        auto type = _analysis.typeOf(constant);
        auto kind = _analysis.valueOf(constant).match!(
            (const ConstInt v) => type == types.float_ ? ExprKind(FloatLit(v.value)) : ExprKind(IntLit(cast(ulong) v.value)),
            (const ConstUInt v) => type == types.float_ ? ExprKind(FloatLit(v.value)) : ExprKind(IntLit(v.value)),
            (const bool v) => ExprKind(BoolLit(v)),
            (const double v) => ExprKind(FloatLit(v)),
            (const string v) => ExprKind(StringLit(v)),
            (const ConstUnit _) => ExprKind(UnitLit()),
        );
        return Expr(type, span, kind);
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

    private Expr lowerBinary(const ast.BinaryExpr binary, const ast.Expr e, Type type)
    {
        auto span = e.span;
        switch (binary.op)
        {
            // Short-circuiting: the right side runs only when the left doesn't decide.
            case ast.BinaryOp.And:
                return Expr(type, span, ExprKind(If(boxed(lowerExpr(*binary.left)), boxed(lowerExpr(*binary.right)),
                    boxed(boolLiteral(false, span)))));
            case ast.BinaryOp.Or:
                return Expr(type, span, ExprKind(If(boxed(lowerExpr(*binary.left)), boxed(boolLiteral(true, span)),
                    boxed(lowerExpr(*binary.right)))));
            // Sema flattens a chain of `~` into one list of operands, so it's one allocation.
            case ast.BinaryOp.Concat:
                return Expr(type, span, ExprKind(Prim(PrimOp.Concat,
                    _analysis.concatOperands(e.id).map!(o => lowerExpr(o)).array)));
            case ast.BinaryOp.Coalesce:
                return lowerCoalesce(binary, type, span);
            case ast.BinaryOp.Equal, ast.BinaryOp.NotEqual:
                auto left = lowerExpr(*binary.left);
                auto right = lowerExpr(*binary.right);
                if (isPrimitive(left.type)) goto default;
                auto equal = equality(left, right);
                return binary.op == ast.BinaryOp.Equal ? equal : not(equal);
            default:
                return Expr(type, span, ExprKind(Prim(primOp(binary.op), [lowerExpr(*binary.left), lowerExpr(*binary.right)])));
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

    /// `a ?? b`: `a` itself where the result is an option of `a`'s type, otherwise its payload,
    /// and `b` only when `a` is `None`.
    private Expr lowerCoalesce(const ast.BinaryExpr binary, Type type, Span span)
    {
        auto left = lowerExpr(*binary.left);
        auto option = temp("option", left.type);
        auto present = left.type == type ? use(option, span) : payload(use(option, span), 1);
        auto choice = Expr(type, span, ExprKind(If(boxed(isMember(use(option, span), 1)), boxed(present),
            boxed(lowerExpr(*binary.right)))));
        return Expr(type, span, ExprKind(Block([let(option, left)], boxed(choice))));
    }

    /// `x?`: the payload, or `None` returned from the function.
    private Expr lowerPropagate(const ast.PropagateExpr propagate, Type type, Span span)
    {
        auto operand = lowerExpr(*propagate.operand);
        auto option = temp("option", operand.type);
        auto leave = Expr(types.never, span, ExprKind(Return(boxed(noneOf(_returnType, span)))));
        auto choice = Expr(type, span, ExprKind(If(boxed(isMember(use(option, span), 1)),
            boxed(payload(use(option, span), 1)), boxed(leave))));
        return Expr(type, span, ExprKind(Block([let(option, operand)], boxed(choice))));
    }

    /// `x?.f`: `None` if `x` is, and otherwise its field, which isn't wrapped again when it's an
    /// option already.
    private Expr lowerSafeMember(const ast.Expr e, const ast.SafeMemberAccess access, Type type)
    {
        auto span = e.span;
        auto object = lowerExpr(*access.object);
        auto option = temp("option", object.type);
        auto index = _analysis.fieldIndexOf(e.id);
        auto record = payload(use(option, span), 1);
        auto value = field(record, index, fieldTypes(record.type)[index]);
        if (value.type != type) value = inject(1, value, type);
        auto choice = Expr(type, span, ExprKind(If(boxed(isMember(use(option, span), 1)), boxed(value),
            boxed(noneOf(type, span)))));
        return Expr(type, span, ExprKind(Block([let(option, object)], boxed(choice))));
    }

    /// `None` as a value of `type`, an option or a sum with an option member.
    private Expr noneOf(Type type, Span span)
    {
        if (types.isOption(type)) return Expr(type, span, ExprKind(Inject(0, null)));
        auto index = _analysis.memberIndexFor(type, types.none);
        return inject(index, noneOf(_analysis.membersOf(type)[index], span), type);
    }

    /// `value`, of type `from`, as `to`: injected into a sum, wrapped in as many `Some`s as the
    /// option types between them, or a `None` or `[]` taking on its type.
    private Expr promote(Expr value, Type from, Type to)
    {
        if (from == to || from == types.never) return value;
        if (_analysis.membersOf(to).length > 0)
        {
            auto index = _analysis.memberIndexFor(to, from);
            return inject(index, promote(value, from, _analysis.membersOf(to)[index]), to);
        }
        if (from == types.none)
        {
            // Anything but a bare `None`, like a block ending in one, still runs.
            auto bare = value.kind.match!((const UnitLit _) => true, _ => false);
            auto none = noneOf(to, value.span);
            if (bare) return none;
            return Expr(to, value.span, ExprKind(Block([eval(value)], boxed(none))));
        }
        if (from == types.emptyArray)
        {
            value.type = to;
            return value;
        }
        if (types.isOption(to)) return inject(1, promote(value, from, types.optionInner(to)), to);
        return value;
    }

    private Expr lowerInterpolated(const ast.InterpolatedString interpolated, Span span)
    {
        auto parts = interpolated.parts.map!(p => formatted(lowerExpr(p))).array;
        if (parts.length == 1) return parts[0];
        return Expr(types.string_, span, ExprKind(Prim(PrimOp.Concat, parts)));
    }

    private Expr lowerMember(const ast.Expr e, const ast.MemberAccess access, Type type)
    {
        // `std.math.pi` names a declaration.
        if (auto symbol = _analysis.resolutionOf(e.id)) return symbolValue(*symbol, type, e.span, e.id);
        auto object = lowerExpr(*access.object);
        return field(object, _analysis.fieldIndexOf(e.id), type);
    }

    private Expr lowerIndex(const ast.IndexExpr index, Type type, Span span)
    {
        auto array = lowerExpr(*index.object);
        if (auto range = ast.asRange(index.index))
        {
            auto start = range.start is null ? intLiteral(types.int_, 0, span) : lowerExpr(*range.start);
            if (range.end !is null)
            {
                return Expr(type, span, ExprKind(Slice(boxed(array), boxed(start), boxed(lowerExpr(*range.end)))));
            }
            // `xs[a..]` ends at the length of the array it slices, which is evaluated once.
            auto held = temp("sliced", array.type);
            auto end = Expr(types.int_, span, ExprKind(Length(boxed(use(held, span)))));
            auto slice = Expr(type, span, ExprKind(Slice(boxed(use(held, span)), boxed(start), boxed(end))));
            return Expr(type, span, ExprKind(Block([let(held, array)], boxed(slice))));
        }
        return Expr(type, span, ExprKind(Index(boxed(array), boxed(lowerExpr(*index.index)))));
    }

    /// `object with (a.b = v, ...)`: a copy of the object, with the updates applied in order.
    private Expr lowerWith(const ast.Expr e, const ast.WithExpr with_, Type type)
    {
        auto span = e.span;
        auto result = temp("with", type, true);
        Stmt[] statements = [let(result, lowerExpr(*with_.object))];
        foreach (i, path; _analysis.updatePathsOf(e.id))
        {
            auto value = lowerExpr(with_.updates[i].value);
            statements ~= assign(result, rebuild(use(result, span), stepsOf(type, path), value));
        }
        return Expr(type, span, ExprKind(Block(statements, boxed(use(result, span)))));
    }

    /// The steps through a value of `type` that the field indexes `path` take.
    private Step[] stepsOf(Type type, const(size_t)[] path)
    {
        Step[] steps;
        foreach (index; path)
        {
            type = fieldTypes(type)[index];
            steps ~= Step(index, type);
        }
        return steps;
    }

    /// `object`, a pure expression, with the field at the end of `steps` replaced by `value`.
    private Expr rebuild(Expr object, const Step[] steps, Expr value)
    {
        if (steps.length == 0) return value;
        auto inner = field(object, steps[0].index, steps[0].type);
        auto updated = Update(boxed(object), steps[0].index, boxed(rebuild(inner, steps[1 .. $], value)));
        return Expr(object.type, value.span, ExprKind(updated));
    }

    /// The local a place like `a.b.c` starts at, and the steps from it.
    private Local placeOf(const ast.Expr target, out Step[] steps)
    {
        return target.kind.match!(
            (const ast.Identifier _) => localOf(target),
            (const ast.MemberAccess access) {
                auto root = placeOf(*access.object, steps);
                steps ~= Step(_analysis.fieldIndexOf(target.id), _analysis.typeOf(target.id));
                return root;
            },
            (_) => notLowered!Local("assigning to that kind of place"),
        );
    }

    private Local localOf(const ast.Expr use)
    {
        if (auto local = resolved(use) in _locals) return *local;
        return notLowered!Local("a reference to something other than a local or param");
    }

    private Expr lowerIf(const ast.IfExpr if_, Type type, Span span)
    {
        auto otherwise = if_.falseBody is null ? unit(span) : coerce(lowerExpr(*if_.falseBody), type);
        if (if_.binding is null)
        {
            auto trueBody = coerce(lowerExpr(*if_.trueBody), type);
            return Expr(type, span, ExprKind(If(boxed(lowerExpr(*if_.condition)), boxed(trueBody), boxed(otherwise))));
        }

        // `if val x = o`: `x` is `o`'s payload, in the true arm alone.
        auto value = lowerExpr(if_.binding.value);
        auto option = temp("option", value.type);
        auto binds = bindOrDrop(*if_.binding, payload(use(option, span), 1));
        auto trueBody = coerce(lowerExpr(*if_.trueBody), type);
        auto taken = Expr(trueBody.type, span, ExprKind(Block(binds, boxed(trueBody))));
        auto choice = Expr(type, span, ExprKind(If(boxed(isMember(use(option, span), 1)), boxed(taken), boxed(otherwise))));
        return Expr(type, span, ExprKind(Block([let(option, value)], boxed(choice))));
    }

    /// A block of `type`, which is `Never` when it has no value though sema gave it one, since
    /// it can only end by leaving.
    private Expr lowerBlock(const ast.BlockExpr block, Type type, Span span)
    {
        Stmt[] statements;
        foreach (ref statement; block.statements)
        {
            statements ~= lowerStmt(statement);
        }
        Expr* result;
        if (block.value !is null)
        {
            auto value = lowerExpr(*block.value);
            if (type == types.unit && value.type != types.unit && value.type != types.never)
            {
                statements ~= eval(value);
            }
            else
            {
                result = boxed(value);
            }
        }
        if (result is null && type != types.unit) type = types.never;
        return Expr(type, span, ExprKind(Block(statements, result)));
    }

    private Stmt[] lowerStmt(const ast.Stmt statement)
    {
        auto outer = _span;
        _span = statement.span;
        scope (exit) _span = outer;
        return statement.kind.match!(
            (const ast.VarDecl decl) => lowerVar(decl),
            (const ast.AssignStmt assign) => lowerAssign(assign, statement.span),
            (const ast.ExprStmt stmt) => [eval(lowerExpr(stmt.expr))],
            (const ast.BreakStmt _) => [eval(breakExpr(statement.span, _loop))],
            (const ast.ContinueStmt _) => [eval(continueExpr(statement.span, _loop))],
            (const ast.ReturnStmt return_) => [eval(returnExpr(coerce(lowerExpr(return_.value), _returnType)))],
            (const ast.PatternDecl decl) => lowerPatternDecl(decl.pattern, decl.value),
            (const ast.FunctionDecl _) => notLowered!(Stmt[])("a nested function that isn't a lambda"),
        );
    }

    private Stmt[] lowerVar(const ast.VarDecl decl)
    {
        // The value goes first: `val x = x` can't see the new `x`.
        return bindOrDrop(decl, lowerExpr(decl.value));
    }

    /// `decl` bound to `value`, or `value` dropped for `_`.
    private Stmt[] bindOrDrop(const ast.VarDecl decl, Expr value)
    {
        if (decl.name == discardName) return [eval(value)];
        auto local = new Local(decl.name, value.type, decl.mutable);
        _locals[SymbolId(decl.id)] = local;
        return [let(local, value)];
    }

    /// `val (a, b) = value`. A tuple literal is taken apart element by element, so no tuple is built.
    private Stmt[] lowerPatternDecl(const ast.Pattern pattern, const ast.Expr value)
    {
        if (auto literal = ast.elementwise(pattern, value))
        {
            auto parts = pattern.kind.match!(
                (const ast.TuplePattern tuple) => tuple.elements,
                (_) => assert(0, "only a tuple pattern goes element by element"),
            );
            Stmt[] statements;
            foreach (i, ref element; literal.elements)
            {
                statements ~= lowerPatternDecl(parts[i], element);
            }
            return statements;
        }

        auto whole = lowerExpr(value);
        auto taken = pattern.kind.match!((const ast.VarDecl decl) => true, _ => false);
        if (taken)
        {
            return pattern.kind.match!((const ast.VarDecl decl) => bindOrDrop(decl, whole), _ => (Stmt[]).init);
        }
        auto held = temp("tuple", whole.type);
        Expr[] tests;
        Stmt[] binds;
        takeApart(pattern, use(held, whole.span), tests, binds);
        assert(tests.length == 0, "a `val` pattern matches every value of its type");
        return let(held, whole) ~ binds;
    }

    private Stmt[] lowerAssign(const ast.AssignStmt assign, Span span)
    {
        if (assign.target.kind.match!((const ast.TupleLiteral _) => true, _ => false))
        {
            return lowerTupleAssign(assign.target, assign.value, span);
        }
        auto element = assign.target.kind.match!((ref const ast.IndexExpr index) => &index, _ => null);
        if (element !is null) return lowerAssignElement(assign, *element, span);
        return [Stmt(span, StmtKind(lowerAssignPlace(assign)))];
    }

    /// `xs[i] = v`. In `xs[i] += v`, the value's read of `xs[i]` uses the index already evaluated.
    private Stmt[] lowerAssignElement(const ast.AssignStmt assign, const ast.IndexExpr target, Span span)
    {
        auto local = localOf(*target.object);
        auto index = lowerExpr(*target.index);
        if (!assign.compound) return [Stmt(span, StmtKind(AssignElement(local, index, lowerExpr(assign.value))))];

        auto read = assign.value.kind.match!(
            (const ast.BinaryExpr binary) => binary.left.kind.match!(
                (ref const ast.IndexExpr index) => index.index.id,
                _ => assert(0, "a compound assignment reads its target"),
            ),
            _ => assert(0, "a compound assignment is a binary operation"),
        );
        auto held = temp("index", index.type);
        _lowered[read] = use(held, index.span);
        scope (exit) _lowered.remove(read);
        auto value = lowerExpr(assign.value);
        return [let(held, index), Stmt(span, StmtKind(AssignElement(local, use(held, index.span), value)))];
    }

    private Assign lowerAssignPlace(const ast.AssignStmt assign)
    {
        return assignPlace(assign.target, lowerExpr(assign.value));
    }

    /// `(a, xs[i], _) = value`. Each element target's index is evaluated, left to right, then every
    /// part of the value, and only then are the targets written, left to right, so `(a, b) = (b, a)`
    /// swaps. A tuple literal is taken apart element by element, so no tuple is built.
    private Stmt[] lowerTupleAssign(const ast.Expr target, const ast.Expr value, Span span)
    {
        Stmt[] statements;
        Local[typeof(target.id)] indices;
        const(ast.Expr)[] places;
        Expr[] parts;

        static const(ast.Expr)[] partsOf(const ast.Expr e) =>
            e.kind.match!((const ast.TupleLiteral t) => t.elements, _ => null);
        static bool isDiscard(const ast.Expr e) =>
            e.kind.match!((const ast.Identifier name) => name.name == discardName, _ => false);

        void holdIndices(const ast.Expr t)
        {
            t.kind.match!(
                (const ast.TupleLiteral tuple) {
                    foreach (ref element; tuple.elements) holdIndices(element);
                },
                (const ast.IndexExpr index) {
                    auto lowered = lowerExpr(*index.index);
                    auto held = temp("index", lowered.type);
                    statements ~= let(held, lowered);
                    indices[t.id] = held;
                },
                (_) {},
            );
        }

        // `whole` is pure, so each place can take its part with a read of it.
        void distribute(const ast.Expr t, Expr whole)
        {
            if (auto elements = partsOf(t))
            {
                foreach (i, ref element; elements)
                {
                    distribute(element, field(whole, i, fieldTypes(whole.type)[i]));
                }
                return;
            }
            if (isDiscard(t)) return;
            places ~= t;
            parts ~= whole;
        }

        void evaluate(const ast.Expr t, const ast.Expr v)
        {
            auto elements = partsOf(t);
            auto literal = partsOf(v);
            if (elements !is null && literal.length == elements.length)
            {
                foreach (i, ref element; elements) evaluate(element, literal[i]);
                return;
            }
            auto lowered = lowerExpr(v);
            if (isDiscard(t))
            {
                statements ~= eval(lowered);
                return;
            }
            auto held = temp(elements is null ? "value" : "tuple", lowered.type);
            statements ~= let(held, lowered);
            distribute(t, use(held, lowered.span));
        }

        holdIndices(target);
        evaluate(target, value);
        foreach (i, place; places)
        {
            if (auto index = place.id in indices)
            {
                auto object = place.kind.match!((const ast.IndexExpr e) => e.object, _ => null);
                auto write = AssignElement(localOf(*object), use(*index, place.span), parts[i]);
                statements ~= Stmt(span, StmtKind(write));
            }
            else
            {
                statements ~= Stmt(span, StmtKind(assignPlace(place, parts[i])));
            }
        }
        return statements;
    }

    /// `target = value` for a name or a chain of fields rooted at one.
    private Assign assignPlace(const ast.Expr target, Expr value)
    {
        Step[] steps;
        auto root = placeOf(target, steps);
        if (steps.length == 0) return Assign(root, value);
        // `p.x = v` gives `p` a copy of itself with `x` replaced, after `v` is evaluated.
        auto span = target.span;
        auto held = temp("value", value.type);
        auto rebuilt = rebuild(use(root, span), steps, use(held, span));
        return Assign(root, Expr(root.type, span, ExprKind(Block([let(held, value)], boxed(rebuilt)))));
    }

    /// `while c { body }` is `loop { if (!c) break; body }`, so `continue` re-checks `c`. A jump in
    /// `c` is the enclosing loop's, so only the body is lowered as this loop's.
    private Expr lowerWhile(const ast.WhileExpr while_, Span span)
    {
        auto label = newLabel();
        Stmt[] head;
        if (while_.binding is null)
        {
            head = [breakUnless(lowerExpr(*while_.condition), label)];
        }
        else
        {
            // `while val x = o` ends when `o` is `None`, and otherwise binds its payload.
            auto value = lowerExpr(while_.binding.value);
            auto option = temp("option", value.type);
            head = [let(option, value), breakUnless(isMember(use(option, span), 1), label)]
                ~ bindOrDrop(*while_.binding, payload(use(option, span), 1));
        }
        return loop(boxed(block(span, head ~ statementsOf(loopBody(*while_.body, label)))), span, label);
    }

    /// `body` lowered as the body of the loop `label`, which its `break` and `continue` leave.
    private Expr loopBody(const ast.Expr body, size_t label)
    {
        auto outer = _loop;
        _loop = label;
        scope (exit) _loop = outer;
        return lowerExpr(body);
    }

    private Expr lowerFor(const ast.Expr e, const ast.ForExpr for_, Span span)
    {
        auto range = ast.asRange(&for_.binding.value);
        if (range is null)
        {
            auto functions = _analysis.loopOf(e.id);
            if (functions is null || functions.indexed) return lowerForIndexed(for_, functions, span);
            return lowerForStepped(for_, functions.next, span);
        }
        auto start = lowerExpr(*range.start);
        auto end = lowerExpr(*range.end);

        auto type = _analysis.typeOf(for_.binding.id);

        auto next = temp("next", type, true);
        auto last = temp("end", type);

        auto bindingVar = temp(for_.binding.name, type);
        _locals[SymbolId(for_.binding.id)] = bindingVar;
        auto label = newLabel();
        auto forBody = loopBody(*for_.body, label);
        return block(span, [
            let(next, start),
            let(last, end),
            eval(loop(boxed(block(span, [
                breakUnless(prim(PrimOp.Less, types.bool_, use(next, span), use(last, span)), label),
                let(bindingVar, use(next, span)),
                assign(next, prim(PrimOp.Add, type, use(next, span), intLiteral(type, 1, span))),
            ] ~ statementsOf(forBody))), span, label)),
        ]);
    }

    /// `for x in xs` over an array, or a value with `length` and `at` (`functions`), evaluates `xs`
    /// and its length once, and steps an index before the body, so `continue` can't skip it. An
    /// array's element isn't read for `_`, since that can't be seen, but `at` is called.
    private Expr lowerForIndexed(const ast.ForExpr for_, const(LoopFunctions)* functions, Span span)
    {
        auto source = lowerExpr(for_.binding.value);
        auto held = temp(functions is null ? "array" : "source", source.type);
        auto count = temp("count", types.int_);
        auto next = temp("next", types.int_, true);
        Expr length;
        Expr value;
        if (functions is null)
        {
            auto element = types.isArray(source.type) ? types.arrayElement(source.type) : types.never;
            length = Expr(types.int_, span, ExprKind(Length(boxed(use(held, span)))));
            value = Expr(element, span, ExprKind(Index(boxed(use(held, span)), boxed(use(next, span)))));
        }
        else
        {
            length = callLoopFunction(functions.length, [use(held, span)], span);
            value = callLoopFunction(functions.at, [use(held, span), use(next, span)], span);
        }
        auto binds = functions is null && for_.binding.name == discardName ? null : bindOrDrop(*for_.binding, value);
        auto label = newLabel();
        auto forBody = loopBody(*for_.body, label);
        return block(span, [
            let(held, source),
            let(count, length),
            let(next, intLiteral(types.int_, 0, span)),
            eval(loop(boxed(block(span, [
                breakUnless(prim(PrimOp.Less, types.bool_, use(next, span), use(count, span)), label),
            ] ~ binds ~ [
                assign(next, prim(PrimOp.Add, types.int_, use(next, span), intLiteral(types.int_, 1, span))),
            ] ~ statementsOf(forBody))), span, label)),
        ]);
    }

    /// `for x in r` with `next` is `while val step = next(rest)` over a mutable `rest` that starts
    /// as `r`. `rest` moves on before the body, so `continue` can't skip it.
    private Expr lowerForStepped(const ast.ForExpr for_, const LoopFunction stepper, Span span)
    {
        auto source = lowerExpr(for_.binding.value);
        auto rest = temp("rest", source.type, true);
        auto next = callLoopFunction(stepper, [use(rest, span)], span);
        auto step = temp("step", next.type);
        auto stepped = payload(use(step, span), 1);
        auto pair = temp("pair", stepped.type);
        auto parts = fieldTypes(pair.type);
        auto binds = bindOrDrop(*for_.binding, field(use(pair, span), 0, parts[0]));
        auto label = newLabel();
        auto forBody = loopBody(*for_.body, label);
        return block(span, [
            let(rest, source),
            eval(loop(boxed(block(span, [
                let(step, next),
                breakUnless(isMember(use(step, span), 1), label),
                let(pair, stepped),
            ] ~ binds ~ [
                assign(rest, field(use(pair, span), 1, parts[1])),
            ] ~ statementsOf(forBody))), span, label)),
        ]);
    }

    /// Tries the arms in order. Each arm's tests are joined with `&&`, so a payload is only read
    /// once its tag has been checked, and the last arm needs none, since sema found the arms cover
    /// every value.
    private Expr lowerMatch(const ast.MatchExpr match_, Type type, Span span)
    {
        auto subject = lowerExpr(*match_.subject);
        auto held = temp("subject", subject.type);
        Expr[] conditions;
        Expr[] bodies;
        foreach (ref arm; match_.arms)
        {
            Expr[] tests;
            Stmt[] binds;
            takeApart(arm.pattern, use(held, arm.span), tests, binds);
            auto body = coerce(lowerExpr(arm.body), type);
            conditions ~= allOf(tests, arm.span);
            bodies ~= binds.length == 0 ? body : Expr(body.type, arm.span, ExprKind(Block(binds, boxed(body))));
            if (tests.length == 0) break;
        }
        auto chain = bodies[$ - 1];
        foreach_reverse (i; 0 .. bodies.length - 1)
        {
            chain = Expr(type, span, ExprKind(If(boxed(conditions[i]), boxed(bodies[i]), boxed(chain))));
        }
        return Expr(type, span, ExprKind(Block([let(held, subject)], boxed(chain))));
    }

    /// What `value` has to pass to match `pattern`, appended to `tests` in the order they're
    /// checked, and the lets for what the pattern binds. `value` is pure, so it can be repeated.
    private void takeApart(const ast.Pattern pattern, Expr value, ref Expr[] tests, ref Stmt[] binds)
    {
        if (auto index = _analysis.memberTestOf(pattern.id))
        {
            tests ~= isMember(value, *index);
            value = payload(value, *index);
        }
        pattern.kind.match!(
            (const ast.VarDecl binding) {
                binds ~= bindOrDrop(binding, value);
            },
            (const ast.TuplePattern tuple) {
                foreach (i, ref element; tuple.elements)
                {
                    takeApart(element, field(value, i, fieldTypes(value.type)[i]), tests, binds);
                }
            },
            (const ast.ConstructorPattern constructor) {
                auto fields = fieldTypes(value.type);
                foreach (i, ref argument; constructor.arguments)
                {
                    takeApart(argument, field(value, i, fields[i]), tests, binds);
                }
            },
            (const ast.SomePattern some) {
                tests ~= isMember(value, 1);
                takeApart(*some.inner, payload(value, 1), tests, binds);
            },
            (const ast.NonePattern _) {
                tests ~= isMember(value, 0);
            },
            (const ast.LiteralPattern literal) {
                auto expected = lowerExpr(*literal.value);
                tests ~= isPrimitive(value.type) ? prim(PrimOp.Equal, types.bool_, value, expected) : equality(value, expected);
            },
        );
    }

    /// `tests` joined with `&&`, or `true` for none.
    private Expr allOf(Expr[] tests, Span span)
    {
        if (tests.length == 0) return boolLiteral(true, span);
        auto joined = tests[$ - 1];
        foreach_reverse (test; tests[0 .. $ - 1])
        {
            joined = Expr(types.bool_, span, ExprKind(If(boxed(test), boxed(joined), boxed(boolLiteral(false, span)))));
        }
        return joined;
    }

    /// A lambda becomes a function of its own, and a closure that carries a copy of each value it
    /// captures.
    private Expr lowerLambda(const ast.Expr e, const ast.Lambda lambda, Type type)
    {
        auto span = e.span;
        auto signature = _analysis.signatureOf(e.id);
        auto captured = _analysis.capturesOf(e.id);
        auto captureValues = captured.map!(c => symbolValue(c, symbolType(c), span)).array;

        auto slot = reserveSlot();
        auto outerLocals = _locals;
        auto outerSelves = _selves;
        auto outerReturn = _returnType;
        auto outerLoop = _loop;
        scope (exit)
        {
            _locals = outerLocals;
            _selves = outerSelves;
            _returnType = outerReturn;
            _loop = outerLoop;
        }
        _locals = null;
        _selves = null;
        _returnType = signature.ret;
        _loop = size_t.max;

        Local[] captures;
        foreach (symbol; captured)
        {
            auto local = new Local(symbolName(symbol), symbolType(symbol));
            _locals[symbol] = local;
            captures ~= local;
        }
        Local[] params;
        foreach (i, ref param; lambda.params)
        {
            auto local = new Local(paramName(param.name, i), signature.params[i], signature.isMutable(i));
            _locals[SymbolId(param.id)] = local;
            params ~= local;
        }
        if (lambda.self.isValid) _selves[SymbolId(lambda.self)] = Self(slot, captures);

        auto body = coerce(lowerExpr(*lambda.body), signature.ret);
        auto name = lambda.name is null ? "lambda" : lambda.name;
        functions[slot] = Function(name, _moduleName, params, captures, signature.ret, body, FunctionOrigin.lambda);
        return Expr(type, span, ExprKind(MakeClosure(slot, captureValues)));
    }

    private Type symbolType(SymbolId symbol)
    {
        return symbol.match!(
            (const Id!(ast.Param) param) => _analysis.typeOf(param),
            (const Id!(ast.VarDecl) local) => _analysis.typeOf(local),
            (_) => assert(0, "only locals and params are captured"),
        );
    }

    private string symbolName(SymbolId symbol)
    {
        return symbol.match!(
            (const Id!(ast.Param) param) => _analysis.declarationOf(param).name,
            (const Id!(ast.VarDecl) local) => _analysis.declarationOf(local).name,
            (_) => assert(0, "only locals and params are captured"),
        );
    }

    /// A call to a function sema has picked, a constructor, a conversion, or a function value.
    private Expr lowerCall(const ast.Expr e, const ast.CallExpr call, Type type)
    {
        auto span = e.span;
        if (_analysis.constructionOf(e.id) !is null)
        {
            return construct(type, call.args.map!(a => lowerExpr(a)).array, span);
        }
        if (_analysis.isConversion(e.id)) return lowerConversion(lowerExpr(call.args[0]), type, span);
        // `x.f(y)` is `f(x, y)`, which sema has built.
        auto method = _analysis.methodCallOf(e.id);
        auto written = method is null ? call.args : method.args;

        auto calleeId = _analysis.calleeOf(e.id);
        if (calleeId is null)
        {
            auto callee = lowerExpr(*call.callee);
            auto signature = functionData(callee.type);
            return callWith(written, signature, type, span, &callee,
                (Expr[] args, Expr* callee) => Expr(type, span, ExprKind(CallClosure(callee, args))));
        }

        auto decl = _analysis.declarationOf(*calleeId);
        auto typeArgs = _analysis.typeArgumentsOf(call.callee.id);
        auto signature = _analysis.signatureOf(*calleeId, typeArgs);
        final switch (decl.kind)
        {
            case ast.FunctionKind.ordinary:
                auto target = slotFor(*calleeId, typeArgs);
                return callWith(written, signature, type, span, null,
                    (Expr[] args, Expr* _) => Expr(signature.ret, span, ExprKind(Call(target, args))));
            case ast.FunctionKind.native:
                noteLibrary(*calleeId);
                auto symbol = decl.symbol;
                return callWith(written, signature, type, span, null,
                    (Expr[] args, Expr* _) => Expr(signature.ret, span, ExprKind(ForeignCall(symbol, args))));
            case ast.FunctionKind.intrinsic:
                return lowerIntrinsic(*calleeId, written, signature, span);
        }
    }

    /// A call of a function a `for` uses, given its arguments as values.
    private Expr callLoopFunction(const LoopFunction f, Expr[] args, Span span)
    {
        return callDirect(f.func, f.typeArgs.idup, args, span);
    }

    /// A call of the instance of `callee` with `typeArgs`, given its arguments as values.
    private Expr callDirect(Id!(ast.FunctionDecl) callee, immutable(Type)[] typeArgs, Expr[] args, Span span)
    {
        auto decl = _analysis.declarationOf(callee);
        auto signature = _analysis.signatureOf(callee, typeArgs);
        final switch (decl.kind)
        {
            case ast.FunctionKind.ordinary:
                return Expr(signature.ret, span, ExprKind(Call(slotFor(callee, typeArgs), args)));
            case ast.FunctionKind.native:
                noteLibrary(callee);
                return Expr(signature.ret, span, ExprKind(ForeignCall(decl.symbol, args)));
            case ast.FunctionKind.intrinsic:
                return intrinsicCall(_analysis.intrinsicOf(callee), args, signature, span);
        }
    }

    private void noteLibrary(Id!(ast.FunctionDecl) native)
    {
        if (auto library = _analysis.libraryOf(native))
        {
            if (!libraries.canFind(library)) libraries ~= library;
        }
    }

    private Expr lowerIntrinsic(Id!(ast.FunctionDecl) callee, const ast.Expr[] written, FunctionData signature, Span span)
    {
        return intrinsicCall(_analysis.intrinsicOf(callee), written.map!(a => lowerExpr(a)).array, signature, span);
    }

    /// What `intrinsic` does with `args`, which are values. One filling an `Any` that isn't a
    /// primitive is formatted to a String first.
    private Expr intrinsicCall(Intrinsic intrinsic, Expr[] args, FunctionData signature, Span span)
    {
        final switch (intrinsic)
        {
            case Intrinsic.length:
                return Expr(types.int_, span, ExprKind(Length(boxed(args[0]))));
            case Intrinsic.get:
                return Expr(signature.ret, span, ExprKind(Cell(CellOp.Get, args)));
            case Intrinsic.set:
                return Expr(types.unit, span, ExprKind(Cell(CellOp.Set, args)));
            case Intrinsic.update:
                return updateCell(args[0], args[1], span);
            case Intrinsic.print, Intrinsic.printl, Intrinsic.read, Intrinsic.panic:
                break;
        }
        bool[] anyArgs;
        foreach (i, ref value; args)
        {
            auto isAny = signature.params[i] == types.any;
            if (isAny && !isPrimitive(value.type)) value = formatted(value);
            anyArgs ~= isAny;
        }
        return Expr(signature.ret, span, ExprKind(IntrinsicCall(intrinsic, args, anyArgs)));
    }

    /// `update(cell, change)`. The contents are taken out of the cell while `change` runs, so
    /// nothing else holds them and `change` can extend them in place.
    private Expr updateCell(Expr cell, Expr change, Span span)
    {
        auto heldCell = temp("ref", cell.type);
        auto heldChange = temp("change", change.type);
        auto contents = cellContents(cell.type);
        auto taken = Expr(contents, span, ExprKind(Cell(CellOp.Take, [use(heldCell, span)])));
        auto changed = Expr(contents, span, ExprKind(CallClosure(boxed(use(heldChange, span)), [taken])));
        auto fill = Expr(types.unit, span, ExprKind(Cell(CellOp.Fill, [use(heldCell, span), changed])));
        return Expr(types.unit, span, ExprKind(Block([let(heldCell, cell), let(heldChange, change), eval(fill)], null)));
    }

    /// A call of `signature` with `written` as its arguments, made by `call` from the lowered
    /// arguments and callee. A `mutable` argument that's a field path, like `p.rng`, is passed in
    /// a temporary written back after the call. The other arguments and the callee are then put
    /// in temporaries first, since a place is only read once every other argument is evaluated.
    private Expr callWith(const ast.Expr[] written, FunctionData signature, Type type, Span span, Expr* callee,
        Expr delegate(Expr[], Expr*) call)
    {
        auto hasPath = false;
        foreach (i, ref arg; written)
        {
            if (signature.isMutable(i)) hasPath |= arg.kind.match!((const ast.Identifier _) => false, _ => true);
        }
        if (!hasPath)
        {
            auto args = written.map!(a => lowerExpr(a)).array;
            return coerce(call(args, callee is null ? null : boxed(*callee)), type);
        }

        Stmt[] before;
        Expr hold(Expr value, string name)
        {
            auto local = temp(name, value.type);
            before ~= let(local, value);
            return use(local, value.span);
        }

        Expr* heldCallee = callee is null ? null : boxed(hold(*callee, "callee"));
        auto args = new Expr[written.length];
        foreach (i, ref arg; written)
        {
            if (signature.isMutable(i)) continue;
            args[i] = hold(lowerExpr(arg), "arg");
        }
        Stmt[] after;
        foreach (i, ref arg; written)
        {
            if (!signature.isMutable(i)) continue;
            Step[] steps;
            auto root = placeOf(arg, steps);
            if (steps.length == 0)
            {
                args[i] = use(root, arg.span);
                continue;
            }
            auto place = temp("place", steps[$ - 1].type, true);
            Expr read = use(root, arg.span);
            foreach (step; steps) read = field(read, step.index, step.type);
            before ~= let(place, read);
            after ~= assign(root, rebuild(use(root, arg.span), steps, use(place, arg.span)));
            args[i] = use(place, arg.span);
        }

        auto called = call(args, heldCallee);
        if (called.type == types.never)
        {
            return Expr(types.never, span, ExprKind(Block(before ~ eval(called), null)));
        }
        auto result = temp("result", called.type);
        auto whole = Expr(called.type, span, ExprKind(Block(before ~ let(result, called) ~ after, boxed(use(result, span)))));
        return coerce(whole, type);
    }

    /// `T(x)` for a number type `T`, or `String(x)`.
    private Expr lowerConversion(Expr value, Type type, Span span)
    {
        if (type == types.string_) return formatted(value);
        if (value.type == type) return value;
        return Expr(type, span, ExprKind(Convert(boxed(value))));
    }

    // Equality and formatting, which lowering writes as Core functions for anything that isn't a
    // primitive.

    /// Whether `a` and `b`, of one type, are equal.
    private Expr equality(Expr a, Expr b)
    {
        auto type = a.type;
        if (isPrimitive(type)) return prim(PrimOp.Equal, types.bool_, a, b);
        return Expr(types.bool_, a.span, ExprKind(Call(equalityFunction(type), [a, b])));
    }

    /// The function telling whether two values of `type` are equal: field by field, tag then
    /// payload, or element by element.
    private size_t equalityFunction(Type type)
    {
        if (auto existing = type in _equalities) return *existing;
        if (types.depth(type) > instanceNestingLimit) reportTypeNesting(type);
        auto slot = reserveSlot();
        _equalities[type] = slot;

        auto span = _span;
        auto a = new Local("a", type);
        auto b = new Local("b", type);
        Expr left() => use(a, span);
        Expr right() => use(b, span);
        auto no = boolLiteral(false, span);

        Expr body;
        if (types.isArray(type) || type == types.emptyArray)
        {
            auto lengthOf = (Expr array) => Expr(types.int_, span, ExprKind(Length(boxed(array))));
            Stmt[] statements = [eval(when(prim(PrimOp.NotEqual, types.bool_, lengthOf(left()), lengthOf(right())),
                returnExpr(no)))];
            if (type != types.emptyArray)
            {
                auto element = types.arrayElement(type);
                auto label = newLabel();
                auto i = temp("i", types.int_, true);
                Expr at(Expr array) => Expr(element, span, ExprKind(Index(boxed(array), boxed(use(i, span)))));
                statements ~= [
                    let(i, intLiteral(types.int_, 0, span)),
                    eval(loop(boxed(block(span, [
                        breakUnless(prim(PrimOp.Less, types.bool_, use(i, span), lengthOf(left())), label),
                        eval(when(not(equality(at(left()), at(right()))), returnExpr(no))),
                        assign(i, prim(PrimOp.Add, types.int_, use(i, span), intLiteral(types.int_, 1, span))),
                    ])), span, label)),
                ];
            }
            body = Expr(types.bool_, span, ExprKind(Block(statements, boxed(boolLiteral(true, span)))));
        }
        else if (isSum(type) || types.isOption(type))
        {
            // The arms test `a`'s tag, and the last needs no test.
            auto count = memberCount(type);
            Expr chain;
            foreach_reverse (i; 0 .. count)
            {
                auto payloads = hasPayload(type, i) ? equality(payload(left(), i), payload(right(), i)) : boolLiteral(true, span);
                auto same = Expr(types.bool_, span, ExprKind(If(boxed(isMember(right(), i)), boxed(payloads), boxed(no))));
                chain = i == count - 1 ? same
                    : Expr(types.bool_, span, ExprKind(If(boxed(isMember(left(), i)), boxed(same), boxed(chain))));
            }
            body = chain;
        }
        else
        {
            auto fields = fieldTypes(type);
            Expr[] tests;
            foreach (i, fieldType; fields)
            {
                tests ~= equality(field(left(), i, fieldType), field(right(), i, fieldType));
            }
            body = allOf(tests, span);
        }
        functions[slot] = Function("equal." ~ types.describe(type), _moduleName, [a, b], null, types.bool_, body,
            FunctionOrigin.derived);
        return slot;
    }

    /// `value` as a String, as `print` shows it.
    private Expr formatted(Expr value)
    {
        auto type = value.type;
        auto span = value.span;
        if (type == types.string_ || type == types.never) return value;
        if (type == types.unit) return Expr(types.string_, span, ExprKind(Block([eval(value)], boxed(stringLiteral("()", span)))));
        if (isPrimitive(type) || types.isFunction(type))
        {
            return Expr(types.string_, span, ExprKind(Prim(PrimOp.Format, [value])));
        }
        return Expr(types.string_, span, ExprKind(Call(formatFunction(type), [value])));
    }

    /// The function that formats a value of `type`: `Point(1, 2)`, `Red`, `(1, 2)`, `Some(1)`,
    /// `[1, 2]`, or for a sum, its member.
    private size_t formatFunction(Type type)
    {
        if (auto existing = type in _formats) return *existing;
        if (types.depth(type) > instanceNestingLimit) reportTypeNesting(type);
        auto slot = reserveSlot();
        _formats[type] = slot;

        auto span = _span;
        auto v = new Local("value", type);
        Expr value() => use(v, span);
        Expr text(string s) => stringLiteral(s, span);
        Expr concat(Expr[] parts...) => Expr(types.string_, span, ExprKind(Prim(PrimOp.Concat, parts.dup)));

        /// `open`, then each part formatted with `, ` between them, then `close`.
        Expr listed(string open, Expr[] parts, string close)
        {
            Expr[] pieces = [text(open)];
            foreach (i, part; parts)
            {
                if (i > 0) pieces ~= text(", ");
                pieces ~= formatted(part);
            }
            return concat(pieces ~ text(close));
        }

        Expr body;
        if (type == types.emptyArray)
        {
            body = text("[]");
        }
        else if (types.isArray(type))
        {
            auto element = types.arrayElement(type);
            auto s = temp("text", types.string_, true);
            auto label = newLabel();
            auto i = temp("i", types.int_, true);
            Expr appended(Expr part) => prim(PrimOp.Append, types.string_, use(s, span), part);
            auto at = Expr(element, span, ExprKind(Index(boxed(value()), boxed(use(i, span)))));
            auto lengthOf = Expr(types.int_, span, ExprKind(Length(boxed(value()))));
            body = Expr(types.string_, span, ExprKind(Block([
                let(s, text("[")),
                let(i, intLiteral(types.int_, 0, span)),
                eval(loop(boxed(block(span, [
                    breakUnless(prim(PrimOp.Less, types.bool_, use(i, span), lengthOf), label),
                    eval(when(prim(PrimOp.Greater, types.bool_, use(i, span), intLiteral(types.int_, 0, span)),
                        block(span, [assign(s, appended(text(", ")))]))),
                    assign(s, appended(formatted(at))),
                    assign(i, prim(PrimOp.Add, types.int_, use(i, span), intLiteral(types.int_, 1, span))),
                ])), span, label)),
            ], boxed(concat(use(s, span), text("]"))))));
        }
        else if (types.isOption(type))
        {
            auto some = concat(text("Some("), formatted(payload(value(), 1)), text(")"));
            body = Expr(types.string_, span, ExprKind(If(boxed(isMember(value(), 1)), boxed(some), boxed(text("None")))));
        }
        else if (isSum(type))
        {
            auto count = memberCount(type);
            Expr chain = formatted(payload(value(), count - 1));
            foreach_reverse (i; 0 .. count - 1)
            {
                chain = Expr(types.string_, span, ExprKind(If(boxed(isMember(value(), i)),
                    boxed(formatted(payload(value(), i))), boxed(chain))));
            }
            body = chain;
        }
        else if (isCellType(type))
        {
            auto contents = Expr(cellContents(type), span, ExprKind(Cell(CellOp.Get, [value()])));
            body = concat(text(typeName(type) ~ "("), formatted(contents), text(")"));
        }
        else
        {
            auto fields = fieldTypes(type);
            Expr[] parts;
            foreach (i, fieldType; fields) parts ~= field(value(), i, fieldType);
            if (types.isTuple(type))
            {
                body = listed("(", parts, ")");
            }
            else
            {
                auto name = typeName(type);
                body = parts.length == 0 ? text(name) : listed(name ~ "(", parts, ")");
            }
        }
        functions[slot] = Function("format." ~ types.describe(type), _moduleName, [v], null, types.string_, body,
            FunctionOrigin.derived);
        return slot;
    }

    // Types

    private const(TypeTable) types()
    {
        return _analysis.types;
    }

    /// Whether `type` is built in and has no structure, so comparing two is one primitive.
    private bool isPrimitive(Type type)
    {
        return types[type].match!((const Primitive _) => true, _ => false);
    }

    /// Whether `type` is a `Ref`, the one intrinsic type.
    private bool isCellType(Type type)
    {
        return types[type].match!(
            (const NominalData nominal) => _analysis.declarationOf(nominal.decl).intrinsic,
            _ => false,
        );
    }

    /// What a value of the `Ref` type `type` holds.
    private Type cellContents(Type type)
    {
        return _analysis.fieldsOf(type)[0].type;
    }

    private bool isSum(Type type)
    {
        return _analysis.membersOf(type).length > 0;
    }

    /// How many members a sum or option has.
    private size_t memberCount(Type type)
    {
        return types.isOption(type) ? 2 : _analysis.membersOf(type).length;
    }

    /// The type of member `index` of a sum or option.
    private Type memberType(Type type, size_t index)
    {
        if (types.isOption(type))
        {
            assert(index == 1, "an option's None has no payload");
            return types.optionInner(type);
        }
        return _analysis.membersOf(type)[index];
    }

    private bool hasPayload(Type type, size_t index)
    {
        return !types.isOption(type) || index == 1;
    }

    /// The types of a tuple's elements, or of a declared type's fields.
    private const(Type)[] fieldTypes(Type type)
    {
        if (types.isTuple(type)) return types.tupleElements(type);
        return types[type].match!(
            (const NominalData _) => _analysis.fieldsOf(type).map!(f => f.type).array,
            (_) => assert(0, "only a tuple or a declared type has fields"),
        );
    }

    private string typeName(Type type)
    {
        return types[type].match!(
            (const NominalData nominal) => _analysis.declarationOf(nominal.decl).name,
            (_) => types.describe(type),
        );
    }

    private FunctionData functionData(Type type)
    {
        return types[type].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "only a function value can be called"),
        );
    }

    // Helpers for building Core. The nodes lowering makes up have no AST node to ask sema about,
    // so these supply the types.

    /// `value` as a value of `type`: dropped when `type` is `Unit` and `value` has another type,
    /// as a Unit function's body is, and otherwise unchanged.
    private Expr coerce(Expr value, Type type)
    {
        if (type != types.unit || value.type == types.unit || value.type == types.never) return value;
        return Expr(types.unit, value.span, ExprKind(Block([eval(value)], null)));
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

    private Expr stringLiteral(string value, Span span)
    {
        return Expr(types.string_, span, ExprKind(StringLit(value)));
    }

    private Expr field(Expr object, size_t index, Type type)
    {
        return Expr(type, object.span, ExprKind(Field(boxed(object), index)));
    }

    private Expr inject(size_t member, Expr value, Type type)
    {
        return Expr(type, value.span, ExprKind(Inject(member, boxed(value))));
    }

    private Expr isMember(Expr subject, size_t member)
    {
        return Expr(types.bool_, subject.span, ExprKind(IsMember(boxed(subject), member)));
    }

    private Expr payload(Expr subject, size_t member)
    {
        return Expr(memberType(subject.type, member), subject.span, ExprKind(Payload(boxed(subject), member)));
    }

    private size_t newLabel()
    {
        return _nextLabel++;
    }

    private Expr breakExpr(Span span, size_t label)
    {
        return Expr(types.never, span, ExprKind(Break(label)));
    }

    private Expr continueExpr(Span span, size_t label)
    {
        return Expr(types.never, span, ExprKind(Continue(label)));
    }

    private Expr returnExpr(Expr value)
    {
        return Expr(types.never, value.span, ExprKind(Return(boxed(value))));
    }

    /// `if (condition) then else ()`, for when only one arm does anything.
    private Expr when(Expr condition, Expr then)
    {
        return Expr(types.unit, condition.span, ExprKind(If(boxed(condition), boxed(coerce(then, types.unit)),
            boxed(unit(condition.span)))));
    }

    private Expr loop(Expr* body, Span span, size_t label)
    {
        return Expr(types.unit, span, ExprKind(Loop(body, label)));
    }

    /// Leaves the loop `label` when `condition` is false.
    private Stmt breakUnless(Expr condition, size_t label)
    {
        return eval(when(not(condition), breakExpr(condition.span, label)));
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
            (Block b) => b.result is null && e.type == types.unit ? b.statements : [eval(e)],
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

@("an element assignment names its local, and a compound one evaluates the index once")
unittest
{
    auto result = loweredFunction(`
def f(mutable xs: [Int], i: UInt8): Unit {
    xs[i] = 1
    xs[i + 1] += 2
}
`, "f");
    print(result.program).should.equal(
`def f(mutable xs: [Int], i: UInt8): Unit {
    xs[i] = 1
    let index: UInt8 = Add(i, 1)
    xs[index] = Add(xs[index], 2)
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
@("a match tests each arm's member in order, and the last arm, which must match, tests nothing")
unittest
{
    auto result = loweredFunction(`
type Shape = Circle(r: Float) | Square(side: Float) | Empty

def area(s: Shape): Float => match s {
    Circle(r) => r * r
    Square(side) => side * side
    Empty => 0.0
}
`, "area");
    print(result.program).should.equal(
`def area(s: Shape): Float {
    let subject: Shape = s
    if (is#0(subject)) {
        let r: Float = payload#0(subject).0
        Multiply(r, r)
    } else if (is#1(subject)) {
        let side: Float = payload#1(subject).0
        Multiply(side, side)
    } else 0.0
}`);
}

@("a lambda becomes a function of its own whose closure carries its captures")
unittest
{
    auto result = loweredFunction(`def adder(n: Int): (Int) -> Int => x => x + n`, "adder");
    print(result.program).should.equal(
`def adder(n: Int): (Int) -> Int closure lambda(n)

def lambda(x: Int): Int Add(x, n)`);
}

@("a nested def calls itself by rebuilding its closure, so it isn't a capture of itself")
unittest
{
    auto result = loweredFunction(`
def f(): Int {
    def factorial(k: Int): Int => if k <= 1 => 1 else k * factorial(k - 1)
    factorial(3)
}
`, "f");
    print(result.program).should.equal(
`def f(): Int {
    let factorial: (Int) -> Int = closure factorial
    call factorial(3)
}

def factorial(k: Int): Int if (LessEqual(k, 1)) 1 else Multiply(k, call closure factorial(Subtract(k, 1)))`);
}

@("assigning a field rebuilds the value up the path, after the new value is evaluated, and == on a declared type is a derived function")
unittest
{
    auto result = loweredFunction(`
type Point(x: Int, y: Int)
type Line(from: Point, to: Point)

def f(): Bool {
    mutable val line = Line(Point(0, 0), Point(1, 1))
    line.to.x = 5
    val moved = line with (from.y = 2)
    moved == line
}
`, "f");
    print(result.program).should.equal(
`def f(): Bool {
    let mutable line: Line = Line(Point(0, 0), Point(1, 1))
    line = {
        let value: Int = 5
        line with .1 = line.1 with .0 = value
    }
    let moved: Line = {
        let mutable with: Line = line
        with = with with .0 = with.0 with .1 = 2
        with
    }
    equal.Line(moved, line)
}

def equal.Line(a: Line, b: Line): Bool if (equal.Point(a.0, b.0)) equal.Point(a.1, b.1) else false

def equal.Point(a: Point, b: Point): Bool if (Equal(a.0, b.0)) Equal(a.1, b.1) else false`);
}

@("postfix ? returns None from the function, and a value going into an option is wrapped")
unittest
{
    auto result = loweredFunction(`
def first(xs: [Int]): Int? => if length(xs) > 0 => xs[0] else None

def plusOne(xs: [Int]): Int? {
    val x = first(xs)?
    x + 1
}
`, "plusOne");
    print(result.program).should.equal(
`def plusOne(xs: [Int]): Int? {
    let x: Int = {
        let option: Int? = first(xs)
        if (is#1(option)) payload#1(option) else return Int?#0
    }
    Int?#1(Add(x, 1))
}

def first(xs: [Int]): Int? if (Greater(length(xs), 0)) Int?#1(xs[0]) else Int?#0`);
}

@("a block promoted to an option as a whole still runs before its None")
unittest
{
    auto result = loweredFunction(`
def f(): Int {
    val positive = (x: Int) => {
        if x > 0 { return Some(x) }
        None
    }
    positive(1) ?? 0
}
`, "f");
    print(result.program).should.equal(
`def f(): Int {
    let positive: (Int) -> Int? = closure lambda
    {
        let option: Int? = call positive(1)
        if (is#1(option)) payload#1(option) else 0
    }
}

def lambda(x: Int): Int? {
    {
        if (Greater(x, 0)) {
            return Int?#1(x)
        } else ()
        ()
    }
    Int?#0
}`);
}

@("a mutable field path is passed in a temporary that's written back, read after the other arguments")
unittest
{
    auto result = loweredFunction(`
type Rng(state: Int)
type Game(rng: Rng, score: Int)

def step(mutable rng: Rng, by: Int): Int {
    rng.state += by
    rng.state
}

def f(): Game {
    mutable val game = Game(Rng(0), 0)
    _ = step(mutable game.rng, 1)
    game
}
`, "f");
    print(result.program).should.equal(
`def f(): Game {
    let mutable game: Game = Game(Rng(0), 0)
    {
        let arg: Int = 1
        let mutable place: Rng = game.0
        let result: Int = step(place, arg)
        game = game with .0 = place
        result
    }
    game
}

def step(mutable rng: Rng, by: Int): Int {
    rng = {
        let value: Int = Add(rng.0, by)
        rng with .0 = value
    }
    rng.0
}`);
}

@("a jump in a while condition leaves the enclosing loop, though Core evaluates it inside the while's own")
unittest
{
    auto result = loweredFunction(`
def f(): Int {
    mutable val n = 0
    while n < 10 {
        n += 1
        while { if n == 3 { continue }; false } { }
    }
    n
}
`, "f");
    print(result.program).should.equal(
`def f(): Int {
    let mutable n: Int = 0
    loop {
        if (Not(Less(n, 10))) break else ()
        {
            n = Add(n, 1)
            loop {
                if (Not({
                    if (Equal(n, 3)) {
                        continue 1
                    } else ()
                    false
                })) break else ()
            }
        }
    }
    n
}`);
}

@("printing a value that isn't a primitive formats it with a derived function first")
unittest
{
    auto result = loweredFunction(`def f(xs: [Int]): () => printl(xs)`, "f");
    print(result.program).should.equal(
`def f(xs: [Int]): Unit intrinsic printl(format.[Int](xs))

def format.[Int](value: [Int]): String {
    let mutable text: String = "["
    let mutable i: Int = 0
    loop {
        if (Not(Less(i, length(value)))) break else ()
        if (Greater(i, 0)) {
            text = Append(text, ", ")
        } else ()
        text = Append(text, Format(value[i]))
        i = Add(i, 1)
    }
    Concat(text, "]")
}`);
}

@("each instance of a generic function is lowered once, with its type arguments filled in")
unittest
{
    auto result = loweredFunction(`
def identity<T>(x: T): T => x

def f(): Int {
    val a = identity(1)
    val b = identity(2)
    val s = identity("s")
    a + b
}
`, "f");
    print(result.program).should.equal(
`def f(): Int {
    let a: Int = identity<Int>(1)
    let b: Int = identity<Int>(2)
    let s: String = identity<String>("s")
    Add(a, b)
}

def identity<Int>(x: Int): Int x

def identity<String>(x: String): String x`);
}

@("each overload is a function of its own, named with its parameter types")
unittest
{
    auto result = loweredFunction(`
def show(x: Int): Int => x
def show(x: Bool): Int => 0
def show<T>(x: [T]): Int => length(x)

def f(): Int => show(1) + show(true) + show(["a"])
`, "f");
    print(result.program).should.equal(
`def f(): Int Add(Add(show(Int)(1), show(Bool)(true)), show<String>([String])(["a"]))

def show(Int)(x: Int): Int x

def show(Bool)(x: Bool): Int 0

def show<String>([String])(x: [String]): Int length(x)`);
}

@("an instance's body, lambdas and types have no type parameter left in them")
unittest
{
    auto result = loweredFunction(`
type Box<T>(value: T)

def boxAll<T>(values: [T]): [Box<T>?] {
    mutable val out: [Box<T>?] = []
    for value in values {
        val make = (v: T) => Box(v)
        out ~= [make(value)]
    }
    out
}

def f(): [Box<UInt8>?] => boxAll<UInt8>([1])
`, "f");
    auto printed = print(result.program);
    printed.canFind("T").should.equal(false);
    printed.should.equal(
`def f(): [Box<UInt8>?] boxAll<UInt8>([1])

def boxAll<UInt8>(values: [UInt8]): [Box<UInt8>?] {
    let mutable out: [Box<UInt8>?] = []
    {
        let array: [UInt8] = values
        let count: Int = length(array)
        let mutable next: Int = 0
        loop {
            if (Not(Less(next, count))) break else ()
            let value: UInt8 = array[next]
            next = Add(next, 1)
            let make: (UInt8) -> Box<UInt8> = closure lambda
            out = Append(out, [Box<UInt8>?#1(call make(value))])
        }
    }
    out
}

def lambda(v: UInt8): Box<UInt8> Box<UInt8>(v)`);
    result.program.recordFields.length.should.equal(1);
}

@("the functions lowering derives are made per instance of a generic type")
unittest
{
    auto result = loweredFunction(`
type Box<T>(value: T)

def f(): Bool => Box(1) == Box(2) && Box("a") == Box("b")
`, "f");
    auto names = result.program.functions.map!(f => f.name).array;
    names.should.equal(["f", "equal.Box<Int>", "equal.Box<String>"]);
}

@("polymorphic recursion stops at the nesting limit, showing the instances that led there")
unittest
{
    import std.exception : collectException;
    import silver.ast : DiagnosticCode, DiagnosticException;

    auto error = collectException!DiagnosticException(loweredFunction(`
def grow<T>(x: T): Unit => grow([x])

def f(): Unit => grow(1)
`, "f"));
    assert(error !is null, "expected the nesting limit");
    error.diagnostic.code.should.equal(DiagnosticCode.InstanceNestingTooDeep);
    error.diagnostic.message.canFind("f\n    -> grow<Int>\n    -> grow<[Int]>").should.equal(true);
}

@("a Ref is a cell, and update takes the contents out while its change runs")
unittest
{
    auto result = loweredFunction(`import std.ref
def f(): () {
    val r = Ref(1)
    r.update(n => n + r.get())
    printl(r)
}`, "f");
    print(result.program).should.equal(
`def f(): Unit {
    let r: Ref<Int> = cell.New(1)
    {
        let ref: Ref<Int> = r
        let change: (Int) -> Int = closure lambda(r)
        cell.Fill(ref, call change(cell.Take(ref)))
    }
    intrinsic printl(format.Ref<Int>(r))
}

def lambda(n: Int): Int Add(n, cell.Get(r))

def format.Ref<Int>(value: Ref<Int>): String Concat("Ref(", Format(cell.Get(value)), ")")`);
}
