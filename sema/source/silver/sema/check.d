module silver.sema.check;

import std.algorithm;
import std.array;
import std.conv;
import std.range : iota, repeat;
import std.sumtype;
import std.string;


import silver.ast;
import silver.sema.constant_eval;
import silver.sema.coverage;
import silver.sema.declare;
import silver.sema.recursion;
import silver.sema.type;
import silver.sema.resolve;
import silver.sema.typing;

// Type checking for Silver programs.

/// Where a body is written: the module whose functions a call there sees, and the module-level
/// function it's in, if any, whose own bounds supply functions to a conformance search too. A
/// lambda's or nested `def`'s body has the site of the body around it.
private struct Site
{
    string module_;
    Id!FunctionDecl function_;
    /// Whether that function is a test.
    bool inTest;
    /// The nested `def`s around this whose result types are being worked out, innermost first.
    Unsettled* unsettled;
}

/// A nested `def` whose result type is being worked out from its body.
private struct Unsettled
{
    Id!VarDecl self;
    /// Its result type as written.
    Span written;
    Unsettled* outer;
    /// Whether its body used it, which is reported once.
    bool usedItself;
}

/// Where the checker is inside a function body. Passed by value, so a nested body (a lambda)
/// gets its own copy and the enclosing one is untouched when it returns.
private struct BodyContext
{
    Site site;
    /// What `return` checks against: the innermost enclosing function's return type.
    Type returnType;
    /// Whether this is in the body of a loop, so `break` and `continue` have one to act on.
    bool inLoop;
    /// Collects what the body returns when `returnType` is still to be inferred, or null.
    InferredReturn* inferred;
    /// Whether this is a test's own body, where `?` stops the test instead of returning.
    bool testBody;
}

/// A search made once every body is checked, for the queries generic functions ask and what
/// answers them.
private struct Deferral
{
    /// The module-level function the search is in, whose own type parameters a goal it can't
    /// meet is asked of.
    Id!FunctionDecl owner;
    /// The function a query added now is first asked by.
    Id!FunctionDecl asker;
    /// Whether a function was given a query it didn't have.
    bool changed;
    /// The use the search is for, where an answer that's neither yes nor no is reported, when
    /// `reporting`.
    Span span;
    bool reporting;
}

/// A use of a generic function from a body, whose witnesses are found again once every body is
/// checked, with the answers to the function's queries and the functions that ask more than it.
private struct Reference
{
    Site site;
    Span span;
    Id!FunctionDecl func;
    Type[] typeArgs;
    /// What checking found for it, and once its queries are answered, what was kept.
    Witness[] witnesses;
    /// The functions it was chosen from, which may ask more than it.
    const(Id!FunctionDecl)[] siblings;
    void delegate(Witness[] witnesses, Witness[] alternatives) store;
    Witness[] alternatives;
}

/// A `for` in a generic function that steps, which loops by index where `length` and `opIndex`
/// are found for the real type.
private struct SteppedLoop
{
    Site site;
    Span span;
    Id!Expr for_;
    Type iterable;
    Type element;
}

/// A value of a type with an invariant built, or changed by a `with` the invariant checks, in a
/// function. The type is `type`, or found in what `expr` gives.
private struct InvariantUse
{
    Site site;
    Span span;
    Id!TypeDecl decl;
    Id!Expr expr;
    Type type;
}

/// What a lambda with no known return type was found to return.
private struct InferredReturn
{
    const(Expr)[] values;
    Type[] types;
    /// Each postfix `?`, which returns `None`.
    Span[] nones;
    /// What each postfix `?` on an error union passes on, and where it is.
    Type[] errors;
    Span[] errorSpans;
    /// The errors written after a result type whose success side is a floor, which everything
    /// returned is typed beside, or `Type.init`.
    Type beside;
}

/// Where working out a result type from its function's body has got to.
private enum ResultState { waiting, working, settled }

/// A type written with floors, each an interface name standing for the type a value has there.
private struct Floored
{
    Type written;
    const(TypeParam)[] floors;
    /// What has the type, to start a message with: "`f` returns", "`xs` is".
    string subject;
}


private final class TypeChecker
{
    this(const Resolution resolutions, Collector collector, NodeIds ids)
    {
        _types = new TypeTable();
        _typing.types = _types;
        _collector = collector;
        _resolutions = resolutions;
        _ids = ids;
        _declarer = new Declarer(_types, &_typing, resolutions, collector);
    }

    private TypeTable _types;
    private Collector _collector;
    /// Whether a pattern of the match being checked names a type that name resolution couldn't,
    /// which it reported before checking began.
    private bool _unresolvedPattern;
    private const Resolution _resolutions;
    /// What checking produces, built up in place.
    private Typing _typing;
    private Declarer _declarer;
    /// Every integer literal. A literal's type can change after it's first seen, as it adapts
    /// to where it's used, so ranges are checked once all the bodies have been.
    private const(Expr)[] _intLiterals;
    private bool[Id!Expr] _negatedLiterals;
    /// Constants whose initializer already has an error, which evaluating would only repeat.
    private bool[Id!ConstDecl] _unevaluable;
    /// Constructions of a type with an invariant from literals alone, which are checked once the
    /// literals' types are final.
    private const(Expr)[] _literalConstructions;
    /// The option or error union `!` or `?` is typing its operand toward, which a bare type
    /// parameter takes whole, though against any other expected type it takes what that holds.
    private Type _unwrapTarget;
    /// The functions bounds supply that an earlier bound of the same function supplies already,
    /// by the earlier one.
    private Id!FunctionDecl[Id!FunctionDecl] _repeatedBounds;
    /// How many elements `placePath` has named, so each is a place of its own.
    private size_t _elementPlaces;
    /// The types with an invariant whose `else` hasn't been typed yet, and whether it's being typed.
    private bool[Id!TypeDecl] _pendingInvariants;
    /// Each function whose result type is worked out from its body that has been started on.
    private ResultState[Id!FunctionDecl] _resultStates;
    /// Those found to need their own result type while it was being worked out.
    private bool[Id!FunctionDecl] _recursiveResults;
    /// Every use of a generic function, for `answerQueries`.
    private Reference[] _references;
    private SteppedLoop[] _steppedLoops;
    private InvariantUse[] _invariantUses;
    /// For a name chosen from several functions, the ones of its group, which may ask more.
    private const(Id!FunctionDecl)[][Id!Expr] _siblings;
    /// What's been reported about answers, so a use searched again isn't reported twice.
    private bool[string] _reportedAnswers;
    /// The functions holding invariants and their `else`s, once `askerAt` has needed them.
    private bool[Id!FunctionDecl] _invariantFunctions;
    /// For the type parameters a search makes up.
    private NodeIds _ids;

    Typing checkProgram(const Program program)
    {
        auto programModules = program.sortedModules;

        // phase 1: all declared types; phase 2: all signatures; phase 3: all bodies
        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const TypeDecl t) {
                        _typing.nominalTypes[t.id] = _types.nominal(t.id, t.name, t.typeParams.map!(p => _declarer.parameterType(p)).array);
                    },
                    (_) {},
                );
            }
        }

        // Before anything that can name one, and even if nothing does, so a bad target is reported.
        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const AliasDecl a) { _declarer.aliasType(a.id); },
                    (_) {},
                );
            }
        }

        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const FunctionDecl f) {
                        _declarer.declareSignature(f);
                    },
                    (const TypeDecl decl) {
                        _declarer.declareConstructor(decl);
                    },
                    (const ConstDecl c) {
                        declareConstant(c);
                    },
                    (const InterfaceDecl i) {
                        _declarer.declareInterface(i);
                    },
                    (const AliasDecl _) {},
                    (const ImportStmt _) {},
                );
            }
        }

        // After every interface's functions have their signatures, which a bound's functions take.
        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const FunctionDecl f) {
                        declareBounds(f);
                    },
                    (const TypeDecl t) {
                        if (!t.inheritsParams) rejectBounds(t.typeParams,
                            "A type's parameter can't have a bound yet; put the bound on the functions that need it");
                    },
                    (_) {},
                );
            }
        }

        // After every signature, since an invariant's `else` can call anything, and before any body,
        // since a body can build the type. One that another needs first is typed from there.
        noteInvariantMentions();
        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const TypeDecl t) {
                        if (t.invariantError.isValid) _pendingInvariants[t.id] = false;
                    },
                    (_) {},
                );
            }
        }
        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const TypeDecl t) {
                        if (t.id in _pendingInvariants) inferInvariantError(t);
                    },
                    (_) {},
                );
            }
        }

        foreach (mod; programModules)
        {
            checkOverloads(mod);
            checkForwardedOverloads(mod.name);
        }

        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const FunctionDecl f) {
                        checkFunction(f);
                    },
                    (const ConstDecl c) {
                        checkConstant(c, mod.name);
                    },
                    (const TypeDecl _) {},
                    (const AliasDecl _) {},
                    (const InterfaceDecl _) {},
                    (const ImportStmt _) {},
                );
            }
        }

        _declarer.checkInhabited(programModules);
        _declarer.rejectGrowingTypes(programModules);
        answerQueries();
        rejectGrowingCalls();

        foreach (literal; _intLiterals)
        {
            checkLiteralRange(literal);
        }

        // Last, because an integer literal's type isn't final until everything's been checked.
        _typing.constants = evaluateConstants(programModules, _types, _typing.exprTypes, _resolutions, _unevaluable,
            _negatedLiterals, _collector, _literalConstructions);

        return _typing;
    }

    /// The function a use at `site` asks its questions of, if any. An invariant has no caller to
    /// ask, so what it calls is chosen from what's known where it's written.
    private Id!FunctionDecl askerAt(Site site)
    {
        if (_invariantFunctions is null)
        {
            foreach (decl; _resolutions.declarations.types.byValue)
            {
                _invariantFunctions[decl.invariantFunction] = true;
                _invariantFunctions[decl.invariantError] = true;
            }
        }
        return site.function_ in _invariantFunctions ? Id!FunctionDecl.init : site.function_;
    }

    /// Works out what each generic function asks of its callers, then finds again what each use
    /// of a generic function needs, now with the answers to its queries and the functions that
    /// ask more than the one chosen.
    ///
    /// A function's queries come from its own body and from the queries of what it calls, so
    /// the uses in generic functions are searched until none gains another. Only then is
    /// everything kept, so every use of a function has the same queries' answers.
    private void answerQueries()
    {
        if (_collector.hasErrors) return;
        bool generic(Site site) => askerAt(site).isValid && isGenericFunction(askerAt(site));
        for (auto changed = true; changed;)
        {
            changed = false;
            foreach (reference; _references)
            {
                if (generic(reference.site)) changed |= findAgain(reference, false);
            }
            foreach (loop; _steppedLoops) changed |= indexLoop(loop, false);
        }
        if (_typing.queries.length == 0) return;
        foreach (ref reference; _references) findAgain(reference, true);
        foreach (loop; _steppedLoops) indexLoop(loop, true);
    }

    /// Reports each generic function that needs an instance of itself at ever larger type
    /// arguments: by calling itself or through other functions, the witnesses their uses and
    /// loops find, and the invariants of the values they build.
    private void rejectGrowingCalls()
    {
        Use!(Id!FunctionDecl)[] uses;
        void add(Id!FunctionDecl from, Id!FunctionDecl to, const(Type)[] args, Span span)
        {
            // What's already an error has been reported.
            if (!to.isValid || args.length == 0 || args.any!(a => _types.mentionsError(a))) return;
            uses ~= Use!(Id!FunctionDecl)(from, to, args, span);
        }
        void addWitnesses(Id!FunctionDecl from, const(Witness)[] witnesses, Span span)
        {
            foreach (w; witnesses)
            {
                add(from, w.func, w.typeArgs, span);
                addWitnesses(from, w.witnesses, span);
                addWitnesses(from, w.alternatives, span);
            }
        }
        bool generic(Id!FunctionDecl f) => f.isValid && isGenericFunction(f);
        foreach (reference; _references)
        {
            auto from = reference.site.function_;
            if (!generic(from)) continue;
            add(from, reference.func, reference.typeArgs, reference.span);
            addWitnesses(from, reference.witnesses, reference.span);
            addWitnesses(from, reference.alternatives, reference.span);
        }
        foreach (loop; _steppedLoops)
        {
            if (!generic(loop.site.function_)) continue;
            if (auto functions = loop.for_ in _typing.loops) addWitnesses(loop.site.function_, functions.indexedIf, loop.span);
        }
        // An invariant's functions have the type's parameters, and each value built needs them at its own.
        foreach (use; _invariantUses)
        {
            if (!generic(use.site.function_)) continue;
            auto decl = _resolutions.declarations.types[use.decl];
            auto type = use.expr.isValid ? _typing.exprTypes.get(use.expr, _types.error) : use.type;
            auto args = argumentsOf(type, *decl);
            if (args is null) continue;
            add(use.site.function_, decl.invariantFunction, args, use.span);
            if (decl.invariantError.isValid) add(use.site.function_, decl.invariantError, args, use.span);
        }

        const(TypeParam)[] paramsOf(Id!FunctionDecl f) => _resolutions.typeParamsOf(f);
        string name(Id!FunctionDecl f) => _resolutions.declarations.functions[f].name;
        for (auto cycle = growingCycle(uses, &paramsOf, _types); cycle !is null; cycle = growingCycle(uses, &paramsOf, _types))
        {
            _collector.reportError(DiagnosticCode.PolymorphicRecursion, cycle[0].span,
                "`%s` can't be instantiated, as it would need endlessly many instances, each needing a larger one: %-(%s, then %), and so on"
                    .format(name(cycle[0].from), instancesAround(cycle, &paramsOf, _types, &describeInstance)));
            uses = uses.filter!(u => !cycle.canFind!(c => c.from == u.from)).array;
        }
    }

    /// Notes that a generic function may build a value of a type with an invariant, for
    /// `rejectGrowingCalls`.
    private void noteInvariantUse(InvariantUse use)
    {
        if (!_resolutions.declarations.types[use.decl].invariantFunction.isValid || !isGenericFunction(use.site.function_)) return;
        use.site.unsettled = null;
        _invariantUses ~= use;
    }

    /// The type arguments of the instance of `decl` that `type` builds, for the type parameters of
    /// its invariant's functions, or null if there's none. `type` is the instance, what a
    /// construction gives, or a constructor's function type, so only the success side of what it
    /// returns is the instance: a parameter can hold others. A member a sum declares inline is
    /// built as the sum, and has the sum's parameters it mentions.
    private const(Type)[] argumentsOf(Type type, const TypeDecl decl)
    {
        type = _types[type].match!((const FunctionData f) => f.ret, _ => type);
        type = _types[type].match!((const ErrorUnionData u) => u.success, _ => type);
        auto owner = _declarer.ownerOf(decl.id);
        auto sought = owner !is null && decl.inheritsParams ? _types[*owner].match!((const NominalData n) => n.decl, _ => decl.id)
            : decl.id;
        auto found = _types[type].match!((const NominalData n) => n.decl == sought ? n.args : null, _ => null);
        if (found is null || sought == decl.id) return found;
        auto sumParams = _resolutions.declarations.types[sought].typeParams;
        const(Type)[] args;
        foreach (param; decl.typeParams)
        {
            auto at = sumParams.countUntil!(p => p.id == param.id);
            if (at < 0 || at >= found.length) return null;
            args ~= found[at];
        }
        return args;
    }

    /// `first<Int>`; for an invariant, `the invariant of W<Int>`; and a parameter whose type is
    /// an interface name is shown by what it's given, as in `primes with r a Skipped<R>`.
    private string describeInstance(Id!FunctionDecl f, const(Type)[] args)
    {
        auto func = _resolutions.declarations.functions[f];
        auto declared = func.typeParams.length;
        auto shown = args[0 .. declared].map!(a => _types.describe(a)).array;
        if (func.invariantOf.isValid)
        {
            auto type = "%s%s".format(_resolutions.declarations.types[func.invariantOf].name,
                shown.length > 0 ? "<%-(%s, %)>".format(shown) : "");
            return func.invariantErrorOf.isValid ? "the `else` of `%s`'s invariant".format(type) : "the invariant of `%s`".format(type);
        }
        auto text = "`%s%s`".format(func.name, shown.length > 0 ? "<%-(%s, %)>".format(shown) : "");
        string[] given;
        foreach (k, param; _resolutions.hiddenParams.get(f, null))
        {
            auto arg = args[declared + k];
            if (_types[arg].match!((const TypeParamData p) => p.param == param.id, _ => false)) continue;
            auto written = func.params.find!(p => _resolutions.sugarParams.get(p.type.id, Id!TypeParam.init) == param.id);
            if (written.empty) continue;
            given ~= "`%s` %s".format(written.front.name, withArticle(_types.describe(arg)));
        }
        return given.length > 0 ? "%s with %-(%s and %)".format(text, given) : text;
    }

    /// Searches for `reference`'s witnesses and alternatives again, keeping them when `keep`.
    /// Whether a function was given a query.
    private bool findAgain(ref Reference reference, bool keep)
    {
        auto defer = Deferral(askerAt(reference.site), askerAt(reference.site), false, reference.span, keep);
        auto params = _resolutions.typeParamsOf(reference.func);
        Substitution bound;
        foreach (i, param; params) bound[param.id] = reference.typeArgs[i];
        auto found = conformanceOf(reference.func, bound, reference.site, null, &defer);
        auto witnesses = found.holds ? found.witnesses : reference.witnesses;

        Witness[] rungs;
        auto signature = signatureOf(reference.func);
        foreach (sibling; reference.siblings)
        {
            if (sibling == reference.func || !asksForMore(sibling, reference.func)) continue;
            settleResult(sibling);
            auto theirs = signatureOf(sibling);
            auto theirParams = _resolutions.typeParamsOf(sibling);
            Substitution binding;
            foreach (i, param; theirs.params) bindParams(param, _types.substitute(signature.params[i], bound), theirParams, binding);
            // A function that turns out not to stand in for this one asks nothing of the caller.
            auto owner = askerAt(reference.site);
            auto asked = owner.isValid ? _typing.queries.get(owner, null).length : 0;
            auto changed = defer.changed;
            void rejected()
            {
                if (owner.isValid && owner in _typing.queries) _typing.queries[owner].length = asked;
                if (asked == 0) _typing.queries.remove(owner);
                defer.changed = changed;
            }
            auto fits = conformanceOf(sibling, binding, reference.site, null, &defer);
            if (!fits.holds)
            {
                if (fits.ambiguous || fits.tooDeep) reportRung(sibling, fits, &defer);
                rejected();
                continue;
            }
            if (theirParams.any!(p => p.id !in binding)
                || _types.substitute(theirs.ret, binding) != _types.substitute(signature.ret, bound))
            {
                rejected();
                continue;
            }
            rungs ~= Witness(sibling, theirParams.map!(p => binding[p.id]).array, fits.witnesses);
        }
        rungs.sort!((a, b) => asksForMore(a.func, b.func));
        if (keep)
        {
            reference.store(witnesses, rungs);
            reference.witnesses = witnesses;
            reference.alternatives = rungs;
        }
        return defer.changed;
    }

    /// Reports a function that asks more than the one a call chose, whose bounds the search
    /// couldn't answer either way.
    private void reportRung(Id!FunctionDecl rung, const Conformance fits, const Deferral* defer)
    {
        if (!defer.reporting) return;
        auto message = "`%s` %s".format(overloadLabel(rung), fits.failure);
        auto key = "%s:%s:%s".format(defer.span.start, defer.span.end, message);
        if (key in _reportedAnswers) return;
        _reportedAnswers[key] = true;
        _collector.reportError(fits.tooDeep ? DiagnosticCode.BoundSearchTooDeep : DiagnosticCode.AmbiguousQuery, defer.span, message);
    }

    /// Looks for the `length` and `opIndex` a stepping `loop` would use to loop by index, keeping
    /// them when `keep`. Whether a function was given a query.
    private bool indexLoop(SteppedLoop loop, bool keep)
    {
        auto defer = Deferral(askerAt(loop.site), askerAt(loop.site), false, loop.span, keep);
        auto requests = [
            Request("length", _types.function_([loop.iterable], _types.int_)),
            Request("opIndex", _types.function_([loop.iterable, _types.int_], loop.element)),
        ];
        Substitution none;
        auto found = satisfy(Goal(Id!InterfaceDecl.init, loop.iterable, null), null, none, loop.site, null, &defer, requests);
        if (keep && found.holds) _typing.loops[loop.for_].indexedIf = found.witnesses;
        return defer.changed;
    }

    /// Notes a use of the generic `func` from `site`, for `answerQueries`.
    private void noteUse(Site site, Span span, Id!FunctionDecl func, Type[] typeArgs, const(Witness)[] witnesses,
        const(Id!FunctionDecl)[] siblings, void delegate(Witness[], Witness[]) store)
    {
        if (!func.isValid || !isGenericFunction(func)) return;
        site.unsettled = null;
        _references ~= Reference(site, span, func, typeArgs, cast(Witness[]) witnesses, siblings, store);
    }

    /// Notes a use of a generic function by the name `g` is written with.
    private void noteNamed(Site site, const Generic g, const(Witness)[] witnesses)
    {
        auto name = g.name;
        noteUse(site, g.span, g.func, _typing.typeArguments[name], witnesses, _siblings.get(name, null), (w, a) {
            if (w.length > 0) _typing.witnesses[name] = w;
            if (a.length > 0) _typing.alternatives[name] = a;
        });
    }

    /// Notes a function that syntax uses, as `noteUse` does; `place` says where it's kept.
    private void noteSyntaxUse(Site site, Span span, const SyntaxUse use, FunctionUse* delegate() place)
    {
        noteUse(site, span, use.use.func, cast(Type[]) use.use.typeArgs, use.use.witnesses, use.siblings, (w, a) {
            auto kept = place();
            kept.witnesses = w;
            kept.alternatives = a;
        });
    }

    /// The functions of `candidates`' group that holds `chosen`.
    private static const(Id!FunctionDecl)[] siblingsOf(const Candidates candidates, Id!FunctionDecl chosen)
    {
        foreach (group; candidates.groups)
        {
            if (group.canFind(chosen)) return group;
        }
        return null;
    }

    private void declareConstant(const ConstDecl constant)
    {
        auto type = constant.type is null ? _types.error : _declarer.resolveType(*constant.type);
        // Name resolution reports any other type, so uses shouldn't report it again.
        _typing.symbolTypes[SymbolId(constant.id)] = isConstantType(type) ? type : _types.error;
    }

    private bool isConstantType(Type type)
    {
        return _types[type].match!(
            (const Primitive p) => p.kind != Primitive.Kind.Any && p.kind != Primitive.Kind.Never,
            _ => false,
        );
    }

    /// What the bounds of `func`'s type parameters name, and the functions they supply inside it.
    private void declareBounds(const FunctionDecl func)
    {
        if (func.kind != FunctionKind.ordinary)
        {
            rejectBounds(func.typeParams, "An intrinsic's type parameter can't have a bound");
            return;
        }
        _declarer.declareBounds(_resolutions.typeParamsOf(func.id));
        _declarer.declareBounds(_resolutions.resultFloors.get(func.id, null));
        _declarer.declareBoundFunctions(func.id);
        // Two bounds that declare the same function supply one function.
        Id!FunctionDecl[] distinct;
        foreach (supplied; _resolutions.boundFunctions.get(func.id, null))
        {
            auto same = distinct.find!(d => _resolutions.declarations.functions[d].name == _resolutions.declarations.functions[supplied].name
                && _typing.symbolTypes[SymbolId(d)] == _typing.symbolTypes[SymbolId(supplied)]);
            if (same.empty) distinct ~= supplied;
            else _repeatedBounds[supplied] = same.front;
        }
    }

    private void rejectBounds(const(TypeParam)[] params, string message)
    {
        foreach (param; params)
        {
            if (param.bounds.length > 0) _collector.reportError(DiagnosticCode.InvalidBound, param.bounds[0].span, message);
        }
    }

    /// `candidates` without the functions a bound supplies that another bound supplies already.
    private const(Candidates) distinct(const Candidates candidates)
    {
        if (_repeatedBounds.length == 0 || !candidates.groups.joiner.any!(f => (f in _repeatedBounds) !is null)) return candidates;
        Candidates kept;
        foreach (group; candidates.groups) kept.groups ~= group.filter!(f => f !in _repeatedBounds).array.dup;
        kept.sources = candidates.sources.dup;
        return kept;
    }

    private void checkConstant(const ConstDecl constant, string moduleName)
    {
        auto type = _typing.symbolTypes[SymbolId(constant.id)];
        auto reported = _collector.diagnostics.length;
        if (type != _types.error && requireConstantExpr(constant.value))
        {
            // A constant expression can't contain a `return`, so nothing reads the return type.
            check(constant.value, type, BodyContext(Site(moduleName), _types.error));
        }
        if (type == _types.error || _collector.diagnostics.length > reported)
        {
            _unevaluable[constant.id] = true;
        }
    }

    /// Reports the first part of `expr` that a constant can't be built from, if there is one.
    private bool requireConstantExpr(const Expr expr)
    {
        return expr.kind.match!(
            (const BoolLiteral _) => true,
            (const IntLiteral _) => true,
            (const FloatLiteral _) => true,
            (const StringLiteral _) => true,
            (const CharLiteral _) => true,
            (const InterpolatedString interpolated) => interpolated.parts.all!(p => requireConstantExpr(p)),
            (const UnitLiteral _) => true,
            (const UnaryExpr unary) => requireConstantExpr(*unary.operand),
            (const BinaryExpr binary) => requireConstantExpr(*binary.left) && requireConstantExpr(*binary.right),
            (const Identifier _) => requireConstantName(expr),
            (const MemberAccess _) => requireConstantName(expr),
            (_) => reportNonConstant(expr),
        );
    }

    private bool requireConstantName(const Expr name)
    {
        if (auto symbol = name.id in _resolutions.resolutions)
        {
            return (*symbol).match!(
                (const Id!ConstDecl _) => true,
                // Name resolution reports a module used as a value.
                (const Id!Module _) => true,
                (_) => reportNonConstant(name),
            );
        }
        // Name resolution reports an unknown name, but a member of a value is left to types.
        return isModulePath(name) || reportNonConstant(name);
    }

    private bool reportNonConstant(const Expr expr)
    {
        _collector.reportError(DiagnosticCode.NonConstantInitializer, expr.span,
            "A top-level constant can only be built from literals, operators and other constants");
        return false;
    }

    private void checkLiteralRange(const Expr expr)
    {
        auto literal = expr.kind.match!(
            (const IntLiteral l) => l,
            (_) => assert(0, "only integer literals are recorded"),
        );
        if (literal.tooLarge)
        {
            _collector.reportError(DiagnosticCode.LiteralOutOfRange, expr.span,
                "This integer literal doesn't fit in 64 bits");
            return;
        }
        auto type = _typing.exprTypes[expr.id];
        if (!_types.isInteger(type)) return;

        auto info = _types.integerOf(type);
        auto negated = (expr.id in _negatedLiterals) !is null;
        if (negated && !info.signed)
        {
            _collector.reportError(DiagnosticCode.LiteralOutOfRange, expr.span,
                "`%s` can't hold a negative value".format(_types.describe(type)));
        }
        else if (literal.value > (negated ? info.minMagnitude : info.maxValue))
        {
            _collector.reportError(DiagnosticCode.LiteralOutOfRange, expr.span,
                "`%s%s` doesn't fit in `%s`".format(negated ? "-" : "", literal.value, _types.describe(type)));
        }
    }

    private void checkFunction(const FunctionDecl func)
    {
        if (func.id in _resolutions.resultFloors) return settleResult(func.id);
        auto returnType = _types[_typing.symbolTypes[SymbolId(func.id)]].match!(
            (const FunctionData fd)=>fd.ret,
            (_)=>_types.error
            );
        // An invariant's `else` was checked when its type was inferred.
        if (func.body is null || func.invariantErrorOf.isValid) return;
        checkBody(*func.body, returnType, siteOf(func.id), func.testName !is null);
    }

    /// Works out the result type of `f` from its body, checking the body, when it's written with
    /// floors and that hasn't been done. Whatever needs the result of a function it has chosen asks
    /// for this first, so the order functions are checked in doesn't matter. A function reached
    /// again while it's being worked out depends on itself: it's reported and its result is an
    /// error from then on. Without `required`, one being worked out is left as it is, for a
    /// candidate that may not be the one used.
    private void settleResult(Id!FunctionDecl f, bool required = true)
    {
        auto floors = f in _resolutions.resultFloors;
        if (floors is null) return;
        auto func = _resolutions.declarations.functions[f];
        auto signature = signatureOf(f);
        final switch (_resultStates.get(f, ResultState.waiting))
        {
            case ResultState.settled:
                return;
            case ResultState.working:
                if (!required || f in _recursiveResults) return;
                _recursiveResults[f] = true;
                _collector.reportError(DiagnosticCode.RecursiveResultType, func.returnType.span,
                    ("The type `%s` returns is worked out from its body, which uses `%s` before that's known; "
                        ~ "write the type it returns in place of `%s`").format(func.name, func.name, printTypeExpr(func.returnType)));
                _typing.symbolTypes[SymbolId(f)] = _types.function_(signature.params, _types.error, signature.mutables);
                return;
            case ResultState.waiting:
                break;
        }
        _resultStates[f] = ResultState.working;
        auto result = inferReturn(*func.body, siteOf(f), false,
            Floored(signature.ret, *floors, "`%s` returns".format(func.name)));
        if (f in _recursiveResults) result = _types.error;
        _typing.symbolTypes[SymbolId(f)] = _types.function_(signature.params, result, signature.mutables);
        _resultStates[f] = ResultState.settled;
        // Resolution has reported one that's written.
        auto written = privateTypeIn(signature.ret) !is null || (*floors).any!(floor => _typing.bounds.get(floor.id, null)
            .any!(bound => bound.args.any!(a => privateTypeIn(a) !is null)));
        auto hidden = func.isPrivate || written ? null : privateTypeIn(result);
        if (hidden !is null)
        {
            _collector.reportError(DiagnosticCode.PrivateTypeExposed, func.returnType.span,
                ("`%s` is private, so it can't appear in a public function's signature, and `%s` returns `%s`; "
                    ~ "make `%s` private or `%s` public").format(hidden, func.name, _types.describe(result), func.name, hidden));
        }
    }

    /// The name of a private declared type that `type` is or holds, or null.
    private string privateTypeIn(Type type)
    {
        string first(const(Type)[] types)
        {
            foreach (t; types)
            {
                if (auto found = privateTypeIn(t)) return found;
            }
            return null;
        }
        return _types[type].match!(
            (const NominalData n) {
                auto decl = _resolutions.declarations.types[n.decl];
                return decl.isPrivate ? decl.name : first(n.args);
            },
            (const OptionData o) => privateTypeIn(o.inner),
            (const ErrorUnionData u) => first([u.success, u.error]),
            (const ErrorListData l) => first(l.members),
            (const ArrayData a) => privateTypeIn(a.element),
            (const FunctionData f) => first(f.params ~ f.ret),
            (const TupleData t) => first(t.elements),
            _ => null,
        );
    }

    /// The type `floored.written` stands for once each of its floors is the type that `actual`,
    /// the type of the value at `span`, has there, or `error` after reporting a floor that
    /// `actual` doesn't give a type or gives one that doesn't satisfy its interfaces. A floor
    /// before another may say what the other is, as `Range<Range<Int>>` does.
    private Type settleFloors(const Floored floored, Type actual, Site site, Span span, const(Expr)[] values)
    {
        if (actual == _types.error || _types.mentionsError(floored.written)) return _types.error;
        if (_types.isFailure(actual)) return _declarer.requireTyped(actual, span);
        auto untyped = actual == _types.none || actual == _types.emptyArray;
        Substitution found;
        bindParams(floored.written, actual, floored.floors, found);
        foreach (floor; floored.floors)
        {
            auto type = floor.id in found;
            if (type is null || untyped)
            {
                auto whole = floored.floors.length == 1 && _types.isParameter(floored.written)
                    ? "" : " in `%s`".format(_types.describe(floored.written));
                _collector.reportError(DiagnosticCode.TypeMismatch, span, actual == _types.never
                    ? "%s nothing, so nothing says what type `%s` stands for; write the type out".format(floored.subject, floor.name)
                    : "%s `%s`, which doesn't say what type `%s` stands for%s%s".format(floored.subject,
                        _types.describe(actual), floor.name, whole, untyped ? "; write the type out"
                            : literalHint(values, [floored.written])));
                return _types.error;
            }
            foreach (declared; _typing.bounds.get(floor.id, null))
            {
                if (!declared.valid) continue;
                auto goal = Goal(declared.decl, *type, declared.args.map!(a => _types.substitute(a, found)).array);
                if (_types.mentionsError(goal.self) || goal.args.any!(a => _types.mentionsError(a))) continue;
                auto conformance = satisfy(goal, floored.floors, found, site, null);
                if (conformance.holds) continue;
                auto wanted = Bound(goal.decl, goal.args.map!(a => _types.substitute(a, found)).array);
                auto whole = *type == actual ? "" : " in `%s`".format(_types.describe(actual));
                _collector.reportError(conformance.tooDeep ? DiagnosticCode.BoundSearchTooDeep : DiagnosticCode.UnsatisfiedBound,
                    floor.span, "%s `%s`%s, which isn't %s: %s%s".format(floored.subject, _types.describe(*type), whole,
                        withArticle(_declarer.describe(wanted)), conformance.failure is null
                            ? "more than one function could say what its type arguments are" : conformance.failure,
                        literalHint(values, wanted.args)));
                return _types.error;
            }
        }
        auto settled = _types.substitute(floored.written, found);
        if (!isAssignable(actual, settled))
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, span, "%s `%s`, where `%s` is written%s".format(floored.subject,
                _types.describe(actual), _types.describe(floored.written), literalHint(values, [floored.written])));
            return _types.error;
        }
        return settled;
    }

    /// What an error about `values` beside a floor adds when a literal in them could be why:
    /// nothing is passed down beside a floor, so a literal there has its default type, whatever
    /// number the types in `wanted` ask for.
    private string literalHint(const(Expr)[] values, const(Type)[] wanted)
    {
        bool adapts(const Expr value) => isIntLiteral(value) || value.kind.match!(
            (const ArrayLiteral literal) => literal.elements.any!(e => adapts(e)),
            (const TupleLiteral literal) => literal.elements.any!(e => adapts(e)),
            (const SomeExpr some) => adapts(*some.value),
            (const BlockExpr block) => block.value !is null && adapts(*block.value),
            _ => false,
        );
        bool otherNumber(Type type) => (isNumeric(type) && type != _types.int_) || _types[type].match!(
            (const NominalData n) => n.args.any!(a => otherNumber(a)),
            (const OptionData o) => otherNumber(o.inner),
            (const ErrorUnionData u) => otherNumber(u.success),
            (const ArrayData a) => otherNumber(a.element),
            (const TupleData t) => t.elements.any!(e => otherNumber(e)),
            _ => false,
        );
        return values.any!(v => adapts(v)) && wanted.any!(t => otherNumber(t))
            ? "\n    a literal beside an interface name has its default type, so an integer literal is an `Int` here; "
                ~ "write it as the type that's meant, as in `1.0` or `Float(1)`"
            : "";
    }

    private static string withArticle(string name)
    {
        return ("AEIOU".canFind(name[0]) ? "an `" : "a `") ~ name ~ "`";
    }

    /// Declares what the bounds of `floors` name, once.
    private void declareFloors(const(TypeParam)[] floors)
    {
        if (floors.length > 0 && floors[0].id !in _typing.bounds) _declarer.declareBounds(floors);
    }

    /// Where the body of the module-level function `func` looks for conformances.
    private Site siteOf(Id!FunctionDecl func)
    {
        return Site(_resolutions.declarations.functionModules[func], func,
            _resolutions.declarations.functions[func].testName !is null);
    }

    /// The fields each invariant's condition names: those of its function's parameters that
    /// something resolves to, since only the condition can see them.
    private void noteInvariantMentions()
    {
        bool[SymbolId] resolved;
        foreach (symbol; _resolutions.resolutions.byValue) resolved[symbol] = true;
        foreach (type; _resolutions.declarations.types.byValue)
        {
            if (!type.invariantFunction.isValid) continue;
            auto condition = _resolutions.declarations.functions[type.invariantFunction];
            _typing.invariantMentions[type.id] = condition.params.filter!(p => (SymbolId(p.id) in resolved) !is null)
                .map!(p => p.name.idup).array;
        }
    }

    /// What `type`'s invariant gives when it doesn't hold, from its `else`, and its constructor
    /// as a function returning an error union of that.
    private void inferInvariantError(const TypeDecl type)
    {
        auto func = _resolutions.declarations.functions[type.invariantError];
        auto params = signatureOf(func.id).params;
        _pendingInvariants[type.id] = true;
        auto error = inferReturn(*func.body, siteOf(func.id));
        _pendingInvariants.remove(type.id);
        if (error == _types.never)
        {
            _collector.reportError(DiagnosticCode.InvalidErrorType, func.body.span,
                "An invariant's `else` has to give the error, not stop the program");
            error = _types.error;
        }
        _typing.symbolTypes[SymbolId(func.id)] = _types.function_(params, error);

        // The function has type parameters of its own, in the type's order.
        Substitution toType;
        foreach (i, param; func.typeParams) toType[param.id] = _declarer.parameterType(type.typeParams[i]);
        auto own = _types.substitute(error, toType);
        _typing.invariantErrors[type.id] = own;
        auto constructor = SymbolId(type.id);
        _typing.symbolTypes[constructor] = _types[_typing.symbolTypes[constructor]].match!(
            (const FunctionData f) => _types.function_(f.params, own == _types.error ? own : _types.errorUnion(f.ret, own)),
            (_) => _typing.symbolTypes[constructor],
        );
    }

    /// Whether what the invariant of `decl` gives is known, typing its `else` first when nothing
    /// has yet. It isn't, and that's reported at `span`, when that `else` is what's being typed
    /// and has got here, so it needs its own type. `site` is where `span` is.
    private bool requireInvariant(Id!TypeDecl decl, Span span, Site site)
    {
        auto working = decl in _pendingInvariants;
        if (working is null) return true;
        if (!*working)
        {
            inferInvariantError(*_resolutions.declarations.types[decl]);
            return true;
        }
        auto name = _resolutions.declarations.types[decl].name;
        // The `else` got here through a function whose body it wouldn't need if its result were written.
        if (site.function_ in _resolutions.resultFloors && _resultStates.get(site.function_, ResultState.waiting) == ResultState.working)
        {
            auto through = _resolutions.declarations.functions[site.function_];
            _collector.reportError(DiagnosticCode.NotSupportedYet, span,
                ("This needs what building %s can give, which is worked out from the `else` of `%s`'s invariant, and that "
                    ~ "`else` leads to `%s`, whose result type is worked out from this body; write the type `%s` returns in "
                    ~ "place of `%s`, so the `else` doesn't need its body")
                    .format(withArticle(name), name, through.name, through.name, printTypeExpr(through.returnType)));
            return false;
        }
        _collector.reportError(DiagnosticCode.NotSupportedYet, span,
            ("What building %s can give is worked out from the `else` of its invariant, which needs this before "
                ~ "that's known; an `else` can't lead back to its own type")
                .format(withArticle(name)));
        return false;
    }

    /// Whether the invariant of `type`, a declared type, names its field `field`.
    private bool invariantMentions(Type type, string field)
    {
        auto decl = declOf(type);
        if (!decl.isValid) return false;
        auto mentioned = decl in _typing.invariantMentions;
        return mentioned !is null && (*mentioned).canFind(field);
    }

    /// What the invariant of the declared type `type` gives when it doesn't hold, or `Type.init`
    /// when it has none.
    private Type invariantErrorOf(Type type)
    {
        auto decl = declOf(type);
        if (!decl.isValid) return Type.init;
        auto error = decl in _typing.invariantErrors;
        return error is null ? Type.init : _types.substitute(*error, _declarer.substitutionOf(type));
    }

    /// The function type of `lambda`, checking its body. `expected` supplies what it leaves out.
    /// `optional` says the return it's expected to have is an option whose type isn't known yet, so
    /// an inferred return that isn't one is promoted to one.
    private Type typeLambda(const Expr expr, const Lambda lambda, const(FunctionData)* expected, Site site, bool optional = false)
    {
        auto wrongCount = expected !is null && expected.params.length != lambda.params.length;
        if (wrongCount)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
                "This lambda has %s parameters, where %s are expected".format(lambda.params.length, expected.params.length));
            expected = null;
        }

        Type[] params;
        bool[] mutables;
        foreach (i, param; lambda.params)
        {
            auto type = _types.error;
            if (param.annotated)
            {
                type = _declarer.resolveType(param.type);
            }
            else if (expected !is null)
            {
                type = expected.params[i];
            }
            else if (!wrongCount)
            {
                _collector.reportError(DiagnosticCode.UntypedLambdaParameter, param.nameSpan,
                    "Nothing here says what type `%s` is; write `%s: Type`".format(param.name, param.name));
            }
            _typing.symbolTypes[SymbolId(param.id)] = type;
            params ~= type;
            mutables ~= param.mutable;
        }

        Type ret = lambda.returnType !is null ? _declarer.resolveType(*lambda.returnType)
            : expected !is null ? expected.ret : Type.init;
        if (auto floors = expr.id in _resolutions.lambdaFloors)
        {
            declareFloors(*floors);
            auto self = Unsettled(lambda.self, lambda.returnType.span, site.unsettled);
            auto inside = site;
            if (lambda.self.isValid) inside.unsettled = &self;
            ret = inferReturn(*lambda.body, inside, false, Floored(ret, *floors, "This function returns"));
            if (self.usedItself) ret = _types.error;
        }
        else if (ret == Type.init)
        {
            ret = inferReturn(*lambda.body, site, optional);
        }
        else
        {
            if (lambda.self.isValid) _typing.symbolTypes[SymbolId(lambda.self)] = _types.function_(params, ret, mutables);
            checkBody(*lambda.body, ret, site);
        }

        auto failed = wrongCount || ret == _types.error || params.canFind(_types.error);
        auto type = failed ? _types.error : _types.function_(params, ret, mutables);
        _typing.exprTypes[expr.id] = type;
        return type;
    }

    /// The common type of everything `body` can return, each promoted to it as needed. With
    /// `optional`, that type is an option, so a body that returns `(a, b)` returns `(a, b)?`.
    /// With `floored`, it's the type written there, with its floors as what the body returns.
    private Type inferReturn(const Expr body, Site site, bool optional = false, const Floored floored = Floored.init)
    {
        InferredReturn inferred;
        if (isFallible(floored)) inferred.beside = _types.errorOf(floored.written);
        auto bodyType = synthesizeBeside(body, inferred.beside, BodyContext(site, _types.error, false, &inferred));
        inferred.values ~= body;
        inferred.types ~= bodyType;
        if (floored.floors.length > 0 && _types.isErrorUnion(floored.written)) return settleFallible(floored, inferred, site, body.span);

        auto joined = _types.never;
        foreach (i, type; inferred.types)
        {
            joined = join(joined, type, inferred.values[i].span, "Return values");
        }
        foreach (span; inferred.nones)
        {
            joined = join(joined, _types.none, span, "Return values");
        }
        if (inferred.errors.length > 0 && joined != _types.error)
        {
            if (floored.floors.length > 0)
            {
                auto passed = _types.describe(inferred.errors[0]);
                _collector.reportError(DiagnosticCode.InvalidPropagation, inferred.errorSpans[0],
                    ("This `?` passes on `%s`, so the function returns an error union; write the errors after the "
                        ~ "result type, as in `%s ! %s`").format(passed, _types.describe(floored.written), passed));
                return _types.error;
            }
            joined = withPassedErrors(joined, inferred, body.span);
        }
        if (floored.floors.length > 0) joined = settleFloors(floored, joined, site, body.span, inferred.values);
        else
        {
            joined = _declarer.requireTyped(joined, body.span);
            if (optional && joined != _types.error && joined != _types.never && !_types.isOption(joined))
            {
                joined = _declarer.optionOf(joined, body.span);
            }
        }
        if (joined == _types.error) return joined;

        foreach (i, type; inferred.types)
        {
            if (type != _types.never && type != joined) coerce(inferred.values[i], type, joined);
        }
        return joined;
    }

    /// Whether `floored` is an error union with floors on its success side, whose errors are passed
    /// down to what gives it its type.
    private bool isFallible(const Floored floored)
    {
        return floored.floors.length > 0 && _types.isErrorUnion(floored.written) && !_types.mentionsError(floored.written);
    }

    /// What a body returns whose result type is written `floored.written`, an error union with
    /// floors on its success side. Its values were typed beside the errors as written, which is
    /// where what its `?`s pass on has to fit too.
    private Type settleFallible(const Floored floored, const InferredReturn inferred, Site site, Span span)
    {
        if (!isFallible(floored)) return _types.error;
        auto declared = _types.errorOf(floored.written);
        auto failed = false;
        foreach (i, error; inferred.errors)
        {
            if (errorFits(error, declared)) continue;
            _collector.reportError(DiagnosticCode.InvalidPropagation, inferred.errorSpans[i],
                "`?` passes on `%s`, which this function's errors, `%s`, don't include"
                    .format(_types.describe(error), _types.describe(declared)));
            failed = true;
        }
        foreach (none; inferred.nones)
        {
            _collector.reportError(DiagnosticCode.InvalidPropagation, none,
                "`?` would return `None`, but this function returns `%s`, so it needs a reason; write `?? { return Error(...) }`"
                    .format(_types.describe(floored.written)));
            failed = true;
        }
        auto result = settleBeside(floored, inferred.types, inferred.values, site, span, "only errors");
        return failed ? _types.error : result;
    }

    /// The error union written `floored.written` once the floors on its success side are settled
    /// from `values`, whose `types` came from `synthesizeBeside` with its errors. `failures` is
    /// what the subject is said to give when none of them is a value.
    private Type settleBeside(const Floored floored, const(Type)[] types, const(Expr)[] values, Site site, Span span,
        string failures)
    {
        auto success = _types.never;
        foreach (i, type; types)
        {
            auto part = _types.isFailure(type) ? _types.never : _types.isErrorUnion(type) ? _types.successOf(type) : type;
            success = join(success, part, values[i].span, "Return values");
        }
        if (success == _types.error) return success;
        if (success == _types.never && types.any!(t => _types.isFailure(t)))
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, span,
                "%s %s, so nothing gives the type `%s` stands for; write the type out"
                    .format(floored.subject, failures, floored.floors[0].name));
            return _types.error;
        }
        auto settled = settleFloors(Floored(_types.successOf(floored.written), floored.floors, floored.subject), success,
            site, span, values);
        if (settled == _types.error) return settled;

        auto result = _types.errorUnion(settled, _types.errorOf(floored.written));
        foreach (i, type; types)
        {
            if (type != _types.never && type != result) coerce(values[i], type, result);
        }
        return result;
    }

    /// The type of `expr` where an error union is expected whose errors are `errors` and whose
    /// success side is whatever `expr` gives: an `Ok` or `Error` takes those errors, and so does a
    /// value that can be some of them, through branches and a block's value. With no `errors`,
    /// nothing is expected.
    private Type synthesizeBeside(const Expr expr, Type errors, BodyContext ctx)
    {
        if (errors == Type.init) return synthesize(expr, ctx);
        auto written = expr.kind.match!(
            (const OkExpr ok) {
                auto value = _declarer.requireTyped(synthesize(*ok.value, ctx), ok.value.span);
                return value == _types.error ? value : _types.errorUnion(value, errors);
            },
            (const ErrorExpr error) {
                auto reported = _collector.diagnostics.length;
                check(*error.value, errors, ctx);
                return _collector.diagnostics.length > reported ? _types.error : _types.failure(errors);
            },
            (const IfExpr if_) => if_.falseBody is null ? Type.init : synthesizeIf(if_, expr.span, ctx, errors),
            (const BlockExpr block) => synthesizeBlock(block, expr.span, ctx, errors),
            (const MatchExpr match_) => match_.origin == MatchOrigin.IfVal ? Type.init
                : synthesizeMatch(match_, expr.span, ctx, errors),
            _ => Type.init,
        );
        if (written != Type.init)
        {
            _typing.exprTypes[expr.id] = written;
            return written;
        }

        auto type = synthesize(expr, ctx);
        if (!_types.isErrorUnion(type) || _types.errorOf(type) == errors) return type;
        if (!errorFits(_types.errorOf(type), errors))
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
                "This can be the error `%s`, which the errors written here, `%s`, don't include"
                    .format(_types.describe(_types.errorOf(type)), _types.describe(errors)));
            return _types.error;
        }
        return coerce(expr, type, _types.errorUnion(_types.successOf(type), errors));
    }

    /// The error union a lambda returns when its `?`s pass on errors and its values join to
    /// `joined`. One error has to take in the others, since a list is never invented.
    private Type withPassedErrors(Type joined, const InferredReturn inferred, Span span)
    {
        if (inferred.nones.length > 0)
        {
            _collector.reportError(DiagnosticCode.InvalidPropagation, inferred.nones[0],
                "This `?` returns `None`, where another one here passes on an error; write the lambda's return type");
            return _types.error;
        }
        auto success = joined;
        Type reason = inferred.errors[0];
        Span at = inferred.errorSpans[0];
        if (_types.isErrorUnion(joined) || _types.isFailure(joined))
        {
            success = _types.isErrorUnion(joined) ? _types.successOf(joined) : _types.never;
            reason = _types.errorOf(joined);
            at = span;
        }
        foreach (i, error; inferred.errors)
        {
            if (errorFits(error, reason)) continue;
            if (!errorFits(reason, error))
            {
                _collector.reportError(DiagnosticCode.InvalidPropagation, inferred.errorSpans[i],
                    "This `?` passes on `%s`, and %s `%s`; write the lambda's return type, as in `(...): %s ! %s | %s => ...`"
                        .format(_types.describe(error), at == span ? "its value is" : "another passes on", _types.describe(reason),
                            _types.describe(success == _types.never ? _types.unit : success), _types.describe(reason), _types.describe(error)));
                return _types.error;
            }
            reason = error;
        }
        if (success == _types.never)
        {
            _collector.reportError(DiagnosticCode.UntypedErrorUnion, span,
                "Nothing this lambda returns says what its value is; write its return type");
            return _types.error;
        }
        return _types.errorUnion(_declarer.requireTyped(success, span), reason);
    }

    /// Checks a function or lambda body in a fresh context, against its return type.
    private void checkBody(const Expr body, Type returnType, Site site, bool testBody = false)
    {
        auto ctx = BodyContext(site, returnType);
        ctx.testBody = testBody;
        if (returnType == _types.unit)
        {
            checkDiscarded(body, ctx);
        }
        else
        {
            check(body, returnType, ctx);
        }
    }

    /// Checks an expression whose value lands where Unit is expected, so any type will do and
    /// the value is dropped: a Unit function's body, a `while` body, an `if` without an `else`.
    /// That reaches through blocks and `if` arms, so `if c => 1 else "a"` needs no common type.
    private Type checkDiscarded(const Expr expr, BodyContext ctx)
    {
        Type dropped(Type type) => type == _types.never ? type : _types.unit;

        auto type = expr.kind.match!(
            (const BlockExpr block) {
                foreach (stmt; block.statements)
                {
                    checkStmt(stmt, ctx);
                }
                return block.value is null ? valuelessBlockType(block) : dropped(checkDiscarded(*block.value, ctx));
            },
            (const IfExpr if_) {
                if (if_.falseBody is null) return synthesizeIf(if_, expr.span, ctx);
                checkIfHead(if_, ctx);
                auto thenType = checkDiscarded(*if_.trueBody, ctx);
                auto elseType = checkDiscarded(*if_.falseBody, ctx);
                return thenType == _types.never && elseType == _types.never ? _types.never : _types.unit;
            },
            (const MatchExpr match_) => checkDiscardedMatch(match_, expr.span, ctx),
            (_) {
                auto type = synthesize(expr, ctx);
                if (_types.isErrorUnion(type)) reportUnhandled(expr.span, type);
                return type;
            },
        );
        _typing.exprTypes[expr.id] = type;
        return type;
    }

    /// An error union dropped where its value isn't used, which would lose the error.
    private void reportUnhandled(Span span, Type type)
    {
        _collector.reportError(DiagnosticCode.UnusedValue, span,
            "This `%s` could be an error, which would be lost here; pass it on with `?`, assert that it worked with `!`, or drop it with `_ = ...`"
                .format(_types.describe(type)));
    }

    private void checkStmt(const Stmt stmt, BodyContext ctx)
    {
        stmt.kind.match!(
            (const VarDecl var) => checkBinding(var, var.value, ctx),
            (const PatternDecl decl) => checkPattern(decl.pattern, decl.value, ctx),
            (const AssignStmt assign) {
                if (assign.target.kind.match!((const TupleLiteral _) => true, _ => false))
                {
                    checkTupleAssign(assign.target, assign.value, ctx);
                    return;
                }
                checkAssign(assign, ctx);
            },
            // Only a block's last expression is its value, so anything else here was dropped by
            // mistake, as with `val y = x` and `-1` from a `- 1` that started a line.
            (const ExprStmt expr) {
                auto type = synthesize(expr.expr, ctx);
                if (_types.isErrorUnion(type))
                {
                    reportUnhandled(expr.expr.span, type);
                }
                else if (type != _types.unit && type != _types.never && type != _types.error)
                {
                    _collector.reportError(DiagnosticCode.UnusedValue, expr.expr.span,
                        "This value of type `%s` is unused; bind it with `val`, or drop it with `_ = ...`"
                            .format(_types.describe(type)));
                }
            },
            // A nested `def` lowers to a VarDecl, and name resolution reports a nested native or intrinsic.
            (const FunctionDecl _) {},
            (const ReturnStmt ret) {
                if (ctx.inferred is null)
                {
                    check(ret.value, ctx.returnType, ctx);
                    return;
                }
                auto type = synthesizeBeside(ret.value, ctx.inferred.beside, ctx);
                ctx.inferred.values ~= ret.value;
                ctx.inferred.types ~= type;
            },
            (const BreakStmt _) => requireLoop("break", stmt.span, ctx),
            (const ContinueStmt _) => requireLoop("continue", stmt.span, ctx),
        );
    }

    /// `val binding = value`, or a binding in a pattern given its part of a tuple literal.
    private void checkBinding(const VarDecl binding, const Expr value, BodyContext ctx)
    {
        if (auto floors = binding.id in _resolutions.bindingFloors)
        {
            declareFloors(*floors);
            auto floored = Floored(_declarer.resolveType(*binding.type), *floors, "`%s` is".format(binding.name));
            auto settled = _types.error;
            if (isFallible(floored))
            {
                auto type = synthesizeBeside(value, _types.errorOf(floored.written), ctx);
                settled = settleBeside(floored, [type], [value], ctx.site, value.span, "only an error");
            }
            else
            {
                auto type = synthesize(value, ctx);
                settled = settleFloors(floored, type, ctx.site, value.span, [value]);
                if (settled != _types.error && settled != type) coerce(value, type, settled);
            }
            _typing.symbolTypes[SymbolId(binding.id)] = settled;
        }
        else if (binding.type is null)
        {
            // A discard keeps no value, so a `None` or `[]` needs no type to be dropped.
            auto type = synthesize(value, ctx);
            _typing.symbolTypes[SymbolId(binding.id)] = binding.name == discardName ? type : _declarer.requireTyped(type, value.span);
        }
        else
        {
            auto type = _declarer.resolveType(*binding.type);
            check(value, type, ctx);
            _typing.symbolTypes[SymbolId(binding.id)] = type;
        }
    }

    /// `val pattern = value`. A tuple literal of the pattern's size is taken apart element by
    /// element, each as its own `val`. Any other value is checked against the pattern's type when
    /// every binding has one, so literals in it still adapt, and synthesized otherwise.
    private void checkPattern(const Pattern pattern, const Expr value, BodyContext ctx)
    {
        if (auto literal = elementwise(pattern, value))
        {
            auto parts = pattern.kind.match!(
                (const TuplePattern tuple) => tuple.elements,
                (_) => assert(0, "only a tuple pattern goes element by element"),
            );
            Type[] types;
            foreach (i, element; literal.elements)
            {
                checkPattern(parts[i], element, ctx);
                types ~= _typing.promotions.get(element.id, _typing.exprTypes.get(element.id, _types.error));
            }
            // Never built, so only recorded for completeness; a dropped `None` leaves it untyped.
            _typing.exprTypes[value.id] = types.canFind(_types.none) || types.canFind(_types.emptyArray)
                ? _types.error : _declarer.tupleOf(types);
            return;
        }

        pattern.kind.match!(
            (const VarDecl binding) => checkBinding(binding, value, ctx),
            (const TuplePattern _) {
                auto expected = annotatedType(pattern);
                if (expected == Type.init)
                {
                    bindPattern(pattern, _declarer.requireTyped(synthesize(value, ctx), value.span));
                }
                else
                {
                    check(value, expected, ctx);
                    bindPattern(pattern, expected);
                }
            },
            (_) { assert(0, "the grammar only allows names and tuples in a `val`"); },
        );
    }

    /// The type of what `pattern` takes apart, or `Type.init` if a binding in it has no annotation.
    /// Each annotated binding is given its type on the way.
    private Type annotatedType(const Pattern pattern)
    {
        return pattern.kind.match!(
            (const VarDecl binding) {
                if (binding.type is null) return Type.init;
                auto type = _declarer.resolveType(*binding.type);
                _typing.symbolTypes[SymbolId(binding.id)] = type;
                return type;
            },
            (const TuplePattern tuple) {
                // Every element, so each annotation is resolved once whatever comes after it.
                auto types = tuple.elements.map!(e => annotatedType(e)).array;
                return types.canFind(Type.init) ? Type.init : _declarer.tupleOf(types);
            },
            (_) => assert(0, "the grammar only allows names and tuples in a `val`"),
        );
    }

    /// Gives each binding in `pattern` its part of a `type` value. An annotated binding already has
    /// its type, which the part has to be exactly, since a value doesn't convert.
    private void bindPattern(const Pattern pattern, Type type)
    {
        auto unknown = type == _types.error || type == _types.never;
        pattern.kind.match!(
            (const VarDecl binding) {
                if (binding.type is null)
                {
                    _typing.symbolTypes[SymbolId(binding.id)] = type;
                    return;
                }
                auto annotated = _typing.symbolTypes[SymbolId(binding.id)];
                if (type != annotated && !unknown && annotated != _types.error)
                {
                    _collector.reportError(DiagnosticCode.TypeMismatch, binding.type.span,
                        "This part of the value is `%s`, which doesn't convert to `%s`"
                            .format(_types.describe(type), _types.describe(annotated)));
                }
            },
            (const TuplePattern tuple) {
                auto count = tuple.elements.length;
                const(Type)[] parts;
                if (_types.isTuple(type) && _types.tupleElements(type).length == count)
                {
                    parts = _types.tupleElements(type);
                }
                else
                {
                    if (!unknown)
                    {
                        _collector.reportError(DiagnosticCode.PatternMismatch, pattern.span, _types.isTuple(type)
                            ? "This pattern takes apart %s values, but `%s` has %s"
                                .format(count, _types.describe(type), _types.tupleElements(type).length)
                            : "This pattern takes apart a tuple, but the value is `%s`".format(_types.describe(type)));
                    }
                    parts = (type == _types.never ? _types.never : _types.error).repeat(count).array;
                }
                foreach (i, element; tuple.elements)
                {
                    bindPattern(element, parts[i]);
                }
            },
            (_) { assert(0, "the grammar only allows names and tuples in a `val`"); },
        );
    }

    private void requireLoop(string keyword, Span span, BodyContext ctx)
    {
        if (ctx.inLoop) return;
        _collector.reportError(DiagnosticCode.JumpOutsideLoop, span,
            "`%s` needs to be in the body of a loop".format(keyword));
    }

    /// Reports `target` unless it's a mutable binding or a chain of fields rooted at one, or, when
    /// assigned to, of fields and elements. `use` is what's being done to it, for the message:
    /// "assigned to", or "passed as `mutable`".
    private bool checkAssignable(const Expr target, string use = "assigned to")
    {
        return target.kind.match!(
            (const Identifier _) => checkBindingMutable(target, use),
            (const MemberAccess access) {
                // The outermost invariant first, so the `with` the message suggests is allowed.
                if (!checkAssignable(*access.object, use)) return false;
                auto object = access.object.id in _typing.exprTypes;
                if (object !is null && invariantMentions(*object, access.member))
                {
                    auto name = spelledPlace(*access.object);
                    _collector.reportError(DiagnosticCode.InvariantFieldChanged, target.span,
                        "`%s` is in the invariant of `%s`, so it changes only through `with`, as in `%s = (%s with (%s = ...))?`"
                            .format(access.member, _types.describe(*object), name, name, access.member));
                    return false;
                }
                return true;
            },
            (const IndexExpr index) {
                if (use == "assigned to" && asRange(index.index) is null) return checkAssignable(*index.object, use);
                _collector.reportError(DiagnosticCode.InvalidAssignmentTarget, target.span, use == "assigned to"
                    ? "A slice can't be assigned to; assign its elements, as `xs[i] = v`"
                    : "An element can't be %s; pass the whole value, or copy the element into a `mutable val`".format(use));
                return false;
            },
            (_) => reportInvalidAssignment(target, use),
        );
    }

    private bool checkBindingMutable(const Expr name, string use)
    {
        auto symbol = name.id in _resolutions.resolutions;
        // A package prefix like `std` in `std.math.pow = f` has no resolution of its own.
        if (symbol is null) return reportInvalidAssignment(name, use);
        return (*symbol).match!(
            (const Id!VarDecl local) {
                auto decl = _resolutions.declarations.locals[local];
                if (decl.mutable) return true;
                _collector.reportError(DiagnosticCode.AssignToImmutable, name.span,
                    "`%s` is not mutable and cannot be %s; declare it with `mutable val`".format(decl.name, use));
                return false;
            },
            (const Id!Param param) {
                auto decl = _resolutions.declarations.params[param];
                if (decl.mutable) return true;
                _collector.reportError(DiagnosticCode.AssignToImmutable, name.span,
                    "`%s` is a parameter, which is not mutable and cannot be %s; declare it `mutable %s`"
                        .format(decl.name, use, decl.name));
                return false;
            },
            (_) => reportInvalidAssignment(name, use),
        );
    }

    private bool reportInvalidAssignment(const Expr target, string use)
    {
        _collector.reportError(DiagnosticCode.InvalidAssignmentTarget, target.span, use == "assigned to"
            ? "Only a `mutable val`, a `mutable` parameter, or a field or element of one, can be assigned to"
            : "Only a `mutable val`, a `mutable` parameter or one of their fields can be %s".format(use));
        return false;
    }

    /// `target = value`, where the target is a place. An element of anything but an array is
    /// written with `opIndexAssign`, and so is each such element the place is inside, from the
    /// inside out, so `grid[y][x] = v` is `grid = opIndexAssign(grid, y, opIndexAssign(grid[y], x, v))`.
    private void checkAssign(const AssignStmt assign, BodyContext ctx)
    {
        auto target = assign.target;
        auto type = targetType(target, ctx);
        auto assignable = type != _types.error && checkAssignable(target);
        auto written = true;
        if (type == Type.init) written = writeIndexed(target, &assign.value, Type.init, false, ctx);
        else check(assign.value, type, ctx);
        if (assignable && written) writeAround(target, ctx);
        if (assign.compound && written) checkCompoundIndices(target, assign.value);
    }

    /// The type a value assigned to `target` has to have, with what's read on the way synthesized,
    /// or `Type.init` when `target` is an element of something other than an array, whose
    /// `opIndexAssign` is chosen once the value is known.
    private Type targetType(const Expr target, BodyContext ctx)
    {
        auto index = target.kind.match!((ref const IndexExpr i) => &i, _ => null);
        if (index is null || asRange(index.index) !is null) return synthesize(target, ctx);
        auto objectType = _declarer.requireTyped(synthesize(*index.object, ctx), index.object.span);
        _typing.exprTypes[index.object.id] = objectType;
        Type type;
        if (objectType == _types.error || objectType == _types.never)
        {
            checkArgument(*index.index, _types.error, ctx);
            type = _types.error;
        }
        else if (_types.isArray(objectType))
        {
            checkIndex(*index.index, ctx);
            type = _types.arrayElement(objectType);
        }
        else
        {
            return Type.init;
        }
        _typing.exprTypes[target.id] = type;
        return type;
    }

    /// Writes an element of something other than an array, the `target` of `x[i] = v`, which means
    /// `x = opIndexAssign(x, i, v)`. `v` is `value`, or else a value of type `type` with no
    /// expression, which has to be exactly the type `opIndexAssign` takes; so does an index that
    /// was already synthesized, when `indexRead`, since it was read with that type. Whether it
    /// could be written.
    private bool writeIndexed(const Expr target, const(Expr)* value, Type type, bool indexRead, BodyContext ctx)
    {
        auto index = target.kind.match!((ref const IndexExpr i) => &i, (_) => null);
        auto objectType = _typing.exprTypes.get(index.object.id, _types.error);
        auto given = placeholder(target.span);
        auto indexType = indexRead ? argumentType(*index.index) : Type.init;
        const(Expr)[] args = [given, indexRead ? given : *index.index, value is null ? given : *value];
        Type[] typed = [objectType, indexType, value is null ? type : Type.init];
        auto write = syntaxFunction(target, target.span, "opIndexAssign", "`x[i] = v`", args, typed, ctx);
        if (!write.found)
        {
            _typing.exprTypes[target.id] = _types.error;
            return false;
        }
        auto params = write.signature.params;
        string problem;
        if (params[0] != objectType || write.signature.ret != objectType)
        {
            problem = "`x[i] = v` assigns what `opIndexAssign` returns back to `x`, so it has to take and return `%s`, but `%s` doesn't"
                .format(_types.describe(objectType), describeUse("opIndexAssign", write));
        }
        else if (indexRead && params[1] != indexType)
        {
            problem = "`%s` reads with an index of type `%s`, and writes back with `%s`, which takes `%s`"
                .format(_types.describe(objectType), _types.describe(indexType),
                    describeUse("opIndexAssign", write), _types.describe(params[1]));
        }
        else if (value is null && params[2] != type)
        {
            problem = "`%s` writes back a `%s`, but `%s` takes `%s`".format(_types.describe(objectType),
                _types.describe(type), describeUse("opIndexAssign", write), _types.describe(params[2]));
        }
        if (problem !is null)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, target.span, problem);
            _typing.exprTypes[target.id] = _types.error;
            return false;
        }
        _typing.indexing.require(target.id).write = write.use;
        auto written = target.id;
        noteSyntaxUse(ctx.site, target.span, write, () => &_typing.indexing[written].write);
        _typing.exprTypes[target.id] = params[2];
        return true;
    }

    /// After a write to `place`, the writes back into each element of something other than an array
    /// that holds it, each of which was read on the way.
    private void writeAround(const Expr place, BodyContext ctx)
    {
        place.kind.match!(
            (const MemberAccess access) => writeBack(*access.object, ctx),
            (const IndexExpr index) => writeBack(*index.object, ctx),
            (_) {},
        );
    }

    private void writeBack(const Expr place, BodyContext ctx)
    {
        auto index = place.kind.match!((ref const IndexExpr i) => &i, _ => null);
        if (index !is null && !_types.isArray(_typing.exprTypes.get(index.object.id, _types.error)))
        {
            auto type = _typing.exprTypes.get(place.id, _types.error);
            if (type == _types.error || !writeIndexed(place, null, type, true, ctx)) return;
        }
        writeAround(place, ctx);
    }

    /// `x[i] += v` reads `x[i]` and writes it with `i` evaluated once, so the read has to take each
    /// index as the type the write does. `value` is the operation, which reads the target again.
    private void checkCompoundIndices(const Expr target, const Expr value)
    {
        auto read = value.kind.match!((const BinaryExpr b) => b.left, _ => null);
        if (read is null) return;
        void compare(const Expr written, const Expr reread)
        {
            auto field = written.kind.match!((const MemberAccess m) => m.object, _ => null);
            if (field !is null)
            {
                compare(*field, *reread.kind.match!((const MemberAccess m) => m.object, _ => null));
                return;
            }
            auto pair = written.kind.match!((ref const IndexExpr i) => &i, _ => null);
            if (pair is null) return;
            auto other = reread.kind.match!((ref const IndexExpr i) => &i, _ => null);
            compare(*pair.object, *other.object);
            auto from = argumentType(*other.index);
            auto to = argumentType(*pair.index);
            if (from == to || _types.mentionsError(from) || _types.mentionsError(to) || asRange(pair.index) !is null) return;
            _collector.reportError(DiagnosticCode.TypeMismatch, pair.index.span,
                "This index is evaluated once, for the read and the write, but the read takes it as `%s` and the write as `%s`"
                    .format(_types.describe(from), _types.describe(to)));
        }
        compare(target, *read);
    }

    /// The type an argument is passed as, after any promotion.
    private Type argumentType(const Expr arg)
    {
        if (auto promoted = arg.id in _typing.promotions) return *promoted;
        return _typing.exprTypes.get(arg.id, _types.error);
    }

    /// The place `target` names as its binding and then field names, for telling whether two
    /// writes overlap. Each element is a place of its own, since indices aren't known. Only called
    /// on a target `checkAssignable` accepted.
    private string[] placePath(const Expr target)
    {
        return target.kind.match!(
            (const Identifier _) => [_resolutions.resolutions[target.id].to!string],
            (const MemberAccess access) => placePath(*access.object) ~ access.member,
            (const IndexExpr index) => placePath(*index.object) ~ "[%s]".format(_elementPlaces++),
            (_) => assert(0, "only names, fields and elements are places"),
        );
    }

    /// A place as it's written, with an index shown as `[...]`.
    private string spelledPlace(const Expr place)
    {
        return place.kind.match!(
            (const Identifier name) => name.name,
            (const MemberAccess access) => spelledPlace(*access.object) ~ "." ~ access.member,
            (const IndexExpr index) => spelledPlace(*index.object) ~ "[...]",
            _ => "...",
        );
    }

    /// Reports each of `paths` that is, or is inside or around, one before it.
    private void reportOverlaps(const(string[])[] paths, const(Span)[] spans, string message)
    {
        foreach (i, path; paths)
        {
            foreach (earlier; paths[0 .. i])
            {
                auto shorter = min(path.length, earlier.length);
                if (path[0 .. shorter] != earlier[0 .. shorter]) continue;
                _collector.reportError(DiagnosticCode.OverlappingWrites, spans[i], message);
                break;
            }
        }
    }

    /// `(a, xs[i], _) = value`. Each target is checked as it would be on its own. A tuple literal's
    /// elements are checked against their targets, so they adapt; any other value's parts have to
    /// be exactly their targets' types, since a value doesn't convert. Targets can't overlap,
    /// except two elements of one array, whose indices aren't known.
    private void checkTupleAssign(const Expr target, const Expr value, BodyContext ctx)
    {
        Type[Id!Expr] placeTypes;
        const(string[])[] paths;
        Span[] spans;
        bool assignable = true;
        const(Expr)[] places;

        bool isDiscard(const Expr e) => e.kind.match!((const Identifier name) => name.name == discardName, _ => false);
        const(Expr)[] partsOf(const Expr e) => e.kind.match!((const TupleLiteral t) => t.elements, _ => null);

        void prepare(const Expr t)
        {
            if (auto parts = partsOf(t))
            {
                foreach (part; parts) prepare(part);
                return;
            }
            if (isDiscard(t)) return;
            auto type = targetType(t, ctx);
            placeTypes[t.id] = type;
            if (type == _types.error || !checkAssignable(t))
            {
                assignable = false;
                return;
            }
            places ~= t;
            paths ~= placePath(t);
            spans ~= t.span;
        }
        prepare(target);
        if (assignable)
        {
            reportOverlaps(paths, spans, "This overlaps a target before it, and one assignment can't change a place twice");
        }

        // A value that isn't a literal: each place takes its part, which has to be exactly its type.
        void takeParts(const Expr t, Type type)
        {
            if (type == _types.error || type == _types.never || isDiscard(t)) return;
            auto parts = partsOf(t);
            if (parts is null)
            {
                auto expected = placeTypes[t.id];
                if (expected == Type.init)
                {
                    writeIndexed(t, null, type, false, ctx);
                    return;
                }
                if (expected != _types.error && type != expected)
                {
                    _collector.reportError(DiagnosticCode.TypeMismatch, t.span,
                        "This part of the value is `%s`, which doesn't convert to `%s`"
                            .format(_types.describe(type), _types.describe(expected)));
                }
                return;
            }
            if (!_types.isTuple(type) || _types.tupleElements(type).length != parts.length)
            {
                _collector.reportError(DiagnosticCode.PatternMismatch, t.span, _types.isTuple(type)
                    ? "These are %s targets, but `%s` has %s values"
                        .format(parts.length, _types.describe(type), _types.tupleElements(type).length)
                    : "These targets take apart a tuple, but the value is `%s`".format(_types.describe(type)));
                return;
            }
            foreach (i, part; parts) takeParts(part, _types.tupleElements(type)[i]);
        }

        void assign(const Expr t, const Expr v)
        {
            auto parts = partsOf(t);
            auto literal = v.kind.match!((const TupleLiteral l) => l.elements, _ => null);
            if (parts !is null && literal.length == parts.length)
            {
                Type[] types;
                foreach (i, part; parts)
                {
                    assign(part, literal[i]);
                    types ~= _typing.promotions.get(literal[i].id, _typing.exprTypes.get(literal[i].id, _types.error));
                }
                // Never built, as with a `val` pattern's literal.
                _typing.exprTypes[v.id] = types.canFind(_types.none) || types.canFind(_types.emptyArray)
                    ? _types.error : _declarer.tupleOf(types);
                return;
            }
            if (parts !is null)
            {
                takeParts(t, synthesize(v, ctx));
                return;
            }
            if (isDiscard(t))
            {
                synthesize(v, ctx);
                return;
            }
            if (placeTypes[t.id] == Type.init) writeIndexed(t, &v, Type.init, false, ctx);
            else check(v, placeTypes[t.id], ctx);
        }
        assign(target, value);
        if (!assignable) return;
        foreach (place; places)
        {
            if (_typing.exprTypes.get(place.id, _types.error) != _types.error) writeAround(place, ctx);
        }
    }

    /// The declaration `expr` builds a value of, or an invalid ID if it doesn't: a constructor call,
    /// or the name of a marker.
    private Id!TypeDecl constructedDecl(const Expr expr)
    {
        if (auto type = expr.id in _resolutions.constructions) return *type;
        auto symbol = expr.id in _resolutions.resolutions;
        if (symbol is null) return Id!TypeDecl.init;
        return (*symbol).match!(
            (const Id!TypeDecl type) {
                Id!TypeDecl marker;
                if (_resolutions.declarations.types[type].fields.length == 0) marker = type;
                return marker;
            },
            _ => Id!TypeDecl.init,
        );
    }

    /// The type of `expr`, where nothing asks for a particular one. A constructor of a member its
    /// sum owns produces the sum.
    private Type synthesize(const Expr expr, BodyContext ctx)
    {
        auto type = synthesizeExact(expr, ctx);
        // A use of a generic one has already decided what it builds.
        if (type == _types.error || genericUse(expr).found) return type;
        auto sum = _declarer.ownerOf(constructedDecl(expr));
        if (sum is null) return type;

        _typing.constructedMembers[expr.id] = type;
        // A member with an invariant yields the sum or its error.
        auto result = _types.isErrorUnion(type) ? _types.errorUnion(*sum, _types.errorOf(type)) : *sum;
        _typing.exprTypes[expr.id] = result;
        return result;
    }

    /// `expected`, when there is one, is only for inferring the type arguments of a generic use.
    private Type synthesizeExact(const Expr expr, BodyContext ctx, Type expected = Type.init)
    {
        // "what type is this?"
        _typing.constructedMembers.remove(expr.id);

        auto type = expr.kind.match!(
            (const BoolLiteral _) => _types.bool_,
            (const IntLiteral _) {
                _intLiterals ~= expr;
                return _types.int_;
            },
            (const FloatLiteral _) => _types.float_,
            (const StringLiteral _) => _types.string_,
            (const CharLiteral _) => _types.char_,
            (const InterpolatedString interpolated) => synthesizeInterpolated(interpolated, ctx),
            (const UnaryExpr unary) => synthesizeUnary(unary, expr.span, ctx),
            (const BinaryExpr binary) => binary.op == BinaryOp.Concat || binary.op == BinaryOp.Append
                ? synthesizeConcat(expr, binary, ctx)
                : synthesizeBinary(binary, expr.span, ctx),
            (const CallExpr call) => expr.id in _resolutions.conversions
                ? synthesizeConversion(call, _declarer.builtinType(_resolutions.conversions[expr.id]), expr.span, ctx)
                : placeExpect(expr, isMethodCall(expr.id, *call.callee)
                    ? synthesizeMethodCall(expr, call, ctx, expected)
                    : synthesizeCall(expr, call, ctx, expected), ctx.site),
            (const MemberAccess member) => synthesizeMemberAccess(expr, member, ctx, expected),
            (const WithExpr with_) => synthesizeWith(expr, with_, ctx),
            (const WhileExpr while_) => synthesizeWhile(while_, expr.span, ctx),
            (const ForExpr for_) => synthesizeFor(expr, for_, ctx),
            (const IfExpr if_) => synthesizeIf(if_, expr.span, ctx),
            (const BlockExpr block) => synthesizeBlock(block, expr.span, ctx),
            (const UnitLiteral _) => _types.unit,
            (const Identifier _) => synthesizeIdentifier(expr, expected, ctx.site),
            (const SomeExpr some) => _declarer.optionOf(synthesize(*some.value, ctx), some.value.span),
            (const NoneLiteral _) => _types.none,
            (const PropagateExpr propagate) => synthesizePropagate(propagate, expr.span, ctx, expected),
            (const OkExpr ok) {
                synthesize(*ok.value, ctx);
                return _declarer.reportUntypedErrorUnion("Ok", expr.span);
            },
            (const ErrorExpr error) {
                auto reason = _declarer.requireTyped(synthesize(*error.value, ctx), error.value.span);
                return reason == _types.error ? reason : _types.failure(reason);
            },
            (const AssertExpr assertion) => synthesizeAssert(assertion, ctx, expected),
            (const SafeMemberAccess access) => synthesizeSafeMember(expr, access, ctx),
            (const ArrayLiteral literal) => synthesizeArrayLiteral(literal, ctx),
            (const MapLiteral literal) => synthesizeMapLiteral(literal, expr.span, ctx),
            (const IndexExpr index) => synthesizeIndex(expr, index, ctx),
            (const RangeExpr range) => synthesizeBareRange(range, expr.span, ctx),
            (const TupleLiteral literal) => _declarer.tupleOf(literal.elements.map!(e => _declarer.requireTyped(synthesize(e, ctx), e.span)).array),
            (const MatchExpr match_) => synthesizeMatch(match_, expr.span, ctx),
            (const Lambda lambda) => typeLambda(expr, lambda, null, ctx.site),
        );
        _typing.exprTypes[expr.id] = type;
        return type;
    }

    private Type synthesizeArrayLiteral(const ArrayLiteral literal, BodyContext ctx)
    {
        if (literal.elements.length == 0) return _types.emptyArray;

        auto types = literal.elements.map!(e => synthesize(e, ctx)).array;
        auto joined = types[0];
        foreach (i, type; types[1 .. $])
        {
            joined = join(joined, type, literal.elements[i + 1].span, "Array elements");
        }
        joined = _declarer.requireTyped(joined, literal.elements[0].span);
        if (joined == _types.error) return joined;

        foreach (i, element; literal.elements)
        {
            coerce(element, types[i], joined);
        }
        return _declarer.arrayOf(joined, literal.elements[0].span);
    }

    private Type synthesizeMapLiteral(const MapLiteral literal, Span span, BodyContext ctx)
    {
        foreach (i, key; literal.keys)
        {
            synthesize(key, ctx);
            synthesize(literal.values[i], ctx);
        }
        _collector.reportError(DiagnosticCode.NotSupportedYet, span, "Maps aren't supported yet");
        return _types.error;
    }

    /// `x[i]`, or `x[a..b]`, whose range is part of the slice rather than a value. An array's are
    /// built in; anything else's call `opIndex` or `opSlice`.
    private Type synthesizeIndex(const Expr expr, const IndexExpr index, BodyContext ctx)
    {
        auto objectType = _declarer.requireTyped(synthesize(*index.object, ctx), index.object.span);
        auto range = asRange(index.index);
        if (range !is null) _typing.exprTypes[index.index.id] = objectType;
        if (objectType == _types.error || objectType == _types.never)
        {
            if (range is null) checkArgument(*index.index, _types.error, ctx);
            if (range !is null && range.start !is null) checkArgument(*range.start, _types.error, ctx);
            if (range !is null && range.end !is null) checkArgument(*range.end, _types.error, ctx);
            return _types.error;
        }
        if (_types.isArray(objectType))
        {
            if (range is null)
            {
                checkIndex(*index.index, ctx);
                return _types.arrayElement(objectType);
            }
            if (range.start !is null) checkIndex(*range.start, ctx);
            if (range.end !is null) checkIndex(*range.end, ctx);
            return objectType;
        }
        if (range !is null) return sliceIndexed(expr, index, *range, objectType, ctx);
        auto read = syntaxFunction(expr, expr.span, "opIndex", "`x[i]`", [*index.object, *index.index], [objectType, Type.init], ctx);
        if (!read.found) return _types.error;
        _typing.indexing.require(expr.id).read = read.use;
        auto readOf = expr.id;
        noteSyntaxUse(ctx.site, expr.span, read, () => &_typing.indexing[readOf].read);
        return read.signature.ret;
    }

    /// `x[a..b]` on something other than an array, which is `opSlice(x, a, b)`. A left-out `a` is
    /// 0, and a left-out `b` is `length(x)`, with `x` evaluated once.
    private Type sliceIndexed(const Expr expr, const IndexExpr index, const RangeExpr range, Type objectType,
        BodyContext ctx)
    {
        auto left = placeholder(expr.span);
        Type end;
        if (range.end is null)
        {
            auto length = syntaxFunction(expr, expr.span, "length", "`x[a..]`", [*index.object], [objectType], ctx);
            if (!length.found)
            {
                if (range.start !is null) checkArgument(*range.start, _types.error, ctx);
                return _types.error;
            }
            _typing.indexing.require(expr.id).length = length.use;
            auto lengthOf = expr.id;
            noteSyntaxUse(ctx.site, expr.span, length, () => &_typing.indexing[lengthOf].length);
            end = length.signature.ret;
        }
        auto args = [*index.object, range.start is null ? left : *range.start, range.end is null ? left : *range.end];
        Type[] typed = [objectType, range.start is null ? _types.int_ : Type.init, end];
        auto slice = syntaxFunction(expr, expr.span, "opSlice", "`x[a..b]`", args, typed, ctx);
        if (!slice.found) return _types.error;
        auto params = slice.signature.params;
        if (range.start is null && params[1] != _types.int_)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
                "`x[..b]` passes `opSlice` an `Int` 0 to start at, but `%s` takes `%s`"
                    .format(describeUse("opSlice", slice), _types.describe(params[1])));
            return _types.error;
        }
        if (range.end is null && params[2] != end)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
                "`x[a..]` passes `opSlice` the `%s` that `length` returns to end at, but `%s` takes `%s`"
                    .format(_types.describe(end), describeUse("opSlice", slice), _types.describe(params[2])));
            return _types.error;
        }
        _typing.indexing.require(expr.id).read = slice.use;
        auto sliced = expr.id;
        noteSyntaxUse(ctx.site, expr.span, slice, () => &_typing.indexing[sliced].read);
        return slice.signature.ret;
    }

    /// An array's index or slice bound, which is an `Int`.
    private void checkIndex(const Expr expr, BodyContext ctx)
    {
        if (isIntLiteral(expr))
        {
            check(expr, _types.int_, ctx);
            return;
        }
        auto type = synthesize(expr, ctx);
        if (type == _types.int_ || type == _types.error || type == _types.never) return;
        _collector.reportError(DiagnosticCode.TypeMismatch, expr.span, _types.isInteger(type)
            ? "An array index is an `Int`, not `%s`; convert it with `Int(...)`".format(_types.describe(type))
            : "An array index is an `Int`, not `%s`".format(_types.describe(type)));
    }

    /// An argument that syntax passes with no expression of its own, such as the 0 a left-out
    /// slice start means. It's given a type, so it's never synthesized.
    private static Expr placeholder(Span span)
    {
        return Expr(Id!Expr.init, span, ExprKind(Identifier(discardName)));
    }

    private Type synthesizeBareRange(const RangeExpr range, Span span, BodyContext ctx)
    {
        synthesize(*range.start, ctx);
        synthesize(*range.end, ctx);
        _collector.reportError(DiagnosticCode.NotSupportedYet, span, "A range can only slice an array or be looped over by `for` for now");
        return _types.error;
    }

    /// The type of a name used as a value, reporting the declarations that have none.
    private Type symbolValue(SymbolId symbol, Span span, Site site)
    {
        auto isSumName = symbol.match!(
            (const Id!TypeDecl type) => _resolutions.declarations.types[type].members.length > 0,
            _ => false,
        );
        if (isSumName)
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, span,
                "A sum type has no value of its own; build one of its members");
            return _types.error;
        }

        if (!symbol.match!((const Id!TypeDecl type) => requireInvariant(type, span, site), _ => true)) return _types.error;

        if (showsCondition(symbol))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, span,
                "`%s` shows the condition it's given, so it can only be called".format(symbolName(symbol)));
            return _types.error;
        }
        if (!takesAnyIntrinsically(symbol)) return symbolType(symbol);
        _collector.reportError(DiagnosticCode.NotSupportedYet, span,
            "`%s` is built into the compiler, so it can only be called for now".format(symbolName(symbol)));
        return _types.error;
    }

    /// Whether `symbol` is `assert` or `expect`, which take apart the condition as written.
    private bool showsCondition(SymbolId symbol)
    {
        return symbol.match!((const Id!FunctionDecl f) => isIntrinsic(f, "assert") || isIntrinsic(f, "expect"), _ => false);
    }

    private bool isIntrinsic(Id!FunctionDecl f, string name)
    {
        auto decl = _resolutions.declarations.functions[f];
        return decl.kind == FunctionKind.intrinsic && decl.name == name;
    }

    /// `call`, of type `type`, reported if it calls `expect` or `panics` outside a test.
    private Type placeExpect(const Expr call, Type type, Site site)
    {
        auto callee = calleeOf(call.id);
        if (callee is null) callee = call.id in _typing.methodCallees;
        if (site.inTest || callee is null) return type;
        if (isIntrinsic(*callee, "expect"))
        {
            _collector.reportError(DiagnosticCode.ExpectOutsideTest, call.span,
                "`expect` records a failure for a test to report, so it can only be used in one; `assert` stops the program instead");
        }
        if (isIntrinsic(*callee, "panics")) reportPanicsOutsideTest(call.span);
        return type;
    }

    private void reportPanicsOutsideTest(Span span)
    {
        _collector.reportError(DiagnosticCode.PanicsOutsideTest, span,
            "`panics` survives a panic so that a test can check it, so it can only be used in one");
    }

    /// Whether `symbol` is an intrinsic with an `Any` parameter, which has no function type to be a value of.
    private bool takesAnyIntrinsically(SymbolId symbol)
    {
        return symbol.match!(
            (const Id!FunctionDecl f) => _resolutions.declarations.functions[f].kind == FunctionKind.intrinsic
                && _types[symbolType(symbol)].match!((const FunctionData data) => data.params.canFind(_types.any), _ => false),
            _ => false,
        );
    }

    private string symbolName(SymbolId symbol)
    {
        return symbol.match!(
            (const Id!FunctionDecl f) => _resolutions.declarations.functions[f].name,
            (const Id!TypeDecl t) => _resolutions.declarations.types[t].name,
            _ => "this",
        );
    }

    /// An array literal, or a `~` of them: what takes its element type from what it's checked against.
    private bool isArraySyntax(const Expr expr)
    {
        return expr.kind.match!(
            (const ArrayLiteral _) => true,
            (const BinaryExpr binary) => binary.op == BinaryOp.Concat
                && isArraySyntax(*binary.left) && isArraySyntax(*binary.right),
            _ => false,
        );
    }

    private void recordConcat(const Expr expr, const BinaryExpr binary)
    {
        if (binary.op == BinaryOp.Concat)
        {
            _typing.concatOperands[expr.id] = concatChain(*binary.left) ~ concatChain(*binary.right);
        }
    }

    private const(Expr)[] concatChain(const Expr expr)
    {
        return expr.kind.match!(
            (const BinaryExpr binary) => binary.op == BinaryOp.Concat
                ? concatChain(*binary.left) ~ concatChain(*binary.right)
                : [expr],
            _ => [expr],
        );
    }

    /// `a ~ b` or `a ~= b`. A side that's written as an array takes its element type from the other.
    private Type synthesizeConcat(const Expr expr, const BinaryExpr binary, BodyContext ctx)
    {
        recordConcat(expr, binary);
        Type leftType, rightType;
        if (isArraySyntax(*binary.left) && !isArraySyntax(*binary.right))
        {
            rightType = synthesize(*binary.right, ctx);
            leftType = _types.isArray(rightType) ? check(*binary.left, rightType, ctx) : synthesize(*binary.left, ctx);
        }
        else
        {
            leftType = synthesize(*binary.left, ctx);
            rightType = _types.isArray(leftType) && isArraySyntax(*binary.right)
                ? check(*binary.right, leftType, ctx)
                : synthesize(*binary.right, ctx);
        }
        if (leftType == _types.error || rightType == _types.error) return _types.error;
        if (leftType == _types.emptyArray && rightType == _types.emptyArray)
        {
            return _declarer.reportUntypedEmptyArray(binary.left.span);
        }

        foreach (side, type; [leftType, rightType])
        {
            if (!isConcatenable(type))
            {
                _collector.reportError(DiagnosticCode.InvalidOperand, side == 0 ? binary.left.span : binary.right.span,
                    "`%s` needs a String or an array, got `%s`".format(cast(string) binary.op, _types.describe(type)));
                return _types.error;
            }
        }
        if (leftType == rightType) return leftType;
        if (isAssignable(leftType, rightType))
        {
            coerce(*binary.left, leftType, rightType);
            return rightType;
        }
        if (isAssignable(rightType, leftType))
        {
            coerce(*binary.right, rightType, leftType);
            return leftType;
        }
        _collector.reportError(DiagnosticCode.InvalidOperand, expr.span,
            "`%s` can't combine `%s` and `%s`".format(cast(string) binary.op,
                _types.describe(leftType), _types.describe(rightType)));
        return _types.error;
    }

    /// `x?`, which returns `None` from the enclosing function, so that has to return an option, or
    /// in a test's own body stops the test.
    private Type synthesizePropagate(const PropagateExpr propagate, Span span, BodyContext ctx, Type expected = Type.init)
    {
        auto operandType = _declarer.requireTyped(unwrapped(*propagate.operand, ctx, expected, true), propagate.operand.span);
        if (operandType == _types.error) return operandType;
        auto returnType = ctx.returnType;
        auto checked = ctx.inferred is null && !ctx.testBody && returnType != _types.error;
        if (_types.isErrorUnion(operandType))
        {
            auto reason = _types.errorOf(operandType);
            if (ctx.inferred !is null)
            {
                ctx.inferred.errors ~= reason;
                ctx.inferred.errorSpans ~= span;
            }
            else if (checked && _types.isOption(returnType))
            {
                _collector.reportError(DiagnosticCode.InvalidPropagation, span,
                    "`?` would turn this `%s` into `None` and lose it, since this function returns `%s`; write `?? { return None }` to mean that"
                        .format(_types.describe(reason), _types.describe(returnType)));
            }
            else if (checked && !_types.isErrorUnion(returnType))
            {
                _collector.reportError(DiagnosticCode.InvalidPropagation, span,
                    "`?` passes on `%s`, but this function returns `%s`, which can't hold one; it could return `%s ! %s`"
                        .format(_types.describe(reason), _types.describe(returnType), _types.describe(returnType),
                            _types.describe(reason)));
            }
            else if (checked && !errorFits(reason, _types.errorOf(returnType)))
            {
                _collector.reportError(DiagnosticCode.InvalidPropagation, span,
                    "`?` passes on `%s`, which this function's errors, `%s`, don't include"
                        .format(_types.describe(reason), _types.describe(_types.errorOf(returnType))));
            }
            return _types.successOf(operandType);
        }
        if (!_types.isOption(operandType))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, propagate.operand.span,
                "`?` needs an option or an error union, got `%s`".format(_types.describe(operandType)));
            return _types.error;
        }
        if (ctx.inferred !is null)
        {
            ctx.inferred.nones ~= span;
        }
        else if (checked && _types.isErrorUnion(returnType))
        {
            _collector.reportError(DiagnosticCode.InvalidPropagation, span,
                "`?` would return `None`, but this function returns `%s`, so it needs a reason; write `?? { return Error(...) }`"
                    .format(_types.describe(returnType)));
        }
        else if (checked && !_types.isOption(returnType))
        {
            _collector.reportError(DiagnosticCode.InvalidPropagation, span,
                "`?` returns `None` when there's no value, but this function returns `%s`"
                    .format(_types.describe(returnType)));
        }
        return _types.optionInner(operandType);
    }

    /// `x!`: the value of an option or error union, which lowering makes a panic when there isn't one.
    private Type synthesizeAssert(const AssertExpr assertion, BodyContext ctx, Type expected = Type.init)
    {
        // A construction from literals alone that `!` says can't fail is checked at compile time.
        auto construction = assertion.operand.kind.match!(
            (const CallExpr call) => (assertion.operand.id in _resolutions.constructions) !is null
                && _resolutions.declarations.types[_resolutions.constructions[assertion.operand.id]].invariantFunction.isValid
                && call.args.all!(a => isLiteral(a)),
            _ => false,
        );
        if (construction) _literalConstructions ~= *assertion.operand;
        auto operandType = _declarer.requireTyped(unwrapped(*assertion.operand, ctx, expected), assertion.operand.span);
        if (operandType == _types.error) return operandType;
        if (_types.isOption(operandType)) return _types.optionInner(operandType);
        if (_types.isErrorUnion(operandType)) return _types.successOf(operandType);
        _collector.reportError(DiagnosticCode.InvalidOperand, assertion.operand.span,
            "`!` needs an option or an error union, got `%s`".format(_types.describe(operandType)));
        return _types.error;
    }

    /// The operand of `!` or `?` (`propagates`), typed toward an option or error union of `expected`,
    /// what's expected of the value it unwraps. For `?` that's the one the function can return;
    /// otherwise its error isn't known, and stands as `error`, which nothing binds to.
    private Type unwrapped(const Expr operand, BodyContext ctx, Type expected, bool propagates = false)
    {
        if (expected == Type.init || expected == _types.error) return synthesize(operand, ctx);
        auto ret = ctx.returnType;
        auto returns = propagates && ctx.inferred is null && !ctx.testBody;
        auto toward = returns && _types.isOption(ret) ? _types.option(expected)
            : _types.errorUnion(expected, returns && _types.isErrorUnion(ret) ? _types.errorOf(ret) : _types.error);
        return synthesizeToward(operand, toward, ctx);
    }

    /// The type of `expr`, toward `expected`, an option or error union that `!` or `?` will unwrap.
    /// It only binds type arguments and picks an owned member over its sum, through branches and a
    /// block's value; nothing is coerced to it.
    private Type synthesizeToward(const Expr expr, Type expected, BodyContext ctx)
    {
        Type joinedOf(const(Expr)[] bodies, const(Type)[] types, Span span, string what)
        {
            auto joined = _types.never;
            foreach (i, type; types) joined = join(joined, type, bodies[i].span, what);
            if (joined != _types.error)
            {
                foreach (i, body; bodies) coerce(body, types[i], joined);
            }
            _typing.exprTypes[expr.id] = joined;
            return joined;
        }

        auto branched = expr.kind.match!(
            (const IfExpr if_) {
                if (if_.falseBody is null) return Type.init;
                checkIfHead(if_, ctx);
                const(Expr)[] bodies = [*if_.trueBody, *if_.falseBody];
                return joinedOf(bodies, bodies.map!(b => synthesizeToward(b, expected, ctx)).array, expr.span, "Branches");
            },
            (const MatchExpr match_) {
                if (match_.origin == MatchOrigin.IfVal) return Type.init;
                checkMatchHead(match_, expr.span, ctx);
                auto bodies = match_.arms.map!(arm => arm.body).array;
                return joinedOf(bodies, bodies.map!(b => synthesizeToward(b, expected, ctx)).array, expr.span, "Match arms");
            },
            (const BlockExpr block) {
                if (block.value is null) return Type.init;
                foreach (stmt; block.statements) checkStmt(stmt, ctx);
                auto type = synthesizeToward(*block.value, expected, ctx);
                _typing.exprTypes[expr.id] = type;
                return type;
            },
            _ => Type.init,
        );
        if (branched != Type.init) return branched;

        auto isMethod = expr.kind.match!((const CallExpr call) => isMethodCall(expr.id, *call.callee), _ => false);
        auto unwraps = expr.kind.match!((const AssertExpr _) => true, (const PropagateExpr _) => true, _ => false);
        auto constructed = constructedDecl(expr);
        auto owner = _declarer.ownerOf(constructed);
        auto member = owner !is null && wantsMember(_typing.nominalTypes[constructed], *owner, expected);
        if (isMethod || unwraps || member || genericUse(expr).found || isOverloadedUse(expr))
        {
            auto outer = _unwrapTarget;
            _unwrapTarget = expected;
            scope (exit) _unwrapTarget = outer;
            return synthesizeExact(expr, ctx, expected);
        }
        return synthesize(expr, ctx);
    }

    /// Whether an error of type `from` fits where `to` is expected: each type it lists is one `to`
    /// lists, or a member of a declared sum that `to` lists.
    private bool errorFits(Type from, Type to)
    {
        if (from == to || _types.mentionsError(from) || _types.mentionsError(to)) return true;
        auto targets = _types.listed(to);
        return _types.listed(from).all!(m => targets.canFind(m) || targets.any!(t => _declarer.membersOf(t).canFind(m)));
    }

    /// `a?.b`. A field that's already an option isn't wrapped again, which is what makes
    /// `a?.b?.c` one flat option: each `?.` works on the option the one before it produced.
    private Type synthesizeSafeMember(const Expr expr, const SafeMemberAccess access, BodyContext ctx)
    {
        auto objectType = _declarer.requireTyped(synthesize(*access.object, ctx), access.object.span);
        if (objectType == _types.error) return objectType;
        auto fallible = _types.isErrorUnion(objectType);
        if (!_types.isOption(objectType) && !fallible)
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, access.object.span,
                "`?.` needs an option or an error union, got `%s`; a field of any other value is read with `.`"
                    .format(_types.describe(objectType)));
            return _types.error;
        }

        auto record = fallible ? _types.successOf(objectType) : _types.optionInner(objectType);
        auto fields = _declarer.fieldsOf(record);
        foreach (i, field; fields)
        {
            if (field.name == access.member)
            {
                _typing.fieldIndexes[expr.id] = i;
                if (!fallible) return _types.isOption(field.type) ? field.type : _types.option(field.type);
                auto reason = _types.errorOf(objectType);
                auto flat = _types.isErrorUnion(field.type) && _types.errorOf(field.type) == reason;
                return flat ? field.type : _types.errorUnion(field.type, reason);
            }
        }
        _collector.reportError(DiagnosticCode.UnknownMember, expr.span,
            "Type `%s` has no member named `%s`".format(_types.describe(objectType), access.member));
        return _types.error;
    }

    /// A hole takes whatever `print` does, so its type needs no check of its own.
    private Type synthesizeInterpolated(const InterpolatedString interpolated, BodyContext ctx)
    {
        foreach (part; interpolated.parts)
        {
            _declarer.requireTyped(synthesize(part, ctx), part.span);
        }
        return _types.string_;
    }

    /// Reports that generic code can't do `what` with a value of `type`, which mentions a type
    /// parameter. `example` is the function parameter that would, with `%s` for the type.
    private Type reportOpaque(Span span, Type type, string what, string example)
    {
        auto subject = _types.isParameter(type)
            ? "`%s` could be any type".format(_types.describe(type))
            : "`%s` holds a type parameter, which could be any type".format(_types.describe(type));
        auto hint = example is null ? ""
            : "; for now, take a function that does it as a parameter, as in `%s`".format(example.replace("%s", _types.describe(type)));
        _collector.reportError(DiagnosticCode.OpaqueTypeParameter, span, "%s, so %s%s".format(subject, what, hint));
        return _types.error;
    }

    private bool isNumeric(Type t)
    {
        return _types.isInteger(t) || t == _types.float_;
    }

    private bool isOrdered(Type t)
    {
        return isNumeric(t) || t == _types.string_ || t == _types.char_;
    }

    /// What `~` joins.
    private bool isConcatenable(Type t)
    {
        return t == _types.string_ || t == _types.emptyArray || _types.isArray(t);
    }

    /// `UInt8(x)`: a literal is checked against the target where it's written, and any other
    /// number at runtime, where one that doesn't fit panics. `String(x)` takes whatever `print` does.
    private Type synthesizeConversion(const CallExpr call, Type target, Span span, BodyContext ctx)
    {
        rejectMutableArguments(call);
        _typing.exprTypes[call.callee.id] = target;
        if (call.args.length != 1)
        {
            foreach (arg; call.args)
            {
                synthesize(arg, ctx);
            }
            _collector.reportError(DiagnosticCode.WrongArgumentCount, span,
                "`%s` converts one %s, got %s arguments".format(_types.describe(target),
                    target == _types.string_ ? "value" : "number", call.args.length));
            return target;
        }

        auto arg = call.args[0];
        if (target == _types.string_)
        {
            _declarer.requireTyped(synthesize(arg, ctx), arg.span);
            return target;
        }
        if (isIntLiteral(arg))
        {
            check(arg, target, ctx);
            return target;
        }
        auto argType = synthesize(arg, ctx);
        if (_types.mentionsParameter(argType))
        {
            reportOpaque(arg.span, argType, "it can't be converted to `%s`".format(_types.describe(target)), null);
        }
        else if (argType != _types.error && !isNumeric(argType) && !(argType == _types.char_ && _types.isInteger(target)))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, arg.span,
                "`%s` can only convert a number, got `%s`".format(_types.describe(target), _types.describe(argType)));
        }
        return target;
    }

    /// The lambda written as `e`, or as part of the value `e` builds with a constructor, a tuple,
    /// an array, `Some`, `Ok` or `Error`. A lambda deeper in, such as an argument of another call,
    /// isn't part of the value compared.
    private const(Expr)* writtenLambda(ref const Expr e)
    {
        const(Expr)* among(const Expr[] parts)
        {
            foreach (ref part; parts)
            {
                if (auto found = writtenLambda(part)) return found;
            }
            return null;
        }

        return e.kind.match!(
            (const Lambda _) => &e,
            (const TupleLiteral tuple) => among(tuple.elements),
            (const ArrayLiteral array) => among(array.elements),
            (const SomeExpr some) => writtenLambda(*some.value),
            (const OkExpr ok) => writtenLambda(*ok.value),
            (const ErrorExpr error) => writtenLambda(*error.value),
            (const CallExpr call) => e.id in _resolutions.constructions ? among(call.args) : null,
            _ => null,
        );
    }

    private Type synthesizeUnary(const UnaryExpr unary, Span span, BodyContext ctx)
    {
        auto operandType = synthesize(*unary.operand, ctx);
        final switch (unary.op)
        {
            case UnaryOp.Minus:
                auto isLiteral = (*unary.operand).kind.match!((const IntLiteral _) => true, _ => false);
                if (isLiteral)
                {
                    _negatedLiterals[unary.operand.id] = true;
                }
                else if (_types.isInteger(operandType) && !_types.integerOf(operandType).signed)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, unary.operand.span,
                        "`%s` can't be negated".format(_types.describe(operandType)));
                    return _types.error;
                }
                goto case;
            case UnaryOp.Plus:
                if (operandType == _types.error) return _types.error;
                if (!isNumeric(operandType))
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, unary.operand.span,
                        "`%s` needs a number, got `%s`".format(unary.op, _types.describe(operandType)));
                    return _types.error;
                }
                return operandType;
            case UnaryOp.BitNot:
                if (operandType == _types.error) return _types.error;
                if (!_types.isInteger(operandType))
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, unary.operand.span,
                        "`%s` needs an integer, got `%s`".format(unary.op, _types.describe(operandType)));
                    return _types.error;
                }
                return operandType;
            case UnaryOp.Not:
                requireAssignable(operandType, _types.bool_, unary.operand.span);
                return _types.bool_;
        }
    }

    /// `Some(x)` or `None`, written out, which takes its type from what it's checked against.
    private bool isOptionSyntax(const Expr expr)
    {
        return expr.kind.match!(
            (const SomeExpr _) => true,
            (const NoneLiteral _) => true,
            _ => false,
        );
    }

    /// `Ok(x)` or `Error(e)`, written out, which takes its type from what it's checked against.
    private bool isErrorUnionSyntax(const Expr expr)
    {
        return expr.kind.match!(
            (const OkExpr _) => true,
            (const ErrorExpr _) => true,
            _ => false,
        );
    }

    /// `a ?? b`. A `b` that's written as an option, or has `a`'s type, keeps the option, and
    /// anything else has to fit `T`, so the result is `T` and the fallback is never missing.
    private Type synthesizeCoalesce(const BinaryExpr binary, BodyContext ctx)
    {
        auto optionType = synthesize(*binary.left, ctx);
        // An error union's error is dropped, so the result types are an option's.
        if (_types.isErrorUnion(optionType)) optionType = _declarer.optionOf(_types.successOf(optionType), binary.left.span);
        if (!_types.isOption(optionType))
        {
            synthesize(*binary.right, ctx);
            if (optionType == _types.error) return optionType;
            if (optionType == _types.none) return _declarer.reportUntypedNone(binary.left.span);
            _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                "`??` needs an option on its left, got `%s`".format(_types.describe(optionType)));
            return _types.error;
        }

        auto inner = _types.optionInner(optionType);
        if (isOptionSyntax(*binary.right))
        {
            check(*binary.right, optionType, ctx);
            return optionType;
        }
        if (isArraySyntax(*binary.right) || isTupleLiteral(*binary.right))
        {
            check(*binary.right, inner, ctx);
            return inner;
        }
        auto rightType = synthesize(*binary.right, ctx);
        if (rightType == inner) return inner;
        if (_types.isOption(rightType) || rightType == _types.none)
        {
            coerce(*binary.right, rightType, optionType);
            return optionType;
        }
        coerce(*binary.right, rightType, inner);
        return inner;
    }

    /// A tuple written out, which takes its element types from what it's checked against.
    private bool isTupleLiteral(const Expr expr)
    {
        return expr.kind.match!((const TupleLiteral _) => true, _ => false);
    }

    /// Synthesizes both sides of `==` or `!=`. A side written as `Some`, `None` or an array is
    /// checked against the other one, whichever side it's on, so `x == Some(1)` adapts the literal.
    private void synthesizeCompared(const BinaryExpr binary, out Type leftType, out Type rightType, BodyContext ctx)
    {
        bool takesType(const Expr expr) => isOptionSyntax(expr) || isErrorUnionSyntax(expr) || isArraySyntax(expr)
            || isTupleLiteral(expr) || genericUse(expr).found;
        bool givesType(Type type) => _types.isOption(type) || _types.isErrorUnion(type) || _types.isArray(type) || _types.isTuple(type)
            || declOf(type).isValid;

        if (takesType(*binary.left) && !takesType(*binary.right))
        {
            rightType = synthesize(*binary.right, ctx);
            leftType = givesType(rightType) ? check(*binary.left, rightType, ctx) : synthesize(*binary.left, ctx);
            return;
        }
        leftType = synthesize(*binary.left, ctx);
        rightType = givesType(leftType) && takesType(*binary.right)
            ? check(*binary.right, leftType, ctx)
            : synthesize(*binary.right, ctx);
    }

    /// Whether `expr`, of type `type`, can become `target` when compared with it: an option, or
    /// the array a `[]` takes on.
    private bool promotes(const Expr expr, Type type, Type target)
    {
        auto core = layerCore(target);
        auto literalFits = isIntLiteral(expr)
            && (isNumeric(core) || _declarer.isSum(core) && _declarer.membersOf(core).any!(m => isNumeric(m)));
        if (_declarer.isSum(target)) return isAssignable(type, target) || literalFits;
        if (type == _types.emptyArray && _types.isArray(target)) return true;
        if (_types.isErrorUnion(target)) return isAssignable(type, target) || literalFits;
        if (!_types.isOption(target) || _types.isOption(type) && !isAssignable(type, target)) return false;
        return isAssignable(type, target) || literalFits;
    }

    private Type innermost(Type option)
    {
        while (_types.isOption(option)) option = _types.optionInner(option);
        return option;
    }

    private Type synthesizeBinary(const BinaryExpr binary, Span span, BodyContext ctx)
    {
        if (binary.op == BinaryOp.Coalesce) return synthesizeCoalesce(binary, ctx);

        Type leftType, rightType;
        if (binary.op == BinaryOp.Equal || binary.op == BinaryOp.NotEqual)
        {
            auto lambda = writtenLambda(*binary.left);
            if (lambda is null) lambda = writtenLambda(*binary.right);
            if (lambda is null)
            {
                synthesizeCompared(binary, leftType, rightType, ctx);
            }
            else
            {
                // What the lambda's parameters would be is beside the point, so only this is reported.
                auto collector = _collector;
                _collector = new Collector;
                synthesizeCompared(binary, leftType, rightType, ctx);
                _collector = collector;
                _collector.reportError(DiagnosticCode.LambdaInComparison, lambda.span,
                    "This lambda is equal to nothing else, since a function value is equal only to one made by the same "
                        ~ "function or lambda; compare a named function, or a value made earlier");
                return _types.error;
            }
        }
        else
        {
            leftType = synthesize(*binary.left, ctx);
            rightType = synthesize(*binary.right, ctx);
        }
        if (leftType == _types.error || rightType == _types.error) return _types.error;
        // An integer literal takes the type of the number beside it, so `x * 2` and `x == 0` work.
        // Not a Float beside an integer-only operator, or the error would blame the literal.
        with (BinaryOp)
        {
            auto integerOnly = [BitAnd, BitOr, BitXor, ShiftLeft, ShiftRight,
                WrappingAdd, WrappingSubtract, WrappingMultiply].canFind(binary.op);
            bool adaptsTo(Type t) => integerOnly ? _types.isInteger(t) : isNumeric(t);
            auto isShift = binary.op == ShiftLeft || binary.op == ShiftRight;
            if (adaptsTo(leftType) && isIntLiteral(*binary.right) && !isIntLiteral(*binary.left))
            {
                rightType = adaptLiteral(*binary.right, leftType);
            }
            else if (!isShift && adaptsTo(rightType) && isIntLiteral(*binary.left) && !isIntLiteral(*binary.right))
            {
                leftType = adaptLiteral(*binary.left, rightType);
            }
        }
        final switch (binary.op)
        {
            case BinaryOp.BitAnd:
            case BinaryOp.BitOr:
            case BinaryOp.BitXor:
            case BinaryOp.ShiftLeft:
            case BinaryOp.ShiftRight:
            case BinaryOp.WrappingAdd:
            case BinaryOp.WrappingSubtract:
            case BinaryOp.WrappingMultiply:
                if (!_types.isInteger(leftType))  {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                        "`%s` needs an integer, got `%s`".format(binary.op, _types.describe(leftType)));
                    return _types.error;
                }
                if (!_types.isInteger(rightType)) {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.right.span,
                        "`%s` needs an integer, got `%s`".format(binary.op, _types.describe(rightType)));
                    return _types.error;
                }
                if (binary.op != BinaryOp.ShiftLeft && binary.op != BinaryOp.ShiftRight && leftType != rightType)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't combine `%s` and `%s`".format(binary.op, _types.describe(leftType), _types.describe(rightType)));
                    return _types.error;
                }
                return leftType;
            case BinaryOp.Add:
            case BinaryOp.Subtract:
            case BinaryOp.Multiply:
            case BinaryOp.Divide:
            case BinaryOp.Modulo:
                if (!isNumeric(leftType))  {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                        "`%s` needs a number, got `%s`".format(binary.op, _types.describe(leftType)));
                    return _types.error;
                }
                if (!isNumeric(rightType)) {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.right.span,
                        "`%s` needs a number, got `%s`".format(binary.op, _types.describe(rightType)));
                    return _types.error;
                }
                if (leftType != rightType)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't combine `%s` and `%s`".format(binary.op, _types.describe(leftType), _types.describe(rightType)));
                    return _types.error;
                }
                return leftType;
            case BinaryOp.Less:
            case BinaryOp.LessEqual:
            case BinaryOp.Greater:
            case BinaryOp.GreaterEqual:
                foreach (side, sideType; [leftType, rightType])
                {
                    if (!_types.mentionsParameter(sideType)) continue;
                    return reportOpaque(side == 0 ? binary.left.span : binary.right.span, sideType,
                        "its values can't be ordered with `%s`".format(cast(string) binary.op), "less: (%s, %s) -> Bool");
                }
                if (!isOrdered(leftType))  {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                        "`%s` needs a number, a String or a Char, got `%s`".format(cast(string) binary.op, _types.describe(leftType)));
                    return _types.error;
                }
                if (!isOrdered(rightType)) {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.right.span,
                        "`%s` needs a number, a String or a Char, got `%s`".format(cast(string) binary.op, _types.describe(rightType)));
                    return _types.error;
                }
                if (leftType != rightType)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't compare `%s` and `%s`".format(cast(string) binary.op, _types.describe(leftType), _types.describe(rightType)));
                    return _types.error;
                }
                return _types.bool_;
            case BinaryOp.And:
            case BinaryOp.Or:
                requireAssignable(leftType, _types.bool_, binary.left.span);
                requireAssignable(rightType, _types.bool_, binary.right.span);
                return _types.bool_;
            case BinaryOp.Equal:
            case BinaryOp.NotEqual:
                if (leftType == _types.none && rightType == _types.none) return _declarer.reportUntypedNone(binary.left.span);
                if (leftType == _types.emptyArray && rightType == _types.emptyArray)
                {
                    return _declarer.reportUntypedEmptyArray(binary.left.span);
                }
                if (leftType != rightType && promotes(*binary.right, rightType, leftType))
                {
                    rightType = coerce(*binary.right, rightType, leftType);
                }
                else if (leftType != rightType && promotes(*binary.left, leftType, rightType))
                {
                    leftType = coerce(*binary.left, leftType, rightType);
                }
                if (leftType != rightType)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't compare `%s` and `%s`".format(cast(string) binary.op, _types.describe(leftType), _types.describe(rightType)));
                    return _types.error;
                }
                return _types.bool_;
            case BinaryOp.Coalesce:
            case BinaryOp.Concat:
            case BinaryOp.Append:
                assert(0, "handled above");
        }
    }

    private Type synthesizeCall(const Expr expr, const CallExpr call, BodyContext ctx, Type expected)
    {
        if (auto decl = expr.id in _resolutions.constructions)
        {
            noteInvariantUse(InvariantUse(ctx.site, expr.span, *decl, expr.id));
            if (!requireInvariant(*decl, expr.span, ctx.site))
            {
                foreach (arg; call.args) synthesize(arg, ctx);
                return _types.error;
            }
        }
        Type[] typed;
        if (auto candidates = call.callee.id in _resolutions.overloads)
        {
            typed = new Type[call.args.length];
            auto chosen = chooseFunction(*call.callee, spelling(*call.callee), typeArgsOf(*call.callee), distinct(*candidates),
                call, typed, false, ctx, expected);
            if (!chosen.isValid)
            {
                _typing.exprTypes[call.callee.id] = _types.error;
                typeUnchosen(call, typed, ctx);
                return _types.error;
            }
            _typing.chosenSymbols[call.callee.id] = SymbolId(chosen);
            _typing.chosenCallees[expr.id] = chosen;
            _siblings[call.callee.id] = siblingsOf(distinct(*candidates), chosen);
        }
        auto generic = genericUse(expr);
        if (generic.found) return applyGeneric(expr, generic, call, expected, ctx, typed);
        // A function named directly is called, not used as a value, so an intrinsic can be.
        if (auto function_ = calleeOf(expr.id))
        {
            rejectTypeArguments(typeArgsOf(*call.callee), spelling(*call.callee), call.callee.span);
            auto calleeType = symbolType(SymbolId(*function_));
            _typing.exprTypes[call.callee.id] = calleeType;
            return applyCallee(calleeType, call, expr.span, ctx, typed);
        }
        return applyCallee(synthesize(*call.callee, ctx), call, expr.span, ctx);
    }

    /// Whether `expr` names an overloaded function or calls one, which are chosen as they're checked.
    private bool isOverloadedUse(const Expr expr)
    {
        if (expr.id in _resolutions.overloads) return true;
        return expr.kind.match!((const CallExpr call) => (call.callee.id in _resolutions.overloads) !is null, _ => false);
    }

    private const(SymbolId)* resolutionOf(Id!Expr name)
    {
        if (auto chosen = name in _typing.chosenSymbols) return chosen;
        return name in _resolutions.resolutions;
    }

    private const(Id!FunctionDecl)* calleeOf(Id!Expr call)
    {
        if (auto chosen = call in _typing.chosenCallees) return chosen;
        return call in _resolutions.callees;
    }

    /// How well an argument fits a parameter: not at all, or in some number of promotion steps,
    /// fewer being better.
    private struct Fit
    {
        /// 0 when it doesn't fit, and otherwise `int.max` less the steps.
        int rank;

        enum none = Fit(0);
        enum exact = Fit(int.max);
        enum converted = promoted(1);

        static Fit promoted(int steps) => steps < 0 ? none : Fit(int.max - steps);

        /// This fit with `more` steps after it, as a layer around what fits adds one.
        Fit then(int more) const => this == none ? none : Fit(rank - more);

        int opCmp(const Fit other) const => rank < other.rank ? -1 : rank > other.rank ? 1 : 0;
    }

    /// One candidate of an overloaded call, tried against its arguments.
    private struct Trial
    {
        Id!FunctionDecl func;
        Fit[] fits;
        /// Why it doesn't fit, or null when it does.
        string problem;
        /// Whether what doesn't fit is an argument, against what the expected type binds.
        bool againstExpected;
        /// Whether the bounds fail for what the expected type binds.
        bool boundsAgainstExpected;
        /// Whether a bound is undecided because only a lambda's result would say what its type is.
        bool awaitsLambda;
        /// The lambdas whose results were left undecided, with what each would be typed against.
        LambdaTurn[] turns;

        bool fitsAll() const => problem is null;
    }

    /// Chooses which of `candidates` a call of `name` invokes, reporting it when none or several
    /// do. Each argument with a type of its own is synthesized first, once, and its type is left
    /// in `typed`; the rest only have to have the right shape, and are checked once one is chosen.
    private Id!FunctionDecl chooseFunction(const Expr name, string spelled, const(TypeExpr)[] written,
        const Candidates candidates, const CallExpr call, Type[] typed, bool hasReceiver, BodyContext ctx,
        Type expected = Type.init)
    {
        auto args = call.args;
        Trial[][] groups;
        foreach (group; candidates.groups)
        {
            groups ~= group.map!(f => arityTrial(f, args.length, written.length)).array;
        }
        auto plausible = groups.joiner.filter!(t => t.fitsAll).array;
        // One candidate is called as a lone function is, so its arguments can adapt to it.
        if (plausible.length == 1) return plausible[0].func;
        if (plausible.length == 0)
        {
            reportNoOverload(name.span, spelled, groups);
            return Id!FunctionDecl.init;
        }

        foreach (i, arg; args)
        {
            if (typed[i] == Type.init && (call.isMutable(i) || !isShaped(arg))) typed[i] = synthesize(arg, ctx);
        }
        auto writtenTypes = written.map!(w => quietlyResolved(w)).array;
        Trial[][] fitAll(Type against)
        {
            auto tried = groups.map!(g => g.dup).array;
            foreach (ref group; tried)
            {
                foreach (ref trial; group)
                {
                    if (trial.fitsAll) fitTrial(trial, call, typed, writtenTypes, hasReceiver, ctx, against);
                }
            }
            return tried;
        }
        auto arity = groups;
        Trial[] own;
        const(Trial[])[] imported;
        while (true)
        {
            groups = arity;
            auto tried = fitAll(expected);
            // When what the expected type binds leaves nothing fitting the arguments, the choice is made
            // without it, so the argument is reported against the chosen function, as for a lone one.
            // Not when it broke a function's bounds, since that would bring the function back.
            if (!tried.joiner.any!(t => t.fitsAll) && tried.joiner.any!(t => t.againstExpected)
                && !tried.joiner.any!(t => t.boundsAgainstExpected)) tried = fitAll(Type.init);
            groups = tried;
            own = groups[0].filter!(t => t.fitsAll).array;
            imported = own.length > 0 ? null : rankedImports(groups[1 .. $].map!(g => g.filter!(t => t.fitsAll).array).array);
            auto pool = own.length > 0 ? cast(const(Trial)[]) own : imported.length == 1 ? imported[0] : null;
            if (!typeAwaitedLambdas(pool, groups.joiner.filter!(t => t.fitsAll).array, call, typed, ctx)) break;
        }
        // An argument whose type is already an error fits anything, so it would only add to it.
        auto reportable = !typed.any!(t => t != Type.init && _types.mentionsError(t));

        if (own.length > 0) return bestTrial(own, name.span, spelled, reportable);
        if (imported.length == 1) return bestTrial(imported[0], name.span, spelled, reportable);
        if (imported.length > 1)
        {
            if (reportable) reportImportedOverloads(name.span, spelled, importsOf(candidates, imported.map!(g => functionsOf(g))));
            return Id!FunctionDecl.init;
        }
        if (reportable) reportNoOverload(name.span, spelled, groups);
        return Id!FunctionDecl.init;
    }

    /// Types, once, the lambdas whose results the functions of `pool` that are tied wait on, when
    /// those functions differ only in their bounds and every function that fits, `fitting`, would
    /// type the lambdas alike. Each then has a type of its own, in `typed`, and its result decides
    /// the bounds when the choice is made again. Whether it typed any.
    private bool typeAwaitedLambdas(const(Trial)[] pool, const(Trial)[] fitting, const CallExpr call, Type[] typed,
        BodyContext ctx)
    {
        if (pool.length < 2 || pool.any!(t => pool.all!(u => u.func == t.func || beats(t, u)))) return false;
        auto tied = pool.filter!(t => !pool.any!(u => beats(u, t))).array;
        if (!tied.any!(t => t.awaitsLambda)) return false;
        auto turns = tied[0].turns;
        bool alike(const(LambdaTurn)[] other) => other.length == turns.length && other.length.iota.all!(k =>
            other[k].arg == turns[k].arg && other[k].expectation == turns[k].expectation && other[k].optional == turns[k].optional);
        bool boundsOnly(Id!FunctionDecl a, Id!FunctionDecl b) => requiresAll(a, b) || requiresAll(b, a);
        if (turns.length == 0 || !fitting.all!(t => alike(t.turns))
            || !tied.all!(t => tied.all!(u => u.func == t.func || boundsOnly(t.func, u.func)))) return false;
        foreach (turn; turns)
        {
            auto arg = call.args[turn.arg];
            auto lambda = arg.kind.match!((const Lambda l) => l, (_) => Lambda.init);
            auto expectation = turn.expectation;
            typed[turn.arg] = typeLambda(arg, lambda, &expectation, ctx.site, turn.optional);
        }
        return true;
    }

    /// The fitting trials of the imported modules that have any, a list per module, narrowed to
    /// the modules with a function that fits every argument exactly and isn't generic when some
    /// have one.
    private const(Trial[])[] rankedImports(const(Trial[])[] fitting)
    {
        auto imported = fitting.filter!(g => g.length > 0).array;
        auto exact = imported.filter!(g => g.any!(t => fitsExactly(t))).array;
        return agreeing!(t => t.func)(exact.length > 0 ? exact : imported);
    }

    /// `groups`, each one import's functions that fit, without those whose functions another has
    /// too: imports that lead to the same functions agree, however else they differ.
    private static G[] agreeing(alias functionOf, G)(G[] groups)
    {
        bool covered(size_t i)
        {
            foreach (j, other; groups)
            {
                if (j == i || !groups[i].all!(t => other.any!(u => functionOf(u) == functionOf(t)))) continue;
                if (groups[i].length < other.length || j < i) return true;
            }
            return false;
        }
        return groups.length.iota.filter!(i => !covered(i)).map!(i => groups[i]).array;
    }

    private static Id!FunctionDecl[] functionsOf(const(Trial)[] trials)
    {
        return trials.map!(t => cast() t.func).array;
    }

    /// The import that brought each of `groups`, which hold functions of `candidates`' imported
    /// groups and are in their order.
    private string[] importsOf(R)(const Candidates candidates, R groups)
    {
        string[] names;
        size_t next = 1;
        foreach (group; groups)
        {
            auto at = next;
            while (at < candidates.groups.length && !group.all!(f => candidates.groups[at].canFind(f))) at++;
            if (at < candidates.sources.length)
            {
                names ~= candidates.sources[at];
                next = at + 1;
            }
            else names ~= _resolutions.declarations.functionModules[group[0]];
        }
        return names;
    }

    private bool fitsExactly(const Trial trial)
    {
        return trial.fits.all!(f => f == Fit.exact) && !isGenericFunction(trial.func);
    }

    /// `f` as a candidate for a call with `count` arguments and `written` type arguments, failed
    /// already if those can't fit it.
    private Trial arityTrial(Id!FunctionDecl f, size_t count, size_t written)
    {
        auto trial = Trial(f);
        auto params = signatureOf(f).params.length;
        // Only the type parameters a function declares can be written.
        auto typeParams = _resolutions.declarations.functions[f].typeParams.length;
        if (params != count)
        {
            trial.problem = "takes %s argument%s".format(params, params == 1 ? "" : "s");
        }
        else if (written > 0 && typeParams != written)
        {
            trial.problem = typeParams == 0 ? "isn't generic" : "takes %s type arguments".format(typeParams);
        }
        return trial;
    }

    /// Fills in how well each argument fits `trial`'s function, or why one doesn't, binding its
    /// type parameters as a call of it alone would, in a trial that records nothing. How well an
    /// argument fits is read from what the arguments bind; the expected type, if any, binds too,
    /// and the arguments and bounds have to suit what it binds, but it doesn't say how well.
    private void fitTrial(ref Trial trial, const CallExpr call, const(Type)[] typed, const(Type)[] written, bool hasReceiver,
        BodyContext ctx, Type expected)
    {
        auto params = _resolutions.typeParamsOf(trial.func);
        auto signature = signatureOf(trial.func);
        Binding bindAgainst(Type against)
        {
            Binding binding;
            foreach (i, type; written) binding.bound[params[i].id] = type;
            binding.typed = typed.dup;
            // A trial records nothing, so it doesn't work out a result from the body. A result written
            // as an interface name then says nothing the expected type could bind, whether or not
            // it's been worked out elsewhere, so the choice doesn't depend on the order of checking.
            if ((trial.func in _resolutions.resultFloors) !is null) against = Type.init;
            bindCall(binding, signature, signatureOf(trial.func).ret, params, trial.func, call, against, ctx, true);
            binding.conformance = conformanceOf(trial.func, binding.bound, ctx.site);
            return binding;
        }

        string argument(size_t i) => hasReceiver && i == 0 ? "the receiver" : "argument %s".format(hasReceiver ? i : i + 1);
        // A literal receiver has been synthesized to look for a field, but still adapts.
        bool byShape(size_t i) => typed[i] == Type.init || isIntLiteral(call.args[i]);
        Fit fitAt(size_t i, Type param)
        {
            return byShape(i) ? shapeFit(call.args[i], param, params) : typedFit(typed[i], param, params, call.isMutable(i));
        }
        string misfit(size_t i, Type param)
        {
            auto type = typed[i] == Type.init ? literalType(call.args[i]) : typed[i];
            return type == Type.init
                ? "%s can't be `%s`".format(argument(i), _types.describe(param))
                : "%s is `%s`, not `%s`".format(argument(i), _types.describe(type), _types.describe(param));
        }

        auto plain = bindAgainst(Type.init);
        trial.fits = new Fit[call.args.length];
        foreach (i, arg; call.args)
        {
            if (call.isMutable(i) != signature.isMutable(i))
            {
                trial.problem = call.isMutable(i)
                    ? "%s is passed as `mutable`, and its parameter isn't".format(argument(i))
                    : "%s has to be passed as `mutable`".format(argument(i));
                return;
            }
            auto param = _types.substitute(signature.params[i], plain.bound);
            auto fit = fitAt(i, param);
            if (fit == Fit.none)
            {
                trial.problem = misfit(i, param);
                return;
            }
            trial.fits[i] = fit;
        }

        auto binding = plain;
        auto withExpected = expected != Type.init && !plain.failedEarly;
        if (withExpected) binding = bindAgainst(expected);
        // Every argument has to fit what's bound in the end. A promotion into a sum binds nothing,
        // so a parameter that still mentions a type parameter takes no member of a sum here.
        Fit finalFit(size_t i, Type param) => byShape(i) ? shapeFit(call.args[i], param, params)
            : typedFit(typed[i], param, params, call.isMutable(i), false);
        foreach (i; 0 .. call.args.length)
        {
            auto param = _types.substitute(signature.params[i], binding.bound);
            if (finalFit(i, param) != Fit.none) continue;
            auto plainParam = _types.substitute(signature.params[i], plain.bound);
            if (!withExpected || finalFit(i, plainParam) == Fit.none)
            {
                trial.problem = misfit(i, plainParam);
                return;
            }
            auto given = binding.fromExpected.filter!(p => _types.mentionsParameter(signature.params[i], p)).array;
            trial.problem = misfit(i, param) ~ (given.length == 1
                ? ", which the expected type gives `%s`".format(_resolutions.declarations.typeParams[given[0]].name) : "");
            trial.againstExpected = true;
            trial.boundsAgainstExpected = binding.conformance.failure !is null;
            return;
        }
        auto conformance = binding.conformance;
        // Undecided only when a bound is on what a lambda's result would decide.
        trial.awaitsLambda = conformance.pending
            && binding.undecided.any!(p => _typing.bounds.get(p, null).length > 0);
        trial.turns = binding.turns;
        if (conformance.failure is null) return;
        trial.problem = conformance.failure.replace("\n", "\n    ");
        trial.boundsAgainstExpected = !binding.failedEarly && binding.fromExpected.length > 0;
    }

    /// How well an argument of type `actual` fits `param`, which may still mention some of the
    /// candidate's own `params`.
    private Fit typedFit(Type actual, Type param, const(TypeParam)[] params, bool mutable, bool injects = true)
    {
        if (actual == _types.error || actual == _types.never || _types.mentionsError(param)) return Fit.exact;
        if (mentionsAny(param, params)) return couldBe(param, actual, params, injects) ? Fit.exact : Fit.none;
        if (actual == param) return Fit.exact;
        if (mutable) return Fit.none;
        return Fit.promoted(fitSteps(actual, param));
    }

    private bool mentionsAny(Type type, const(TypeParam)[] params)
    {
        return params.any!(p => _types.mentionsParameter(type, p.id));
    }

    /// Whether `declared`, in which any of `params` could be any type, could take a value of `actual`.
    private bool couldBe(Type declared, Type actual, const(TypeParam)[] params, bool injects = true)
    {
        if (actual == _types.error || actual == _types.never) return true;
        if (!mentionsAny(declared, params)) return isAssignable(actual, declared);
        auto data = _types[actual];
        return _types[declared].match!(
            (const TypeParamData _) => true,
            (const OptionData o) => (_types.isOption(actual) && couldBe(o.inner, _types.optionInner(actual), params, injects))
                || couldBe(o.inner, actual, params, injects),
            (const ErrorUnionData u) => (_types.isErrorUnion(actual) && couldBe(u.success, _types.successOf(actual), params, injects)
                    && couldBe(u.error, _types.errorOf(actual), params, injects))
                || (_types.isFailure(actual) && couldBe(u.error, _types.errorOf(actual), params, injects))
                || couldBe(u.success, actual, params, injects),
            (const ErrorListData _) => true,
            (const ArrayData a) => actual == _types.emptyArray
                || _types.isArray(actual) && couldBe(a.element, _types.arrayElement(actual), params, injects),
            (const TupleData t) => data.match!(
                (const TupleData u) => u.elements.length == t.elements.length
                    && t.elements.length.iota.all!(i => couldBe(t.elements[i], u.elements[i], params, injects)),
                _ => false,
            ),
            (const FunctionData f) => data.match!(
                (const FunctionData g) => g.params.length == f.params.length && g.mutables == f.mutables
                    && f.params.length.iota.all!(i => couldBe(f.params[i], g.params[i], params, injects))
                    && couldBe(f.ret, g.ret, params, injects),
                _ => false,
            ),
            (const NominalData n) => data.match!(
                (const NominalData m) => m.decl == n.decl
                    ? n.args.length.iota.all!(i => couldBe(n.args[i], m.args[i], params, injects))
                    : injects && _typing.members.get(n.decl, null).any!(member => declOf(member) == m.decl),
                _ => false,
            ),
            _ => false,
        );
    }

    /// A literal of a primitive type, or a negated number literal.
    private static bool isLiteral(const Expr arg)
    {
        return arg.kind.match!(
            (const BoolLiteral _) => true,
            (const IntLiteral _) => true,
            (const FloatLiteral _) => true,
            (const StringLiteral _) => true,
            (const CharLiteral _) => true,
            (const UnitLiteral _) => true,
            (const UnaryExpr unary) => unary.op == UnaryOp.Minus && unary.operand.kind.match!(
                (const IntLiteral _) => true,
                (const FloatLiteral _) => true,
                _ => false,
            ),
            _ => false,
        );
    }

    /// An argument that isn't synthesized to choose an overload, because its type depends on where
    /// it goes, or because it can be compared with a parameter as it's written: a literal, `None`,
    /// `[]`, a lambda, a generic or overloaded name, or an array, tuple or `Some` of those.
    private bool isShaped(const Expr arg)
    {
        if (isUntyped(arg)) return true;
        return arg.kind.match!(
            (const BoolLiteral _) => true,
            (const FloatLiteral _) => true,
            (const StringLiteral _) => true,
            (const CharLiteral _) => true,
            (const UnitLiteral _) => true,
            (const ArrayLiteral literal) => literal.elements.all!(e => isShaped(e)),
            (const TupleLiteral literal) => literal.elements.all!(e => isShaped(e)),
            (const SomeExpr some) => isShaped(*some.value),
            _ => false,
        );
    }

    /// How well `arg`, one that `isShaped`, fits `param`, which may still mention `params`.
    private Fit shapeFit(const Expr arg, Type param, const(TypeParam)[] params)
    {
        if (_types.mentionsError(param)) return Fit.exact;
        if (param == _types.any) return Fit.converted;
        auto bare = _types[param].match!((const TypeParamData p) => params.canFind!(q => q.id == p.param), _ => false);
        auto members = _declarer.membersOf(param);
        bool sumHas(bool delegate(Type) test) => members.any!(m => test(m));
        // Inside an option, the value is promoted, which is a step more.
        Fit inOption(Fit delegate(Type) inner)
        {
            if (!_types.isOption(param)) return inner(param);
            return inner(_types.optionInner(param)).then(1);
        }

        if (isIntLiteral(arg))
        {
            if (bare || param == _types.int_) return Fit.exact;
            // A step for each layer, one for an injection, and one for taking a type other than `Int`.
            auto steps = 0;
            auto core = param;
            for (; _types.isOption(core) || _types.isErrorUnion(core); steps++)
            {
                core = _types.isOption(core) ? _types.optionInner(core) : _types.successOf(core);
            }
            if (params.canFind!(p => core == _declarer.parameterType(p))) return Fit.promoted(max(steps, 1));
            if (_declarer.isSum(core))
            {
                auto numbers = _declarer.membersOf(core).filter!(m => isNumeric(m)).array;
                if (numbers.empty) return Fit.none;
                steps++;
                core = numbers.canFind(_types.int_) ? _types.int_ : numbers[0];
            }
            if (!isNumeric(core)) return Fit.none;
            return Fit.promoted(steps + (core == _types.int_ ? 0 : 1));
        }
        if (isLambda(arg))
        {
            auto lambda = arg.kind.match!((const Lambda l) => l, (_) => Lambda.init);
            if (bare) return lambda.params.all!(p => p.annotated) ? Fit.exact : Fit.none;
            bool annotationsFit(const FunctionData f)
            {
                foreach (i, p; lambda.params)
                {
                    if (!p.annotated) continue;
                    auto annotated = quietlyResolved(p.type);
                    auto fits = mentionsAny(f.params[i], params) ? couldBe(f.params[i], annotated, params) : annotated == f.params[i];
                    if (!fits && annotated != _types.error) return false;
                }
                return true;
            }
            return inOption((Type t) => _types[t].match!(
                (const FunctionData f) => f.params.length == lambda.params.length && annotationsFit(f) ? Fit.exact : Fit.none,
                _ => Fit.none,
            ));
        }
        if (auto candidates = arg.id in _resolutions.overloads)
        {
            if (bare) return Fit.none;
            return inOption((Type t) => _types[t].match!(
                (const FunctionData f) => candidates.groups.joiner.any!(c => signatureOf(c).params.length == f.params.length)
                    ? Fit.exact : Fit.none,
                _ => Fit.none,
            ));
        }
        auto generic = isUntyped(arg) ? genericNamed(arg) : Generic.init;
        if (generic.found)
        {
            if (bare) return Fit.converted;
            return inOption((Type t) {
                if (_types.isFunction(generic.type)) return _types.isFunction(t)
                    && signatureOf(t).params.length == signatureOf(generic.type).params.length ? Fit.exact : Fit.none;
                auto decl = declOf(t);
                return decl == declOf(generic.member) || generic.owner != Type.init && decl == declOf(generic.owner)
                    ? Fit.exact : Fit.none;
            });
        }
        return arg.kind.match!(
            (const NoneLiteral _) => bare || _types.isOption(param) || sumHas(m => _types.isOption(m)) ? Fit.converted : Fit.none,
            (const ArrayLiteral literal) {
                if (literal.elements.length == 0)
                {
                    auto array = _types.isArray(param) || _types.isOption(param) && _types.isArray(_types.optionInner(param));
                    return bare || array || sumHas(m => _types.isArray(m)) ? Fit.converted : Fit.none;
                }
                if (bare) return Fit.exact;
                if (sumHas(m => _types.isArray(m))) return Fit.converted;
                return inOption((Type t) => _types.isArray(t)
                    ? literal.elements.map!(e => shapeFit(e, _types.arrayElement(t), params)).fold!min(Fit.exact)
                    : Fit.none);
            },
            (const TupleLiteral literal) {
                if (bare) return Fit.exact;
                if (sumHas(m => _types.isTuple(m))) return Fit.converted;
                return inOption((Type t) {
                    if (!_types.isTuple(t) || _types.tupleElements(t).length != literal.elements.length) return Fit.none;
                    auto elements = _types.tupleElements(t);
                    return literal.elements.length.iota.map!(i => shapeFit(literal.elements[i], elements[i], params))
                        .fold!min(Fit.exact);
                });
            },
            (const SomeExpr some) {
                if (bare) return Fit.exact;
                if (_types.isOption(param)) return shapeFit(*some.value, _types.optionInner(param), params);
                return sumHas(m => _types.isOption(m)) ? Fit.converted : Fit.none;
            },
            (const OkExpr ok) {
                if (bare) return Fit.converted;
                return _types.isErrorUnion(param) ? Fit.exact : Fit.none;
            },
            _ => literalType(arg) != Type.init ? typedFit(literalType(arg), param, params, false)
                : assert(0, "only an argument that isShaped is fitted by its shape"),
        );
    }

    /// The type of a literal that has only one, or `Type.init` for anything else.
    private Type literalType(const Expr arg)
    {
        return arg.kind.match!(
            (const BoolLiteral _) => _types.bool_,
            (const FloatLiteral _) => _types.float_,
            (const StringLiteral _) => _types.string_,
            (const CharLiteral _) => _types.char_,
            (const UnitLiteral _) => _types.unit,
            _ => Type.init,
        );
    }

    /// The type synthesis gives an argument made only of literals, or `Type.init` when part of it
    /// has none of its own. An array's elements join as they do there, so `[Some(1), None]` is an
    /// `[Int?]`.
    private Type defaultType(const Expr arg)
    {
        if (isIntLiteral(arg)) return _types.int_;
        Type[] each(const(Expr)[] elements) => elements.map!(e => defaultType(e)).array;
        Type joined(Type a, Type b)
        {
            if (a == Type.init || b == Type.init) return Type.init;
            if (isAssignable(a, b)) return b;
            if (isAssignable(b, a)) return a;
            if (a == _types.none && !_types.isOption(b)) return _types.option(b);
            if (b == _types.none && !_types.isOption(a)) return _types.option(a);
            return Type.init;
        }
        return arg.kind.match!(
            (const NoneLiteral _) => _types.none,
            (const ArrayLiteral literal) {
                auto elements = each(literal.elements);
                if (elements.length == 0) return Type.init;
                auto element = elements.fold!((a, b) => joined(a, b));
                return element == Type.init || element == _types.none ? Type.init : _types.array(element);
            },
            (const TupleLiteral literal) {
                auto elements = each(literal.elements);
                return elements.canFind(Type.init) ? Type.init : _types.tuple(elements);
            },
            (const SomeExpr some) {
                auto inner = defaultType(*some.value);
                return inner == Type.init || inner == _types.none ? Type.init : _types.option(inner);
            },
            _ => literalType(arg),
        );
    }

    /// The one of `trials` that beats each of the others, reporting it when there isn't one.
    private Id!FunctionDecl bestTrial(const(Trial)[] trials, Span span, string spelled, bool reportable)
    {
        auto winners = trials.filter!(t => trials.all!(u => u.func == t.func || beats(t, u))).array;
        if (winners.length == 1) return winners[0].func;
        if (!reportable) return Id!FunctionDecl.init;
        auto unbeaten = trials.filter!(t => !trials.any!(u => beats(u, t))).array;
        auto tied = unbeaten.map!(t => "`" ~ overloadLabel(t.func) ~ "`").array;
        if (unbeaten.any!(t => t.awaitsLambda))
        {
            _collector.reportError(DiagnosticCode.AmbiguousOverload, span,
                ("This call fits more than one `%s`: %s, and only what a lambda here returns would say which bounds hold, "
                    ~ "but they'd give the lambda different types; annotate it, as in `(x: Int): Int => ...`")
                    .format(spelled, tied.join(" and ")));
            return Id!FunctionDecl.init;
        }
        _collector.reportError(DiagnosticCode.AmbiguousOverload, span,
            "This call fits more than one `%s` equally well: %s; convert an argument, or annotate it, to choose one"
                .format(spelled, tied.join(" and ")));
        return Id!FunctionDecl.init;
    }

    /// Whether `a` fits a call better than `b`: at least as well for every argument and better for
    /// one, or, when they fit every argument alike, by being the more specific function.
    private bool beats(const Trial a, const Trial b)
    {
        bool better, worse;
        foreach (i; 0 .. a.fits.length)
        {
            if (a.fits[i] > b.fits[i]) better = true;
            if (a.fits[i] < b.fits[i]) worse = true;
        }
        if (better || worse) return better && !worse;
        auto aGeneric = isGenericFunction(a.func), bGeneric = isGenericFunction(b.func);
        if (aGeneric != bGeneric) return bGeneric;
        if (!aGeneric) return false;
        auto aTakes = accepts(a.func, b.func), bTakes = accepts(b.func, a.func);
        if (aTakes != bTakes) return bTakes;
        // Bounds that only a lambda's result would decide can't say the function fits better.
        return asksForMore(a.func, b.func) && !a.awaitsLambda;
    }

    /// Whether `a` and `b` take the same parameters and `a`'s bounds require every function `b`'s
    /// do, and one more at least.
    private bool asksForMore(Id!FunctionDecl a, Id!FunctionDecl b)
    {
        return signatureOf(a).mutables == signatureOf(b).mutables && requiresAll(a, b) && !requiresAll(b, a);
    }

    /// Whether `a` and `b` take the same parameters and each function `b`'s bounds require is one
    /// `a`'s do: of the same name and, with `a`'s type parameters read as `b`'s, the same signature.
    private bool requiresAll(Id!FunctionDecl a, Id!FunctionDecl b)
    {
        Id!TypeParam[Id!TypeParam] renamed;
        if (!sameParameters(a, b, renamed)) return false;
        auto aTypeParams = _resolutions.typeParamsOf(a);
        auto bTypeParams = _resolutions.typeParamsOf(b);
        auto supplied = _resolutions.boundFunctions.get(a, null);

        // A type parameter only the bounds mention is paired by the functions that are, so an
        // earlier pairing that a later function can't keep is tried again.
        bool found(const(Id!FunctionDecl)[] needed, Id!TypeParam[Id!TypeParam] pairs)
        {
            if (needed.length == 0) return true;
            auto wanted = _resolutions.declarations.functions[needed[0]].name;
            foreach (s; supplied)
            {
                if (_resolutions.declarations.functions[s].name != wanted) continue;
                auto attempt = pairs.dup;
                if (sameUpToRenaming(_typing.symbolTypes[SymbolId(s)], _typing.symbolTypes[SymbolId(needed[0])],
                    aTypeParams, bTypeParams, attempt) && found(needed[1 .. $], attempt)) return true;
            }
            return false;
        }
        return found(_resolutions.boundFunctions.get(b, null), renamed);
    }

    private bool isGenericFunction(Id!FunctionDecl f)
    {
        return _resolutions.typeParamsOf(f).length > 0;
    }

    /// Whether the generic `wider` takes every list of arguments that `narrower` does: its type
    /// parameters can be bound so its parameters are exactly `narrower`'s.
    private bool accepts(Id!FunctionDecl wider, Id!FunctionDecl narrower)
    {
        auto widerParams = signatureOf(wider).params;
        auto narrowerParams = signatureOf(narrower).params;
        auto typeParams = _resolutions.typeParamsOf(wider);
        Substitution bound;
        foreach (i, param; widerParams) bindParams(param, narrowerParams[i], typeParams, bound);
        return widerParams.length.iota.all!(i => _types.substitute(widerParams[i], bound) == narrowerParams[i]);
    }

    /// `type` resolved without reporting anything, to look ahead at a type that's resolved again,
    /// and reported, where it's checked.
    private Type quietlyResolved(const TypeExpr type)
    {
        auto collector = _collector;
        _collector = new Collector;
        scope (exit) _collector = collector;
        return _declarer.resolveType(type);
    }

    private FunctionData signatureOf(Id!FunctionDecl f)
    {
        return signatureOf(_typing.symbolTypes[SymbolId(f)]);
    }

    private FunctionData signatureOf(Type functionType)
    {
        return _types[functionType].match!((const FunctionData data) => data, _ => FunctionData.init);
    }

    /// `f(Int, String)`, or `lib.f<T: Json>(mutable T)` for a function of another module.
    private string overloadLabel(Id!FunctionDecl f, bool qualified = false)
    {
        auto decl = _resolutions.declarations.functions[f];
        auto signature = signatureOf(f);
        auto params = signature.params.length.iota
            .map!(i => (signature.isMutable(i) ? "mutable " : "") ~ _types.describe(signature.params[i])).join(", ");
        string bounded(const TypeParam p)
        {
            auto bounds = _typing.bounds.get(p.id, null).filter!(b => b.valid).map!(b => _declarer.describe(b)).array;
            return bounds.length == 0 ? p.name : p.name ~ ": " ~ bounds.join(" & ");
        }
        auto typeParams = decl.typeParams.length == 0 ? "" : "<" ~ decl.typeParams.map!(p => bounded(p)).join(", ") ~ ">";
        auto owner = qualified ? _resolutions.declarations.functionModules[f] ~ "." : "";
        return owner ~ decl.name ~ typeParams ~ "(" ~ params ~ ")";
    }

    private void reportNoOverload(Span span, string spelled, const(Trial[])[] groups)
    {
        string[] lines;
        foreach (g, group; groups)
        {
            foreach (trial; group) lines ~= "%s %s".format(overloadLabel(trial.func, g > 0), trial.problem);
        }
        _collector.reportError(DiagnosticCode.NoMatchingOverload, span,
            "No `%s` takes these arguments:\n    %-(%s\n    %)".format(spelled, lines));
    }

    /// Reports a call that functions of more than one imported module fit.
    private void reportImportedOverloads(Span span, string spelled, const(string)[] modules)
    {
        _collector.reportError(DiagnosticCode.AmbiguousName, span,
            "This call fits a `%s` in more than one imported module (%s); qualify it, as in `%s.%s(...)`"
                .format(spelled, modules.join(", "), modules[0], spelled));
    }

    /// Gives each argument of a call that couldn't be chosen a type, without reporting it again.
    private void typeUnchosen(const CallExpr call, const(Type)[] typed, BodyContext ctx)
    {
        foreach (i, arg; call.args)
        {
            if (typed[i] == Type.init) checkArgument(arg, _types.error, ctx);
        }
    }

    /// An overloaded function used as a value, chosen by the function type it's expected to be.
    private Type overloadedValue(const Expr name, const Candidates candidates, Type expected, Site site)
    {
        auto spelled = spelling(name);
        if (expected == _types.error) return _types.error;
        if (expected == Type.init || !_types.isFunction(expected))
        {
            reportOverloadedValue(name);
            return _types.error;
        }

        const(Id!FunctionDecl)[][] matching;
        foreach (group; candidates.groups)
        {
            matching ~= group.filter!(f => valueFits(f, typeArgsOf(name), expected, site)).array;
        }
        const(Id!FunctionDecl)[] fits = matching[0];
        if (fits.length == 0)
        {
            auto imported = agreeing!(f => f)(matching[1 .. $].filter!(g => g.length > 0).array);
            if (imported.length > 1)
            {
                auto modules = importsOf(candidates, imported);
                _collector.reportError(DiagnosticCode.AmbiguousName, name.span,
                    "A `%s` in more than one imported module (%s) is a `%s`; qualify it, as in `%s.%s`"
                        .format(spelled, modules.join(", "), _types.describe(expected), modules[0], spelled));
                return _types.error;
            }
            if (imported.length == 1) fits = imported[0];
        }
        // A function that isn't generic is more specific than one that is.
        if (fits.length > 1 && fits.any!(f => !isGenericFunction(f))) fits = fits.filter!(f => !isGenericFunction(f)).array;
        if (fits.length > 1) fits = fits.filter!(f => !fits.any!(g => asksForMore(g, f))).array;
        if (fits.length != 1)
        {
            auto all = candidates.groups.joiner.map!(f => "`" ~ overloadLabel(f) ~ "`").array;
            _collector.reportError(fits.length == 0 ? DiagnosticCode.NoMatchingOverload : DiagnosticCode.AmbiguousOverload,
                name.span, "%s `%s` is a `%s`; there are %s".format(fits.length == 0 ? "No" : "More than one", spelled,
                    _types.describe(expected), all.join(", ")));
            return _types.error;
        }
        _typing.chosenSymbols[name.id] = SymbolId(fits[0]);
        _siblings[name.id] = siblingsOf(candidates, fits[0]);
        return namedValue(name, SymbolId(fits[0]), expected, site);
    }

    /// Whether the function `f`, given the type arguments `written`, can be a value of `expected`.
    private bool valueFits(Id!FunctionDecl f, const(TypeExpr)[] written, Type expected, Site site)
    {
        auto params = _resolutions.typeParamsOf(f);
        settleResult(f, false);
        auto type = _typing.symbolTypes[SymbolId(f)];
        if (written.length > 0 && written.length != _resolutions.declarations.functions[f].typeParams.length) return false;
        Substitution bound;
        foreach (i, w; written) bound[params[i].id] = quietlyResolved(w);
        bindParams(type, expected, params, bound);
        auto conformance = conformanceOf(f, bound, site);
        if (params.any!(p => p.id !in bound) || !conformance.holds) return false;
        return _types.substitute(type, bound) == expected;
    }

    private void reportOverloadedValue(const Expr name)
    {
        auto spelled = spelling(name);
        // One whose result is being worked out has no type to show yet.
        auto known = (name.id in _resolutions.overloads).groups.joiner.filter!((f) {
            settleResult(f, false);
            return _resultStates.get(f, ResultState.settled) == ResultState.settled;
        });
        _collector.reportError(DiagnosticCode.AmbiguousOverload, name.span,
            "`%s` is overloaded, so as a value it needs a function type to choose by%s".format(spelled, known.empty
                ? "" : ", as in `val f: %s = %s`".format(_types.describe(_typing.symbolTypes[SymbolId(known.front)]), spelled)));
    }

    /// Reports two functions of one name in `mod` that take the same parameters, and notes which
    /// functions are overloaded.
    private void checkOverloads(const Module mod)
    {
        Id!FunctionDecl[][string] seen;
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl f) {
                    // A second `main` is reported by name resolution.
                    if (f.name == "main") return;
                    auto earlier = seen.get(f.name, null);
                    seen[f.name] ~= f.id;
                    if (earlier.length == 0) return;
                    _typing.overloaded[f.id] = true;
                    foreach (e; earlier) _typing.overloaded[e] = true;
                    foreach (e; earlier)
                    {
                        if (reportDuplicateOverload(e, f)) break;
                    }
                },
                (_) {},
            );
        }
    }

    /// Reports each function the module `m` forwards that takes the same parameters as one of its
    /// own or one forwarded before it, since its importers choose among them all as one module's.
    private void checkForwardedOverloads(string m)
    {
        auto forwarded = m in _resolutions.forwards;
        if (forwarded is null) return;
        foreach (name; (*forwarded).keys.sort)
        {
            auto seen = _resolutions.publicFunctions(m, name);
            foreach (forward; (*forwarded)[name])
            {
                auto brought = _resolutions.publicFunctions(forward.origin, name);
                reportForwardedDuplicate(m, seen, brought, forward);
                seen ~= brought;
            }
        }
    }

    private void reportForwardedDuplicate(string m, const(Id!FunctionDecl)[] seen, const(Id!FunctionDecl)[] brought, Forward forward)
    {
        foreach (later; brought)
        {
            foreach (earlier; seen)
            {
                if (!sameParameters(earlier, later) || asksForMore(earlier, later) || asksForMore(later, earlier)) continue;
                auto home = _resolutions.declarations.functionModules[earlier];
                _collector.reportError(DiagnosticCode.DuplicateOverload, forward.span,
                    ("`%s` can't be forwarded: %s takes the same parameter types, so a module importing this one "
                        ~ "couldn't choose between them%s").format(overloadLabel(later, true),
                            home == m ? "this module's `" ~ overloadLabel(earlier) ~ "`" : "`" ~ overloadLabel(earlier, true)
                                ~ "`, forwarded too,",
                            _resolutions.boundFunctions.get(earlier, null).length + _resolutions.boundFunctions.get(later, null).length == 0
                                ? "" : "; bounds only tell two functions apart when one asks for everything the other does, and more"));
                return;
            }
        }
    }

    /// Reports `later` if it can't be told apart from `earlier`, an overload declared before it.
    private bool reportDuplicateOverload(Id!FunctionDecl earlier, const FunctionDecl later)
    {
        auto first = _resolutions.declarations.functions[earlier];
        string problem;
        // Lowering expands `assert` and `expect` from what's written, telling their forms apart by their arguments.
        auto shownForms = (later.name == "assert" || later.name == "expect") && first.params.length != later.params.length;
        if (later.testName !is null)
        {
            _collector.reportError(DiagnosticCode.DuplicateDeclaration, later.nameSpan,
                "There's already a test named \"%s\" in this module".format(later.testName));
            return true;
        }
        if (first.kind == FunctionKind.intrinsic && later.kind == FunctionKind.intrinsic && !shownForms)
        {
            problem = "`%s` is already an intrinsic, and an intrinsic's name says which one it is";
        }
        else if (first.kind == FunctionKind.native && later.kind == FunctionKind.native && first.symbol == later.symbol)
        {
            problem = "`%s` already binds the C symbol `" ~ later.symbol ~ "`; give this one another with `native(\"...\")`";
        }
        else if (sameParameters(earlier, later.id) && !asksForMore(earlier, later.id) && !asksForMore(later.id, earlier))
        {
            auto a = signatureOf(earlier), b = signatureOf(later.id);
            problem = "`%s` already takes `" ~ overloadLabel(earlier)[first.name.length .. $] ~ "`; overloads need different parameter types"
                ~ (a.mutables == b.mutables ? "" : ", and `mutable` alone doesn't make one")
                ~ (_resolutions.boundFunctions.get(earlier, null).length + _resolutions.boundFunctions.get(later.id, null).length == 0
                    ? "" : ", and bounds only tell two functions apart when one asks for everything the other does, and more");
        }
        if (problem is null) return false;
        _collector.reportError(DiagnosticCode.DuplicateOverload, later.nameSpan, problem.format(later.name));
        return true;
    }

    /// Whether `a` and `b` take the same parameter types, apart from what they name their type
    /// parameters and which parameters are `mutable`.
    private bool sameParameters(Id!FunctionDecl a, Id!FunctionDecl b)
    {
        Id!TypeParam[Id!TypeParam] renamed;
        return sameParameters(a, b, renamed);
    }

    /// Leaves in `renamed` which of `b`'s type parameters each of `a`'s is.
    private bool sameParameters(Id!FunctionDecl a, Id!FunctionDecl b, ref Id!TypeParam[Id!TypeParam] renamed)
    {
        auto aParams = signatureOf(a).params;
        auto bParams = signatureOf(b).params;
        if (aParams.length != bParams.length) return false;
        auto aTypeParams = _resolutions.typeParamsOf(a);
        auto bTypeParams = _resolutions.typeParamsOf(b);
        return aParams.length.iota.all!(i => sameUpToRenaming(aParams[i], bParams[i], aTypeParams, bTypeParams, renamed));
    }

    private bool sameUpToRenaming(Type a, Type b, const(TypeParam)[] aParams, const(TypeParam)[] bParams,
        ref Id!TypeParam[Id!TypeParam] renamed)
    {
        if (a == b) return true;
        bool same(Type x, Type y) => sameUpToRenaming(x, y, aParams, bParams, renamed);
        bool allSame(const(Type)[] xs, const(Type)[] ys) => xs.length == ys.length && xs.length.iota.all!(i => same(xs[i], ys[i]));
        auto other = _types[b];
        return _types[a].match!(
            (const TypeParamData p) => other.match!(
                (const TypeParamData q) {
                    if (!aParams.canFind!(t => t.id == p.param) || !bParams.canFind!(t => t.id == q.param)) return false;
                    if (auto existing = p.param in renamed) return *existing == q.param;
                    if (renamed.byValue.canFind(q.param)) return false;
                    renamed[p.param] = q.param;
                    return true;
                },
                _ => false,
            ),
            (const OptionData o) => _types.isOption(b) && same(o.inner, _types.optionInner(b)),
            (const ErrorUnionData u) => _types.isErrorUnion(b) && same(u.success, _types.successOf(b)) && same(u.error, _types.errorOf(b)),
            (const ErrorListData l) => _types.isErrorList(b) && allSame(l.members, _types.listed(b)),
            (const ArrayData x) => _types.isArray(b) && same(x.element, _types.arrayElement(b)),
            (const TupleData t) => _types.isTuple(b) && allSame(t.elements, _types.tupleElements(b)),
            (const FunctionData f) => other.match!(
                (const FunctionData g) => f.mutables == g.mutables && allSame(f.params, g.params) && same(f.ret, g.ret),
                _ => false,
            ),
            (const NominalData n) => other.match!(
                (const NominalData m) => n.decl == m.decl && allSame(n.args, m.args),
                _ => false,
            ),
            _ => false,
        );
    }

    /// How many bounds deep a search for a conformance goes before it's given up, which only a
    /// search that keeps reaching larger types gets to.
    private enum boundDepthLimit = 32;

    /// A type that has to satisfy an interface, while that's being looked into.
    private struct Goal
    {
        Id!InterfaceDecl decl;
        Type self;
        const(Type)[] args;
    }

    /// What a search for conformances found.
    private struct Conformance
    {
        /// The function found for each function the bounds declare. One whose bound wasn't looked
        /// into, because its type is unknown or already an error, has no `func`.
        Witness[] witnesses;
        /// Why the first bound that doesn't hold doesn't, worded to follow the function's name, or null.
        string failure;
        /// Whether it failed by going too deep.
        bool tooDeep;
        /// Whether a bound is still undecided: its type isn't known, or more than one function
        /// could say what a type argument of its interface is.
        bool pending;
        /// Whether it failed because more than one function fits as well as the best.
        bool ambiguous;

        bool holds() const => failure is null && !pending;
    }

    /// Looks for what makes the types in `bound` satisfy the bounds of `func`'s type parameters, as
    /// calls from `site` would find it. A bound whose type isn't in `bound` yet is left pending, and
    /// one whose interface has type arguments that aren't known yet binds them from the function
    /// found. `stack` holds the goals this search is already inside. With `defer`, the witnesses
    /// are followed by the answers to `func`'s queries.
    private Conformance conformanceOf(Id!FunctionDecl func, ref Substitution bound, Site site, const(Goal)[] stack = null,
        Deferral* defer = null)
    {
        auto params = _resolutions.typeParamsOf(func);
        if (!bound.byValue.any!(v => mentionsAny(v, params))) return conformanceOf(func, params, null, null, bound, site, stack, defer);

        // In a call from `func`'s own body, what `bound` says is in terms of the same type
        // parameters it binds, and the search substitutes again for the ones it finds. So the
        // search binds stand-ins for them instead, and what it finds is copied back.
        auto standIns = params.map!(p => TypeParam(_ids.next!TypeParam, p.name, p.span, cast(TypeExpr[]) p.bounds)).array;
        Substitution renaming;
        Substitution renamed;
        foreach (i, param; params)
        {
            renaming[param.id] = _types.parameter(standIns[i].id, param.name);
            if (auto known = param.id in bound) renamed[standIns[i].id] = *known;
        }
        auto result = conformanceOf(func, params, standIns, renaming, renamed, site, stack, defer);
        foreach (i, param; params)
        {
            if (param.id !in bound && standIns[i].id in renamed) bound[param.id] = renamed[standIns[i].id];
        }
        return result;
    }

    /// `conformanceOf`, with each of `func`'s type parameters `params` standing for the one
    /// `renaming` gives in `bound`, which are `open`; with no `renaming`, they stand for themselves.
    private Conformance conformanceOf(Id!FunctionDecl func, const(TypeParam)[] params, const(TypeParam)[] open,
        Substitution renaming, ref Substitution bound, Site site, const(Goal)[] stack, Deferral* defer)
    {
        Conformance result;
        auto supplied = _resolutions.boundFunctions.get(func, null);
        auto asked = defer is null ? null : _typing.queries.get(func, null);
        if (supplied.length == 0 && asked.length == 0) return result;
        if (renaming.length == 0) open = params;
        Id!TypeParam key(Id!TypeParam param)
        {
            if (auto standIn = param in renaming) return _types[*standIn].match!((const TypeParamData p) => p.param, _ => param);
            return param;
        }
        Type inTermsOfOpen(Type type) => _types.substitute(_types.substitute(type, renaming), bound);
        result.witnesses = new Witness[supplied.length];
        auto decided = new bool[supplied.length];

        for (auto progress = true; progress;)
        {
            progress = false;
            size_t end;
            for (size_t start = 0; start < supplied.length; start = end)
            {
                auto first = _resolutions.requirements[supplied[start]];
                end = start + 1;
                while (end < supplied.length && _resolutions.requirements[supplied[end]].param == first.param
                    && _resolutions.requirements[supplied[end]].bound == first.bound) end++;
                if (decided[start]) continue;
                auto self = key(first.param) in bound;
                if (self is null) continue;
                auto declared = _typing.bounds[first.param][first.bound];
                auto goal = Goal(declared.decl, *self, declared.args.map!(a => inTermsOfOpen(a)).array);
                // What's already an error has been reported, and anything satisfies it.
                if (_types.mentionsError(goal.self) || goal.args.any!(a => _types.mentionsError(a)))
                {
                    decided[start .. end] = true;
                    continue;
                }
                auto found = satisfy(goal, open, bound, site, stack, defer);
                if (found.pending) continue;
                if (found.tooDeep) return found;
                if (found.failure !is null)
                {
                    auto wanted = Bound(goal.decl, declared.args.map!(a => inTermsOfOpen(a)).array);
                    auto hidden = _resolutions.hiddenParams.get(func, null).canFind!(p => p.id == first.param);
                    result.failure = (hidden ? "needs %2$s, and `%3$s` isn't one: %4$s" : "needs `%1$s` to be %2$s, and `%3$s` isn't one: %4$s")
                        .format(_resolutions.declarations.typeParams[first.param].name, withArticle(_declarer.describe(wanted)),
                            _types.describe(goal.self), found.failure);
                    result.tooDeep = found.tooDeep;
                    result.ambiguous = found.ambiguous;
                    return result;
                }
                result.witnesses[start .. end] = found.witnesses[];
                decided[start .. end] = true;
                progress = true;
            }
        }
        result.pending = decided.canFind(false);
        if (asked.length > 0 && !result.pending && open.all!(p => (p.id in bound) !is null))
        {
            Substitution whole;
            foreach (param; params) whole[param.id] = bound[key(param.id)];
            result.witnesses ~= answersTo(asked, whole, site, stack, defer);
        }
        return result;
    }

    /// Looks for the function behind each function of `goal`'s interface, which is what it is for
    /// `goal.self` to satisfy it. `open` are the type parameters `goal.args` may still mention
    /// unbound, which the functions found bind in `bound`. `given`, when there's no interface, are
    /// the functions to look for instead.
    ///
    /// With `defer`, a goal on a type parameter of the function the search is in that its bounds
    /// don't meet is asked of that function's caller: the witnesses found are its query's slots.
    private Conformance satisfy(const Goal goal, const(TypeParam)[] open, ref Substitution bound, Site site,
        const(Goal)[] stack, Deferral* defer = null, const(Request)[] given = null)
    {
        Conformance result;
        string described(const Goal g) => g.decl.isValid
            ? "`%s: %s`".format(_types.describe(g.self), _declarer.describe(Bound(g.decl, g.args.dup)))
            : "`%s` looped over by index".format(_types.describe(g.self));
        if (stack.canFind(goal))
        {
            result.failure = "that would need %s to hold already".format(described(goal));
            return result;
        }
        if (stack.length >= boundDepthLimit)
        {
            result.tooDeep = true;
            result.failure = "has bounds that need more than %s others in turn, each for a larger type: %-(%s, then %), and so on"
                .format(boundDepthLimit, stack[0 .. 4].map!(g => described(g)));
            return result;
        }

        auto askable = defer !is null && isOwnParameter(goal.self, defer.owner);
        Conformance asking()
        {
            Conformance asked;
            auto requests = given !is null ? given.dup : requestsOf(goal, bound);
            auto slot = ask(defer, Query(goal.decl, goal.self, goal.args.dup, requests, defer.asker));
            if (slot == size_t.max)
            {
                asked.failure = "asks too many questions of its callers";
                return asked;
            }
            foreach (i; 0 .. requests.length) asked.witnesses ~= Witness(Id!FunctionDecl.init, null, null, slot + i);
            return asked;
        }

        auto functions = given !is null ? null : _resolutions.declarations.interfaces[goal.decl].functions;
        foreach (i; 0 .. given !is null ? given.length : functions.length)
        {
            Request request;
            if (given !is null) request = cast() given[i];
            else
            {
                auto asked = Bound(goal.decl, goal.args.map!(a => _types.substitute(a, bound)).array);
                request = Request(functions[i].name,
                    _types.substitute(symbolType(SymbolId(functions[i].id)), _declarer.substitutionOf(asked, goal.self)));
            }
            auto found = witnessFor(request.name, signatureOf(request.wanted), open, bound, site, stack ~ goal, defer);
            if (askable && !found.pending && !found.ambiguous && !found.tooDeep && (!found.holds || !settled(found.witnesses[0])))
            {
                return asking();
            }
            if (!found.holds)
            {
                found.witnesses = null;
                return found;
            }
            result.witnesses ~= found.witnesses;
        }
        return result;
    }

    /// What each function of `goal`'s interface has to be, with what `bound` says.
    private Request[] requestsOf(const Goal goal, ref Substitution bound)
    {
        auto asked = Bound(goal.decl, goal.args.map!(a => _types.substitute(a, bound)).array);
        return _resolutions.declarations.interfaces[goal.decl].functions
            .map!(f => Request(f.name, _types.substitute(symbolType(SymbolId(f.id)), _declarer.substitutionOf(asked, goal.self))))
            .array;
    }

    /// How many queries a function can ask, which only one whose questions keep growing reaches.
    private enum queryLimit = 64;

    /// Whether `type` is one of `owner`'s own type parameters.
    private bool isOwnParameter(Type type, Id!FunctionDecl owner)
    {
        if (!owner.isValid) return false;
        return _types[type].match!(
            (const TypeParamData p) => _resolutions.typeParamsOf(owner).canFind!(q => q.id == p.param),
            _ => false,
        );
    }

    /// The first of the slots `query` has among the witnesses of each use of `defer.owner`,
    /// adding it to the owner's queries if it's new; `size_t.max` when it has too many already.
    private size_t ask(Deferral* defer, Query query)
    {
        bool same(const Query a, const Query b) => a.decl == b.decl && a.self == b.self && a.args == b.args
            && a.requests.length == b.requests.length
            && a.requests.length.iota.all!(i => a.requests[i].name == b.requests[i].name && a.requests[i].wanted == b.requests[i].wanted);
        auto slot = _resolutions.boundFunctions.get(defer.owner, null).length;
        auto asked = _typing.queries.get(defer.owner, null);
        foreach (existing; asked)
        {
            if (same(existing, query)) return slot;
            slot += existing.requests.length;
        }
        if (asked.length >= queryLimit) return size_t.max;
        _typing.queries[defer.owner] ~= query;
        defer.changed = true;
        return slot;
    }

    /// Whether `witness` holds whatever answers the instance it's in was given.
    private bool settled(const Witness witness)
    {
        if (witness.isSlot || !witness.func.isValid) return false;
        auto required = min(_resolutions.boundFunctions.get(witness.func, null).length, witness.witnesses.length);
        return witness.witnesses[0 .. required].all!(w => settled(w));
    }

    private bool settledAttempt(const Attempt attempt)
    {
        auto required = min(_resolutions.boundFunctions.get(attempt.trial.func, null).length, attempt.witnesses.length);
        return attempt.witnesses[0 .. required].all!(w => settled(w));
    }

    /// The answers to `asked`, the queries of a function whose type parameters stand for what
    /// `bound` says, from `site`: each query's witnesses, or as many that never hold.
    private Witness[] answersTo(const(Query)[] asked, ref Substitution bound, Site site, const(Goal)[] stack, Deferral* defer)
    {
        Witness[] found;
        foreach (query; asked)
        {
            auto goal = Goal(query.decl, _types.substitute(query.self, bound), query.args.map!(a => _types.substitute(a, bound)).array);
            auto requests = query.requests.map!(r => Request(r.name, _types.substitute(r.wanted, bound))).array;
            auto asker = defer.asker;
            defer.asker = query.asker;
            scope (exit) defer.asker = asker;
            Substitution none;
            auto answer = satisfy(goal, null, none, site, stack, defer, requests);
            if (answer.holds)
            {
                found ~= answer.witnesses;
                continue;
            }
            if (answer.ambiguous || answer.tooDeep) reportAnswer(query.asker, goal, answer, defer);
            found ~= new Witness[query.requests.length];
        }
        return found;
    }

    /// Reports an answer to a query that's neither yes nor no, at the use the search is for.
    private void reportAnswer(Id!FunctionDecl asker, const Goal goal, const Conformance answer, const Deferral* defer)
    {
        if (!defer.reporting) return;
        auto what = goal.decl.isValid
            ? "whether `%s` is %s".format(_types.describe(goal.self), withArticle(_declarer.describe(Bound(goal.decl, goal.args.dup))))
            : "whether `for` can loop over `%s` by index".format(_types.describe(goal.self));
        auto message = "`%s` asks %s, and %s".format(_resolutions.declarations.functions[asker].name, what, answer.failure);
        auto key = "%s:%s:%s".format(defer.span.start, defer.span.end, message);
        if (key in _reportedAnswers) return;
        _reportedAnswers[key] = true;
        _collector.reportError(answer.tooDeep ? DiagnosticCode.BoundSearchTooDeep : DiagnosticCode.AmbiguousQuery, defer.span, message);
    }


    /// One function a search for a witness tried.
    private struct Attempt
    {
        Trial trial;
        /// What its type parameters stand for, as far as the known arguments and its bounds say.
        Substitution binding;
        Witness[] witnesses;
        bool tooDeep;
        /// Which group of candidates it's in: 0 for the current module's.
        size_t group;
    }

    /// The function a call of `name` from `site`, with arguments of `wanted`'s parameter types,
    /// chooses, which has to return exactly what `wanted` does. A parameter type that mentions one
    /// of `open` that isn't in `bound` yet isn't known: it takes no part in the choice, and the
    /// function chosen says what it is, as its result says what the result is.
    ///
    /// With `defer`, a function that fits only where a query's answer is there doesn't fit, and
    /// is one of the witness's alternatives when it would be chosen over the one that does.
    private Conformance witnessFor(string name, const FunctionData wanted, const(TypeParam)[] open, ref Substitution bound,
        Site site, const(Goal)[] stack, Deferral* defer = null)
    {
        Conformance result;
        auto unbound = open.filter!(p => p.id !in bound).array;
        auto known = wanted.params.map!(p => !mentionsAny(p, unbound)).array;
        string arguments()
        {
            auto shown = wanted.params.length.iota.map!(i => (wanted.isMutable(i) ? "mutable " : "") ~ _types.describe(wanted.params[i]));
            return wanted.params.length == 1 ? "`%-(%s%)`".format(shown) : "`(%-(%s, %))`".format(shown);
        }

        Attempt attempt(Id!FunctionDecl f, size_t group)
        {
            auto tried = Attempt(Trial(f));
            tried.group = group;
            auto signature = signatureOf(f);
            auto params = _resolutions.typeParamsOf(f);
            if (signature.params.length != wanted.params.length)
            {
                tried.trial.problem = "takes %s argument%s".format(signature.params.length, signature.params.length == 1 ? "" : "s");
                return tried;
            }
            foreach (i, type; wanted.params)
            {
                if (known[i]) bindParams(signature.params[i], type, params, tried.binding);
            }
            tried.trial.fits = new Fit[wanted.params.length];
            foreach (i, type; wanted.params)
            {
                if (signature.isMutable(i) != wanted.isMutable(i))
                {
                    tried.trial.problem = wanted.isMutable(i)
                        ? "doesn't take argument %s as `mutable`".format(i + 1)
                        : "takes argument %s as `mutable`".format(i + 1);
                    return tried;
                }
                tried.trial.fits[i] = Fit.exact;
                if (!known[i]) continue;
                auto param = _types.substitute(signature.params[i], tried.binding);
                tried.trial.fits[i] = typedFit(type, param, params, wanted.isMutable(i));
                if (tried.trial.fits[i] == Fit.none)
                {
                    tried.trial.problem = "takes `%s` there, not `%s`".format(_types.describe(param), _types.describe(type));
                    return tried;
                }
            }
            auto needs = conformanceOf(f, tried.binding, site, stack, defer);
            tried.witnesses = needs.witnesses;
            tried.tooDeep = needs.tooDeep;
            if (needs.failure !is null) tried.trial.problem = needs.tooDeep ? needs.failure : needs.failure.replace("\n", "\n    ");
            return tried;
        }

        auto candidates = candidatesFrom(site, name);
        Attempt[][] groups;
        foreach (g, group; candidates.groups) groups ~= group.map!(f => attempt(f, g)).array;
        foreach (tried; groups.joiner)
        {
            if (!tried.tooDeep) continue;
            result.tooDeep = true;
            result.failure = tried.trial.problem;
            return result;
        }
        Attempt[] conditional;
        if (defer !is null)
        {
            foreach (ref group; groups)
            {
                foreach (ref tried; group)
                {
                    if (!tried.trial.fitsAll || settledAttempt(tried)) continue;
                    conditional ~= tried;
                    tried.trial.problem = "fits only where what it asks of its caller holds";
                }
            }
        }

        // What's left to say once a function is chosen: what the arguments that weren't known
        // are, and that it returns what's wanted.
        Conformance finish(Attempt best, ref Substitution into)
        {
            Conformance finished;
            auto label = overloadLabel(best.trial.func, _resolutions.declarations.functionModules[best.trial.func] != site.module_);
            settleResult(best.trial.func);
            auto signature = signatureOf(best.trial.func);
            auto params = _resolutions.typeParamsOf(best.trial.func);
            auto missing = params.filter!(p => p.id !in best.binding);
            if (!missing.empty)
            {
                finished.failure = "nothing a call of `%s` passes says what its `%s` is".format(label, missing.front.name);
                return finished;
            }
            foreach (i, type; wanted.params)
            {
                if (!known[i]) bindParams(type, _types.substitute(signature.params[i], best.binding), open, into);
            }
            auto ret = _types.substitute(signature.ret, best.binding);
            bindParams(wanted.ret, ret, open, into);
            if (_types.mentionsError(ret))
            {
                // Already reported, so what it would have said isn't asked for again.
                foreach (param; open)
                {
                    if (param.id !in into && _types.mentionsParameter(wanted.ret, param.id)) into[param.id] = _types.error;
                }
            }
            foreach (i, type; wanted.params)
            {
                if (known[i]) continue;
                auto now = _types.substitute(type, into);
                auto param = _types.substitute(signature.params[i], best.binding);
                if (mentionsAny(now, open.filter!(p => p.id !in into).array) || typedFit(now, param, null, wanted.isMutable(i)) == Fit.none)
                {
                    finished.failure = "`%s` takes `%s` where `%s` is passed".format(label, _types.describe(param), _types.describe(now));
                    return finished;
                }
            }
            auto expected = _types.substitute(wanted.ret, into);
            if (expected != ret && !_types.mentionsError(ret) && !_types.mentionsError(expected))
            {
                finished.failure = "`%s` returns `%s`, where `%s` is needed".format(label, _types.describe(ret), _types.describe(expected));
                return finished;
            }
            finished.witnesses = [Witness(best.trial.func, params.map!(p => best.binding[p.id]).array, best.witnesses)];
            return finished;
        }

        // The functions that fit only where answers are there, best first, that would be chosen
        // over `best`, or over nothing when it's null.
        Witness[] alternativesTo(const(Attempt)* best)
        {
            auto better = conditional.filter!(c => best is null || c.group == 0 && best.group > 0
                || c.group == best.group && beats(c.trial, best.trial)).array;
            better.sort!((a, b) => a.group < b.group || a.group == b.group && beats(a.trial, b.trial));
            Witness[] found;
            foreach (c; better)
            {
                auto into = bound.dup;
                auto finished = finish(c, into);
                if (finished.holds) found ~= finished.witnesses[0];
            }
            return found;
        }
        Conformance onlyAlternatives(Conformance failed)
        {
            auto alternatives = alternativesTo(null);
            if (alternatives.length == 0) return failed;
            Conformance some;
            some.witnesses = [Witness(Id!FunctionDecl.init, null, null, size_t.max, alternatives)];
            return some;
        }

        Attempt[] fitting(Attempt[] group) => group.filter!(t => t.trial.fitsAll).array;
        auto pool = groups.length > 0 ? fitting(groups[0]) : null;
        if (pool.length == 0 && groups.length > 1)
        {
            auto imported = groups[1 .. $].map!(g => fitting(g)).filter!(g => g.length > 0).array;
            auto exact = imported.filter!(g => g.any!(t => fitsExactly(t.trial))).array;
            if (exact.length > 0) imported = exact;
            imported = agreeing!(t => t.trial.func)(imported);
            if (imported.length > 1)
            {
                auto modules = importsOf(candidates, imported.map!(g => g.map!(t => t.trial.func).array));
                result.failure = ("a `%s` in more than one imported module (%-(%s, %)) takes %s; declare one in this module that "
                    ~ "calls the one you mean").format(name, modules, arguments());
                result.ambiguous = true;
                return result;
            }
            if (imported.length == 1) pool = imported[0];
        }
        if (pool.length == 0)
        {
            string[] lines;
            foreach (g, group; groups)
            {
                foreach (tried; group) lines ~= "\n    %s %s".format(overloadLabel(tried.trial.func, g > 0), tried.trial.problem);
            }
            result.failure = "no `%s` in scope takes %s%s%s".format(name, arguments(), lines.join, importHint(name, wanted, known, candidates));
            return onlyAlternatives(result);
        }
        // With an argument unknown, ranking the ones that are known could choose by half a call.
        if (pool.length > 1 && known.canFind(false))
        {
            result.pending = true;
            return result;
        }
        auto winners = pool.filter!(t => pool.all!(u => u.trial.func == t.trial.func || beats(t.trial, u.trial))).array;
        if (winners.length != 1)
        {
            auto tied = pool.filter!(t => !pool.any!(u => beats(u.trial, t.trial))).map!(t => "`" ~ overloadLabel(t.trial.func) ~ "`").array;
            result.failure = "more than one `%s` takes %s equally well: %-(%s and %)".format(name, arguments(), tied);
            result.ambiguous = true;
            return result;
        }

        auto best = winners[0];
        auto finished = finish(best, bound);
        if (!finished.holds) return onlyAlternatives(finished);
        if (conditional.length > 0) finished.witnesses[0].alternatives = alternativesTo(&best);
        return finished;
    }

    /// The functions a call of `name` from `site` chooses from: the current module's, with those
    /// the bounds of the function it's in supply, then a group per imported module.
    private Candidates candidatesFrom(Site site, string name)
    {
        auto found = _resolutions.functionsFrom(site.module_, name);
        Id!FunctionDecl[] supplied;
        if (site.function_.isValid)
        {
            supplied = _resolutions.boundFunctions.get(site.function_, null)
                .filter!(f => _resolutions.declarations.functions[f].name == name && f !in _repeatedBounds).array.dup;
        }
        if (found.groups.length == 0) return Candidates([supplied]);
        found.groups[0] = supplied ~ found.groups[0];
        return found;
    }

    /// What to say when no function in scope fits and the module that declares one of the
    /// arguments' types has one that would, since importing it is all that's missing.
    private string importHint(string name, const FunctionData wanted, const(bool)[] known, const Candidates seen)
    {
        foreach (type; wanted.params)
        {
            auto decl = declOf(type);
            if (!decl.isValid) continue;
            auto home = _resolutions.declarations.typeModules[decl];
            foreach (f; _resolutions.publicFunctions(home, name))
            {
                if (seen.groups.joiner.canFind(f)) continue;
                auto signature = signatureOf(f);
                auto params = _resolutions.typeParamsOf(f);
                if (signature.params.length != wanted.params.length) continue;
                Substitution binding;
                foreach (i, argument; wanted.params)
                {
                    if (known[i]) bindParams(signature.params[i], argument, params, binding);
                }
                auto fits = wanted.params.length.iota.all!(i => !known[i] || signature.isMutable(i) == wanted.isMutable(i)
                    && typedFit(wanted.params[i], _types.substitute(signature.params[i], binding), params, wanted.isMutable(i)) != Fit.none);
                if (fits) return "\n    `%s` has a `%s` that would fit; import it to use that one".format(home, overloadLabel(f));
            }
        }
        return null;
    }

    /// Reports a use of the function spelled `spelled` whose type arguments don't satisfy its bounds.
    private void reportUnsatisfied(Span span, string spelled, const Conformance conformance)
    {
        _collector.reportError(conformance.tooDeep ? DiagnosticCode.BoundSearchTooDeep : DiagnosticCode.UnsatisfiedBound, span,
            "`%s` %s".format(spelled, conformance.failure));
    }

    /// A use of a generic function or constructor: what it has to find, and what it is in terms of
    /// that.
    private struct Generic
    {
        /// The name the use is written with, which may give the type arguments.
        Id!Expr name;
        Span span;
        string spelled;
        const(TypeExpr)[] written;
        /// The function's type parameters, or those of the type a constructor names. `written`
        /// gives the first `writable` of them, which leaves out a function's hidden ones.
        const(TypeParam)[] params;
        size_t writable;
        /// The function, when it is one, whose bounds its type arguments have to satisfy.
        Id!FunctionDecl func;
        /// The function's type, or a constructor's or marker's, in terms of `params`.
        Type type;
        /// For a constructor of a member a generic sum owns: the sum, and its parameters, which
        /// include `params`.
        Type owner;
        const(TypeParam)[] ownerParams;
        /// The type a constructor names, in terms of `params`.
        Type member;
        /// For a name that's an alias of an instance, like `IntBox` for `Box<Int>`, that instance,
        /// which gives the type arguments.
        Type aliased;

        bool found() const => type != Type.init;
        bool writes() const => written.length > 0 || aliased != Type.init;
    }

    /// What `expr` uses generically, if it's a call or value of a generic function or constructor.
    private Generic genericUse(const Expr expr)
    {
        return expr.kind.match!(
            (const CallExpr call) => expr.id in _resolutions.conversions || isMethodCall(expr.id, *call.callee)
                ? Generic.init : genericNamed(*call.callee),
            (const Identifier _) => genericNamed(expr),
            (const MemberAccess _) => genericNamed(expr),
            _ => Generic.init,
        );
    }

    private Generic genericNamed(const Expr name)
    {
        auto symbol = resolutionOf(name.id);
        if (symbol is null) return Generic.init;
        Generic g;
        g.name = name.id;
        g.span = name.span;
        g.spelled = spelling(name);
        g.written = typeArgsOf(name);
        if (auto alias_ = name.id in _resolutions.aliasedInstances) g.aliased = _declarer.aliasType(*alias_);
        auto found = (*symbol).match!(
            (const Id!FunctionDecl f) {
                g.params = _resolutions.typeParamsOf(f);
                if (g.params.length == 0) return false;
                g.writable = _resolutions.declarations.functions[f].typeParams.length;
                g.func = f;
                settleResult(f);
                g.type = _typing.symbolTypes[SymbolId(f)];
                return true;
            },
            (const Id!TypeDecl t) {
                auto decl = _resolutions.declarations.types[t];
                if (decl.members.length > 0) return false;
                if (auto owner = _declarer.ownerOf(t))
                {
                    if (_types.mentionsParameter(*owner))
                    {
                        g.owner = *owner;
                        g.ownerParams = _declarer.typeParamsOf(declOf(*owner));
                    }
                }
                if (decl.typeParams.length == 0 && g.owner == Type.init) return false;
                g.params = decl.typeParams;
                g.writable = g.params.length;
                g.type = _typing.symbolTypes[SymbolId(t)];
                g.member = _typing.nominalTypes[t];
                return true;
            },
            _ => false,
        );
        return found ? g : Generic.init;
    }

    private static const(TypeExpr)[] typeArgsOf(const Expr name)
    {
        return name.kind.match!(
            (const Identifier id) => id.typeArgs,
            (const MemberAccess access) => access.typeArgs,
            _ => (const(TypeExpr)[]).init,
        );
    }

    /// `name` as written, for a message: `f`, or `a.b.f` when the object is a module path.
    private static string spelling(const Expr name)
    {
        return name.kind.match!(
            (const Identifier id) => id.name,
            (const MemberAccess access) => access.object.kind.match!(
                (const Identifier _) => spelling(*access.object) ~ "." ~ access.member,
                (const MemberAccess _) => spelling(*access.object) ~ "." ~ access.member,
                _ => access.member,
            ),
            _ => "this",
        );
    }

    private Id!TypeDecl declOf(Type type)
    {
        return _types[type].match!((const NominalData n) => n.decl, _ => Id!TypeDecl.init);
    }

    /// Reports type arguments written on `name`, which isn't generic.
    private void rejectTypeArguments(const(TypeExpr)[] written, string name, Span span)
    {
        if (written.length == 0) return;
        _declarer.resolveTypeArguments(written);
        _collector.reportError(DiagnosticCode.WrongTypeArgumentCount, span,
            "`%s` isn't generic, so it takes no type arguments".format(name));
    }

    /// Whether a use of `g` that's expected to be `expected` builds the member it names rather than
    /// the sum that owns it.
    private bool buildsMember(const Generic g, Type expected)
    {
        if (expected == Type.init || expected == _types.error) return false;
        auto member = declOf(g.member);
        auto owner = declOf(g.owner);
        bool wanted(Type type)
        {
            if (_types.isOption(type)) return wanted(_types.optionInner(type));
            if (_types.isErrorUnion(type)) return wanted(_types.successOf(type));
            auto decl = declOf(type);
            if (decl == member) return true;
            return decl.isValid && decl != owner && _declarer.membersOf(type).any!(m => declOf(m) == member);
        }
        return wanted(expected);
    }

    /// The member a use of `g` builds on the way to its generic sum, as an error union for a member
    /// with an invariant.
    private Type memberBuilt(const Generic g, const Substitution bound)
    {
        auto member = _types.substitute(g.member, bound);
        auto ret = _types[g.type].match!((const FunctionData f) => f.ret, _ => g.type);
        if (!_types.isErrorUnion(ret)) return member;
        return _types.errorUnion(member, _types.substitute(_types.errorOf(ret), bound));
    }

    /// What a use of `g`, a member its generic sum owns, builds: the sum, or for a member with an
    /// invariant, the sum or its error.
    private Type ownerResult(const Generic g)
    {
        auto ret = _types[g.type].match!((const FunctionData f) => f.ret, _ => g.type);
        return _types.isErrorUnion(ret) ? _types.errorUnion(g.owner, _types.errorOf(ret)) : g.owner;
    }

    /// `type` with `result` for its result: a function's return type, or a marker itself.
    private Type withResult(Type type, Type result)
    {
        return _types[type].match!(
            (const FunctionData f) => _types.function_(f.params, result, f.mutables),
            _ => result,
        );
    }

    /// Binds what each parameter in `params` that `declared` mentions has to be for `declared` to be
    /// `actual`. Nothing is reported, and a parameter that's already bound is left alone.
    private void bindParams(Type declared, Type actual, const(TypeParam)[] params, ref Substitution bound)
    {
        if (actual == _types.error || actual == _types.never || actual == _types.none || actual == _types.emptyArray
            || actual == _types.any) return;
        // What `!` unwraps is an option or an error union whose error isn't known, so it's either.
        auto unwrapped = _types.isErrorUnion(actual) && _types.errorOf(actual) == _types.error;
        auto data = _types[actual];
        _types[declared].match!(
            (const TypeParamData p) {
                if (params.canFind!(q => q.id == p.param) && p.param !in bound && !unwrapped) bound[p.param] = actual;
            },
            (const OptionData o) => bindParams(o.inner, _types.isOption(actual) ? _types.optionInner(actual)
                : unwrapped ? _types.successOf(actual) : actual, params, bound),
            (const ErrorUnionData u) {
                if (_types.isErrorUnion(actual))
                {
                    bindParams(u.success, _types.successOf(actual), params, bound);
                    bindParams(u.error, _types.errorOf(actual), params, bound);
                }
                else if (_types.isFailure(actual))
                {
                    bindParams(u.error, _types.errorOf(actual), params, bound);
                }
                else
                {
                    bindParams(u.success, actual, params, bound);
                }
            },
            (const ErrorListData l) => bindListed(l.members, actual, params, bound),
            (const ArrayData a) {
                if (_types.isArray(actual)) bindParams(a.element, _types.arrayElement(actual), params, bound);
            },
            (const TupleData t) => data.match!(
                (const TupleData u) {
                    if (u.elements.length != t.elements.length) return;
                    foreach (i, element; t.elements) bindParams(element, u.elements[i], params, bound);
                },
                (_) {},
            ),
            (const FunctionData f) => data.match!(
                (const FunctionData g) {
                    if (g.params.length != f.params.length) return;
                    foreach (i, param; f.params) bindParams(param, g.params[i], params, bound);
                    bindParams(f.ret, g.ret, params, bound);
                },
                (_) {},
            ),
            (const NominalData n) => data.match!(
                (const NominalData m) {
                    if (m.decl != n.decl) return;
                    foreach (i, arg; n.args) bindParams(arg, m.args[i], params, bound);
                },
                (_) {},
            ),
            (_) {},
        );
    }

    /// Binds the one type parameter a written error list names to what `actual` lists beyond the
    /// list's other types, so `Int ! E | Overflow` binds `E` from `Int ! Negative | Overflow`.
    private void bindListed(const(Type)[] declared, Type actual, const(TypeParam)[] params, ref Substitution bound)
    {
        auto open = declared.filter!(m => mentionsAny(m, params)).array;
        if (open.length != 1 || !_types.isParameter(open[0])) return;
        auto rest = _types.listed(actual).filter!(m => !declared.canFind(m)).array;
        if (rest.length > 0) bindParams(open[0], _types.errorList(rest), params, bound);
    }

    /// Binds from where a use's result is expected to land: inside an option the result isn't, and
    /// at the member of a sum that the result names.
    private void bindExpected(Type result, Type expected, const(TypeParam)[] params, ref Substitution bound)
    {
        if (expected == Type.init || expected == _types.error) return;
        // What `!` unwraps, when the result isn't something it can unwrap.
        auto unwrapped = _types.isErrorUnion(expected) && _types.errorOf(expected) == _types.error;
        if (unwrapped && !_types.isOption(result) && !_types.isErrorUnion(result)) return;
        auto bare = _types.isParameter(result) && expected == _unwrapTarget;
        if (!bare && _types.isOption(expected) && !_types.isOption(result)) expected = _types.optionInner(expected);
        if (!bare && _types.isErrorUnion(expected) && !_types.isErrorUnion(result)) expected = _types.successOf(expected);
        if (_types.isErrorUnion(result) && !_types.isErrorUnion(expected)) result = _types.successOf(result);
        auto decl = declOf(result);
        if (decl.isValid && declOf(expected).isValid && declOf(expected) != decl)
        {
            auto member = _declarer.membersOf(expected).find!(m => declOf(m) == decl);
            if (!member.empty) expected = member.front;
        }
        bindParams(result, expected, params, bound);
    }

    private bool isBound(Type declared, const(TypeParam)[] params, const Substitution bound)
    {
        return !params.any!(p => p.id !in bound && _types.mentionsParameter(declared, p.id));
    }

    /// Binds what `g.written` gives, reporting it unless it gives every one of `g.params` that can
    /// be written.
    private void bindWritten(const Generic g, ref Substitution bound)
    {
        auto args = _declarer.resolveTypeArguments(g.written);
        if (g.aliased != Type.init)
        {
            if (args.length > 0 || g.aliased == _types.error)
            {
                if (args.length > 0)
                {
                    _collector.reportError(DiagnosticCode.WrongTypeArgumentCount, g.span,
                        "`%s` isn't generic, so it takes no type arguments".format(g.spelled));
                }
                foreach (param; g.params ~ g.ownerParams) bound[param.id] = _types.error;
                return;
            }
            args = _types.nominalArgs(g.aliased).dup;
        }
        if (args.length == g.writable)
        {
            foreach (i, arg; args) bound[g.params[i].id] = arg;
            return;
        }
        _collector.reportError(DiagnosticCode.WrongTypeArgumentCount, g.span, g.writable == 0
            ? "`%s` has no type parameters to write: the types it takes come from its arguments".format(g.spelled)
            : "`%s` takes %s type arguments, got %s; write all of them or none".format(g.spelled, g.writable, args.length));
        foreach (param; g.params ~ g.ownerParams) bound[param.id] = _types.error;
    }

    /// An argument whose type depends on where it goes: an integer literal, a lambda, `None` or
    /// `[]`, and as with `None`, a generic name with no type arguments that isn't called, like `Nil`.
    private bool isUntyped(const Expr expr)
    {
        if (expr.id in _resolutions.overloads) return true;
        auto genericName = expr.kind.match!(
            (const Identifier id) => id.typeArgs.length == 0,
            (const MemberAccess access) => access.typeArgs.length == 0,
            _ => false,
        );
        if (genericName && expr.id !in _resolutions.aliasedInstances && genericNamed(expr).found) return true;
        return isIntLiteral(expr) || isLambda(expr) || expr.kind.match!(
            (const NoneLiteral _) => true,
            (const OkExpr _) => true,
            (const ArrayLiteral literal) => literal.elements.length == 0,
            _ => false,
        );
    }

    /// What a lambda passed for a parameter of type `declared` is checked against, when each of its
    /// parameters is annotated or known by now. An unknown return type is left to infer.
    private const(FunctionData)* lambdaExpectation(const Lambda lambda, Type declared, const(TypeParam)[] params,
        const Substitution bound)
    {
        return _types[declared].match!(
            (const FunctionData f) {
                if (f.params.length != lambda.params.length) return null;
                foreach (i, param; f.params)
                {
                    if (!lambda.params[i].annotated && !isBound(param, params, bound)) return null;
                }
                auto ret = isBound(f.ret, params, bound) ? _types.substitute(f.ret, bound) : Type.init;
                return new const FunctionData(f.params.map!(p => _types.substitute(p, bound)).array.idup, ret, f.mutables);
            },
            _ => null,
        );
    }

    /// What binding a call's type parameters has found.
    private struct Binding
    {
        Substitution bound;
        /// Each argument's type, once it has one of its own.
        Type[] typed;
        /// Which arguments have had their turn without a type of their own: checked against a
        /// parameter that was known by then, or, in a trial, compared by their shape.
        bool[] checked;
        Conformance conformance;
        /// Whether the bounds failed before the expected type was looked at.
        bool failedEarly;
        /// The type parameters the expected type bound.
        Id!TypeParam[] fromExpected;
        /// In a trial, the type parameters only a lambda's result would decide, which stay unbound.
        Id!TypeParam[] undecided;
        /// In a trial, each lambda whose result was left undecided, with what it would be typed against.
        LambdaTurn[] turns;
    }

    /// A lambda argument a trial would have typed: its place, and what it's typed against.
    private struct LambdaTurn
    {
        size_t arg;
        FunctionData expectation;
        bool optional;
    }

    /// Binds `params`, the type parameters of a call of a function with `signature` and `result`,
    /// from `call`'s arguments, in inference's order: those with a type of their own, left to
    /// right; then the bounds of `func`, when it's valid, whose type is known; then the expected
    /// type; then integer literals and lambdas, as each can be typed, and a lambda that can't be
    /// yet may be once a later one binds what it needs.
    ///
    /// A call being checked runs it with `trial` false, and its arguments are synthesized, or
    /// checked against a parameter known by their turn, as they're reached. Overload choice runs
    /// it with `trial` true, which records nothing: an argument has the type `b.typed` gives it,
    /// or the one synthesis would, and a lambda binds only what its annotations say, so what its
    /// result would bind is undecided.
    private void bindCall(ref Binding b, const FunctionData signature, Type result, const(TypeParam)[] params,
        Id!FunctionDecl func, const CallExpr call, Type expected, BodyContext ctx, bool trial)
    {
        auto args = call.args;
        if (b.typed.length < args.length) b.typed.length = args.length;
        b.checked = new bool[args.length];
        const(TypeParam)[] bindable() => b.undecided.length == 0 ? params : params.filter!(p => !b.undecided.canFind(p.id)).array;
        void bind(size_t i, Type type)
        {
            bindParams(signature.params[i], type, bindable(), b.bound);
        }
        bool known(size_t i) => !signature.isMutable(i) && !call.isMutable(i) && isBound(signature.params[i], params, b.bound);
        bool open() => params.any!(p => p.id !in b.bound);
        void solveBounds()
        {
            if (!func.isValid) return;
            b.conformance = conformanceOf(func, b.bound, ctx.site);
            foreach (param; b.undecided) b.bound.remove(param);
        }
        void undecide(Type declared)
        {
            foreach (param; params)
            {
                if (param.id !in b.bound && _types.mentionsParameter(declared, param.id) && !b.undecided.canFind(param.id))
                {
                    b.undecided ~= param.id;
                }
            }
        }
        // A lambda in a trial: its annotations bind, and its result, unless it's written, is undecided.
        void bindLambda(size_t i, const Expr arg, const Lambda lambda, const(FunctionData)* expectation)
        {
            Type[] types;
            bool[] mutables;
            foreach (j, param; lambda.params)
            {
                types ~= param.annotated ? quietlyResolved(param.type) : expectation.params[j];
                mutables ~= param.mutable;
            }
            if (lambda.returnType !is null && (arg.id in _resolutions.lambdaFloors) is null)
            {
                bind(i, _types.function_(types, quietlyResolved(*lambda.returnType), mutables));
                return;
            }
            _types[signature.params[i]].match!(
                (const FunctionData f) {
                    foreach (j, param; f.params) bindParams(param, types[j], bindable(), b.bound);
                },
                (_) {},
            );
            if (expectation !is null)
            {
                auto optional = expectation.ret == Type.init && _types.isOption(signatureOf(signature.params[i]).ret);
                b.turns ~= LambdaTurn(i, *expectation, optional);
            }
            undecide(signature.params[i]);
        }

        foreach (i, arg; args)
        {
            if (b.typed[i] != Type.init)
            {
                bind(i, b.typed[i]);
                continue;
            }
            if (!call.isMutable(i) && isUntyped(arg)) continue;
            if (known(i))
            {
                if (!trial) checkArgument(arg, _types.substitute(signature.params[i], b.bound), ctx);
                b.checked[i] = true;
                continue;
            }
            if (trial)
            {
                auto type = defaultType(arg);
                if (type != Type.init) bind(i, type);
                b.checked[i] = true;
                continue;
            }
            b.typed[i] = synthesize(arg, ctx);
            bind(i, b.typed[i]);
        }
        solveBounds();
        b.failedEarly = b.conformance.failure !is null;
        if (open())
        {
            auto before = params.filter!(p => p.id !in b.bound).array;
            bindExpected(result, expected, bindable(), b.bound);
            b.fromExpected = before.filter!(p => p.id in b.bound).map!(p => cast() p.id).array;
        }
        for (auto progress = true; progress;)
        {
            progress = false;
            foreach (i, arg; args)
            {
                if (b.typed[i] != Type.init || b.checked[i]) continue;
                if (known(i))
                {
                    if (!trial) checkArgument(arg, _types.substitute(signature.params[i], b.bound), ctx);
                    b.checked[i] = progress = true;
                }
                else if (isIntLiteral(arg))
                {
                    if (trial)
                    {
                        bind(i, _types.int_);
                        b.checked[i] = true;
                    }
                    else
                    {
                        b.typed[i] = synthesize(arg, ctx);
                        bind(i, b.typed[i]);
                    }
                    progress = true;
                }
                else if (isLambda(arg))
                {
                    auto lambda = arg.kind.match!((const Lambda l) => l, (_) => Lambda.init);
                    auto expectation = lambdaExpectation(lambda, signature.params[i], params, b.bound);
                    // Against a bare parameter, a lambda is its own type when it says all of it.
                    auto annotated = !_types.isFunction(signature.params[i]) && lambda.params.all!(p => p.annotated);
                    if (expectation is null && !annotated) continue;
                    if (trial)
                    {
                        bindLambda(i, arg, lambda, expectation);
                        b.checked[i] = true;
                    }
                    else
                    {
                        auto optional = expectation !is null && expectation.ret == Type.init
                            && _types.isOption(signatureOf(signature.params[i]).ret);
                        b.typed[i] = typeLambda(arg, lambda, expectation, ctx.site, optional);
                        bind(i, b.typed[i]);
                    }
                    progress = true;
                }
            }
            if (progress && open()) solveBounds();
        }
        if (!trial) return;
        foreach (i, arg; args)
        {
            if (isLambda(arg) && !b.checked[i]) undecide(signature.params[i]);
        }
    }

    /// A call of `g` with `call`'s arguments, whose type arguments are written or inferred. With a
    /// `receiver`, the first argument is a method call's, already synthesized.
    /// `pretyped` is as for `applyCallee`. `hasReceiver` says the first argument is the `x` of `x.f()`.
    private Type applyGeneric(const Expr expr, const Generic g, const CallExpr call, Type expected, BodyContext ctx,
        const(Type)[] pretyped = null, bool hasReceiver = false)
    {
        auto args = call.args;
        auto sum = g.owner != Type.init && !buildsMember(g, expected);
        auto params = sum ? g.ownerParams : g.params;
        auto shape = sum ? withResult(g.type, ownerResult(g)) : g.type;
        auto typed = new Type[args.length];
        foreach (i, type; pretyped) typed[i] = type;
        void typeTheRest()
        {
            _declarer.resolveTypeArguments(g.written);
            foreach (i, arg; args)
            {
                if (typed[i] == Type.init) synthesize(arg, ctx);
            }
        }

        if (!_types.isFunction(shape))
        {
            typeTheRest();
            _collector.reportError(DiagnosticCode.NotCallable, expr.span,
                "`%s` is a value, not a function, so it can't be called".format(g.spelled));
            return _types.error;
        }
        auto signature = _types[shape].match!((const FunctionData f) => f, (_) => FunctionData.init);
        if (signature.params.length != args.length)
        {
            typeTheRest();
            _collector.reportError(DiagnosticCode.WrongArgumentCount, expr.span,
                "Expected %s arguments, got %s".format(signature.params.length, args.length));
            return _types.error;
        }

        Binding binding;
        binding.typed = typed;
        if (g.writes) bindWritten(g, binding.bound);
        auto bounded = sum ? Id!FunctionDecl.init : g.func;
        bindCall(binding, signature, signature.ret, params, bounded, call, expected, ctx, false);
        auto checked = binding.checked;
        reportUnbound(expr, g, params, sum, signature, args, typed, hasReceiver, binding.bound, expected);
        auto bound = binding.bound;
        Conformance conformance;
        if (bounded.isValid) conformance = conformanceOf(bounded, bound, ctx.site);
        if (conformance.failure !is null) reportUnsatisfied(g.span, g.spelled, conformance);

        auto paramTypes = signature.params.map!(p => _types.substitute(p, bound)).array;
        string[][] places;
        Span[] placeSpans;
        foreach (i, arg; args)
        {
            if (!call.isMutable(i))
            {
                if (signature.isMutable(i))
                {
                    _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                        "This parameter is `mutable`, so the call can change the argument; write `mutable` before it");
                }
                if (checked[i]) continue;
                if (typed[i] != Type.init) coerce(arg, typed[i], paramTypes[i]);
                else checkArgument(arg, paramTypes[i], ctx);
                continue;
            }
            if (!signature.isMutable(i))
            {
                if (typed[i] == Type.init) synthesize(arg, ctx);
                _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                    "This parameter isn't `mutable`, so the argument can't be passed as `mutable`");
                continue;
            }
            if (checkMutableArgument(arg, paramTypes[i], ctx, typed[i]))
            {
                places ~= placePath(arg);
                placeSpans ~= arg.span;
            }
        }
        reportOverlaps(places, placeSpans,
            "This overlaps a `mutable` argument before it, and one call can't change a place through two");

        _typing.exprTypes[g.name] = _types.substitute(shape, bound);
        _typing.typeArguments[g.name] = params.map!(p => bound[p.id]).array;
        if (conformance.witnesses.length > 0) _typing.witnesses[g.name] = conformance.witnesses;
        if (g.func.isValid && !sum) noteNamed(ctx.site, g, conformance.witnesses);
        if (sum) _typing.constructedMembers[expr.id] = memberBuilt(g, bound);
        return _types.substitute(signature.ret, bound);
    }

    /// Checks an argument against `type`, which is an error type when what it needed couldn't be
    /// found, and a lambda then has nothing more to say.
    private void checkArgument(const Expr arg, Type type, BodyContext ctx)
    {
        if (isLambda(arg) && !_types.isFunction(type) && _types.mentionsError(type))
        {
            auto lambda = arg.kind.match!((const Lambda l) => l, (_) => Lambda.init);
            auto unknown = FunctionData(_types.error.repeat(lambda.params.length).array.idup, _types.error);
            typeLambda(arg, lambda, &unknown, ctx.site);
            return;
        }
        check(arg, type, ctx);
    }

    /// Reports the first of `params` that nothing bound, as the argument that didn't fit when one
    /// should have bound it, and binds each to `error`.
    private void reportUnbound(const Expr expr, const Generic g, const(TypeParam)[] params, bool sum,
        const FunctionData signature, const(Expr)[] args, const(Type)[] typed, bool hasReceiver, ref Substitution bound,
        Type expected)
    {
        auto reported = false;
        foreach (param; params)
        {
            if (param.id in bound) continue;
            scope (exit) bound[param.id] = _types.error;
            if (reported) continue;
            reported = true;

            bool mentions(size_t i) => _types.mentionsParameter(signature.params[i], param.id);
            auto culprit = args.length.iota.filter!(i => typed[i] != Type.init && mentions(i));
            if (!culprit.empty)
            {
                auto i = culprit.front;
                if (typed[i] == _types.none) _declarer.reportUntypedNone(args[i].span);
                else if (typed[i] == _types.emptyArray) _declarer.reportUntypedEmptyArray(args[i].span);
                else if (_types.mentionsError(typed[i]) || typed[i] == _types.never) continue;
                else
                {
                    _collector.reportError(DiagnosticCode.TypeMismatch, args[i].span,
                        "`%s` takes `%s` %s, but this is `%s`".format(g.spelled, _types.describe(signature.params[i]),
                            hasReceiver && i == 0 ? "first" : "here", _types.describe(typed[i])));
                }
                continue;
            }
            auto untyped = args.length.iota.filter!(i => mentions(i) && typed[i] == Type.init && !isLambda(args[i])
                && !isIntLiteral(args[i]));
            if (!untyped.empty)
            {
                auto arg = args[untyped.front];
                arg.kind.match!(
                    (const NoneLiteral _) { _declarer.reportUntypedNone(arg.span); },
                    (const OkExpr _) { _declarer.reportUntypedErrorUnion("Ok", arg.span); },
                    (const ArrayLiteral _) { _declarer.reportUntypedEmptyArray(arg.span); },
                    (_) {
                        if (arg.id in _resolutions.overloads) reportOverloadedValue(arg);
                        else reportUninferredValue(arg, genericNamed(arg), true);
                    },
                );
                continue;
            }
            auto hidden = g.params[g.writable .. $].canFind!(p => p.id == param.id);
            auto taking = args.length.iota.filter!(i => hidden && mentions(i));
            if (!taking.empty)
            {
                _collector.reportError(DiagnosticCode.CannotInferTypeArgument, args[taking.front].span,
                    "`%s` takes any `%s` here, so this needs a type of its own; annotate it".format(g.spelled, param.name));
                continue;
            }
            if (sum && !g.params.canFind!(p => p.id == param.id))
            {
                auto owner = _resolutions.declarations.types[declOf(g.owner)].name;
                _collector.reportError(DiagnosticCode.CannotInferTypeArgument, expr.span,
                    "This builds a `%s`, but nothing here says what `%s` is; annotate the type it's used as, as in `val x: %s = ...`"
                        .format(_types.describe(_types.substitute(g.owner, bound)), param.name,
                            _declarer.example(owner, g.ownerParams.length, "")));
                continue;
            }
            // Under `!`, `Int` expected of a bare `T` could mean `Int?` or `Int ! E`, and `Int` itself is wrong.
            auto unwrapped = expected != Type.init && _types.isErrorUnion(expected) && _types.errorOf(expected) == _types.error
                && _types.isParameter(signature.ret);
            _collector.reportError(DiagnosticCode.CannotInferTypeArgument, expr.span, unwrapped
                ? "Nothing in this call says what `%s` is: `!` takes an option or an error union, and either could be meant; write the type arguments"
                    .format(param.name)
                : "Nothing in this call says what `%s` is; write the type arguments, as in `%s`"
                    .format(param.name, _declarer.example(g.spelled, g.writable, args.length == 0 ? "()" : "(...)")));
        }
    }

    /// Reports a use of `g` as a value that nothing gives its type arguments. `sum` says it's a marker
    /// that builds its generic sum.
    private void reportUninferredValue(const Expr expr, const Generic g, bool sum)
    {
        if (sum && g.owner != Type.init)
        {
            auto owner = _resolutions.declarations.types[declOf(g.owner)].name;
            _collector.reportError(DiagnosticCode.CannotInferTypeArgument, expr.span,
                "This `%s` has no type to take here; annotate one, as in `val x: %s = %s`"
                    .format(g.spelled, _declarer.example(owner, g.ownerParams.length, ""), g.spelled));
            return;
        }
        _collector.reportError(DiagnosticCode.CannotInferTypeArgument, expr.span,
            g.writable < g.params.length
                ? "`%s` takes any `%s`, so as a value it needs a function type to say which, as in `val f: (...) -> ... = %s`"
                    .format(g.spelled, g.params[g.writable].name, g.spelled)
                : "`%s` is generic, so as a value it needs its type arguments, as in `%s`, or a type to take them from"
                    .format(g.spelled, _declarer.example(g.spelled, g.writable, "")));
    }

    /// A generic function, constructor or marker used as a value, which has one type: from its
    /// written type arguments, or the function type it's expected to be.
    private Type instantiateValue(const Expr expr, const Generic g, Type expected, Site site)
    {
        auto sum = !_types.isFunction(g.type) && g.owner != Type.init && !buildsMember(g, expected);
        auto params = sum ? g.ownerParams : g.params;
        auto shape = sum ? g.owner : g.type;
        Substitution bound;
        if (g.writes) bindWritten(g, bound);
        if (params.any!(p => p.id !in bound)) bindExpected(shape, expected, params, bound);
        Conformance conformance;
        if (g.func.isValid) conformance = conformanceOf(g.func, bound, site);
        if (params.any!(p => p.id !in bound))
        {
            // An expected type that's already wrong has been reported.
            if (expected == Type.init || !_types.mentionsError(expected)) reportUninferredValue(expr, g, sum);
            foreach (param; params) bound.require(param.id, _types.error);
        }
        else if (conformance.failure !is null)
        {
            reportUnsatisfied(g.span, g.spelled, conformance);
        }
        if (conformance.witnesses.length > 0) _typing.witnesses[g.name] = conformance.witnesses;
        _typing.typeArguments[g.name] = params.map!(p => bound[p.id]).array;
        if (g.func.isValid && !sum) noteNamed(site, g, conformance.witnesses);
        if (sum) _typing.constructedMembers[expr.id] = memberBuilt(g, bound);
        // Without its type arguments the value has no type, rather than one made up from `error`.
        if (params.any!(p => bound[p.id] == _types.error)) return _types.error;
        return _types.substitute(shape, bound);
    }

    /// `typed` has the type of each argument that has already been given one, and is otherwise
    /// `Type.init`, or empty when none has.
    private Type applyCallee(Type calleeType, const CallExpr call, Span span, BodyContext ctx, const(Type)[] typed = null)
    {
        Type typeOf(size_t i) => i < typed.length ? typed[i] : Type.init;
        // Each argument is checked against its parameter when there is one, and synthesized
        // otherwise, so even a wrong call gives every argument a type and its own errors.
        void synthesizeArgs()
        {
            foreach (i, arg; call.args)
            {
                if (typeOf(i) == Type.init) synthesize(arg, ctx);
            }
        }
        if (calleeType == _types.error)
        {
            synthesizeArgs();
            return _types.error;
        }
        return _types[calleeType].match!(
            (const FunctionData funcData) {
                if (funcData.params.length != call.args.length)
                {
                    synthesizeArgs();
                    _collector.reportError(DiagnosticCode.WrongArgumentCount, span,
                        "Expected %s arguments, got %s".format(funcData.params.length, call.args.length));
                    return _types.error;
                }
                string[][] places;
                Span[] placeSpans;
                foreach (i, arg; call.args)
                {
                    auto type = typeOf(i);
                    if (!call.isMutable(i))
                    {
                        if (funcData.isMutable(i))
                        {
                            _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                                "This parameter is `mutable`, so the call can change the argument; write `mutable` before it");
                        }
                        if (type == Type.init) check(arg, funcData.params[i], ctx);
                        else coerce(arg, type, funcData.params[i]);
                        continue;
                    }
                    if (!funcData.isMutable(i))
                    {
                        if (type == Type.init) synthesize(arg, ctx);
                        _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                            "This parameter isn't `mutable`, so the argument can't be passed as `mutable`");
                        continue;
                    }
                    if (checkMutableArgument(arg, funcData.params[i], ctx, type))
                    {
                        places ~= placePath(arg);
                        placeSpans ~= arg.span;
                    }
                }
                reportOverlaps(places, placeSpans,
                    "This overlaps a `mutable` argument before it, and one call can't change a place through two");
                return funcData.ret;
            },
            (_) {
                synthesizeArgs();
                _collector.reportError(DiagnosticCode.NotCallable, span,
                    "Expression of type `%s` is not function-like and cannot be called".format(_types.describe(calleeType)));
                return _types.error;
            },
        );
    }

    /// Whether `object.f(...)` is on a value and some declaration could be `f`.
    private bool isMethodCall(Id!Expr call, const Expr callee)
    {
        if ((call in _resolutions.methodLookups) is null) return false;
        return callee.kind.match!(
            (const MemberAccess access) => !isModulePath(*access.object),
            _ => false,
        );
    }

    /// `object.f(args)`. A field named `f` comes first; otherwise it's `f(object, args)`, with the
    /// `f` a plain name finds at module level. The receiver was synthesized to look for the field,
    /// so it's an argument that already has its type.
    private Type synthesizeMethodCall(const Expr expr, const CallExpr call, BodyContext ctx, Type expected)
    {
        auto access = (*call.callee).kind.match!(
            (const MemberAccess m) => m,
            (_) => assert(0, "isMethodCall only accepts a member access"),
        );
        auto objectType = synthesize(*access.object, ctx);

        Type asField()
        {
            rejectTypeArguments(access.typeArgs, access.member, call.callee.span);
            auto calleeType = fieldOf(*call.callee, access, objectType);
            _typing.exprTypes[call.callee.id] = calleeType;
            return applyCallee(calleeType, call, expr.span, ctx);
        }

        if (objectType == _types.error || hasField(objectType, access.member)) return asField();

        auto lookup = distinct(_resolutions.methodLookups[expr.id]);
        auto arguments = (cast(Expr*) access.object)[0 .. 1] ~ cast(Expr[]) call.args;
        auto mutables = call.mutableArgs.length > 0 ? false ~ call.mutableArgs.dup : null;
        auto rewritten = new const CallExpr(cast(Expr*) call.callee, arguments, mutables);
        _typing.methodCalls[expr.id] = rewritten;
        auto receiver = _declarer.requireTyped(objectType, access.object.span);
        auto typed = new Type[arguments.length];
        typed[0] = receiver;

        Id!FunctionDecl function_;
        if (lookup.count == 1)
        {
            function_ = cast() lookup.groups.joiner.front;
        }
        else if (receiver != _types.error)
        {
            function_ = chooseFunction(*call.callee, access.member, access.typeArgs, lookup, *rewritten, typed, true, ctx, expected);
            if (function_.isValid) _siblings[call.callee.id] = siblingsOf(lookup, function_);
        }
        if (!function_.isValid)
        {
            _typing.exprTypes[call.callee.id] = _types.error;
            typeUnchosen(*rewritten, typed, ctx);
            return _types.error;
        }
        settleResult(function_);
        auto functionType = _typing.symbolTypes[SymbolId(function_)];
        _typing.exprTypes[call.callee.id] = functionType;
        _typing.methodCallees[expr.id] = function_;

        auto decl = _resolutions.declarations.functions[function_];
        if (!receiverFits(access, functionType, receiver, call.callee.span))
        {
            return applyCallee(_types.error, *rewritten, expr.span, ctx, typed);
        }
        if (isGenericFunction(function_))
        {
            Generic g;
            g.name = call.callee.id;
            g.span = call.callee.span;
            g.spelled = access.member;
            g.written = access.typeArgs;
            g.params = _resolutions.typeParamsOf(function_);
            g.writable = decl.typeParams.length;
            g.func = function_;
            g.type = functionType;
            return applyGeneric(expr, g, *rewritten, expected, ctx, typed, true);
        }
        rejectTypeArguments(access.typeArgs, access.member, call.callee.span);
        return applyCallee(functionType, *rewritten, expr.span, ctx, typed);
    }

    /// Whether a receiver of type `receiver` can be the first argument of a function of type
    /// `functionType`, reporting why not. Its type is checked as any argument's is.
    private bool receiverFits(const MemberAccess access, Type functionType, Type receiver, Span calleeSpan)
    {
        if (receiver == _types.error) return false;
        auto signature = _types[functionType].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "a function's type is a function type"),
        );
        if (signature.params.length == 0)
        {
            _collector.reportError(DiagnosticCode.WrongArgumentCount, calleeSpan,
                "`%s` takes no arguments, so it can't be called on a value".format(access.member));
            return false;
        }
        if (signature.isMutable(0))
        {
            _collector.reportError(DiagnosticCode.MutabilityMismatch, access.object.span,
                "`%s` changes its first argument, so the write has to show at the call; write `%s(mutable ...)`"
                    .format(access.member, access.member));
            return false;
        }
        return true;
    }

    private bool hasField(Type type, string name)
    {
        return _declarer.fieldsOf(type).canFind!(f => f.name == name);
    }

    /// A `mutable` argument is written back when the call returns, so it must be a place of exactly
    /// the parameter's type. Whether it's one that can be overlap-checked. `type` is the argument's,
    /// when it's been synthesized already.
    private bool checkMutableArgument(const Expr arg, Type param, BodyContext ctx, Type type = Type.init)
    {
        if (type == Type.init) type = synthesize(arg, ctx);
        if (type == _types.error) return false;
        if (!checkAssignable(arg, "passed as `mutable`")) return false;
        if (type == param || _types.mentionsError(param)) return true;
        _collector.reportError(DiagnosticCode.TypeMismatch, arg.span,
            "A `mutable` argument is written back, so it has to be exactly `%s`, not `%s`"
                .format(_types.describe(param), _types.describe(type)));
        return false;
    }

    /// For the calls that aren't to a function, which can't take a `mutable` argument.
    private void rejectMutableArguments(const CallExpr call)
    {
        foreach (i, arg; call.args)
        {
            if (!call.isMutable(i)) continue;
            _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                "This parameter isn't `mutable`, so the argument can't be passed as `mutable`");
        }
    }

    /// `object with (a = 1, b.c = 2)`: a copy of `object`, so it has `object`'s type, and each value
    /// is checked as an assignment to that field would be.
    private Type synthesizeWith(const Expr expr, const WithExpr with_, BodyContext ctx)
    {
        auto objectType = _declarer.requireTyped(synthesize(*with_.object, ctx), with_.object.span);

        size_t[][] indexes;
        string[][] paths;
        Span[] spans;
        foreach (ref update; with_.updates)
        {
            size_t[] steps;
            auto fieldType = updatedField(objectType, update, steps);
            check(update.value, fieldType, ctx);
            indexes ~= steps;
            if (fieldType == _types.error) continue;
            paths ~= update.path.dup;
            spans ~= update.span;
        }
        reportOverlaps(paths, spans, "This overlaps an update before it, and one `with` can't change a place twice");
        _typing.updatePaths[expr.id] = indexes;

        // Each value along a path whose invariant names the field updated in it is checked, once.
        size_t[][] checks;
        Type[] errors;
        Type[] checkedTypes;
        foreach (i, ref update; with_.updates)
        {
            if (indexes[i].length < update.path.length) continue;
            auto type = objectType;
            foreach (depth, name; update.path)
            {
                auto prefix = indexes[i][0 .. depth];
                if (invariantMentions(type, name) && !checks.canFind(prefix))
                {
                    noteInvariantUse(InvariantUse(ctx.site, expr.span, declOf(type), Id!Expr.init, type));
                    if (!requireInvariant(declOf(type), expr.span, ctx.site)) return _types.error;
                    checks ~= prefix.dup;
                    errors ~= invariantErrorOf(type);
                    checkedTypes ~= type;
                }
                type = _declarer.fieldsOf(type)[indexes[i][depth]].type;
            }
        }
        if (checks.length == 0) return objectType;
        auto different = errors.countUntil!(e => e != errors[0]);
        if (different >= 0)
        {
            _collector.reportError(DiagnosticCode.NotSupportedYet, expr.span,
                ("This `with` checks the invariants of `%s` and `%s`, which give different errors, and a `with` with "
                    ~ "two errors isn't supported yet; update the inner value with a `with` of its own first")
                    .format(_types.describe(checkedTypes[0]), _types.describe(checkedTypes[different])));
            return _types.error;
        }
        _typing.withChecks[expr.id] = checks.sort!((a, b) => a.length > b.length).release;
        return errors[0] == _types.error ? _types.error : _types.errorUnion(objectType, errors[0]);
    }

    /// The type of the field `update` writes, reached from `object`, with the field index of each
    /// step of its path in `steps`.
    private Type updatedField(Type object, const FieldUpdate update, out size_t[] steps)
    {
        auto type = object;
        foreach (name; update.path)
        {
            if (type == _types.error) return type;
            auto fields = _declarer.fieldsOf(type);
            auto index = fields.countUntil!(f => f.name == name);
            if (index < 0)
            {
                _collector.reportError(DiagnosticCode.UnknownMember, update.span,
                    "Type `%s` has no field named `%s`".format(_types.describe(type), name));
                return _types.error;
            }
            steps ~= index;
            type = fields[index].type;
        }
        return type;
    }

    private Type synthesizeMemberAccess(const Expr expr, const MemberAccess member, BodyContext ctx, Type expected)
    {
        // `std.math.pow`: resolution already found the declaration, or the functions it could be.
        if (auto candidates = expr.id in _resolutions.overloads) return overloadedValue(expr, distinct(*candidates), expected, ctx.site);
        if (auto symbol = expr.id in _resolutions.resolutions) return namedValue(expr, *symbol, expected, ctx.site);
        // `std.math.nope` or `std.nope`: resolution reported it.
        if (isModulePath(*member.object)) return _types.error;

        rejectTypeArguments(member.typeArgs, member.member, expr.span);
        return fieldOf(expr, member, synthesize(*member.object, ctx));
    }

    /// The field `member` names on a value of `objectType`, reported if there's none.
    private Type fieldOf(const Expr expr, const MemberAccess member, Type objectType)
    {
        if (objectType == _types.error) return _types.error;

        auto fields = _declarer.fieldsOf(objectType);
        foreach (i, field; fields)
        {
            if (field.name == member.member)
            {
                _typing.fieldIndexes[expr.id] = i;
                return field.type;
            }
        }
        _collector.reportError(DiagnosticCode.UnknownMember, expr.span,
            "Type `%s` has no member named `%s`".format(_types.describe(objectType), member.member));
        return _types.error;
    }

    private bool isModulePath(const Expr expr)
    {
        if (auto symbol = expr.id in _resolutions.resolutions)
        {
            return (*symbol).match!(
                (const Id!Module _) => true,
                _ => false,
            );
        }
        return expr.kind.match!(
            // A package prefix like `std`, or an unknown name.
            (const Identifier _) => true,
            // `a.b` with no resolution is a module path only if `a` is one; otherwise it's a member of a value.
            (const MemberAccess access) => isModulePath(*access.object),
            _ => false,
        );
    }

    /// Whether `symbol` is a nested `def` whose result type is being worked out from the body at
    /// `site`, which is reported the first time.
    private bool usesUnsettled(SymbolId symbol, Site site)
    {
        auto local = symbol.match!((const Id!VarDecl l) => l, _ => Id!VarDecl.init);
        if (!local.isValid) return false;
        for (auto nested = site.unsettled; nested !is null; nested = nested.outer)
        {
            if (nested.self != local) continue;
            if (!nested.usedItself)
            {
                auto name = _resolutions.declarations.locals[local].name;
                _collector.reportError(DiagnosticCode.RecursiveResultType, nested.written,
                    ("The type `%s` returns is worked out from its body, which uses `%s` before that's known; "
                        ~ "write the type it returns out").format(name, name));
            }
            nested.usedItself = true;
            return true;
        }
        return false;
    }

    private Type symbolType(SymbolId symbol)
    {
        symbol.match!((const Id!FunctionDecl f) => settleResult(f), (_) {});
        if (auto type = symbol in _typing.symbolTypes) return *type;
        // A module used as a value; name resolution has already reported it.
        if (symbol.match!((const Id!Module _) => true, _ => false)) return _types.error;
        // This should never happen: every symbol that can be resolved should have a type.
        _collector.reportError(DiagnosticCode.InternalError, Span.init,
            "No type found for symbol %s".format(symbol.to!string));
        return _types.error;
    }

    private Type synthesizeWhile(const WhileExpr while_, Span span, BodyContext ctx)
    {
        if (while_.binding is null)
        {
            auto condType = synthesize(*while_.condition, ctx);
            requireAssignable(condType, _types.bool_, while_.condition.span);
        }
        else
        {
            checkOptionBinding(*while_.binding, "while val", ctx);
        }
        checkLoopBody(*while_.body, ctx);
        return _types.unit;
    }

    private Type synthesizeFor(const Expr expr, const ForExpr for_, BodyContext ctx)
    {
        auto iterable = &for_.binding.value;
        auto range = asRange(iterable);
        _typing.symbolTypes[SymbolId(for_.binding.id)] = range is null
            ? synthesizeForValue(expr, *iterable, ctx)
            : synthesizeForRange(*iterable, *range, ctx);
        checkLoopBody(*for_.body, ctx);
        return _types.unit;
    }

    /// The element type of what a `for` loops over, which isn't `a..b`: an array, or a value that
    /// `next` takes.
    private Type synthesizeForValue(const Expr for_, const Expr iterable, BodyContext ctx)
    {
        auto type = _declarer.requireTyped(synthesize(iterable, ctx), iterable.span);
        if (_types.isArray(type)) return _types.arrayElement(type);
        if (type == _types.error || type == _types.never) return type;
        auto element = loopElement(for_, iterable, type, ctx);
        if (element != Type.init) return element;
        _collector.reportError(DiagnosticCode.InvalidOperand, iterable.span,
            "`for` needs an array, a range, or a value that `next` takes; got `%s`"
                .format(_types.describe(type)));
        return _types.error;
    }

    /// A function that syntax calls, as `syntaxFunction` finds it.
    private struct SyntaxUse
    {
        FunctionUse use;
        /// With the type arguments filled in.
        FunctionData signature;
        /// The functions it was chosen from that may ask more than it.
        const(Id!FunctionDecl)[] siblings;
        /// Whether finding it was reported as an error.
        bool failed;

        bool found() const => use.found;
    }

    /// What `for` yields from a `type` that isn't an array, with the functions calls at the loop
    /// would choose. There has to be a `next(r): (T, type)?`. When a `length(r): Int` and an
    /// `opIndex(r, i: Int): T` both take a `type` as well, it loops by index, and otherwise steps.
    /// Each has to take exactly `type`, and `T` is the element type. `Type.init` when neither way is there.
    private Type loopElement(const Expr for_, const Expr iterable, Type type, BodyContext ctx)
    {
        auto index = placeholder(iterable.span);
        auto length = syntaxFunction(for_, iterable.span, "length", "`for`", [iterable], [type], ctx, false);
        auto at = syntaxFunction(for_, iterable.span, "opIndex", "`for`", [iterable, index], [type, _types.int_], ctx, false);
        auto next = syntaxFunction(for_, iterable.span, "next", "`for`", [iterable], [type], ctx, false);
        if (length.failed || at.failed || next.failed) return _types.error;
        if (length.found && at.found)
        {
            if (!takesExactly("length", length, [type], iterable.span)
                || !takesExactly("opIndex", at, [type, _types.int_], iterable.span))
            {
                return _types.error;
            }
            if (length.signature.ret != _types.int_)
            {
                _collector.reportError(DiagnosticCode.InvalidOperand, iterable.span,
                    "`for` loops over `%s` by index with a `length` that returns `Int`, but `%s` returns `%s`"
                        .format(_types.describe(type), describeUse("length", length), _types.describe(length.signature.ret)));
                return _types.error;
            }
            if (!next.found)
            {
                _collector.reportError(DiagnosticCode.InvalidOperand, iterable.span,
                    ("`for` needs a `next` for `%s`: a `length` and an `opIndex` alone don't make it loopable; "
                        ~ "write a `next`, or loop over `iterate()` of it").format(_types.describe(type)));
                return _types.error;
            }
            if (!takesExactly("next", next, [type], iterable.span)) return _types.error;
            if (stepParts(next, type, at.signature.ret, iterable.span).length != 2) return _types.error;
            _typing.loops[for_.id] = LoopFunctions(length.use, at.use);
            auto loopId = for_.id;
            noteSyntaxUse(ctx.site, iterable.span, length, () => &_typing.loops[loopId].length);
            noteSyntaxUse(ctx.site, iterable.span, at, () => &_typing.loops[loopId].index);
            return at.signature.ret;
        }

        if (!next.found) return Type.init;
        if (!takesExactly("next", next, [type], iterable.span)) return _types.error;
        auto parts = stepParts(next, type, Type.init, iterable.span);
        if (parts.length != 2) return _types.error;
        _typing.loops[for_.id] = LoopFunctions(FunctionUse.init, FunctionUse.init, next.use);
        auto loopId = for_.id;
        noteSyntaxUse(ctx.site, iterable.span, next, () => &_typing.loops[loopId].next);
        if (ctx.site.function_.isValid && isGenericFunction(ctx.site.function_))
        {
            _steppedLoops ~= SteppedLoop(ctx.site, iterable.span, for_.id, type, parts[0]);
            _steppedLoops[$ - 1].site.unsettled = null;
        }
        return parts[0];
    }

    /// The element and rest of what `next` returns for a `type`, which has to be `(T, type)?`, with
    /// `T` the `element` when that's given. Empty, after reporting it, when it isn't.
    private immutable(Type)[] stepParts(SyntaxUse next, Type type, Type element, Span span)
    {
        auto result = next.signature.ret;
        auto step = _types.isOption(result) ? _types.optionInner(result) : Type.init;
        auto parts = step != Type.init && _types.isTuple(step) ? _types.tupleElements(step) : null;
        if (parts.length == 2 && parts[1] == type && (element == Type.init || parts[0] == element)) return parts;
        _collector.reportError(DiagnosticCode.InvalidOperand, span,
            "`for` steps `%s` with a `next` that returns `(%s, %s)?`, but `%s` returns `%s`".format(_types.describe(type),
                element == Type.init ? "T" : _types.describe(element), _types.describe(type),
                describeUse("next", next), _types.describe(result)));
        return null;
    }

    /// The function `name` that `syntax` at `at` calls with `args`, chosen as a call is from the
    /// functions resolution found there, with its type arguments bound by the arguments. An
    /// argument with a type in `typed` has it already: it's been synthesized, or it's a placeholder
    /// for a value with no expression, which the caller checks. The rest are checked against their
    /// parameters. Not found when no function takes them, which is reported when `required`;
    /// failed when finding one reported an error.
    private SyntaxUse syntaxFunction(const Expr at, Span span, string name, string syntax, const(Expr)[] args,
        Type[] typed, BodyContext ctx, bool required = true)
    {
        SyntaxUse failed;
        failed.failed = true;
        void typeTheRest()
        {
            foreach (i, arg; args)
            {
                if (typed[i] == Type.init) checkArgument(arg, _types.error, ctx);
            }
        }

        auto lookups = at.id in _resolutions.operatorLookups;
        auto recorded = lookups is null ? null : name in *lookups;
        const(Candidates)* lookup = recorded is null ? null : [distinct(*recorded)].ptr;
        // What's indexed or looped over is what a reader looks for the function by.
        bool takesFirst(Id!FunctionDecl f)
        {
            auto params = signatureOf(f).params;
            auto typeParams = _resolutions.typeParamsOf(f);
            return params.length == args.length && typedFit(typed[0], params[0], typeParams, false) != Fit.none;
        }
        if (lookup is null || !lookup.groups.joiner.any!takesFirst)
        {
            if (!required) return SyntaxUse.init;
            typeTheRest();
            _collector.reportError(DiagnosticCode.InvalidOperand, args[0].id.isValid ? args[0].span : span,
                "%s calls `%s`, and no `%s` here takes a `%s`".format(syntax, name, name, _types.describe(typed[0])));
            return failed;
        }
        // Each argument with a type of its own is synthesized once, so it's fitted by its type.
        foreach (i, arg; args)
        {
            if (typed[i] == Type.init && !isShaped(arg)) typed[i] = synthesize(arg, ctx);
        }
        auto call = CallExpr(null, cast(Expr[]) args);
        Candidates fitting;
        Trial[][] trials;
        Trial[][] tried;
        foreach (group; lookup.groups)
        {
            Trial[] fits;
            Trial[] all;
            foreach (f; group)
            {
                auto trial = arityTrial(f, args.length, 0);
                if (trial.fitsAll) fitTrial(trial, call, typed, null, false, ctx, Type.init);
                all ~= trial;
                if (trial.fitsAll) fits ~= trial;
            }
            trials ~= fits;
            tried ~= all;
            fitting.groups ~= fits.map!(t => t.func).array;
        }
        fitting.sources = lookup.sources.dup;
        auto reportable = !typed.any!(t => t != Type.init && _types.mentionsError(t));
        if (fitting.count == 0)
        {
            if (!required) return SyntaxUse.init;
            typeTheRest();
            if (reportable) reportNoOverload(span, name, tried);
            return failed;
        }

        auto imported = rankedImports(trials[1 .. $]);
        if (fitting.groups[0].length == 0 && imported.length > 1)
        {
            typeTheRest();
            auto modules = importsOf(*lookup, imported.map!(g => functionsOf(g)));
            _collector.reportError(DiagnosticCode.AmbiguousName, span,
                ("%s could use `%s` from more than one imported module (%s); declare one in this module that "
                    ~ "calls the one you mean, as in `def %s(...) => %s.%s(...)`")
                    .format(syntax, name, modules.join(", "), name, modules[0], name));
            return failed;
        }
        auto named = Expr(Id!Expr.init, span, ExprKind(Identifier(name)));
        auto function_ = chooseFunction(named, name, null, fitting, call, typed, false, ctx);
        if (!function_.isValid)
        {
            typeTheRest();
            return failed;
        }

        auto params = _resolutions.typeParamsOf(function_);
        auto signature = signatureOf(function_);
        Binding binding;
        binding.typed = typed;
        bindCall(binding, signature, signature.ret, params, function_, call, Type.init, ctx, false);
        auto bound = binding.bound;
        auto checked = binding.checked;
        void typeUnchecked()
        {
            foreach (i, arg; args)
            {
                if (typed[i] == Type.init && !checked[i] && arg.id.isValid) synthesize(arg, ctx);
            }
        }
        auto unbound = params.filter!(p => p.id !in bound);
        if (!unbound.empty)
        {
            typeUnchecked();
            _collector.reportError(DiagnosticCode.CannotInferTypeArgument, span,
                "%s uses `%s: %s` here, but nothing it passes says what its `%s` is".format(syntax, name,
                    _types.describe(symbolType(SymbolId(function_))), unbound.front.name));
            return failed;
        }
        auto conformance = conformanceOf(function_, bound, ctx.site);
        if (conformance.failure !is null)
        {
            typeUnchecked();
            _collector.reportError(conformance.tooDeep ? DiagnosticCode.BoundSearchTooDeep : DiagnosticCode.UnsatisfiedBound, span,
                "%s calls `%s`, and `%s` %s".format(syntax, name, overloadLabel(function_), conformance.failure));
            return failed;
        }
        SyntaxUse found;
        found.use = FunctionUse(function_, params.map!(p => bound[p.id]).array, conformance.witnesses);
        found.siblings = siblingsOf(*lookup, function_);
        found.signature = signatureOf(_types.substitute(symbolType(SymbolId(function_)), bound));
        foreach (i, arg; args)
        {
            if (checked[i] || !arg.id.isValid) continue;
            if (typed[i] != Type.init) coerce(arg, typed[i], found.signature.params[i]);
            else checkArgument(arg, found.signature.params[i], ctx);
        }
        return found;
    }

    /// Whether `use` takes exactly `params`, reporting it when not, since a `for` doesn't convert
    /// what it passes.
    private bool takesExactly(string name, const SyntaxUse use, const(Type)[] params, Span span)
    {
        if (use.signature.params == params) return true;
        auto describe(const(Type)[] types) => types.length == 1
            ? "`%s`".format(_types.describe(types[0]))
            : "`(%s)`".format(types.map!(t => _types.describe(t)).join(", "));
        _collector.reportError(DiagnosticCode.InvalidOperand, span,
            "`for` calls a `%s` that takes exactly %s, but `%s` takes %s"
                .format(name, describe(params), describeUse(name, use), describe(use.signature.params)));
        return false;
    }

    /// A function that syntax uses, as an error message names it, with its signature.
    private string describeUse(string name, const SyntaxUse use)
    {
        return "%s: %s".format(name, _types.describe(symbolType(SymbolId(use.use.func))));
    }

    /// The type of a `for` range's bounds, which is also its own type and that of each value.
    /// Only integers count, and a literal takes the type of the number beside it.
    private Type synthesizeForRange(const Expr expr, const RangeExpr range, BodyContext ctx)
    {
        auto startType = synthesize(*range.start, ctx);
        auto endType = synthesize(*range.end, ctx);
        if (_types.isInteger(startType) && isIntLiteral(*range.end) && !isIntLiteral(*range.start))
        {
            endType = adaptLiteral(*range.end, startType);
        }
        else if (_types.isInteger(endType) && isIntLiteral(*range.start) && !isIntLiteral(*range.end))
        {
            startType = adaptLiteral(*range.start, endType);
        }

        auto type = join(startType, endType, expr.span, "Range bounds");
        if (type != _types.error && type != _types.never && !_types.isInteger(type))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, expr.span,
                "`for` needs a range of integers, got `%s`".format(_types.describe(type)));
            type = _types.error;
        }
        _typing.exprTypes[expr.id] = type;
        return type;
    }

    /// `break` and `continue` act on the loop whose body holds them, so a condition or what a
    /// `for` loops over isn't part of this and they belong to any loop around it.
    private void checkLoopBody(const Expr body, BodyContext ctx)
    {
        ctx.inLoop = true;
        checkDiscarded(body, ctx);
    }

    /// The condition, or the binding of an `if val`.
    private void checkIfHead(const IfExpr if_, BodyContext ctx)
    {
        if (if_.binding is null)
        {
            auto condType = synthesize(*if_.condition, ctx);
            requireAssignable(condType, _types.bool_, if_.condition.span);
            return;
        }

        checkOptionBinding(*if_.binding, "if val", ctx);
    }

    /// The binding of an `if val` or `while val`, which holds the payload of its initializer.
    private void checkOptionBinding(const VarDecl binding, string keyword, BodyContext ctx)
    {
        auto initializer = binding.value;
        auto optionType = _declarer.requireTyped(synthesize(initializer, ctx), initializer.span);
        auto payload = _types.error;
        if (_types.isOption(optionType))
        {
            payload = _types.optionInner(optionType);
        }
        else if (_types.isErrorUnion(optionType) && keyword == "while val")
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, initializer.span,
                "`while val` would end the loop on an error without a word; pass it on first, as in `while val x = f()? { ... }`");
        }
        else if (_types.isErrorUnion(optionType))
        {
            payload = _types.successOf(optionType);
        }
        else if (optionType != _types.error)
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, initializer.span,
                "`%s` needs an option, got `%s`".format(keyword, _types.describe(optionType)));
        }
        _typing.symbolTypes[SymbolId(binding.id)] = payload;
    }

    private Type synthesizeIf(const IfExpr if_, Span span, BodyContext ctx, Type errors = Type.init)
    {
        checkIfHead(if_, ctx);
        if (if_.falseBody is null)
        {
            checkDiscarded(*if_.trueBody, ctx);
            return _types.unit;
        }

        auto thenType = synthesizeBeside(*if_.trueBody, errors, ctx);
        auto elseType = synthesizeBeside(*if_.falseBody, errors, ctx);
        auto joined = join(thenType, elseType, span, "Branches");
        if (joined != _types.error)
        {
            coerce(*if_.trueBody, thenType, joined);
            coerce(*if_.falseBody, elseType, joined);
        }
        return joined;
    }

    /// The type that both `a` and `b` fit, or `error` (reported at `span`) if there isn't one.
    /// `what` names the things that have these types, for the error.
    private Type join(Type a, Type b, Span span, string what)
    {
        if (a == _types.error || b == _types.error) return _types.error;
        if (a == _types.never) return b;
        if (b == _types.never) return a;
        if (isAssignable(a, b)) return b;
        if (isAssignable(b, a)) return a;
        if (a == _types.none) return _declarer.optionOf(b, span);
        if (b == _types.none) return _declarer.optionOf(a, span);
        // A bare `Error(e)` beside a value that isn't an error union makes one.
        auto valued = (Type t) => !_types.isFailure(t) && !_types.isErrorUnion(t) && t != _types.emptyArray;
        if (_types.isFailure(a) && valued(b)) return _types.errorUnion(b, _types.errorOf(a));
        if (_types.isFailure(b) && valued(a)) return _types.errorUnion(a, _types.errorOf(b));

        if (_types.sameApartFromError(a, b)) return _types.error;
        _collector.reportError(DiagnosticCode.TypeMismatch, span,
            "%s have different types `%s` and `%s`".format(what, _types.describe(a), _types.describe(b)));
        return _types.error;
    }

    private Type synthesizeBlock(const BlockExpr block, Span span, BodyContext ctx, Type errors = Type.init)
    {
        foreach (stmt; block.statements)
        {
            checkStmt(stmt, ctx);
        }
        if (block.value !is null)
        {
            return synthesizeBeside(*block.value, errors, ctx);
        }
        return valuelessBlockType(block);
    }

    /// The type of a block with no value expression, after its statements have been checked.
    private Type valuelessBlockType(const BlockExpr block)
    {
        if (block.statements.length > 0 && alwaysExits(block.statements[$ - 1]))
        {
            return _types.never;
        }
        return _types.unit;
    }

    /// Whether control never continues past `stmt`, so a block ending in it has type Never.
    private bool alwaysExits(const Stmt stmt)
    {
        return stmt.kind.match!(
            (const ReturnStmt _) => true,
            (const BreakStmt _) => true,
            (const ContinueStmt _) => true,
            (const ExprStmt e) => _typing.exprTypes.get(e.expr.id, _types.error) == _types.never,
            _ => false,
        );
    }

    private Type synthesizeIdentifier(const Expr expr, Type expected, Site site)
    {
        if (auto candidates = expr.id in _resolutions.overloads) return overloadedValue(expr, distinct(*candidates), expected, site);
        if (auto symbol = expr.id in _resolutions.resolutions) return namedValue(expr, *symbol, expected, site);
        // Name resolution couldn't find it and has already reported that.
        return _types.error;
    }

    /// What `name`, which resolution found to be `symbol`, is as a value.
    private Type namedValue(const Expr name, SymbolId symbol, Type expected, Site site)
    {
        if (!site.inTest && symbol.match!((const Id!FunctionDecl f) => isIntrinsic(f, "panics"), _ => false))
        {
            reportPanicsOutsideTest(name.span);
            return _types.error;
        }
        if (usesUnsettled(symbol, site)) return _types.error;
        symbol.match!((const Id!TypeDecl type) => noteInvariantUse(InvariantUse(site, name.span, type, name.id)), (_) {});
        auto generic = genericNamed(name);
        if (generic.found && !takesAnyIntrinsically(symbol)) return instantiateValue(name, generic, expected, site);
        if (generic.found) _declarer.resolveTypeArguments(generic.written);
        else rejectTypeArguments(typeArgsOf(name), spelling(name), name.span);
        return symbolValue(symbol, name.span, site);
    }

    /// Whether a constructor of `member`, which `owner` owns, should build the member itself.
    private bool wantsMember(Type member, Type owner, Type expected)
    {
        if (expected == member) return true;
        if (_types.isOption(expected)) return wantsMember(member, owner, _types.optionInner(expected));
        if (_types.isErrorUnion(expected)) return wantsMember(member, owner, _types.successOf(expected));
        return expected != owner && _declarer.membersOf(expected).canFind(member);
    }

    /// The one member of `sum` that the option, array or tuple written out as `expr` can be, or
    /// `Type.init` if `expr` isn't one of those or there's no single member.
    private Type memberForSyntax(const Expr expr, Type sum)
    {
        auto candidates = expr.kind.match!(
            (const SomeExpr _) => _declarer.membersOf(sum).filter!(m => _types.isOption(m)).array,
            (const NoneLiteral _) => _declarer.membersOf(sum).filter!(m => _types.isOption(m)).array,
            (const ArrayLiteral _) => _declarer.membersOf(sum).filter!(m => _types.isArray(m)).array,
            (const BinaryExpr _) => isArraySyntax(expr) ? _declarer.membersOf(sum).filter!(m => _types.isArray(m)).array : null,
            (const TupleLiteral literal) => _declarer.membersOf(sum)
                .filter!(m => _types.isTuple(m) && _types.tupleElements(m).length == literal.elements.length).array,
            _ => (const(Type)[]).init,
        );
        return candidates.length == 1 ? candidates[0] : Type.init;
    }

    private Type check(const Expr expr, Type expected, BodyContext ctx)
    {
        if (isLambda(expr) && _types.isFunction(expected))
        {
            auto data = _types[expected].match!(
                (const FunctionData f) => f,
                (_) => assert(0, "checked above"),
            );
            auto lambda = expr.kind.match!(
                (const Lambda l) => l,
                (_) => assert(0, "checked above"),
            );
            return coerce(expr, typeLambda(expr, lambda, &data, ctx.site), expected);
        }
        // What's expected can say what a generic use's type arguments are, also through `!` and `?`.
        auto isMethod = expr.kind.match!((const CallExpr call) => isMethodCall(expr.id, *call.callee), _ => false);
        auto unwraps = expr.kind.match!((const AssertExpr _) => true, (const PropagateExpr _) => true, _ => false);
        if (isMethod || unwraps || genericUse(expr).found || isOverloadedUse(expr))
        {
            return coerce(expr, synthesizeExact(expr, ctx, expected), expected);
        }
        auto constructed = constructedDecl(expr);
        if (auto owner = _declarer.ownerOf(constructed))
        {
            auto member = _typing.nominalTypes[constructed];
            if (wantsMember(member, *owner, expected)) return coerce(expr, synthesizeExact(expr, ctx), expected);
        }
        if (_declarer.isSum(expected))
        {
            auto member = memberForSyntax(expr, expected);
            if (member != Type.init)
            {
                check(expr, member, ctx);
                _typing.promotions[expr.id] = expected;
                return expected;
            }
        }

        if (_types.isErrorUnion(expected))
        {
            auto written = expr.kind.match!(
                (const OkExpr ok) {
                    check(*ok.value, _types.successOf(expected), ctx);
                    return true;
                },
                (const ErrorExpr error) {
                    check(*error.value, _types.errorOf(expected), ctx);
                    return true;
                },
                _ => false,
            );
            if (written)
            {
                _typing.exprTypes[expr.id] = expected;
                return expected;
            }
            // Written out as what the success side takes its type from, then promoted.
            if (isOptionSyntax(expr) || isArraySyntax(expr) || isTupleLiteral(expr) || isLambda(expr))
            {
                check(expr, _types.successOf(expected), ctx);
                _typing.promotions[expr.id] = expected;
                return expected;
            }
        }

        // A number, option, array or tuple is passed down, so that a literal adapts, and a value is
        // promoted, in an `if` arm or as a block's value too.
        auto isOption = _types.isOption(expected);
        auto isArray = _types.isArray(expected);
        auto isTuple = _types.isTuple(expected);
        // An array or tuple written out against an option is checked against what it holds, then promoted.
        if (isOption && (isArraySyntax(expr) || isTupleLiteral(expr) || isLambda(expr)))
        {
            check(expr, _types.optionInner(expected), ctx);
            _typing.promotions[expr.id] = expected;
            return expected;
        }
        if (isNumeric(expected) || isOption || isArray || isTuple || _declarer.isSum(expected) || _declarer.isOwnedMember(expected)
            || _types.isFunction(expected) || _types.isErrorUnion(expected))
        {
            auto passedDown = expr.kind.match!(
                (const IfExpr if_) => if_.falseBody !is null,
                (const BlockExpr _) => true,
                (const SomeExpr _) => isOption,
                (const ArrayLiteral _) => isArray,
                (const BinaryExpr _) => isArray && isArraySyntax(expr),
                (const TupleLiteral literal) => isTuple && literal.elements.length == _types.tupleElements(expected).length,
                (const MatchExpr match_) => match_.origin != MatchOrigin.IfVal,
                _ => false,
            );
            if (passedDown)
            {
                auto type = expr.kind.match!(
                    (const IfExpr if_) => checkIf(if_, expected, ctx),
                    (const BlockExpr block) => checkBlock(expr, block, expected, ctx),
                    (const SomeExpr some) {
                        check(*some.value, _types.optionInner(expected), ctx);
                        return expected;
                    },
                    (const ArrayLiteral literal) {
                        foreach (element; literal.elements)
                        {
                            check(element, _types.arrayElement(expected), ctx);
                        }
                        return expected;
                    },
                    (const BinaryExpr binary) {
                        recordConcat(expr, binary);
                        check(*binary.left, expected, ctx);
                        check(*binary.right, expected, ctx);
                        return expected;
                    },
                    (const TupleLiteral literal) {
                        foreach (i, element; literal.elements)
                        {
                            check(element, _types.tupleElements(expected)[i], ctx);
                        }
                        return expected;
                    },
                    (const MatchExpr match_) => checkMatch(match_, expected, expr.span, ctx),
                    (_) => assert(0, "only ifs, blocks, matches, Some, arrays and tuples are passed down"),
                );
                _typing.exprTypes[expr.id] = type;
                return type;
            }
        }

        return coerce(expr, synthesize(expr, ctx), expected);
    }

    /// Fits `expr`, already found to have type `type`, to `expected`: a literal adapts and a
    /// value that isn't an option yet is promoted, and anything else has to be assignable.
    private Type coerce(const Expr expr, Type type, Type expected)
    {
        if (isNumeric(expected) && isIntLiteral(expr))
        {
            return adaptLiteral(expr, expected);
        }
        if (_declarer.isSum(expected))
        {
            auto hasValue = type != _types.error && type != _types.never;
            if (hasValue && type != expected)
            {
                if (isIntLiteral(expr)) return injectLiteral(expr, expected);
                if (isAssignable(type, expected))
                {
                    _typing.promotions[expr.id] = expected;
                    return expected;
                }
            }
        }
        else if (_types.isOption(expected))
        {
            if (isBothSides(expr, type, expected)) return _types.error;
            if (isIntLiteral(expr)) type = adaptLayered(expr, type, expected);
            auto hasValue = type != _types.error && type != _types.never;
            if (hasValue && type != expected && isAssignable(type, expected))
            {
                _typing.promotions[expr.id] = expected;
                return expected;
            }
        }
        else if (_types.isErrorUnion(expected))
        {
            if (isBothSides(expr, type, expected)) return _types.error;
            if (isIntLiteral(expr)) type = adaptLayered(expr, type, expected);
            auto hasValue = type != _types.error && type != _types.never;
            if (hasValue && type != expected && isAssignable(type, expected))
            {
                _typing.promotions[expr.id] = expected;
                return expected;
            }
        }
        else if (expected == _types.any)
        {
            type = _declarer.requireTyped(type, expr.span);
        }
        else if (type == _types.emptyArray && _types.isArray(expected))
        {
            _typing.promotions[expr.id] = expected;
            return expected;
        }
        requireAssignable(type, expected, expr.span);
        return type;
    }

    /// An integer literal, of type `type`, under the option and error-union layers of `expected`:
    /// adapted to the number at their core, or injected into the sum there.
    private Type adaptLayered(const Expr expr, Type type, Type expected)
    {
        auto core = layerCore(expected);
        if (isNumeric(core)) return adaptLiteral(expr, core);
        if (_declarer.isSum(core)) return injectLiteral(expr, core);
        return type;
    }

    /// Reports `expr`, of `type`, when an error-union layer of `expected` lists it as an error and
    /// it could also become that layer's success, since it would silently be a success.
    private bool isBothSides(const Expr expr, Type type, Type expected)
    {
        if (type == _types.error || type == _types.never || _types.mentionsError(type) || _types.isErrorUnion(type)
            || _types.isFailure(type) || type == _types.none || type == _types.emptyArray) return false;
        for (auto layer = expected; _types.isOption(layer) || _types.isErrorUnion(layer);
            layer = _types.isOption(layer) ? _types.optionInner(layer) : _types.successOf(layer))
        {
            if (!_types.isErrorUnion(layer) || _types.mentionsError(layer)) continue;
            if (!errorFits(type, _types.errorOf(layer)) || !isAssignable(type, _types.successOf(layer))) continue;
            _collector.reportError(DiagnosticCode.ErrorOrSuccess, expr.span,
                "`%s` is one of the errors of `%s` and can also be its success; write `Error(...)` to fail with it, or `Ok(...)` to succeed"
                    .format(_types.describe(type), _types.describe(layer)));
            return true;
        }
        return false;
    }

    /// `type` with every option and error-union success layer taken off.
    private Type layerCore(Type type)
    {
        while (true)
        {
            if (_types.isOption(type)) type = _types.optionInner(type);
            else if (_types.isErrorUnion(type)) type = _types.successOf(type);
            else return type;
        }
    }

    /// An integer literal in a sum takes the type of its only integer member, or else of a Float one.
    private Type injectLiteral(const Expr expr, Type sum)
    {
        auto integers = _declarer.membersOf(sum).filter!(m => _types.isInteger(m)).array;
        if (integers.length > 1)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
                "`%s` has more than one integer member; convert this to the one you mean, as in `%s(...)`"
                    .format(_types.describe(sum), _types.describe(integers[0])));
            return _types.error;
        }
        auto numbers = integers.length == 1 ? integers : _declarer.membersOf(sum).filter!(m => m == _types.float_).array;
        if (numbers.length == 1)
        {
            adaptLiteral(expr, numbers[0]);
            _typing.promotions[expr.id] = sum;
            return sum;
        }
        auto hint = _declarer.membersOf(sum).any!(m => _types.isOption(m) && isNumeric(innermost(m))) ? "; write `Some(...)`" : "";
        _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
            "An integer isn't a member of `%s`%s".format(_types.describe(sum), hint));
        return _types.error;
    }

    /// The subject and every pattern of a `match`, then whether the arms cover it. Bindings have
    /// their types once this returns, so the arms can be checked.
    private void checkMatchHead(const MatchExpr match_, Span span, BodyContext ctx)
    {
        auto subject = _declarer.requireTyped(synthesize(*match_.subject, ctx), match_.subject.span);
        auto reported = _collector.diagnostics.length;
        auto outer = _unresolvedPattern;
        _unresolvedPattern = false;
        scope (exit) _unresolvedPattern = outer;
        auto patterns = match_.arms.map!(arm => checkArmPattern(arm.pattern, subject, ctx)).array;
        if (match_.origin != MatchOrigin.Match || subject == _types.error || subject == _types.never) return;
        // A pattern that's already wrong would only be reported again as a gap in the coverage, or
        // make the arms after it look unreachable.
        if (_collector.diagnostics.length > reported || _unresolvedPattern) return;
        checkCoverage(match_, patterns, subject, span, _types, _declarer, _collector);
    }

    private Type synthesizeMatch(const MatchExpr match_, Span span, BodyContext ctx, Type errors = Type.init)
    {
        if (match_.origin == MatchOrigin.IfVal)
        {
            checkDiscardedMatch(match_, span, ctx);
            return _types.unit;
        }
        checkMatchHead(match_, span, ctx);
        auto types = match_.arms.map!(arm => synthesizeBeside(arm.body, errors, ctx)).array;
        auto joined = _types.never;
        foreach (i, type; types)
        {
            joined = join(joined, type, match_.arms[i].body.span, "Match arms");
        }
        if (joined == _types.error) return joined;
        foreach (i, arm; match_.arms)
        {
            coerce(arm.body, types[i], joined);
        }
        return joined;
    }

    private Type checkMatch(const MatchExpr match_, Type expected, Span span, BodyContext ctx)
    {
        checkMatchHead(match_, span, ctx);
        auto types = match_.arms.map!(arm => check(arm.body, expected, ctx)).array;
        return types.all!(t => t == _types.never) ? _types.never : expected;
    }

    private Type checkDiscardedMatch(const MatchExpr match_, Span span, BodyContext ctx)
    {
        checkMatchHead(match_, span, ctx);
        auto types = match_.arms.map!(arm => checkDiscarded(arm.body, ctx)).array;
        return types.all!(t => t == _types.never) ? _types.never : _types.unit;
    }

    private bool isUnknown(Type type)
    {
        return type == _types.error || type == _types.never;
    }

    private CoveragePattern reportPattern(Span span, string message)
    {
        _collector.reportError(DiagnosticCode.PatternMismatch, span, message);
        return CoveragePattern.init;
    }

    /// Checks `pattern` against a value of `subject`, giving each binding its type.
    private CoveragePattern checkArmPattern(const Pattern pattern, Type subject, BodyContext ctx, bool throughLists = true)
    {
        if (throughLists && _types.isErrorList(subject)) return checkListPattern(pattern, subject, ctx);
        _typing.patternSubjects[pattern.id] = subject;
        if (_types.isParameter(subject))
        {
            auto bound = pattern.kind.match!(
                (const VarDecl binding) {
                    auto type = binding.type is null ? subject : _declarer.resolveType(*binding.type);
                    _typing.symbolTypes[SymbolId(binding.id)] = type;
                    return type == subject || type == _types.error;
                },
                (_) {
                    checkArmPattern(pattern, _types.error, ctx);
                    _typing.patternSubjects[pattern.id] = subject;
                    return false;
                },
            );
            if (!bound) reportOpaque(pattern.span, subject, "a pattern on it can only bind it to a name", null);
            return CoveragePattern.init;
        }
        return pattern.kind.match!(
            (const VarDecl binding) => checkArmBinding(pattern, binding, subject),
            (const TuplePattern tuple) => checkArmTuple(pattern, tuple, subject, ctx),
            (const ConstructorPattern constructor) => checkArmConstructor(pattern, constructor, subject, ctx),
            (const SomePattern some) {
                if (_types.isOption(subject))
                {
                    return CoveragePattern("some", [checkArmPattern(*some.inner, _types.optionInner(subject), ctx)]);
                }
                checkArmPattern(*some.inner, _types.error, ctx);
                if (isUnknown(subject)) return CoveragePattern.init;
                return reportPattern(pattern.span, "`Some` needs an option, but the value is `%s`".format(_types.describe(subject)));
            },
            (const NonePattern _) {
                if (_types.isOption(subject)) return CoveragePattern("none");
                if (isUnknown(subject)) return CoveragePattern.init;
                return reportPattern(pattern.span, "`None` needs an option, but the value is `%s`".format(_types.describe(subject)));
            },
            (const OkPattern ok) {
                if (_types.isErrorUnion(subject))
                {
                    return CoveragePattern("ok", [checkArmPattern(*ok.inner, _types.successOf(subject), ctx)]);
                }
                checkArmPattern(*ok.inner, _types.error, ctx);
                if (isUnknown(subject)) return CoveragePattern.init;
                return reportPattern(pattern.span, "`Ok` needs an error union, but the value is `%s`".format(_types.describe(subject)));
            },
            (const ErrorPattern error) {
                if (_types.isErrorUnion(subject))
                {
                    return CoveragePattern("error", [checkArmPattern(*error.inner, _types.errorOf(subject), ctx)]);
                }
                checkArmPattern(*error.inner, _types.error, ctx);
                if (isUnknown(subject)) return CoveragePattern.init;
                return reportPattern(pattern.span, "`Error` needs an error union, but the value is `%s`".format(_types.describe(subject)));
            },
            (const LiteralPattern literal) {
                if (isOrdered(subject) || subject == _types.bool_)
                {
                    check(*literal.value, subject, ctx);
                    return CoveragePattern(printExpr(*literal.value));
                }
                synthesize(*literal.value, ctx);
                if (isUnknown(subject)) return CoveragePattern.init;
                return reportPattern(pattern.span, "A literal can't match a value of type `%s`".format(_types.describe(subject)));
            },
        );
    }

    /// A pattern on a value of the error list `subject`. One that names a member of a declared sum
    /// the list names reaches through it, as widening does, so it tests for that sum first.
    private CoveragePattern checkListPattern(const Pattern pattern, Type subject, BodyContext ctx)
    {
        auto members = _declarer.membersOf(subject);
        auto instances = bareInstances(pattern, members);
        if (instances.length > 1)
        {
            pattern.kind.match!(
                (const ConstructorPattern c) { foreach (argument; c.arguments) checkArmPattern(argument, _types.error, ctx); },
                (_) {},
            );
            _collector.reportError(DiagnosticCode.AmbiguousInstance, pattern.span, ambiguousInstanceMessage(subject, pattern, instances));
            return CoveragePattern.init;
        }
        auto through = reachedThrough(pattern, members);
        if (through >= 0)
        {
            _typing.patternsThrough[pattern.id] = through;
            auto inner = checkArmPattern(pattern, members[through], ctx);
            _typing.patternListSubjects[pattern.id] = subject;
            return CoveragePattern("member%s".format(through), [inner]);
        }
        _typing.patternsThrough.remove(pattern.id);
        auto result = checkArmPattern(pattern, subject, ctx, false);
        // Coverage looks inside a sum the list names, so a pattern for all of it is a wildcard there.
        if (auto index = pattern.id in _typing.patternMembers)
        {
            if (_declarer.isSum(members[*index])) result.args = [CoveragePattern.init];
        }
        return result;
    }

    /// Which of an error list's `members` a pattern reaches through, or -1 when it doesn't: one
    /// that names a type the list doesn't, which a declared sum the list names has as a member.
    private ptrdiff_t reachedThrough(const Pattern pattern, const(Type)[] members)
    {
        Id!TypeDecl decl;
        auto written = Type.init;
        pattern.kind.match!(
            (const ConstructorPattern c) {
                if (c.type.kind.match!((const NamedType n) => n.args.length > 0, (_) => false))
                {
                    written = quietlyResolved(c.type);
                }
                else if (auto symbol = c.type.id in _resolutions.typeResolutions)
                {
                    // An alias names one instance, so it reaches only a sum that has that one.
                    (*symbol).match!(
                        (const Id!AliasDecl a) { written = _declarer.aliasType(a); },
                        (_) {
                            expandAlias(*symbol, _resolutions.declarations.aliases, _resolutions.typeResolutions)
                                .match!((const Id!TypeDecl t) { decl = t; }, (_) {});
                        },
                    );
                }
            },
            (const VarDecl binding) {
                if (binding.type !is null) written = quietlyResolved(*binding.type);
            },
            (_) {},
        );
        bool names(Type t) => decl.isValid ? declOf(t) == decl : t == written;
        if (!decl.isValid && written == Type.init) return -1;
        if (members.any!(m => names(m))) return -1;
        return members.countUntil!(m => _declarer.isSum(m) && _declarer.membersOf(m).any!(x => names(x)));
    }

    /// The instances of a generic type that a constructor pattern written without type arguments
    /// or an alias can reach in an error list's `members`, directly or through a sum the list
    /// names; none for any other pattern.
    private Type[] bareInstances(const Pattern pattern, const(Type)[] members)
    {
        Id!TypeDecl decl;
        pattern.kind.match!(
            (const ConstructorPattern c) {
                if (c.type.kind.match!((const NamedType n) => n.args.length > 0, (_) => false)) return;
                if (auto symbol = c.type.id in _resolutions.typeResolutions)
                {
                    (*symbol).match!((const Id!TypeDecl t) { decl = t; }, (_) {});
                }
            },
            (_) {},
        );
        if (!decl.isValid || _declarer.typeParamsOf(decl).length == 0) return null;
        Type[] found;
        void add(Type t)
        {
            if (declOf(t) == decl && !found.canFind(t)) found ~= t;
        }
        foreach (member; members)
        {
            add(member);
            if (_declarer.isSum(member)) foreach (inner; _declarer.membersOf(member)) add(inner);
        }
        return found;
    }

    /// Why a constructor pattern without type arguments can't take apart a `subject` that can be
    /// each of `instances`.
    private string ambiguousInstanceMessage(Type subject, const Pattern pattern, const(Type)[] instances)
    {
        auto name = pattern.kind.match!((const ConstructorPattern c) => printTypeExpr(c.type), (_) => "");
        return "`%s` can be more than one instance of `%s` (%-(%s%|, %)), so write which, as in `%s(...)`, or name an alias of it"
            .format(_types.describe(subject), name, instances.map!(i => "`%s`".format(_types.describe(i))),
                _types.describe(instances[0]));
    }

    /// Wildcards for what's inside a `member` that a pattern didn't take apart.
    private CoveragePattern[] wildcardsFor(Type member)
    {
        auto fields = _declarer.fieldsOf(member);
        return new CoveragePattern[fields.length];
    }

    /// Records that `pattern` tests for `member` of the sum `subject`, reporting it if there's no such member.
    private bool recordMember(const Pattern pattern, Type member, Type subject, out string key)
    {
        auto index = _declarer.membersOf(subject).countUntil(member);
        if (index < 0)
        {
            reportPattern(pattern.span, "`%s` can't be a `%s`".format(_types.describe(subject), _types.describe(member)));
            return false;
        }
        _typing.patternMembers[pattern.id] = index;
        key = "member%s".format(index);
        return true;
    }

    private CoveragePattern checkArmBinding(const Pattern pattern, const VarDecl binding, Type subject)
    {
        if (binding.type is null)
        {
            _typing.symbolTypes[SymbolId(binding.id)] = subject;
            return CoveragePattern.init;
        }
        auto type = _declarer.resolveType(*binding.type);
        _typing.symbolTypes[SymbolId(binding.id)] = type;
        if (type == _types.error) _unresolvedPattern = true;
        if (type == _types.error || isUnknown(subject) || type == subject) return CoveragePattern.init;

        string key;
        if (!recordMember(pattern, type, subject, key)) return CoveragePattern.init;
        return CoveragePattern(key, wildcardsFor(type));
    }

    private CoveragePattern checkArmTuple(const Pattern pattern, const TuplePattern tuple, Type subject, BodyContext ctx)
    {
        if (_types.isTuple(subject) && _types.tupleElements(subject).length == tuple.elements.length)
        {
            auto parts = _types.tupleElements(subject);
            CoveragePattern[] args;
            foreach (i, element; tuple.elements)
            {
                args ~= checkArmPattern(element, parts[i], ctx);
            }
            return CoveragePattern("tuple", args);
        }
        foreach (element; tuple.elements)
        {
            checkArmPattern(element, _types.error, ctx);
        }
        if (isUnknown(subject)) return CoveragePattern.init;
        return reportPattern(pattern.span, _types.isTuple(subject)
            ? "This pattern takes apart %s values, but `%s` has %s".format(tuple.elements.length,
                _types.describe(subject), _types.tupleElements(subject).length)
            : "This pattern takes apart a tuple, but the value is `%s`".format(_types.describe(subject)));
    }

    private CoveragePattern checkArmConstructor(const Pattern pattern, const ConstructorPattern constructor,
        Type subject, BodyContext ctx)
    {
        void checkArgumentsAsUnknown()
        {
            foreach (argument; constructor.arguments)
            {
                checkArmPattern(argument, _types.error, ctx);
            }
        }

        Id!TypeDecl decl;
        Type aliased;
        if (auto symbol = constructor.type.id in _resolutions.typeResolutions)
        {
            expandAlias(*symbol, _resolutions.declarations.aliases, _resolutions.typeResolutions)
                .match!((const Id!TypeDecl type) { decl = type; }, (_) {});
            (*symbol).match!((const Id!AliasDecl a) { aliased = _declarer.aliasType(a); }, (_) {});
        }
        else
        {
            // Name resolution reported it.
            _unresolvedPattern = true;
            checkArgumentsAsUnknown();
            return CoveragePattern.init;
        }
        auto written = Type.init;
        if (constructor.type.kind.match!((const NamedType n) => n.args.length > 0, (_) => false))
        {
            written = _declarer.resolveType(constructor.type);
            if (written == _types.error)
            {
                // Name resolution reported an unknown type argument; the declarer, the rest.
                _unresolvedPattern = true;
                checkArgumentsAsUnknown();
                return CoveragePattern.init;
            }
        }
        if (!decl.isValid || _resolutions.declarations.types[decl].members.length > 0)
        {
            checkArgumentsAsUnknown();
            return reportPattern(pattern.span, "`%s` has no constructor; bind a value of it with `name: %s`"
                .format(printTypeExpr(constructor.type), printTypeExpr(constructor.type)));
        }

        if (_declarer.isIntrinsic(decl))
        {
            checkArgumentsAsUnknown();
            return reportPattern(pattern.span, "A `%s` isn't taken apart by a pattern; bind it with a name and read it with `get`"
                .format(printTypeExpr(constructor.type)));
        }

        // A generic type takes the arguments written after it or of the instance an alias names,
        // or else of the instance the subject is or holds.
        auto type = _typing.nominalTypes[decl];
        if (written != Type.init)
        {
            type = written;
        }
        else if (aliased != Type.init && aliased != _types.error && declOf(aliased) == decl)
        {
            type = aliased;
        }
        else if (_declarer.typeParamsOf(decl).length > 0)
        {
            auto instance = (declOf(subject) == decl ? [subject] : _declarer.membersOf(subject).filter!(m => declOf(m) == decl).array);
            if (instance.length > 1)
            {
                checkArgumentsAsUnknown();
                _collector.reportError(DiagnosticCode.AmbiguousInstance, pattern.span,
                    ambiguousInstanceMessage(subject, pattern, instance));
                return CoveragePattern.init;
            }
            Substitution unknown;
            foreach (param; _declarer.typeParamsOf(decl)) unknown[param.id] = _types.error;
            type = instance.length > 0 ? instance[0] : _types.substitute(type, unknown);
        }
        auto fields = _declarer.fieldsOf(type);
        _typing.patternConstructors[pattern.id] = decl;
        if (constructor.arguments.length != fields.length)
        {
            checkArgumentsAsUnknown();
            return reportPattern(pattern.span, "`%s` has %s fields, but this pattern takes apart %s; use `_` for a field you don't need"
                .format(_types.describe(type), fields.length, constructor.arguments.length));
        }

        CoveragePattern[] args;
        foreach (i, argument; constructor.arguments)
        {
            args ~= checkArmPattern(argument, fields[i].type, ctx);
        }
        if (isUnknown(subject)) return CoveragePattern.init;
        if (type == subject) return CoveragePattern("product", args);

        string key;
        if (!recordMember(pattern, type, subject, key)) return CoveragePattern.init;
        return CoveragePattern(key, args);
    }

    private Type checkIf(const IfExpr if_, Type expected, BodyContext ctx)
    {
        checkIfHead(if_, ctx);
        auto thenType = check(*if_.trueBody, expected, ctx);
        auto elseType = check(*if_.falseBody, expected, ctx);
        return thenType == _types.never && elseType == _types.never ? _types.never : expected;
    }

    private Type checkBlock(const Expr expr, const BlockExpr block, Type expected, BodyContext ctx)
    {
        foreach (stmt; block.statements)
        {
            checkStmt(stmt, ctx);
        }
        if (block.value !is null)
        {
            auto type = check(*block.value, expected, ctx);
            return type == _types.never ? type : expected;
        }
        // A Unit block expected to be a `Unit?` is promoted, so its own type stays Unit.
        auto type = valuelessBlockType(block);
        coerce(expr, type, expected);
        return type;
    }

    /// An integer literal, possibly signed: the only integer that takes the type expected of it.
    /// Number values never convert implicitly; only literals adapt to where they're used.
    private bool isLambda(const Expr expr)
    {
        return expr.kind.match!((const Lambda _) => true, _ => false);
    }

    private bool isIntLiteral(const Expr expr)
    {
        return expr.kind.match!(
            (const IntLiteral _) => true,
            (const UnaryExpr unary) => (unary.op == UnaryOp.Minus || unary.op == UnaryOp.Plus)
                && isIntLiteral(*unary.operand),
            _ => false,
        );
    }

    /// Re-records an integer literal (and any sign on it) as `type`.
    private Type adaptLiteral(const Expr expr, Type type)
    {
        expr.kind.match!(
            (const UnaryExpr unary) { adaptLiteral(*unary.operand, type); },
            (_) {},
        );
        _typing.exprTypes[expr.id] = type;
        return type;
    }

    private bool isAssignable(Type from, Type to)
    {
        return fitSteps(from, to) >= 0;
    }

    /// The fit relation: in how many promotion steps a value of type `from` becomes a `to`, or -1
    /// when it can't. Each layer of option or error union it's promoted through is a step, and so
    /// are the widening of an error union and the injection of a member into its sum, so `Box(7)`
    /// into `Held?` is 2. Checking, inference and overload choice all ask this.
    private int fitSteps(Type from, Type to)
    {
        if (from == to) return 0;
        if (from == _types.error || to == _types.error) return 0;  // already reported
        if (from == _types.never) return 0;                         // no value ever arrives
        if (from == _types.none)
        {
            return _types.isOption(to) || _types.isErrorUnion(to) && _types.isOption(_types.successOf(to)) ? 1 : -1;
        }
        if (to == _types.any) return 1;                             // print's placeholder
        if (_types.isFailure(from))
        {
            return (_types.isErrorUnion(to) || _types.isFailure(to)) && errorFits(_types.errorOf(from), _types.errorOf(to)) ? 1 : -1;
        }
        int layer(int inner) => inner < 0 ? -1 : inner + 1;
        return _types[to].match!(
            // T -> T?, through every layer, ending at most in one step into a sum.
            (const OptionData o) => layer(fitSteps(from, o.inner)),
            // Widening, or T -> T ! E as for an option.
            (const ErrorUnionData u) {
                if (_types.isErrorUnion(from) && _types.successOf(from) == u.success) return errorFits(_types.errorOf(from), u.error) ? 1 : -1;
                return layer(fitSteps(from, u.success));
            },
            (const ErrorListData _) => errorFits(from, to) ? 1 : -1,
            (const NominalData _) => _declarer.membersOf(to).canFind(from) ? 1 : -1,
            // Both have the layout of an array with no elements, so no conversion hides here.
            (const ArrayData a) => from == _types.emptyArray
                || (_types.isArray(from) && _types.arrayElement(from) == _types.never) ? 1 : -1,
            _ => -1,
        );
    }

    private void requireAssignable(Type from, Type to, Span span)
    {
        if (isAssignable(from, to) || _types.mentionsError(from) || _types.mentionsError(to)) return;
        auto opaque = _types.isParameter(to)
            ? ", which could be any type; only a value of type `%s` is one".format(_types.describe(to)) : "";
        _collector.reportError(DiagnosticCode.TypeMismatch, span,
            "Type `%s` is not assignable to type `%s`%s".format(_types.describe(from), _types.describe(to), opaque));
    }

}

package Typing checkTypes(const ref Program program, const ref Resolution resolution, Collector collector, NodeIds ids)
{
    auto typeChecker = new TypeChecker(resolution, collector, ids);
    return typeChecker.checkProgram(program);
}