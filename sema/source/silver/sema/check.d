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
import silver.sema.hooks : checkTypeHooks;
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

/// A use of a generic function from a body, with the witnesses checking found for it.
private struct Reference
{
    Site site;
    Span span;
    Id!FunctionDecl func;
    Type[] typeArgs;
    Witness[] witnesses;
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
        foreach (test; resolutions.tests.byKey) _testsByBranch[resolutions.tests[test].branch] = test;
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
    /// What `exportedFunctions` has worked out, by name and then module.
    private const(Id!FunctionDecl)[][string][string] _exported;
    /// How many elements `placePath` has named, so each is a place of its own.
    private size_t _elementPlaces;
    /// The types with an invariant whose `else` hasn't been typed yet, and whether it's being typed.
    private bool[Id!TypeDecl] _pendingInvariants;
    /// Each function whose result type is worked out from its body that has been started on.
    private ResultState[Id!FunctionDecl] _resultStates;
    /// Those found to need their own result type while it was being worked out.
    private bool[Id!FunctionDecl] _recursiveResults;
    /// How far finding each conformance's functions has got.
    private ResultState[Entry] _conformanceStates;
    /// Every conformance, in the order declared.
    private Entry[] _entries;
    /// Those reported as needing themselves to find their functions.
    private bool[Entry] _cycledConformances;
    /// Whether a hint about a missing `conform` line is being worked out, which doesn't look for another.
    private bool _hinting;
    /// How many trials, which drop what they find wrong, the checker is inside.
    private size_t _trials;
    /// What looking a goal on types with no type parameters up found, by the goal.
    private Conformance[Looked] _lookups;
    /// What a `for` asks the element type of its `Range` to be.
    private TypeParam _loopElement;
    private TypeParam _loopRange;
    /// The `if type`s whose true branch is being checked, innermost last, by the `if`.
    private Id!Expr[] _activeTests;
    /// Each `if type`, by its true branch.
    private Id!Expr[Id!Expr] _testsByBranch;
    /// Every use of a generic function, for `rejectGrowingCalls`.
    private Reference[] _references;
    private InvariantUse[] _invariantUses;
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
        qualifyShadowedLibraryTypes(program.prelude);
        _types.writeAsDictionary(_declarer.dictionaryDecl());

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
                    (const ConformDecl _) {},
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
                    (const ConformDecl c) {
                        auto holder = _resolutions.conformances[c.id];
                        _declarer.declareBounds(_resolutions.typeParamsOf(holder));
                        _declarer.declareBoundFunctions(holder);
                        rejectImpossibleBounds(_resolutions.typeParamsOf(holder));
                    },
                    (_) {},
                );
            }
        }

        // After every bound is declared, and before anything that can look a bound up among them.
        declareConformances(programModules);
        checkTypeHooks(programModules, _typing, _resolutions, _collector);

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
            checkOverloads(mod, mod.companionOf is null ? null : program.modules[mod.companionOf]);
            checkForwardedOverloads(mod.name);
            checkListedOverloads(mod.name);
        }

        // After every overload is checked and invariant typed, which finding a conformance's functions
        // can need, and before any body. One that's needed first is found from there.
        foreach (entry; _entries) findConformance(entry);
        checkConformances();

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
                    (const ConformDecl _) {},
                );
            }
        }

        _declarer.checkInhabited(programModules);
        _declarer.rejectGrowingTypes(programModules);
        rejectGrowingCalls();

        foreach (literal; _intLiterals)
        {
            checkLiteralRange(literal);
        }

        // Last, because an integer literal's type isn't final until everything's been checked.
        _typing.constants = evaluateConstants(programModules, _types, _typing.exprTypes, _resolutions, _unevaluable,
            _negatedLiterals, _collector, _literalConstructions, _typing.operators);

        return _typing;
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
            }
        }
        bool generic(Id!FunctionDecl f) => f.isValid && isGenericFunction(f);
        foreach (reference; _references)
        {
            auto from = reference.site.function_;
            if (!generic(from)) continue;
            add(from, reference.func, reference.typeArgs, reference.span);
            addWitnesses(from, reference.witnesses, reference.span);
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

    /// Notes a use of the generic `func` from `site`, for `rejectGrowingCalls`.
    private void noteUse(Site site, Span span, Id!FunctionDecl func, const(Type)[] typeArgs, const(Witness)[] witnesses)
    {
        if (!func.isValid || !isGenericFunction(func)) return;
        site.unsettled = null;
        _references ~= Reference(site, span, func, cast(Type[]) typeArgs, cast(Witness[]) witnesses);
    }

    /// Notes a use of a generic function by the name `g` is written with.
    private void noteNamed(Site site, const Generic g, const(Witness)[] witnesses)
    {
        noteUse(site, g.span, g.func, _typing.typeArguments[g.name], witnesses);
    }

    /// Notes a function that syntax uses, as `noteUse` does.
    private void noteSyntaxUse(Site site, Span span, const SyntaxUse use)
    {
        noteUse(site, span, use.use.func, use.use.typeArgs, use.use.witnesses);
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
    /// Reports two bounds of one of `params` to the same interface that differ only in arguments
    /// the interface's results alone mention: a type has one conformance to an interface, which
    /// says what those are, so no type could meet both.
    private void rejectImpossibleBounds(const(TypeParam)[] params)
    {
        foreach (param; params) rejectImpossibleBounds(param.name, param.span, _typing.bounds.get(param.id, null));
    }

    /// Reports, at `span`, a pair of `bounds` on the type parameter `name` that no type satisfies,
    /// the later of them from `from` on.
    private void rejectImpossibleBounds(string name, Span span, const(Bound)[] bounds, size_t from = 0)
    {
        foreach (j, later; bounds)
        {
            if (!later.valid || j < from) continue;
            foreach (earlier; bounds[0 .. j])
            {
                if (!earlier.valid || earlier.decl != later.decl || earlier.args == later.args) continue;
                if (argumentParameters(later.decl).any!(i => earlier.args[i] != later.args[i])) continue;
                if (from > 0)
                {
                    // A test asks for less than the bounds already say, not something else.
                    _collector.reportError(DiagnosticCode.InvalidBound, span,
                        "`%s` is already %s, so it can't also be %s: a type has one conformance to `%s`, and the bounds already say which"
                            .format(name, withArticle(_declarer.describe(earlier)), withArticle(_declarer.describe(later)),
                                _resolutions.declarations.interfaces[later.decl].name));
                    return;
                }
                _collector.reportError(DiagnosticCode.InvalidBound, span,
                    "`%s` can't be both %s and %s: a type has one conformance to `%s`, which says what %s"
                        .format(name, withArticle(_declarer.describe(earlier)), withArticle(_declarer.describe(later)),
                            _resolutions.declarations.interfaces[later.decl].name,
                            resultOnlyParameters(later.decl).map!(i => "`" ~ _resolutions.declarations.interfaces[later.decl]
                                .typeParams[i].name ~ "`").join(" and ") ~ (resultOnlyParameters(later.decl).length == 1 ? " is" : " are")));
                return;
            }
        }
    }

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
        rejectImpossibleBounds(_resolutions.typeParamsOf(func.id));
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

    /// `candidates` without the functions a bound supplies that another bound supplies already,
    /// and without those a nearer function of the same parameters hides.
    private const(Candidates) distinct(const Candidates candidates)
    {
        auto unhidden = unshadowed(candidates);
        if (_repeatedBounds.length == 0 || !unhidden.groups.joiner.any!(f => (f in _repeatedBounds) !is null)) return unhidden;
        Candidates kept;
        foreach (group; unhidden.groups) kept.groups ~= group.filter!(f => f !in _repeatedBounds).array.dup;
        kept.sources = unhidden.sources.dup;
        kept.exporters = unhidden.exporters.dup;
        kept.scopeModule = unhidden.scopeModule;
        return kept;
    }

    /// `candidates` without what a nearer function hides: in each group, what its module doesn't
    /// give, and among a scope's imports, what one at a nearer level does with the same parameters.
    private const(Candidates) unshadowed(const Candidates candidates)
    {
        auto all = candidates.groups.joiner;
        if (all.empty) return candidates;
        if (candidates.exporters.all!(e => e.length == 0) && candidates.scopeModule.length == 0) return uncovered(cast(Candidates) candidates);
        auto name = _resolutions.declarations.functions[all.front].name;
        const(Id!FunctionDecl)[] inScope = candidates.scopeModule.length > 0 ? scopeFunctions(candidates.scopeModule, name) : null;
        Candidates kept;
        foreach (i, group; candidates.groups)
        {
            auto exporter = i < candidates.exporters.length ? candidates.exporters[i] : null;
            const(Id!FunctionDecl)[] exported = exporter.length > 0 ? exportedFunctions(exporter, name) : null;
            kept.groups ~= group.filter!(f => (exporter.length == 0 || exported.canFind(f))
                && (i == 0 || inScope is null || inScope.canFind(f))).array.dup;
        }
        kept.sources = candidates.sources.dup;
        kept.exporters = candidates.exporters.dup;
        kept.scopeModule = candidates.scopeModule;
        return uncovered(kept);
    }

    /// `candidates` without each imported group that brings nothing another does, so imports that
    /// lead to the same functions count once, and without empty ones. It comes after what imports
    /// hide is left out, so a module hiding a function can't take another import's place.
    private static Candidates uncovered(Candidates candidates)
    {
        auto groups = candidates.groups;
        bool covered(size_t i)
        {
            if (groups[i].length == 0) return true;
            foreach (j, other; groups[1 .. $])
            {
                if (j + 1 == i || !groups[i].all!(f => other.canFind(f))) continue;
                if (groups[i].length < other.length || j + 1 < i) return true;
            }
            return false;
        }
        auto kept = iota(1, groups.length).filter!(i => !covered(i)).array;
        Candidates result;
        result.groups = [groups[0]] ~ kept.map!(i => groups[i]).array;
        string at(const string[] names, size_t i) => i < names.length ? names[i] : null;
        result.sources = [at(candidates.sources, 0)] ~ kept.map!(i => at(candidates.sources, i)).array;
        result.exporters = [at(candidates.exporters, 0)] ~ kept.map!(i => at(candidates.exporters, i)).array;
        result.scopeModule = candidates.scopeModule;
        return result;
    }

    /// A function a module reaches, at how near it is: 0 for its own, 1 through an import or
    /// forward that lists its name, 2 through one that brings every name.
    private static struct Leveled
    {
        Id!FunctionDecl func;
        int level;
    }

    /// The functions named `name` that importing `m` brings: its own public ones and those it
    /// forwards, without any a nearer one of the same parameters hides.
    private const(Id!FunctionDecl)[] exportedFunctions(string m, string name)
    {
        auto byModule = name in _exported;
        if (byModule is null)
        {
            _exported[name] = exportTable(name);
            byModule = name in _exported;
        }
        return (*byModule).get(m, null);
    }

    /// What every module exports as functions named `name`. Each round works out every module's
    /// from what the last round gave, so the order modules are checked in never changes it.
    private const(Id!FunctionDecl)[][string] exportTable(string name)
    {
        auto modules = _resolutions.moduleScopes.keys.sort.array;
        const(Id!FunctionDecl)[][string] current;
        foreach (m; modules) current[m] = _resolutions.publicFunctions(m, name);
        foreach (_; 0 .. modules.length + 2)
        {
            const(Id!FunctionDecl)[][string] next;
            foreach (m; modules)
            {
                auto entries = _resolutions.publicFunctions(m, name).map!(f => Leveled(f, 0)).array;
                foreach (forward; _resolutions.forwardImports.get(m, null))
                {
                    if (forward.names.length > 0 && !forward.names.canFind(name)) continue;
                    foreach (f; current.get(forward.target, null)) entries ~= Leveled(f, forward.names.length > 0 ? 1 : 2);
                }
                next[m] = nearest(entries);
            }
            if (modules.all!(m => sameSet(next[m], current[m]))) return next;
            current = next;
        }
        assert(false, "forwards with no cycle settle");
    }

    private static bool sameSet(const(Id!FunctionDecl)[] a, const(Id!FunctionDecl)[] b)
    {
        return a.length == b.length && a.all!(f => b.canFind(f));
    }

    /// The functions named `name` that a plain name finds in `m`, apart from those of its bounds:
    /// its own, then what each import brings, without any a nearer one of the same parameters hides.
    private const(Id!FunctionDecl)[] scopeFunctions(string m, string name)
    {
        auto entries = _resolutions.moduleScopes[m].functionsNamed(name).map!(f => Leveled(f, 0)).array;
        foreach (access; _resolutions.moduleScopes[m].imports)
        {
            auto level = access.names.canFind(name) ? 1 : access.everyName ? 2 : 0;
            if (level == 0) continue;
            foreach (f; exportedFunctions(access.name, name)) entries ~= Leveled(f, level);
        }
        return nearest(entries);
    }

    /// The functions of `entries`, each at the nearest level it's found at, without those that a
    /// function at a nearer level hides by taking the same parameters.
    private Id!FunctionDecl[] nearest(Leveled[] entries)
    {
        Leveled[] each;
        foreach (entry; entries)
        {
            auto at = each.countUntil!(e => e.func == entry.func);
            if (at < 0) each ~= entry;
            else if (entry.level < each[at].level) each[at].level = entry.level;
        }
        return each.filter!(e => !each.any!(n => n.level < e.level && sameOverload(n.func, e.func)))
            .map!(e => e.func).array;
    }

    /// Whether `a` and `b` couldn't be overloads in one module.
    private bool sameOverload(Id!FunctionDecl a, Id!FunctionDecl b)
    {
        return sameParameters(a, b);
    }

    private void checkConstant(const ConstDecl constant, string moduleName)
    {
        auto type = _typing.symbolTypes[SymbolId(constant.id)];
        auto reported = _collector.diagnostics.length;
        if (type != _types.error && requireConstantExpr(constant.value))
        {
            // A constant expression can't contain a `return`, so nothing reads the return type.
            check(constant.value, type, BodyContext(Site(moduleName), _types.error));
            requireNoOperatorCall(constant.value);
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

    /// Reports the first operator in a checked constant `expr` that means a call, which a constant
    /// can't contain.
    private void requireNoOperatorCall(const Expr expr)
    {
        if (expr.id in _typing.operators)
        {
            _collector.reportError(DiagnosticCode.NonConstantInitializer, expr.span,
                "This operator calls an operator function, and a top-level constant can't call a function");
            return;
        }
        expr.kind.match!(
            (const InterpolatedString interpolated) { foreach (part; interpolated.parts) requireNoOperatorCall(part); },
            (const UnaryExpr unary) { requireNoOperatorCall(*unary.operand); },
            (const BinaryExpr binary) {
                requireNoOperatorCall(*binary.left);
                requireNoOperatorCall(*binary.right);
            },
            (_) {},
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
        auto untyped = isBareLiteralType(actual);
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
                auto conformance = lookUp(goal, floored.floors, found, site, 0);
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
                _collector.reportError(DiagnosticCode.UntypedLambdaParameter, param.nameSpan, param.takenApart
                    ? "Nothing here says what type this parameter is; write a type on each of its parts, or on the whole "
                        ~ "of it, as in `((a, b): (Int, String)) => ...`"
                    : "Nothing here says what type `%s` is; write `%s: Type`".format(param.name, param.name));
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
    /// `joined`, listing the errors of each.
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
        if (_types.isErrorUnion(joined) || _types.isFailure(joined))
        {
            success = _types.isErrorUnion(joined) ? _types.successOf(joined) : _types.never;
            reason = _types.errorOf(joined);
        }
        foreach (error; inferred.errors) reason = mergedErrors(reason, error);
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
                auto thenType = trueBranch(if_, () => checkDiscarded(*if_.trueBody, ctx));
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
                else if (type != _types.unit && type != _types.never && type != _types.error
                    && !(type == _types.option(_types.unit) && givesUnit(expr.expr)))
                {
                    _collector.reportError(DiagnosticCode.UnusedValue, expr.expr.span,
                        "This value of type `%s` is unused; bind it with `val`, or drop it with `_ = ...`"
                            .format(_types.describe(type)));
                }
            },
            // A nested `def` lowers to a VarDecl, and name resolution reports a nested native or intrinsic.
            (const FunctionDecl _) {},
        );
    }

    private Type synthesizeReturn(const ReturnExpr ret, BodyContext ctx)
    {
        if (ctx.inferred is null)
        {
            if (!returnsErrorToNowhere(*ret.value, ctx)) check(*ret.value, ctx.returnType, ctx);
            return _types.never;
        }
        auto type = synthesizeBeside(*ret.value, ctx.inferred.beside, ctx);
        ctx.inferred.values ~= *ret.value;
        ctx.inferred.types ~= type;
        return _types.never;
    }

    /// Reports `fail e` or `return Error(e)` where what's returned can't hold an error.
    private bool returnsErrorToNowhere(const Expr value, BodyContext ctx)
    {
        auto returnType = ctx.returnType;
        if (returnType == _types.error || _types.isErrorUnion(returnType)) return false;
        return value.kind.match!(
            (const ErrorExpr error) {
                auto reason = synthesize(*error.value, ctx);
                if (reason == _types.error) return true;
                if (ctx.testBody)
                {
                    _collector.reportError(DiagnosticCode.InvalidPropagation, value.span,
                        "A test can't return the error `%s`; `panic` stops it with a message"
                            .format(_types.describe(reason)));
                }
                else
                {
                    _collector.reportError(DiagnosticCode.InvalidPropagation, value.span,
                        "This returns the error `%s`, but this function returns `%s`, which can't hold one; it could return `%s ! %s`"
                            .format(_types.describe(reason), _types.describe(returnType), _types.describe(returnType),
                                _types.describe(reason)));
                }
                return true;
            },
            (const _) => false,
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
            _typing.exprTypes[value.id] = types.any!(t => isBareLiteralType(t))
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
                auto arraySlice = asRange(index.index) !is null
                    && _types.isArray(_typing.exprTypes.get(index.object.id, _types.error));
                if (use == "assigned to" && !arraySlice) return checkAssignable(*index.object, use);
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

    /// The `v` of `x op= v`, whose `x` was already reported, so reading it again isn't.
    private void checkCompoundOperand(const Expr value, BodyContext ctx)
    {
        _typing.exprTypes[value.id] = _types.error;
        value.kind.match!(
            (const BinaryExpr binary) {
                _typing.exprTypes[binary.left.id] = _types.error;
                checkArgument(*binary.right, _types.error, ctx);
            },
            (_) {},
        );
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
        else if (type == _types.error && assign.compound) checkCompoundOperand(assign.value, ctx);
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
        if (index is null) return synthesize(target, ctx);
        auto range = asRange(index.index);
        auto objectType = _declarer.requireTyped(synthesize(*index.object, ctx), index.object.span);
        _typing.exprTypes[index.object.id] = objectType;
        Type type;
        if (objectType == _types.error || objectType == _types.never)
        {
            if (range is null) checkArgument(*index.index, _types.error, ctx);
            if (range !is null && range.start !is null) checkArgument(*range.start, _types.error, ctx);
            if (range !is null && range.end !is null) checkArgument(*range.end, _types.error, ctx);
            if (range !is null) _typing.exprTypes[index.index.id] = _types.error;
            type = _types.error;
        }
        else if (range !is null && _types.isArray(objectType))
        {
            // An array's slice is a view, which `checkAssignable` reports.
            if (range.start !is null) checkIndex(*range.start, ctx);
            if (range.end !is null) checkIndex(*range.end, ctx);
            _typing.exprTypes[index.index.id] = objectType;
            type = objectType;
        }
        else if (_types.isArray(objectType))
        {
            type = _types.arrayElement(objectType);
            auto indexType = isIntLiteral(*index.index) ? check(*index.index, _types.int_, ctx) : synthesize(*index.index, ctx);
            if (isInterval(indexType))
            {
                _collector.reportError(DiagnosticCode.InvalidAssignmentTarget, target.span,
                    "A slice can't be assigned to; assign its elements, as `xs[i] = v`");
                type = _types.error;
            }
            else requireIndex(*index.index, indexType);
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
        // `x[a..] = v` and `x[..b] = v` pass the interval they mean, as reading them does.
        auto range = asRange(index.index);
        auto open = range !is null && (range.start is null || range.end is null);
        auto exact = false;
        if (open && !indexRead)
        {
            if (openSliceInterval(target, *index, *range, objectType, ctx) == _types.error)
            {
                if (value !is null) checkArgument(*value, _types.error, ctx);
                _typing.exprTypes[target.id] = _types.error;
                return false;
            }
            exact = true;
        }
        auto indexType = indexRead || exact ? argumentType(*index.index) : Type.init;
        const(Expr)[] args = [given, indexRead || exact ? given : *index.index, value is null ? given : *value];
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
        else if (exact && params[1] != indexType)
        {
            problem = "`x[a..] = v` and `x[..b] = v` pass `opIndexAssign` an `%s`, but `%s` takes `%s`"
                .format(_types.describe(indexType), describeUse("opIndexAssign", write), _types.describe(params[1]));
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
        noteSyntaxUse(ctx.site, target.span, write);
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
                _typing.exprTypes[v.id] = types.any!(t => isBareLiteralType(t))
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
                auto decl = _resolutions.declarations.types[type];
                if (decl.fields.length == 0 && !decl.native) marker = type;
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
            (const UnaryExpr unary) => synthesizeUnary(expr.id, unary, expr.span, ctx),
            (const BinaryExpr binary) => binary.op == BinaryOp.Concat || binary.op == BinaryOp.Append
                ? synthesizeConcat(expr, binary, ctx)
                : synthesizeBinary(expr.id, binary, expr.span, ctx),
            (const CallExpr call) => expr.id in _resolutions.conversions
                ? synthesizeConversion(call, _declarer.builtinType(_resolutions.conversions[expr.id]), expr.span, ctx)
                : deriveOrder(expr, call, placeExpect(expr, isMethodCall(expr.id, *call.callee)
                    ? synthesizeMethodCall(expr, call, ctx, expected)
                    : synthesizeCall(expr, call, ctx, expected), ctx.site), ctx.site),
            (const MemberAccess member) => synthesizeMemberAccess(expr, member, ctx, expected),
            (const WithExpr with_) => synthesizeWith(expr, with_, ctx),
            (const WhileExpr while_) => synthesizeWhile(while_, expr.span, ctx),
            (const ForExpr for_) => synthesizeFor(expr, for_, ctx),
            (const IfExpr if_) => synthesizeIf(if_, expr.span, ctx),
            (const BlockExpr block) => synthesizeBlock(block, expr.span, ctx),
            (const UnitLiteral _) => _types.unit,
            (const Identifier _) => synthesizeIdentifier(expr, expected, ctx.site),
            (const SomeExpr some) {
                auto inner = synthesize(*some.value, ctx);
                // A `[]?` or a `[:]?` fits no array's or dictionary's option, so nothing could use it.
                if (inner == _types.emptyArray || inner == _types.emptyDictionary)
                {
                    inner = _declarer.requireTyped(inner, some.value.span);
                }
                return _declarer.optionOf(inner, some.value.span);
            },
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
            (const ReturnExpr ret) => synthesizeReturn(ret, ctx),
            (const BreakExpr _) {
                requireLoop("break", expr.span, ctx);
                return _types.never;
            },
            (const ContinueExpr _) {
                requireLoop("continue", expr.span, ctx);
                return _types.never;
            },
            (const SafeMemberAccess access) => synthesizeSafeMember(expr, access, ctx, expected),
            (const ArrayLiteral literal) => synthesizeArrayLiteral(literal, ctx),
            (const MapLiteral literal) => synthesizeDictionaryLiteral(expr, literal, ctx),
            (const IndexExpr index) => synthesizeIndex(expr, index, ctx),
            (const RangeExpr range) => synthesizeBareRange(expr, range, ctx),
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

    /// `[k: v]` with nothing saying what it's a dictionary of: its keys are joined as an array's
    /// elements are, and so are its values.
    private Type synthesizeDictionaryLiteral(const Expr expr, const MapLiteral literal, BodyContext ctx)
    {
        if (literal.keys.length == 0)
        {
            _typing.emptyDictionary = dictionaryFunction("empty");
            if (_typing.emptyDictionary.isValid) return _types.emptyDictionary;
            _collector.reportError(DiagnosticCode.InternalError, expr.span, "`lang.dictionary` has no `empty` to make a `[:]` with");
            return _types.error;
        }
        Type joined(const(Expr)[] parts, string what)
        {
            auto types = parts.map!(e => synthesize(e, ctx)).array;
            auto whole = types[0];
            foreach (i, type; types[1 .. $]) whole = join(whole, type, parts[i + 1].span, what);
            whole = _declarer.requireTyped(whole, parts[0].span);
            if (whole == _types.error) return whole;
            foreach (i, part; parts) coerce(part, types[i], whole);
            return whole;
        }
        auto key = joined(literal.keys, "Dictionary keys");
        auto value = joined(literal.values, "Dictionary values");
        return builtDictionary(expr, literal, _declarer.dictionaryOf(key, value, expr.span), ctx);
    }

    /// Whether `type` is what a bare `None`, `[]` or `[:]` has until it lands somewhere.
    private bool isBareLiteralType(Type type)
    {
        return type == _types.none || type == _types.emptyArray || type == _types.emptyDictionary;
    }

    /// Whether `type` is a `[K: V]`.
    private bool isDictionary(Type type)
    {
        auto decl = _declarer.dictionaryDecl();
        return decl.isValid && _types[type].match!((const NominalData nominal) => nominal.decl == decl, _ => false);
    }

    private bool isDictionaryLiteral(const Expr expr)
    {
        return expr.kind.match!((const MapLiteral _) => true, _ => false);
    }

    /// `lang.dictionary`'s function `name`, which a literal is built with.
    private Id!FunctionDecl dictionaryFunction(string name)
    {
        auto home = "lang.dictionary" in _resolutions.moduleScopes;
        auto symbol = home is null ? null : (*home).resolveLocal(name);
        if (symbol is null) return Id!FunctionDecl.init;
        return (*symbol).match!((const Id!FunctionDecl decl) => decl, _ => Id!FunctionDecl.init);
    }

    /// Records how the dictionary literal `expr`, typed as `type`, is built, and reports a constant
    /// written as two of its keys.
    private Type builtDictionary(const Expr expr, const MapLiteral literal, Type type, BodyContext ctx)
    {
        if (type == _types.error) return type;
        rejectRepeatedKeys(literal);
        auto empty = dictionaryFunction("empty");
        auto write = dictionaryFunction("opIndexAssign");
        if (!empty.isValid || !write.isValid)
        {
            _collector.reportError(DiagnosticCode.InternalError, expr.span,
                "`lang.dictionary` has no `empty` or no `opIndexAssign` to build a dictionary with");
            return _types.error;
        }
        auto args = _types.nominalArgs(type);
        _typing.dictionaryLiterals[expr.id] = DictionaryFunctions(FunctionUse(empty, args.dup, null),
            FunctionUse(write, args.dup, null));
        noteUse(ctx.site, expr.span, empty, args, null);
        noteUse(ctx.site, expr.span, write, args, null);
        return type;
    }

    /// A key that's written out and can't vary: a literal, one with a sign, or a tuple of those.
    private static bool isConstantKey(const Expr key)
    {
        return key.kind.match!(
            (const IntLiteral _) => true,
            (const FloatLiteral _) => true,
            (const StringLiteral _) => true,
            (const CharLiteral _) => true,
            (const BoolLiteral _) => true,
            (const UnaryExpr unary) => isConstantKey(*unary.operand),
            (const TupleLiteral tuple) => tuple.elements.all!(e => isConstantKey(e)),
            _ => false,
        );
    }

    private void rejectRepeatedKeys(const MapLiteral literal)
    {
        string[] seen;
        foreach (key; literal.keys)
        {
            if (!isConstantKey(key)) continue;
            auto written = printExpr(key);
            if (seen.canFind(written))
            {
                _collector.reportError(DiagnosticCode.RepeatedKey, key.span,
                    "This key is written twice in the dictionary, and one of the two can only be a mistake");
            }
            else seen ~= written;
        }
    }

    /// `x[i]`, or `x[a..b]`. An array's are built in, with the range of a slice part of it rather
    /// than a value; anything else's call `opIndex`.
    private Type synthesizeIndex(const Expr expr, const IndexExpr index, BodyContext ctx)
    {
        auto objectType = _declarer.requireTyped(synthesize(*index.object, ctx), index.object.span);
        auto range = asRange(index.index);
        if (objectType == _types.error || objectType == _types.never)
        {
            if (range !is null) _typing.exprTypes[index.index.id] = _types.error;
            if (range is null) checkArgument(*index.index, _types.error, ctx);
            if (range !is null && range.start !is null) checkArgument(*range.start, _types.error, ctx);
            if (range !is null && range.end !is null) checkArgument(*range.end, _types.error, ctx);
            return _types.error;
        }
        if (_types.isArray(objectType))
        {
            if (range is null) return arrayIndexed(expr, index, objectType, ctx);
            _typing.exprTypes[index.index.id] = objectType;
            if (range.start !is null) checkIndex(*range.start, ctx);
            if (range.end !is null) checkIndex(*range.end, ctx);
            return objectType;
        }
        if (range !is null) return sliceIndexed(expr, index, *range, objectType, ctx);
        auto read = syntaxFunction(expr, expr.span, "opIndex", "`x[i]`", [*index.object, *index.index], [objectType, Type.init], ctx);
        if (!read.found) return _types.error;
        _typing.indexing.require(expr.id).read = read.use;
        auto readOf = expr.id;
        noteSyntaxUse(ctx.site, expr.span, read);
        return read.signature.ret;
    }

    /// `x[a..b]` on something other than an array, which is `opIndex(x, a..b)`. `x[a..]` is
    /// `opIndex(x, a..length(x))`, with `x` evaluated once, and `x[..b]` is `opIndex(x, 0..b)`.
    private Type sliceIndexed(const Expr expr, const IndexExpr index, const RangeExpr range, Type objectType,
        BodyContext ctx)
    {
        auto open = range.start is null || range.end is null;
        // Two literals are fitted by their shape, so they take the interval type an `opIndex` asks for.
        auto shaped = !open && isShaped(*index.index);
        auto interval = shaped ? Type.init
            : open ? openSliceInterval(expr, index, range, objectType, ctx)
            : synthesize(*index.index, ctx);
        if (interval == _types.error || interval == _types.never) return _types.error;

        auto given = placeholder(index.index.span);
        auto args = [*index.object, open ? given : *index.index];
        auto slice = syntaxFunction(expr, expr.span, "opIndex", "`x[a..b]`", args, [objectType, interval], ctx, false);
        if (slice.failed) return _types.error;
        if (!slice.found)
        {
            if (shaped) checkArgument(*index.index, _types.error, ctx);
            auto passed = shaped ? intervalOf(_types.int_, expr.span) : interval;
            _collector.reportError(DiagnosticCode.InvalidOperand, expr.span,
                "`%s` can't be sliced: `x[a..b]` is `opIndex(x, a..b)`, and no `opIndex` here takes `%s` and `%s`"
                    .format(_types.describe(objectType), _types.describe(objectType), _types.describe(passed)));
            return _types.error;
        }
        if (open && slice.signature.params[1] != interval)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
                "`x[a..]` and `x[..b]` pass `opIndex` an `%s`, but `%s` takes `%s`"
                    .format(_types.describe(interval), describeUse("opIndex", slice), _types.describe(slice.signature.params[1])));
            return _types.error;
        }
        _typing.indexing.require(expr.id).read = slice.use;
        auto sliced = expr.id;
        noteSyntaxUse(ctx.site, expr.span, slice);
        return slice.signature.ret;
    }

    /// The `Interval` that `x[a..]` or `x[..b]` at `at` passes, recording the `length` that gives
    /// `x[a..]` its end, or `error` once reported.
    private Type openSliceInterval(const Expr at, const IndexExpr index, const RangeExpr range, Type objectType,
        BodyContext ctx)
    {
        Type interval;
        if (range.end is null)
        {
            auto length = syntaxFunction(at, at.span, "length", "`x[a..]`", [*index.object], [objectType], ctx);
            if (!length.found)
            {
                checkArgument(*range.start, _types.error, ctx);
                interval = _types.error;
            }
            else
            {
                _typing.indexing.require(at.id).length = length.use;
                auto lengthOf = at.id;
                noteSyntaxUse(ctx.site, at.span, length);
                auto end = length.signature.ret;
                auto start = isIntLiteral(*range.start) && _types.isInteger(end)
                    ? check(*range.start, end, ctx)
                    : synthesize(*range.start, ctx);
                if (_types.isInteger(start) && _types.isInteger(end) && start != end)
                {
                    _collector.reportError(DiagnosticCode.TypeMismatch, range.start.span,
                        "`x[a..]` ends at `length(x)`, which is `%s`, so `a` has to be `%s` too, not `%s`"
                            .format(_types.describe(end), _types.describe(end), _types.describe(start)));
                    interval = _types.error;
                }
                else interval = openInterval(start, end, index.index.span);
            }
        }
        else
        {
            auto end = rangeEnd(*range.end, synthesize(*range.end, ctx));
            interval = openInterval(_types.isInteger(end) ? end : _types.int_, end, index.index.span);
        }
        _typing.exprTypes[index.index.id] = interval;
        return interval;
    }

    /// The `Interval` that `x[a..]` or `x[..b]` passes, with bounds of types `start` and `end`.
    private Type openInterval(Type start, Type end, Span span)
    {
        auto type = join(start, end, span, "Range bounds");
        if (type == _types.error || type == _types.never) return type;
        if (!_types.isInteger(type))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, span,
                "`a..b` needs integer bounds, got `%s`".format(_types.describe(type)));
            return _types.error;
        }
        return intervalOf(type, span);
    }

    /// `xs[i]` on an array: built in for an `Int`, and otherwise `opIndex(xs, i)` when one takes
    /// what `i` is, as the prelude's does an `Interval<Int>`.
    private Type arrayIndexed(const Expr expr, const IndexExpr index, Type objectType, BodyContext ctx)
    {
        auto element = _types.arrayElement(objectType);
        if (isIntLiteral(*index.index))
        {
            check(*index.index, _types.int_, ctx);
            return element;
        }
        auto type = synthesize(*index.index, ctx);
        if (_types.isInteger(type) || type == _types.error || type == _types.never)
        {
            requireIndex(*index.index, type);
            return element;
        }
        auto read = syntaxFunction(expr, expr.span, "opIndex", "`x[i]`", [*index.object, *index.index], [objectType, type],
            ctx, false);
        if (read.failed) return _types.error;
        if (!read.found)
        {
            requireIndex(*index.index, type);
            return _types.error;
        }
        _typing.indexing.require(expr.id).read = read.use;
        auto readOf = expr.id;
        noteSyntaxUse(ctx.site, expr.span, read);
        return read.signature.ret;
    }

    /// An array's index or slice bound, which is an `Int`.
    private void checkIndex(const Expr expr, BodyContext ctx)
    {
        if (isIntLiteral(expr))
        {
            check(expr, _types.int_, ctx);
            return;
        }
        requireIndex(expr, synthesize(expr, ctx));
    }

    /// Reports `expr`, of type `type`, unless it's an `Int` and so can index an array.
    private void requireIndex(const Expr expr, Type type)
    {
        if (type == _types.int_ || type == _types.error || type == _types.never) return;
        auto interval = isInterval(type) ? "; an array is sliced by an `Interval<Int>`" : "";
        _collector.reportError(DiagnosticCode.TypeMismatch, expr.span, _types.isInteger(type)
            ? "An array index is an `Int`, not `%s`; convert it with `Int(...)`".format(_types.describe(type))
            : "An array index is an `Int`, not `%s`%s".format(_types.describe(type), interval));
    }

    /// An argument that syntax passes with no expression of its own, such as the 0 a left-out
    /// slice start means. It's given a type, so it's never synthesized.
    private static Expr placeholder(Span span)
    {
        return Expr(Id!Expr.init, span, ExprKind(Identifier(discardName)));
    }

    /// `a..b` outside a slice or a `for`, which builds an `Interval` of its bounds' type.
    private Type synthesizeBareRange(const Expr expr, const RangeExpr range, BodyContext ctx)
    {
        auto element = rangeBounds(expr, range, "`a..b` needs integer bounds", ctx);
        return element == _types.error || element == _types.never ? element : intervalOf(element, expr.span);
    }

    /// `a..b` checked against `expected`, an `Interval` of an integer type, which the bounds are
    /// checked against so that literals adapt to it.
    private Type checkBareRange(const Expr expr, const RangeExpr range, Type expected, BodyContext ctx)
    {
        auto element = _types.nominalArgs(expected)[0];
        check(*range.start, element, ctx);
        rangeEnd(*range.end, check(*range.end, element, ctx));
        _typing.exprTypes[expr.id] = expected;
        return expected;
    }

    /// `lang`'s `Range`, which `for` loops over, or an invalid ID when `lang` isn't loaded.
    private Id!InterfaceDecl rangeDecl()
    {
        auto prelude = "lang.range" in _resolutions.moduleScopes;
        auto symbol = prelude is null ? null : (*prelude).resolveLocalType("Range");
        if (symbol is null) return Id!InterfaceDecl.init;
        return (*symbol).match!((const Id!InterfaceDecl decl) => decl, _ => Id!InterfaceDecl.init);
    }

    /// `lang`'s `Iterable`, which says what range a `for` steps a value through, or an invalid ID
    /// when `lang` isn't loaded.
    private Id!InterfaceDecl iterableDecl()
    {
        auto prelude = "lang.range" in _resolutions.moduleScopes;
        auto symbol = prelude is null ? null : (*prelude).resolveLocalType("Iterable");
        if (symbol is null) return Id!InterfaceDecl.init;
        return (*symbol).match!((const Id!InterfaceDecl decl) => decl, _ => Id!InterfaceDecl.init);
    }

    /// `lang`'s `Ord`, which `<` compares through, or an invalid ID when `lang` isn't loaded.
    private Id!InterfaceDecl ordDecl()
    {
        auto prelude = "lang.ord" in _resolutions.moduleScopes;
        auto symbol = prelude is null ? null : (*prelude).resolveLocalType("Ord");
        if (symbol is null) return Id!InterfaceDecl.init;
        return (*symbol).match!((const Id!InterfaceDecl decl) => decl, _ => Id!InterfaceDecl.init);
    }

    /// `lang`'s function that `op` calls on two values of a type that's an `Ord`.
    private Id!FunctionDecl orderingFunction(BinaryOp op)
    {
        auto name = op == BinaryOp.Less ? "less" : op == BinaryOp.LessEqual ? "lessEqual"
            : op == BinaryOp.Greater ? "greater" : "greaterEqual";
        auto prelude = "lang.ord" in _resolutions.moduleScopes;
        auto symbol = prelude is null ? null : (*prelude).resolveLocal(name);
        if (symbol is null) return Id!FunctionDecl.init;
        return (*symbol).match!((const Id!FunctionDecl decl) => decl, _ => Id!FunctionDecl.init);
    }

    /// `a < b` and the like on anything but two numbers, Strings or Chars, which the machine
    /// compares: the two are one type already, and its conformance to `Ord` says how they compare.
    private Type synthesizeOrdered(Id!Expr id, const BinaryExpr binary, Span span, Type leftType, Type rightType, BodyContext ctx)
    {
        auto op = cast(string) binary.op;
        if (leftType == _types.none && rightType == _types.none) return _declarer.reportUntypedNone(binary.left.span);
        if (leftType == _types.emptyArray && rightType == _types.emptyArray)
        {
            return _declarer.reportUntypedEmptyArray(binary.left.span);
        }
        if (leftType == _types.emptyDictionary && rightType == _types.emptyDictionary)
        {
            return _declarer.reportUntypedEmptyDictionary(binary.left.span);
        }
        if (leftType != rightType)
        {
            // Unlike `==`, a value isn't wrapped to meet an option: `None` is before every `Some`,
            // so that would quietly give a missing value a side.
            auto wraps = _types.isOption(leftType) != _types.isOption(rightType);
            _collector.reportError(DiagnosticCode.InvalidOperand, span,
                "`%s` can't compare `%s` and `%s`%s".format(op, _types.describe(leftType), _types.describe(rightType),
                    wraps ? "; `None` is before every `Some`, so write the `Some(...)` out, or take the value out of the option first" : ""));
            return _types.error;
        }
        auto ord = ordDecl();
        auto function_ = orderingFunction(binary.op);
        Conformance found;
        if (ord.isValid && function_.isValid)
        {
            Substitution bound;
            found = lookUp(Goal(ord, leftType, []), [], bound, ctx.site, 0);
        }
        else
        {
            found.failure = "`lang` isn't loaded to declare `Ord`";
        }
        if (!found.holds)
        {
            if (_types.mentionsParameter(leftType))
            {
                auto subject = _types.isParameter(leftType)
                    ? "`%s` could be any type".format(_types.describe(leftType))
                    : "`%s` holds a type parameter, which could be any type".format(_types.describe(leftType));
                _collector.reportError(DiagnosticCode.OpaqueTypeParameter, binary.left.span,
                    "%s, so its values can't be ordered with `%s`; a bound says they can, as in `T: Ord`".format(subject, op));
                return _types.error;
            }
            _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                "`%s` compares two values of an `Ord`, and `%s` isn't one: %s".format(op, _types.describe(leftType),
                    found.failure is null ? "nothing says so yet" : found.failure));
            return _types.error;
        }
        _typing.comparisons[id] = FunctionUse(function_, [leftType], found.witnesses);
        noteUse(ctx.site, span, function_, [leftType], found.witnesses);
        return _types.bool_;
    }

    /// `lang`'s `Interval`, which `a..b` builds, or an invalid ID when `lang` isn't loaded.
    private Id!TypeDecl intervalDecl()
    {
        auto prelude = "lang.interval" in _resolutions.moduleScopes;
        auto symbol = prelude is null ? null : (*prelude).resolveLocalType("Interval");
        if (symbol is null) return Id!TypeDecl.init;
        return (*symbol).match!((const Id!TypeDecl decl) => decl, _ => Id!TypeDecl.init);
    }

    /// Names a type of `lang` or of the prelude's package in full when a module outside them
    /// declares a type of the same name, so an error that mentions both tells them apart.
    private void qualifyShadowedLibraryTypes(string prelude)
    {
        auto library = prelude is null ? null : prelude.findSplit(".")[0];
        bool ofLibrary(string m) => library !is null && (m == library || m.startsWith(library ~ "."));
        Id!TypeDecl[][string] byName;
        foreach (moduleScope; _resolutions.moduleScopes)
        {
            foreach (name, symbol; moduleScope.localTypes)
            {
                symbol.match!((const Id!TypeDecl decl) { byName[name] ~= decl; }, (_) {});
            }
        }
        foreach (name, decls; byName)
        {
            auto home(Id!TypeDecl d) => _resolutions.declarations.typeModules[d];
            if (!decls.any!(d => !isInLang(home(d)) && !ofLibrary(home(d)))) continue;
            foreach (d; decls)
            {
                if (isInLang(home(d))) _types.rename(d, langPackage ~ "." ~ name);
                else if (ofLibrary(home(d))) _types.rename(d, home(d) ~ "." ~ name);
            }
        }
    }

    private bool isInterval(Type type)
    {
        auto decl = intervalDecl();
        return decl.isValid && _types[type].match!((const NominalData nominal) => nominal.decl == decl, _ => false);
    }

    private Type intervalOf(Type element, Span span)
    {
        auto decl = intervalDecl();
        if (!decl.isValid)
        {
            _collector.reportError(DiagnosticCode.UnknownType, span,
                "`a..b` builds an `Interval`, which `lang` declares, and `lang` isn't loaded");
            return _types.error;
        }
        return _types.nominal(decl, "Interval", [element]);
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
        if (symbol.match!((const Id!TypeDecl type) => _declarer.isNative(type), _ => false))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, span,
                "`%s` is a native type, which has no constructor; its values only come from native functions"
                    .format(symbolName(symbol)));
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

    /// `call`, of type `type`. When it calls `derivedCompare`, works out how the type it's given
    /// is ordered: a declared type, each of whose parts is an `Ord`.
    private Type deriveOrder(const Expr expr, const CallExpr call, Type type, Site site)
    {
        auto callee = calleeOf(expr.id);
        if (callee is null) callee = expr.id in _typing.methodCallees;
        if (type == _types.error || callee is null || !isIntrinsic(*callee, "derivedCompare")) return type;
        auto given = call.callee.id in _typing.typeArguments;
        auto ord = ordDecl();
        if (given is null || !ord.isValid) return type;
        auto subject = (*given)[0];
        if (subject == _types.error) return type;

        auto declared = _types[subject].match!(
            (const NominalData nominal) => !_declarer.isIntrinsic(nominal.decl) && !_declarer.isNative(nominal.decl), _ => false);
        if (!declared)
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, expr.span,
                "`derivedCompare` orders a declared type by its members and fields, and `%s` isn't one".format(_types.describe(subject)));
            return _types.error;
        }

        auto failed = false;
        FunctionUse compareOf(Type part, lazy string what)
        {
            if (part == _types.error) { failed = true; return FunctionUse.init; }
            Substitution bound;
            auto found = lookUp(Goal(ord, part, []), [], bound, site, 0);
            if (!found.holds)
            {
                if (!failed)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, expr.span,
                        "`derivedCompare` needs every part of `%s` to be an `Ord`, and %s, a `%s`, isn't one: %s".format(
                            _types.describe(subject), what, _types.describe(part),
                            found.failure is null ? "nothing says so yet" : found.failure));
                }
                failed = true;
                return FunctionUse.init;
            }
            auto compare = found.witnesses[0];
            noteUse(site, expr.span, compare.func, compare.typeArgs, compare.witnesses);
            return FunctionUse(compare.func, compare.typeArgs, compare.witnesses);
        }
        DerivedPart byFields(Type whole)
        {
            DerivedPart part;
            foreach (f; _declarer.fieldsOf(whole))
            {
                part.uses ~= compareOf(f.type, whole == subject ? "its field `%s`".format(f.name)
                    : "the field `%s` of `%s`".format(f.name, _types.describe(whole)));
            }
            return part;
        }
        bool ownedBy(Type member, Type sum)
        {
            auto owner = _types[member].match!((const NominalData n) => _declarer.ownerOf(n.decl), _ => null);
            if (owner is null) return false;
            return _types[*owner].match!(
                (const NominalData o) => _types[sum].match!((const NominalData s) => s.decl == o.decl, _ => false),
                _ => false);
        }

        DerivedOrder order;
        order.tags = compareOf(_types.int_, "an `Int`");
        auto members = _declarer.membersOf(subject);
        if (members.length == 0) order.parts = [byFields(subject)];
        foreach (member; members)
        {
            order.parts ~= ownedBy(member, subject) ? byFields(member)
                : DerivedPart(true, [compareOf(member, "its member `%s`".format(_types.describe(member)))]);
        }
        if (failed) return _types.error;
        _typing.derivedOrders[expr.id] = order;
        return type;
    }

    private void reportPanicsOutsideTest(Span span)
    {
        _collector.reportError(DiagnosticCode.PanicsOutsideTest, span,
            "`panics` survives a panic so that a test can check it, so it can only be used in one");
    }

    /// Whether `symbol` is an intrinsic with an `Any` parameter, which has no function type to be a
    /// value of, or `derivedCompare`, which is worked out where it's called.
    private bool takesAnyIntrinsically(SymbolId symbol)
    {
        return symbol.match!(
            (const Id!FunctionDecl f) => _resolutions.declarations.functions[f].kind == FunctionKind.intrinsic
                && (isIntrinsic(f, "derivedCompare")
                    || _types[symbolType(symbol)].match!((const FunctionData data) => data.params.canFind(_types.any), _ => false)),
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
            foreach (i, type; types) joined = join(joined, type, bodies[i].span, what, ctx.site);
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
                auto thenType = trueBranch(if_, () => synthesizeToward(*if_.trueBody, expected, ctx));
                return joinedOf(bodies, [thenType, synthesizeToward(*if_.falseBody, expected, ctx)], expr.span, "Branches");
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

        auto isMethod = expr.kind.match!((const CallExpr call) => isMethodCall(expr.id, *call.callee),
            (const SafeMemberAccess _) => true, _ => false);
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
    private Type synthesizeSafeMember(const Expr expr, const SafeMemberAccess access, BodyContext ctx, Type expected)
    {
        auto objectType = _declarer.requireTyped(synthesize(*access.object, ctx), access.object.span);
        if (!throughValue(objectType, access.object.span, "a field of any other value is read with `.`")) return _types.error;

        auto record = _types.isErrorUnion(objectType) ? _types.successOf(objectType) : _types.optionInner(objectType);
        auto fields = _declarer.fieldsOf(record);
        foreach (i, field; fields)
        {
            if (field.name == access.member)
            {
                _typing.fieldIndexes[expr.id] = i;
                return throughSafe(objectType, field.type);
            }
        }
        _collector.reportError(DiagnosticCode.UnknownMember, expr.span,
            "Type `%s` has no member named `%s`".format(_types.describe(objectType), access.member));
        return _types.error;
    }

    /// Whether `held`, the type of the object of `?.`, is an option or error union, reporting it if not.
    private bool throughValue(Type held, Span span, string otherwise)
    {
        if (held == _types.error) return false;
        if (_types.isOption(held) || _types.isErrorUnion(held)) return true;
        _collector.reportError(DiagnosticCode.InvalidOperand, span,
            "`?.` needs an option or an error union, got `%s`; %s".format(_types.describe(held), otherwise));
        return false;
    }

    /// The errors `a` and `b` together, in the one form they're listed in: when one takes in the
    /// other, that one, and otherwise a list of each type once, leaving out a member of a declared
    /// sum that's listed too.
    private Type mergedErrors(Type a, Type b)
    {
        if (errorFits(b, a)) return a;
        if (errorFits(a, b)) return b;
        auto all = _types.listed(a) ~ _types.listed(b);
        return _types.errorList(all.filter!(m => !all.any!(t => t != m && _declarer.membersOf(t).canFind(m))).array);
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

    private Type synthesizeUnary(Id!Expr id, const UnaryExpr unary, Span span, BodyContext ctx)
    {
        auto operandType = synthesize(*unary.operand, ctx);
        final switch (unary.op)
        {
            case UnaryOp.Minus:
                if (callsOperator(operandType)) return synthesizeOperator(id, "opNeg", "`-a`", [*unary.operand], [operandType], span, ctx);
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

    /// Whether arithmetic on operands of these types is a call of an operator function: it is
    /// unless they're all numbers, which the machine does it for.
    private bool callsOperator(Type[] operands...)
    {
        return !operands.any!(t => t == _types.error || t == _types.never) && !operands.all!(t => isNumeric(t));
    }

    /// An arithmetic operation that means a call of the operator function `name`, chosen as a call
    /// of it with the operands would be, so a literal operand takes the type its parameter asks for.
    private Type synthesizeOperator(Id!Expr id, string name, string syntax, const(Expr)[] args, Type[] operands, Span span,
        BodyContext ctx)
    {
        auto typed = operands.dup;
        foreach (i, arg; args)
        {
            if (isShaped(arg)) typed[i] = Type.init;
        }
        // An operand that isn't a number is what's reported, as it was when only numbers had operators.
        auto blamed = args.length.iota.filter!(i => !isNumeric(operands[i]));
        auto at = Expr(id, span, ExprKind(Identifier(name)));
        auto function_ = syntaxFunction(at, args[blamed.front].span, name, syntax, args, typed, ctx, true, operands);
        if (!function_.found) return _types.error;
        _typing.operators[id] = function_.use;
        noteSyntaxUse(ctx.site, span, function_);
        return function_.signature.ret;
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
        if (isArraySyntax(*binary.right) || isTupleLiteral(*binary.right) || isDictionaryLiteral(*binary.right))
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

    /// Synthesizes both sides of a comparison. A side written as `Some`, `None`, an array or `a..b` is
    private void synthesizeCompared(const BinaryExpr binary, out Type leftType, out Type rightType, BodyContext ctx)
    {
        bool takesType(const Expr expr) => isOptionSyntax(expr) || isErrorUnionSyntax(expr) || isArraySyntax(expr)
            || isTupleLiteral(expr) || isDictionaryLiteral(expr) || asRange(&expr) !is null || genericUse(expr).found;
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
        if (type == _types.emptyDictionary && isDictionary(target)) return true;
        if (_types.isErrorUnion(target)) return isAssignable(type, target) || literalFits;
        if (!_types.isOption(target) || _types.isOption(type) && !isAssignable(type, target)) return false;
        return isAssignable(type, target) || literalFits;
    }

    private Type innermost(Type option)
    {
        while (_types.isOption(option)) option = _types.optionInner(option);
        return option;
    }

    private Type synthesizeBinary(Id!Expr id, const BinaryExpr binary, Span span, BodyContext ctx)
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
        else if (binary.op == BinaryOp.Less || binary.op == BinaryOp.LessEqual || binary.op == BinaryOp.Greater
            || binary.op == BinaryOp.GreaterEqual)
        {
            synthesizeCompared(binary, leftType, rightType, ctx);
        }
        else
        {
            leftType = synthesize(*binary.left, ctx);
            rightType = synthesize(*binary.right, ctx);
        }
        if (leftType == _types.error || rightType == _types.error) return _types.error;
        if (operatorFunction(binary.op) !is null && callsOperator(leftType, rightType))
        {
            return synthesizeOperator(id, operatorFunction(binary.op), "`a %s b`".format(cast(string) binary.op),
                [*binary.left, *binary.right], [leftType, rightType], span, ctx);
        }
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
                if (!isOrdered(leftType) || !isOrdered(rightType))
                {
                    return synthesizeOrdered(id, binary, span, leftType, rightType, ctx);
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
                if (leftType == _types.emptyDictionary && rightType == _types.emptyDictionary)
                {
                    return _declarer.reportUntypedEmptyDictionary(binary.left.span);
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
        auto reported = _collector.diagnostics.length;
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
        }
        auto candidates = call.callee.id in _resolutions.overloads;
        scope (exit) if (candidates !is null) noteOtherCounts(reported, call, distinct(*candidates));
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
        auto tried = fitAll(expected);
        // When what the expected type binds leaves nothing fitting the arguments, the choice is made
        // without it, so the argument is reported against the chosen function, as for a lone one.
        if (!tried.joiner.any!(t => t.fitsAll) && tried.joiner.any!(t => t.againstExpected)) tried = fitAll(Type.init);
        groups = tried;
        auto own = groups[0].filter!(t => t.fitsAll).array;
        auto imported = mergedImports(groups[1 .. $]);
        // An argument whose type is already an error fits anything, so it would only add to it.
        auto reportable = !typed.any!(t => t != Type.init && _types.mentionsError(t));

        // The module's own come first, unless an imported one takes the arguments in fewer steps
        // than each of them.
        auto nearer = imported.any!(t => own.all!(u => fitsNearer(t, u)));
        if (own.length > 0 && !nearer) return bestTrial(own, name.span, spelled, reportable);
        if (imported.length > 0) return bestTrial(imported, name.span, spelled, reportable);
        if (reportable) reportNoOverload(name.span, spelled, groups);
        return Id!FunctionDecl.init;
    }

    /// The trials of the imported groups that fit, each function once, ranked together whichever
    /// import brings it.
    private const(Trial)[] mergedImports(const(Trial[])[] groups)
    {
        const(Trial)[] merged;
        foreach (trial; groups.joiner)
        {
            if (trial.fitsAll && !merged.canFind!(t => t.func == trial.func)) merged ~= trial;
        }
        return merged;
    }


    /// Whether `functions` are declared in more than one module, so a message has to say which.
    private bool acrossModules(R)(R functions)
    {
        auto homes = functions.map!(f => _resolutions.declarations.functionModules.get(f, null).idup).array;
        return homes.sort.uniq.array.length > 1;
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
    /// and the arguments have to suit what it binds, but it doesn't say how well. Bounds are
    /// checked once a function is chosen, so a failing one doesn't keep it from fitting.
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
            _trials++;
            scope (exit) _trials--;
            bindCall(binding, signature, signatureOf(trial.func).ret, params, trial.func, call, against, ctx, true);
            // Bounds don't rule a function out, but one that holds binds what its interface says.
            conformanceOf(trial.func, binding.bound, ctx.site);
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
        auto withExpected = expected != Type.init;
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
            return;
        }
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
            (const NominalData n) => actual == _types.emptyDictionary ? isDictionary(declared) : data.match!(
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
            (const RangeExpr range) => range.start !is null && range.end !is null
                && isIntLiteral(*range.start) && isIntLiteral(*range.end),
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
            // Only the empty one is fitted by its shape.
            (const MapLiteral _) {
                auto dictionary = isDictionary(param) || _types.isOption(param) && isDictionary(_types.optionInner(param));
                return bare || dictionary || sumHas(m => isDictionary(m)) ? Fit.converted : Fit.none;
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
            // `a..b` of two literals fits an interval of any integer type, as each literal would.
            (const RangeExpr range) {
                if (bare) return Fit.exact;
                return inOption((Type t) => isInterval(t)
                    ? min(shapeFit(*range.start, _types.nominalArgs(t)[0], params),
                        shapeFit(*range.end, _types.nominalArgs(t)[0], params))
                    : Fit.none);
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
        // Functions of different modules tie where a blanket forward brings them together.
        auto homes = unbeaten.map!(t => _resolutions.declarations.functionModules.get(t.func, null).idup).array.sort.uniq.array;
        if (homes.length > 1 && !homes.canFind(null) && !unbeaten.any!(t => (t.func in _resolutions.requirements) !is null))
        {
            _collector.reportError(DiagnosticCode.AmbiguousName, span,
                ("This call fits a `%s` of more than one module (%-(%s, %)) equally well: %s; import the one you mean "
                    ~ "and qualify it, as in `%s.%s(...)`").format(spelled, homes,
                    unbeaten.map!(t => "`" ~ overloadLabel(t.func, true) ~ "`").join(" and "), homes[0], _resolutions.declarations.functions[unbeaten[0].func].name));
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
        if (fitsBetter(a, b)) return true;
        if (a.fits != b.fits) return false;
        auto aGeneric = isGenericFunction(a.func), bGeneric = isGenericFunction(b.func);
        if (aGeneric != bGeneric) return bGeneric;
        if (!aGeneric) return false;
        auto aTakes = accepts(a.func, b.func), bTakes = accepts(b.func, a.func);
        return bTakes && !aTakes;
    }

    /// Whether `a` fits every argument at least as well as `b` and one of them better.
    private static bool fitsBetter(const Trial a, const Trial b)
    {
        bool better, worse;
        foreach (i; 0 .. a.fits.length)
        {
            if (a.fits[i] > b.fits[i]) better = true;
            if (a.fits[i] < b.fits[i]) worse = true;
        }
        return better && !worse;
    }

    /// Whether the imported `a` takes the arguments in fewer steps than the module's own `b`. A
    /// parameter that is only a type parameter takes anything, so it's never the nearer one.
    private bool fitsNearer(const Trial a, const Trial b)
    {
        auto params = signatureOf(a.func).params;
        auto typeParams = _resolutions.typeParamsOf(a.func);
        bool better, worse;
        foreach (i; 0 .. a.fits.length)
        {
            auto bare = _types[params[i]].match!((const TypeParamData p) => typeParams.canFind!(q => q.id == p.param), _ => false);
            if (a.fits[i] > b.fits[i] && !bare) better = true;
            if (a.fits[i] < b.fits[i]) worse = true;
        }
        return better && !worse;
    }

    /// Whether `a` is the more specific of two functions that fit alike: it isn't generic and `b`
    /// is, or `b` takes everything it takes and more.
    private bool moreSpecific(Id!FunctionDecl a, Id!FunctionDecl b)
    {
        auto aGeneric = isGenericFunction(a), bGeneric = isGenericFunction(b);
        if (aGeneric != bGeneric) return bGeneric;
        return aGeneric && accepts(b, a) && !accepts(a, b);
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

    /// A call with one candidate that takes its number of arguments is checked against that one
    /// alone, so when that one is imported, the first error about the call itself, since there
    /// were `reported`, says which others there are.
    private void noteOtherCounts(size_t reported, const CallExpr call, const Candidates candidates)
    {
        if (_collector.diagnostics.length == reported) return;
        const(Id!FunctionDecl)[] all;
        foreach (f; candidates.groups.joiner) if (!all.canFind(f)) all ~= f;
        auto others = all.filter!(f => signatureOf(f).params.length != call.args.length).array;
        if (others.length == 0 || others.length + 1 != all.length) return;
        // The module's own function is the one that was meant.
        if (candidates.groups[0].any!(f => signatureOf(f).params.length == call.args.length)) return;
        auto across = acrossModules(all);
        string counted(Id!FunctionDecl f)
        {
            auto params = signatureOf(f).params.length;
            return "`%s`, which takes %s argument%s".format(overloadLabel(f, across), params, params == 1 ? "" : "s");
        }
        bool aboutCall(const Diagnostic d)
        {
            return d.span == call.callee.span;
        }
        _collector.amendFirstErrorSince(reported, "there's also %-(%s, and %)".format(others.map!(f => counted(f))), &aboutCall);
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
            // The current module's functions come first, as for a call.
            if (candidates.groups[0].length == 1)
            {
                _typing.chosenSymbols[name.id] = SymbolId(candidates.groups[0][0]);
                return namedValue(name, SymbolId(candidates.groups[0][0]), expected, site);
            }
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
            foreach (f; matching[1 .. $].joiner) if (!fits.canFind(f)) fits ~= f;
        }
        if (fits.length > 1)
        {
            auto best = fits.filter!(f => fits.all!(g => g == f || moreSpecific(f, g))).array;
            if (best.length == 1) fits = best;
        }
        if (fits.length != 1)
        {
            auto across = acrossModules(candidates.groups.joiner);
            auto all = candidates.groups.joiner.map!(f => "`" ~ overloadLabel(f, across) ~ "`").array;
            _collector.reportError(fits.length == 0 ? DiagnosticCode.NoMatchingOverload : DiagnosticCode.AmbiguousOverload,
                name.span, "%s `%s` is a `%s`; there are %s".format(fits.length == 0 ? "No" : "More than one", spelled,
                    _types.describe(expected), all.join(", ")));
            return _types.error;
        }
        _typing.chosenSymbols[name.id] = SymbolId(fits[0]);
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
        _trials++;
        auto conformance = conformanceOf(f, bound, site);
        _trials--;
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

    /// Reports two functions of one name in `mod` that take the same parameters, and two tests of one
    /// name in it or in it and the module `part` it's the companion test file of, and notes which
    /// functions are overloaded.
    private void checkOverloads(const Module mod, const(Module)* part)
    {
        Id!FunctionDecl[][string] seen;
        if (part !is null) foreach (decl; part.declarations) decl.kind.match!(
            (const FunctionDecl f) { if (f.testName !is null) seen[f.name] ~= f.id; }, (_) {});
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
    /// own, or as one an earlier forward listing the name brings when this one lists it too, since
    /// its importers choose among them all as one module's. Other forwards clash at a call.
    private void checkForwardedOverloads(string m)
    {
        auto forwarded = m in _resolutions.forwards;
        if (forwarded is null) return;
        foreach (name; (*forwarded).keys.sort)
        {
            // Works out what it exports, which reports a cycle of forwards that doesn't settle.
            exportedFunctions(m, name);
            auto own = _resolutions.publicFunctions(m, name);
            Id!FunctionDecl[] listed;
            foreach (forward; (*forwarded)[name])
            {
                auto brought = _resolutions.publicFunctions(forward.origin, name);
                if (!forward.listed) continue;
                reportForwardedDuplicate(m, own ~ listed, brought, forward);
                listed ~= brought;
            }
        }
    }

    /// Reports each function an import or forward lists that takes the same parameters as one of
    /// the module's own, and each one an import lists that does what one an earlier listing brings
    /// does, since the module asked for both. Two forwards that do are reported with what it forwards.
    private void checkListedOverloads(string m)
    {
        const(ListedImport)[] earlier;
        foreach (listing; _resolutions.listedImports.get(m, null))
        {
            auto brought = exportedFunctions(listing.target, listing.name);
            scope (exit) earlier ~= listing;
            if (brought.length == 0) continue;
            string clash;
            // A forward's against the module's public functions was reported with what it forwards.
            foreach (own; _resolutions.moduleScopes[m].functionsNamed(listing.name))
            {
                if (listing.forward && !_resolutions.declarations.functions[own].isPrivate) continue;
                if (brought.any!(f => sameOverload(own, f))) clash = "this module's `%s`".format(overloadLabel(own));
                if (clash !is null) break;
            }
            foreach (other; earlier.filter!(e => e.name == listing.name && e.target != listing.target && !(e.forward && listing.forward)))
            {
                if (clash !is null) break;
                foreach (f; exportedFunctions(other.target, listing.name))
                {
                    if (brought.canFind!(g => g != f && sameOverload(f, g))) clash = "`%s`, listed too,".format(overloadLabel(f, true));
                    if (clash !is null) break;
                }
            }
            if (clash is null) continue;
            _collector.reportError(DiagnosticCode.DuplicateOverload, listing.span,
                "`%s` from `%s` can't be listed: %s takes the same parameter types".format(listing.name, listing.target, clash));
        }
    }

    private void reportForwardedDuplicate(string m, const(Id!FunctionDecl)[] seen, const(Id!FunctionDecl)[] brought, Forward forward)
    {
        foreach (later; brought)
        {
            foreach (earlier; seen)
            {
                if (!sameParameters(earlier, later)) continue;
                auto home = _resolutions.declarations.functionModules[earlier];
                _collector.reportError(DiagnosticCode.DuplicateOverload, forward.span,
                    ("`%s` can't be forwarded: %s takes the same parameter types, so a module importing this one "
                        ~ "couldn't choose between them%s").format(overloadLabel(later, true),
                            home == m ? "this module's `" ~ overloadLabel(earlier) ~ "`" : "`" ~ overloadLabel(earlier, true)
                                ~ "`, forwarded too,",
                            _resolutions.boundFunctions.get(earlier, null).length + _resolutions.boundFunctions.get(later, null).length == 0
                                ? "" : ", whatever their bounds"));
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
        else if (sameParameters(earlier, later.id))
        {
            auto a = signatureOf(earlier), b = signatureOf(later.id);
            problem = "`%s` already takes `" ~ overloadLabel(earlier)[first.name.length .. $] ~ "`; overloads need different parameter types"
                ~ (a.mutables == b.mutables ? "" : ", and `mutable` alone doesn't make one")
                ~ (_resolutions.boundFunctions.get(earlier, null).length + _resolutions.boundFunctions.get(later.id, null).length == 0
                    ? "" : ", whatever their bounds");
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

    /// Keeps each conformance `modules` declare in `Typing.conformances`, before any body is
    /// checked, since a bound anywhere is looked up there. What a conformance's functions are is
    /// found once something needs it, and for every conformance before bodies are checked.
    private void declareConformances(R)(R modules)
    {
        foreach (mod; modules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const ConformDecl c) {
                        auto holder = _resolutions.conformances[c.id];
                        auto self = _declarer.resolveType(c.type);
                        // Name resolution reported a type it couldn't resolve, and a type parameter alone
                        // outside the interface's module.
                        if (_types.mentionsError(self)) return;
                        bool declaredHere(const TypeExpr written)
                        {
                            auto bound = _declarer.resolveBound(written);
                            if (!bound.valid) return false;
                            auto local = _resolutions.moduleScopes[mod.name].resolveLocalType(
                                _resolutions.declarations.interfaces[bound.decl].name);
                            return local !is null && (*local).match!((const Id!InterfaceDecl d) => d == bound.decl, _ => false);
                        }
                        if (_types.isParameter(self) && !c.interfaces.all!(written => declaredHere(written))) return;
                        if (!decidesParameters(holder, self)) return;
                        foreach (written; c.interfaces)
                        {
                            auto bound = _declarer.resolveBound(written);
                            if (!bound.valid || bound.args.any!(a => _types.mentionsError(a))) continue;
                            auto entries = &_typing.conformances.require(bound.decl, null);
                            _entries ~= Entry(bound.decl, entries.length);
                            *entries ~= Conforming(c.id, bound, self, null, holder, mod.name, written.span);
                        }
                    },
                    (_) {},
                );
            }
        }
    }

    /// Whether each type parameter `holder` introduces that `self` doesn't mention is decided by
    /// a `when` bound on one that is decided, reporting each that isn't: it has to be in an
    /// argument of the bound's interface that only the interface's results mention, as `T` is in
    /// `S: Range<T>`.
    private bool decidesParameters(Id!FunctionDecl holder, Type self)
    {
        auto params = _resolutions.typeParamsOf(holder);
        bool[Id!TypeParam] known;
        foreach (param; params) if (_types.mentionsParameter(self, param.id)) known[param.id] = true;
        for (auto progress = true; progress;)
        {
            progress = false;
            foreach (param; params)
            {
                if (param.id in known) continue;
                auto fixed = params.any!(p => (p.id in known) !is null && _typing.bounds.get(p.id, null).any!(b => b.valid
                    && resultOnlyParameters(b.decl).any!(i => _types.mentionsParameter(b.args[i], param.id))));
                if (fixed) known[param.id] = progress = true;
            }
        }
        auto decided = true;
        foreach (param; params)
        {
            if (param.id in known) continue;
            _collector.reportError(DiagnosticCode.UnknownWhenParameter, param.span,
                ("`%s` isn't in the conforming type, and no `when` bound decides it; it has to be an argument of a bound's interface "
                    ~ "that only the interface's results mention, as `T` is in `S: Range<T>`").format(param.name));
            decided = false;
        }
        return decided;
    }

    /// The positions of the type parameters of `decl` that only results of its functions mention.
    private size_t[] resultOnlyParameters(Id!InterfaceDecl decl)
    {
        auto inArguments = argumentParameters(decl);
        return _resolutions.declarations.interfaces[decl].typeParams.length.iota.filter!(i => !inArguments.canFind(i)).array;
    }

    /// A goal on types with no type parameters, as `_lookups` keeps it.
    private struct Looked
    {
        Id!InterfaceDecl decl;
        Type self;
        immutable(Type)[] args;
    }

    /// A conformance in `Typing.conformances`: the `index`th of those to `decl`.
    private struct Entry
    {
        Id!InterfaceDecl decl;
        size_t index;
    }

    /// Finds the functions that make `entry`'s type satisfy its interface, as calls where it's
    /// declared would find them, with the bounds its `when` gives the type parameters it
    /// introduces, reporting it when they aren't found. Whether they are.
    private bool findConformance(Entry entry)
    {
        if (auto state = entry in _conformanceStates) return *state == ResultState.settled;
        _conformanceStates[entry] = ResultState.working;
        auto conforming = &_typing.conformances[entry.decl][entry.index];
        Substitution none;
        auto found = satisfy(Goal(conforming.bound.decl, conforming.self, conforming.bound.args), null, none,
            Site(conforming.module_, conforming.holder), null);
        conforming = &_typing.conformances[entry.decl][entry.index];
        if (!found.holds || entry in _cycledConformances)
        {
            if (entry !in _cycledConformances) _collector.reportError(found.tooDeep ? DiagnosticCode.BoundSearchTooDeep : DiagnosticCode.UnmetConformance, conforming.span,
                "`%s` can't be %s: %s".format(_types.describe(conforming.self), withArticle(_declarer.describe(conforming.bound)),
                    found.failure is null ? "more than one function could say what its type arguments are" : found.failure));
            _conformanceStates[entry] = ResultState.waiting;
            return false;
        }
        conforming.witnesses = found.witnesses;
        _conformanceStates[entry] = ResultState.settled;
        return true;
    }

    /// Reports, once, that finding `entry`'s functions led through a body whose result is worked
    /// out to a use of `entry` itself.
    private void reportConformanceCycle(Entry entry)
    {
        if (entry in _cycledConformances) return;
        _cycledConformances[entry] = true;
        auto conforming = _typing.conformances[entry.decl][entry.index];
        _collector.reportError(DiagnosticCode.UnmetConformance, conforming.span,
            ("`%s` can't be %s: a function it would use works out its result type from its body, which needs this "
                ~ "conformance already; write that function's result type").format(_types.describe(conforming.self),
                withArticle(_declarer.describe(conforming.bound))));
    }

    /// Checks, once every body has been, that each conformance has one for what its interface
    /// requires, and that no two can apply to the same type and interface.
    private void checkConformances()
    {
        Conforming of(Entry e) => _typing.conformances[e.decl][e.index];
        foreach (entry; _entries) checkRequired(of(entry));
        foreach (entry; _entries)
        {
            foreach (earlier; 0 .. entry.index)
            {
                if (reportOverlap(of(Entry(entry.decl, earlier)), of(entry))) break;
            }
        }
    }

    /// Reports `entry` when its interface requires one that no conformance gives its type.
    private void checkRequired(const Conforming entry)
    {
        auto substitution = _declarer.substitutionOf(entry.bound, entry.self);
        foreach (required; _typing.requires.get(entry.bound.decl, null))
        {
            if (!required.valid) continue;
            auto wanted = Bound(required.decl, required.args.map!(a => _types.substitute(a, substitution)).array);
            Substitution none;
            if (lookUp(Goal(wanted.decl, entry.self, wanted.args), null, none, Site(entry.module_, entry.holder), 0).holds) continue;
            _collector.reportError(DiagnosticCode.MissingRequiredConformance, entry.span,
                "`%s` requires %s, and no conformance makes `%s` one; declare it too, on this line or another"
                    .format(_declarer.describe(entry.bound), withArticle(_declarer.describe(wanted)), _types.describe(entry.self)));
        }
    }

    /// What makes `goal.self` satisfy `goal`'s interface, looked up among the conformances, as
    /// `site` sees it: a type parameter of the function there satisfies what its bounds say, and
    /// is given the functions they supply. Otherwise it's the conformance whose type `goal.self`
    /// is an instance of, when its `when` bounds hold in turn, with its functions for that type.
    /// An argument of the interface that mentions one of `open` that isn't in `bound` yet is
    /// what the conformance says it is. `depth` is how many conformances' `when` bounds this is
    /// inside.
    private Conformance lookUp(const Goal goal, const(TypeParam)[] open, ref Substitution bound, Site site, size_t depth)
    {
        Conformance result;
        if (depth >= boundDepthLimit)
        {
            result.tooDeep = true;
            result.failure = "needs more than %s conformances in turn".format(boundDepthLimit);
            return result;
        }
        // A goal on types that mention no type parameter has one answer, wherever it's asked.
        auto concrete = !_types.mentionsParameter(goal.self) && !goal.args.any!(a => _types.mentionsParameter(a));
        auto key = Looked(goal.decl, goal.self, goal.args.idup);
        if (concrete)
        {
            if (auto known = key in _lookups) return *known;
        }
        auto unbound = open.filter!(p => p.id !in bound).array;
        // What the interface's arguments say about the open parameters, once one is chosen.
        bool matchArguments(const(Type)[] declared, ref Substitution into, const(TypeParam)[] params, ref Substitution opened)
        {
            foreach (i, arg; goal.args)
            {
                if (mentionsAny(arg, unbound)) continue;
                bindParams(declared[i], arg, params, into);
                if (_types.substitute(declared[i], into) != arg) return false;
            }
            foreach (i, arg; goal.args)
            {
                if (!mentionsAny(arg, unbound)) continue;
                auto given = _types.substitute(declared[i], into);
                bindParams(arg, given, unbound, opened);
                // Binding goes by shape, so what it leaves has to be the same type.
                auto now = _types.substitute(arg, opened);
                if (!mentionsAny(now, unbound.filter!(p => p.id !in opened).array) && !mentionsAny(given, params) && now != given)
                {
                    return false;
                }
            }
            return true;
        }

        // With an argument of the interface still unknown, two that fit leave it undecided.
        auto unknown = goal.args.any!(a => mentionsAny(a, unbound));
        auto param = _types[goal.self].match!((const TypeParamData p) => p.param, _ => Id!TypeParam.init);
        if (param.isValid)
        {
            auto owner = site.function_;
            if (!owner.isValid || !_resolutions.typeParamsOf(owner).canFind!(p => p.id == param))
            {
                result.failure = "nothing here says what it can do";
                return result;
            }
            // Its own bounds, then what each `if type` around the site asks of it.
            static struct Given { Bound bound; size_t index; Id!Expr test; }
            Given[] givens;
            foreach (k, b; _typing.bounds.get(param, null)) givens ~= Given(b, k);
            foreach (test; _activeTests)
            {
                auto asked = _resolutions.tests[test];
                if (asked.owner != owner || asked.param != param) continue;
                foreach (k, b; _typing.testBounds.get(test, null)) givens ~= Given(b, k, test);
            }
            Given[] fitting;
            Substitution chosen;
            foreach (given; givens)
            {
                if (!given.bound.valid || given.bound.decl != goal.decl) continue;
                Substitution none;
                auto opened = bound.dup;
                if (!matchArguments(given.bound.args, none, null, opened)) continue;
                if (fitting.length == 0) chosen = opened;
                // The same bound from a test supplies nothing more.
                if (fitting.canFind!(f => f.bound == given.bound)) continue;
                fitting ~= given;
            }
            // A conformance for every type that meets a bound can still say so, from what its `when` asks.
            if (fitting.length == 0 && _typing.conformances.get(goal.decl, null).any!(e => _types.isParameter(e.self))) goto declared;
            if (fitting.length == 0)
            {
                string[] others;
                foreach (g; givens.filter!(g => g.bound.valid && g.bound.decl == goal.decl))
                {
                    auto described = withArticle(_declarer.describe(g.bound));
                    if (!others.canFind(described)) others ~= described;
                }
                result.failure = others.length > 0 ? "its bounds make it %-(%s and %) instead".format(others)
                    : "nothing `%s` is bounded by says it is".format(_types.describe(goal.self));
                return result;
            }
            if (fitting.length > 1 && unknown)
            {
                result.pending = true;
                return result;
            }
            bound = chosen;
            auto from = fitting[0];
            foreach (f; from.test.isValid ? _resolutions.tests[from.test].functions : _resolutions.boundFunctions.get(owner, null))
            {
                auto requirement = _resolutions.requirements[f];
                if (requirement.param == param && requirement.bound == from.index) result.witnesses ~= Witness(f);
            }
            return result;
        }

    declared:
        // What the type's conformances make it, where they don't make it what's asked. One for the
        // type itself comes before one for every type that meets a bound, which can't apply as well.
        string[] instead;
        size_t[] fitting;
        Substitution[] bindings;
        auto entries = _typing.conformances.get(goal.decl, null);
        auto order = entries.length.iota.filter!(i => !_types.isParameter(entries[i].self)).array
            ~ entries.length.iota.filter!(i => _types.isParameter(entries[i].self)).array;
        foreach (i; order)
        {
            auto entry = entries[i];
            auto params = _resolutions.typeParamsOf(entry.holder);
            Substitution s;
            bindParams(entry.self, goal.self, params, s);
            if (_types.substitute(entry.self, s) != goal.self) continue;
            // A parameter that only a `when` bound decides is known once that bound is solved.
            foreach (k, arg; goal.args)
            {
                if (!mentionsAny(arg, unbound)) bindParams(entry.bound.args[k], arg, params, s);
            }
            auto differs = goal.args.length.iota.any!(k => !mentionsAny(goal.args[k], unbound)
                && !mentionsAny(_types.substitute(entry.bound.args[k], s), params) && _types.substitute(entry.bound.args[k], s) != goal.args[k]);
            if (differs)
            {
                instead ~= withArticle(_declarer.describe(Bound(goal.decl, entry.bound.args.map!(a => _types.substitute(a, s)).array)));
                continue;
            }
            // One for the type itself is the only one that can apply to it.
            if (_types.isParameter(entry.self) && fitting.length > 0) continue;
            fitting ~= i;
            bindings ~= s;
        }
        if (fitting.length > 1 && unknown)
        {
            result.pending = true;
            return result;
        }
        if (fitting.length > 0)
        {
            auto i = fitting[0];
            auto entry = _typing.conformances[goal.decl][i];
            auto params = _resolutions.typeParamsOf(entry.holder);
            auto s = bindings[0];
            auto when = conformanceOf(entry.holder, s, site, depth + 1);
            if (_types.isParameter(entry.self) && !when.pending && !when.tooDeep && when.failure !is null)
            {
                // It's for the types that meet its bounds, and this isn't one of them.
                result.failure = "no conformance says so" ~ conformHint(goal, open, bound, site);
                return result;
            }
            if (when.pending || when.failure !is null || params.any!(p => p.id !in s))
            {
                result.tooDeep = when.tooDeep;
                result.failure = when.tooDeep ? when.failure : "the conformance for `%s` %s".format(_types.describe(entry.self),
                    when.failure is null ? "can't say what its type arguments are" : when.failure);
                return result;
            }
            auto opened = bound.dup;
            Substitution none;
            if (!matchArguments(entry.bound.args.map!(a => _types.substitute(a, s)).array, none, null, opened))
            {
                result.failure = "it's %s instead".format(withArticle(_declarer.describe(
                    Bound(goal.decl, entry.bound.args.map!(a => _types.substitute(a, s)).array))));
                return result;
            }
            if (!findConformance(Entry(goal.decl, i)))
            {
                if (_conformanceStates.get(Entry(goal.decl, i), ResultState.waiting) == ResultState.working)
                {
                    // Not while a declaration's search is trying functions: one that needs itself just doesn't fit.
                    if (_resultStates.byValue.canFind(ResultState.working))
                    {
                        reportConformanceCycle(Entry(goal.decl, i));
                    }
                    else
                    {
                        result.failure = "that would need `%s: %s` to hold already".format(_types.describe(goal.self),
                            _declarer.describe(Bound(goal.decl, goal.args.dup)));
                        return result;
                    }
                }
                // Its declaration was reported, and the program is never lowered, so nothing reads these.
                bound = opened;
                result.witnesses = new Witness[_resolutions.declarations.interfaces[goal.decl].functions.length];
                return result;
            }
            bound = opened;
            result.witnesses = _typing.conformances[goal.decl][i].witnesses.map!(w => given(w, s, when.witnesses, entry.holder)).array;
            if (concrete) _lookups[key] = result;
            return result;
        }
        result.failure = instead.length > 0 ? "it's %-(%s and %) instead".format(instead)
            : "no conformance says so" ~ conformHint(goal, open, bound, site);
        return result;
    }

    /// `witness`, found for a conformance, as it is for its type parameters bound by `s`: what
    /// one of `holder`'s `when` bounds supplies is what `supplied` gives for it.
    private Witness given(const Witness witness, const Substitution s, const(Witness)[] supplied, Id!FunctionDecl holder)
    {
        if (auto requirement = witness.func in _resolutions.requirements)
        {
            if (requirement.owner == holder) return cast() supplied[requirement.index];
        }
        return Witness(witness.func, witness.typeArgs.map!(t => _types.substitute(t, s)).array,
            witness.witnesses.map!(w => given(w, s, supplied, holder)).array);
    }

    /// What to add when no conformance makes `goal.self` satisfy `goal` and the functions a
    /// conformance would need are there, since then a `conform` line is all that's missing. When
    /// the function found is generic, the line is for every type it takes, with its bounds.
    private string conformHint(const Goal goal, const(TypeParam)[] open, ref Substitution bound, Site site)
    {
        if (_hinting || _trials > 0) return "";
        _hinting = true;
        scope (exit) _hinting = false;
        auto tried = bound.dup;
        auto found = satisfy(goal, open, tried, site, null);
        if (!found.holds) return goal.decl == rangeDecl() || goal.decl == iterableDecl() ? byIndexHint(goal.self, site) : "";
        auto args = goal.args.map!(a => _types.substitute(a, tried)).array;
        auto line = "`conform %s: %s`".format(_types.describe(goal.self), _declarer.describe(Bound(goal.decl, args)));
        if (auto general = generalConformance(goal, found.witnesses)) line = general;
        if (_resolutions.declarations.interfaces[goal.decl].functions.length == 0) return "; declare it with %s".format(line);
        return "; it has the functions, so %s is all that's missing".format(line);
    }

    /// What to add when `self` isn't a range but the standard library's `byIndex` could step it:
    /// it's an `Indexed`, or it has the `length` and `opIndex` one needs. The compiler names no
    /// module outside `lang`, so the interfaces are the ones by those names that arrays conform to.
    private string byIndexHint(Type self, Site site)
    {
        Id!InterfaceDecl named(string name)
        {
            foreach (decl; _typing.conformances.byKey)
            {
                if (_resolutions.declarations.interfaces[decl].name == name
                    && _typing.conformances[decl].any!(entry => _types.isArray(entry.self)))
                    return decl;
            }
            return Id!InterfaceDecl.init;
        }
        auto indexed = named("Indexed"), sized = named("Sized");
        if (!indexed.isValid || !sized.isValid) return "";
        auto t = TypeParam(_ids.next!TypeParam, "T", Span.init);
        auto goal = Goal(indexed, self, [_types.parameter(t.id, "T")]);
        Substitution bound;
        if (lookUp(goal, [t], bound, site, 0).holds) return "; it's an `Indexed`, so `.byIndex()` steps it";
        Substitution tried, none;
        if (!satisfy(goal, [t], tried, site, null).holds || t.id !in tried) return "";
        if (!satisfy(Goal(sized, self, []), null, none, site, null).holds) return "";
        return "; it has a `length` and an `opIndex`, so `conform %s: Sized & Indexed<%s>` lets `.byIndex()` step it"
            .format(_types.describe(self), _types.describe(tried[t.id]));
    }

    /// The `conform` line for every type the generic function `witnesses[0]` stands for takes, as
    /// in `conform Box<T>: Json when T: Json`, or null when it isn't generic in that type.
    private string generalConformance(const Goal goal, const(Witness)[] witnesses)
    {
        if (witnesses.length == 0 || !witnesses[0].func.isValid) return null;
        auto func = witnesses[0].func;
        auto funcParams = _resolutions.typeParamsOf(func);
        auto interface_ = _resolutions.declarations.interfaces[goal.decl];
        auto declared = signatureOf(interface_.functions[0].id);
        auto at = declared.params.countUntil!(p => _types.mentionsParameter(p, interface_.self.id));
        auto signature = signatureOf(func);
        if (at < 0 || at >= signature.params.length || declared.params[at] != _types.parameter(interface_.self.id, "Self")) return null;
        auto pattern = signature.params[at];
        if (!mentionsAny(pattern, funcParams) || _types.isParameter(pattern)) return null;
        // What the interface's parameters are for that type, read off the function's signature.
        Substitution self;
        self[interface_.self.id] = pattern;
        Substitution args;
        bindParams(_types.substitute(symbolType(SymbolId(interface_.functions[0].id)), self), symbolType(SymbolId(func)),
            interface_.typeParams, args);
        if (interface_.typeParams.any!(p => p.id !in args)) return null;
        string[] when;
        foreach (param; funcParams)
        {
            if (!_types.mentionsParameter(pattern, param.id)) continue;
            auto written = _resolutions.declarations.typeParams[param.id].bounds.length;
            auto bounds = _typing.bounds.get(param.id, null);
            auto shown = bounds[0 .. min(written, bounds.length)].filter!(b => b.valid).map!(b => _declarer.describe(b)).array;
            if (shown.length > 0) when ~= "%s: %-(%s & %)".format(param.name, shown);
        }
        auto bound = Bound(goal.decl, interface_.typeParams.map!(p => cast() args[p.id]).array);
        return "`conform %s: %s%s`".format(_types.describe(pattern), _declarer.describe(bound),
            when.length == 0 ? "" : " when %-(%s, %)".format(when));
    }

    /// Reports `later` when it and `earlier`, of the same interface, could apply to one type.
    /// Whether it did.
    private bool reportOverlap(const Conforming earlier, const Conforming later)
    {
        auto vars = (_resolutions.typeParamsOf(earlier.holder) ~ _resolutions.typeParamsOf(later.holder)).map!(p => cast() p.id).array;
        // One for every type that meets a bound applies to another's type only if that type could meet it.
        if (_types.isParameter(earlier.self) != _types.isParameter(later.self))
        {
            auto every = _types.isParameter(earlier.self) ? earlier : later;
            auto other = _types.isParameter(earlier.self) ? later : earlier;
            auto param = _types[every.self].match!((const TypeParamData p) => p.param, _ => Id!TypeParam.init);
            foreach (needed; _typing.bounds.get(param, null))
            {
                if (!needed.valid) continue;
                auto meets = _typing.conformances.get(needed.decl, null).any!((e) {
                    Substitution trial;
                    auto all = vars ~ _resolutions.typeParamsOf(e.holder).map!(p => cast() p.id).array;
                    return unify(e.self, other.self, all, trial);
                });
                if (!meets) return false;
            }
            auto asked = _typing.bounds.get(param, null).filter!(b => b.valid)
                .map!(b => "`" ~ _resolutions.declarations.interfaces[b.decl].name ~ "`").array;
            _collector.reportError(DiagnosticCode.OverlappingConformance, other.span,
                "`%s` conforms to `%s` already, as every %s does; a type has one conformance to an interface".format(
                    _types.describe(other.self), _resolutions.declarations.interfaces[every.bound.decl].name,
                    asked.length == 0 ? "type" : asked.join(" & ")));
            return true;
        }
        Substitution s;
        if (!unify(earlier.self, later.self, vars, s)) return false;
        // A type argument of the interface that only its results mention is what the conformance
        // says, not what it's for, so it doesn't tell two apart.
        foreach (i; argumentParameters(earlier.bound.decl))
        {
            if (!unify(earlier.bound.args[i], later.bound.args[i], vars, s)) return false;
        }
        auto both = resolved(earlier.self, s);
        auto home = _resolutions.declarations.functionModules[earlier.holder];
        auto where = home == _resolutions.declarations.functionModules[later.holder] ? "" : " in `%s`".format(home);
        auto name = _resolutions.declarations.interfaces[earlier.bound.decl].name;
        _collector.reportError(DiagnosticCode.OverlappingConformance, later.span, both == earlier.self && both == later.self
            ? "`%s` already conforms to `%s`%s; a type has one conformance to an interface".format(_types.describe(both), name, where)
            : "`%s` already conforms to `%s`%s, and this conformance would apply to `%s` too; a type has one conformance to an interface"
                .format(_types.describe(earlier.self), name, where, _types.describe(both)));
        return true;
    }

    /// The positions of the type parameters of `decl` that a parameter of one of its functions mentions.
    private size_t[] argumentParameters(Id!InterfaceDecl decl)
    {
        auto interface_ = _resolutions.declarations.interfaces[decl];
        size_t[] found;
        foreach (i, param; interface_.typeParams)
        {
            auto mentioned = interface_.functions.any!(f => signatureOf(f.id).params.any!(p => _types.mentionsParameter(p, param.id)));
            if (mentioned) found ~= i;
        }
        return found;
    }

    /// Whether `a` and `b` can be made the same type by choosing what each of `vars` stands for,
    /// which `s` gathers.
    private bool unify(Type a, Type b, const(Id!TypeParam)[] vars, ref Substitution s)
    {
        a = resolved(a, s);
        b = resolved(b, s);
        if (a == b) return true;
        Id!TypeParam variable(Type t) => _types[t].match!((const TypeParamData p) => vars.canFind(p.param) ? p.param : Id!TypeParam.init,
            _ => Id!TypeParam.init);
        foreach (pair; [[a, b], [b, a]])
        {
            auto v = variable(pair[0]);
            if (!v.isValid) continue;
            if (_types.mentionsParameter(pair[1], v)) return false;
            s[v] = pair[1];
            return true;
        }
        bool all(const(Type)[] xs, const(Type)[] ys) => xs.length == ys.length && xs.length.iota.all!(i => unify(xs[i], ys[i], vars, s));
        auto other = _types[b];
        return _types[a].match!(
            (const OptionData o) => other.match!((const OptionData p) => unify(o.inner, p.inner, vars, s), _ => false),
            (const ArrayData x) => other.match!((const ArrayData y) => unify(x.element, y.element, vars, s), _ => false),
            (const TupleData x) => other.match!((const TupleData y) => all(x.elements, y.elements), _ => false),
            (const NominalData x) => other.match!((const NominalData y) => x.decl == y.decl && all(x.args, y.args), _ => false),
            (const FunctionData x) => other.match!((const FunctionData y) => x.mutables == y.mutables && all(x.params, y.params)
                && unify(x.ret, y.ret, vars, s), _ => false),
            (const ErrorUnionData x) => other.match!((const ErrorUnionData y) => unify(x.success, y.success, vars, s)
                && unify(x.error, y.error, vars, s), _ => false),
            (const ErrorListData x) => other.match!((const ErrorListData y) => all(x.members, y.members), _ => false),
            _ => false,
        );
    }

    /// `type` with what `s` says each of its variables stands for, in turn.
    private Type resolved(Type type, const Substitution s)
    {
        for (auto i = 0; i < 64; i++)
        {
            auto next = _types.substitute(type, s);
            if (next == type) return type;
            type = next;
        }
        return type;
    }

    /// Looks up what makes the types in `bound` satisfy the bounds of `func`'s type parameters, as
    /// calls from `site` see them, among the conformances. A bound whose type isn't in `bound` yet
    /// is left pending, and one whose interface has type arguments that aren't known yet binds them
    /// from the conformance found. `depth` is how many conformances' `when` bounds this is inside.
    private Conformance conformanceOf(Id!FunctionDecl func, ref Substitution bound, Site site, size_t depth = 0)
    {
        auto params = _resolutions.typeParamsOf(func);
        if (!bound.byValue.any!(v => mentionsAny(v, params))) return conformanceOf(func, params, null, null, bound, site, depth);

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
        auto result = conformanceOf(func, params, standIns, renaming, renamed, site, depth);
        foreach (i, param; params)
        {
            if (param.id !in bound && standIns[i].id in renamed) bound[param.id] = renamed[standIns[i].id];
        }
        return result;
    }

    /// `conformanceOf`, with each of `func`'s type parameters `params` standing for the one
    /// `renaming` gives in `bound`, which are `open`; with no `renaming`, they stand for themselves.
    private Conformance conformanceOf(Id!FunctionDecl func, const(TypeParam)[] params, const(TypeParam)[] open,
        Substitution renaming, ref Substitution bound, Site site, size_t depth)
    {
        Conformance result;
        auto supplied = _resolutions.boundFunctions.get(func, null);
        // Every bound, with functions or without.
        auto slots = boundSlots(_resolutions, _typing, func);
        if (slots.length == 0) return result;
        if (renaming.length == 0) open = params;
        Id!TypeParam key(Id!TypeParam param)
        {
            if (auto standIn = param in renaming) return _types[*standIn].match!((const TypeParamData p) => p.param, _ => param);
            return param;
        }
        Type inTermsOfOpen(Type type) => _types.substitute(_types.substitute(type, renaming), bound);
        result.witnesses = new Witness[supplied.length];
        auto decided = new bool[slots.length];

        for (auto progress = true; progress;)
        {
            progress = false;
            foreach (i, slot; slots)
            {
                if (decided[i]) continue;
                auto self = key(slot.param) in bound;
                if (self is null) continue;
                auto declared = _typing.bounds[slot.param][slot.bound];
                // One that couldn't be resolved was reported.
                if (!declared.valid)
                {
                    decided[i] = true;
                    continue;
                }
                auto goal = Goal(declared.decl, *self, declared.args.map!(a => inTermsOfOpen(a)).array);
                // What's already an error has been reported, and anything satisfies it.
                if (_types.mentionsError(goal.self) || goal.args.any!(a => _types.mentionsError(a)))
                {
                    decided[i] = true;
                    continue;
                }
                auto found = lookUp(goal, open, bound, site, depth);
                if (found.pending) continue;
                if (found.tooDeep) return found;
                if (found.failure !is null)
                {
                    auto wanted = Bound(goal.decl, declared.args.map!(a => inTermsOfOpen(a)).array);
                    auto hidden = _resolutions.hiddenParams.get(func, null).canFind!(p => p.id == slot.param);
                    result.failure = (hidden ? "needs %2$s, and `%3$s` isn't one: %4$s" : "needs `%1$s` to be %2$s, and `%3$s` isn't one: %4$s")
                        .format(_resolutions.declarations.typeParams[slot.param].name, withArticle(_declarer.describe(wanted)),
                            _types.describe(goal.self), found.failure);
                    result.tooDeep = found.tooDeep;
                    result.ambiguous = found.ambiguous;
                    return result;
                }
                result.witnesses[slot.start .. slot.end] = found.witnesses[];
                decided[i] = true;
                progress = true;
            }
        }
        result.pending = decided.canFind(false);
        return result;
    }

    /// Looks for the function behind each function of `goal`'s interface, which is what it is for
    /// `goal.self` to satisfy it. `open` are the type parameters `goal.args` may still mention
    /// unbound, which the functions found bind in `bound`.
    private Conformance satisfy(const Goal goal, const(TypeParam)[] open, ref Substitution bound, Site site,
        const(Goal)[] stack)
    {
        Conformance result;
        string described(const Goal g) => "`%s: %s`".format(_types.describe(g.self), _declarer.describe(Bound(g.decl, g.args.dup)));
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

        foreach (function_; _resolutions.declarations.interfaces[goal.decl].functions)
        {
            auto asked = Bound(goal.decl, goal.args.map!(a => _types.substitute(a, bound)).array);
            auto wanted = _types.substitute(symbolType(SymbolId(function_.id)), _declarer.substitutionOf(asked, goal.self));
            auto found = witnessFor(function_.name, signatureOf(wanted), open, bound, site, stack ~ goal);
            if (!found.holds)
            {
                found.witnesses = null;
                return found;
            }
            result.witnesses ~= found.witnesses;
        }
        return result;
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
    private Conformance witnessFor(string name, const FunctionData wanted, const(TypeParam)[] open, ref Substitution bound,
        Site site, const(Goal)[] stack)
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
            auto needs = conformanceOf(f, tried.binding, site);
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

        Attempt[] fitting(Attempt[] group) => group.filter!(t => t.trial.fitsAll).array;
        auto pool = groups.length > 0 ? fitting(groups[0]) : null;
        if (pool.length == 0 && groups.length > 1)
        {
            foreach (each; groups[1 .. $].map!(g => fitting(g)).joiner)
            {
                if (!pool.canFind!(t => t.trial.func == each.trial.func)) pool ~= each;
            }
        }
        if (pool.length == 0)
        {
            string[] lines;
            foreach (g, group; groups)
            {
                foreach (tried; group) lines ~= "\n    %s %s".format(overloadLabel(tried.trial.func, g > 0), tried.trial.problem);
            }
            result.failure = "no `%s` in scope takes %s%s%s".format(name, arguments(), lines.join, importHint(name, wanted, known, candidates, site.module_));
            return result;
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
            auto unbeaten = pool.filter!(t => !pool.any!(u => beats(u.trial, t.trial))).map!(t => t.trial.func).array;
            auto across = acrossModules(unbeaten);
            auto tied = unbeaten.map!(f => "`" ~ overloadLabel(f, across) ~ "`").array;
            result.failure = "more than one `%s` takes %s equally well: %-(%s and %)".format(name, arguments(), tied)
                ~ (across ? "; declare one in this module that calls the one you mean" : "");
            result.ambiguous = true;
            return result;
        }

        return finish(winners[0], bound);
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
        return cast(Candidates) unshadowed(found);
    }

    /// What to say when no function in scope fits and the module that declares one of the
    /// arguments' types has one that would, since importing it is all that's missing.
    private string importHint(string name, const FunctionData wanted, const(bool)[] known, const Candidates seen, string from)
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
                if (!fits) continue;
                // An import that brings it already is one that doesn't list it.
                auto via = _resolutions.moduleScopes[from].importedModules.find!(m => _resolutions.broughtFunctions(m, name).canFind(f));
                if (!via.empty)
                {
                    return "\n    `%s` has a `%s` that would fit; list it in the import of `%s` to use that one"
                        .format(via.front, overloadLabel(f), via.front);
                }
                return "\n    `%s` has a `%s` that would fit; import it to use that one".format(home, overloadLabel(f));
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
        if (actual == _types.error || actual == _types.never || isBareLiteralType(actual) || actual == _types.any) return;
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

    /// An argument whose type depends on where it goes: an integer literal, a lambda, `None`, `[]`
    /// or `[:]`, and as with `None`, a generic name with no type arguments that isn't called, like `Nil`.
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
            (const MapLiteral literal) => literal.keys.length == 0,
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
        /// The type parameters the expected type bound.
        Id!TypeParam[] fromExpected;
        /// In a trial, the type parameters only a lambda's result would decide, which stay unbound.
        Id!TypeParam[] undecided;
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
        // A parameter only a bound decides is unknown because the bound failed, so that's the error.
        if (bounded.isValid && params.any!(p => p.id !in binding.bound))
        {
            if (binding.bound.byValue.any!(t => _types.mentionsError(t)))
            {
                foreach (p; params) if (p.id !in binding.bound) binding.bound[p.id] = _types.error;
            }
            auto tried = binding.bound.dup;
            auto early = conformanceOf(bounded, tried, ctx.site);
            if (early.failure !is null && !early.tooDeep)
            {
                reportUnsatisfied(g.span, g.spelled, early);
                foreach (p; params) if (p.id !in binding.bound) binding.bound[p.id] = _types.error;
            }
        }
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
                if (typed[i] != Type.init) coerce(arg, typed[i], paramTypes[i], ctx.site);
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
                else if (typed[i] == _types.emptyDictionary) _declarer.reportUntypedEmptyDictionary(args[i].span);
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
                    (const MapLiteral _) { _declarer.reportUntypedEmptyDictionary(arg.span); },
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
                        else coerce(arg, type, funcData.params[i], ctx.site);
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

    /// Whether `expr` is `a?.b` or `a?.f(...)` with the field or call a `Unit`, which as a
    /// statement drops only whether it ran.
    private bool givesUnit(const Expr expr)
    {
        if (auto safe = expr.id in _typing.safeCalls) return safe.called == _types.unit;
        return expr.kind.match!(
            (const SafeMemberAccess access) {
                auto held = _typing.exprTypes.get(access.object.id, _types.error);
                auto record = _types.isErrorUnion(held) ? _types.successOf(held)
                    : _types.isOption(held) ? _types.optionInner(held) : _types.error;
                auto index = expr.id in _typing.fieldIndexes;
                return index !is null && _declarer.fieldsOf(record)[*index].type == _types.unit;
            },
            _ => false,
        );
    }

    /// Whether `object.f(...)` is on a value and some declaration could be `f`. `object?.f(...)`
    /// always is one, for a field as for a function.
    private bool isMethodCall(Id!Expr call, const Expr callee)
    {
        return callee.kind.match!(
            (const MemberAccess access) => (call in _resolutions.methodLookups) !is null && !isModulePath(*access.object),
            (const SafeMemberAccess _) => true,
            _ => false,
        );
    }

    private Type synthesizeMethodCall(const Expr expr, const CallExpr call, BodyContext ctx, Type expected)
    {
        auto reported = _collector.diagnostics.length;
        auto type = methodCall(expr, call, ctx, expected);
        if (type == _types.error) sayModuleHidden(*call.callee, reported);
        return type;
    }

    /// When `x` in the member access `access` is a local named like an imported module that has the
    /// member, says so in the first error reported since `reported`, since the module was likely meant.
    private void sayModuleHidden(const Expr access, size_t reported)
    {
        auto hidden = access.id in _resolutions.hiddenModules;
        if (hidden is null || _collector.diagnostics.length == reported) return;
        auto member = access.kind.match!((const MemberAccess m) => m.member, _ => assert(0, "only a member access hides a module"));
        _collector.amend(reported, "\n    `%1$s` here is a local, which hides the module `%1$s`; rename the local to use `%1$s.%2$s`"
            .format(*hidden, member));
    }

    /// `object.f(args)`. A field named `f` comes first; otherwise it's `f(object, args)`, with the
    /// `f` a plain name finds at module level. The receiver was synthesized to look for the field,
    /// so it's an argument that already has its type. `object?.f(args)` is the same call on
    /// `object`'s value, made an option or error union again.
    private Type methodCall(const Expr expr, const CallExpr call, BodyContext ctx, Type expected)
    {
        const(Expr)* object;
        string member;
        const(TypeExpr)[] typeArgs;
        bool safe;
        (*call.callee).kind.match!(
            (const MemberAccess m) {
                object = m.object;
                member = m.member;
                typeArgs = m.typeArgs;
            },
            (const SafeMemberAccess m) {
                object = m.object;
                member = m.member;
                safe = true;
            },
            (_) => assert(0, "isMethodCall only accepts a member access"),
        );
        if (!safe) return callOn(expr, call, object, member, typeArgs, synthesize(*object, ctx), ctx, expected);

        auto held = _declarer.requireTyped(synthesize(*object, ctx), object.span);
        if (!throughValue(held, object.span, "a function is called on any other value with `.`"))
        {
            foreach (arg; call.args) synthesize(arg, ctx);
            return _types.error;
        }
        auto fallible = _types.isErrorUnion(held);
        auto value = fallible ? _types.successOf(held) : _types.optionInner(held);
        // Without a field or a function named `member`, it's the field that's missing.
        if ((expr.id in _resolutions.methodLookups) is null && !hasField(value, member))
        {
            _collector.reportError(DiagnosticCode.UnknownMember, call.callee.span,
                "Type `%s` has no member named `%s`".format(_types.describe(held), member));
            foreach (arg; call.args) synthesize(arg, ctx);
            return _types.error;
        }
        // What's expected of the result, as far as it says what's expected of the call.
        auto inner = expected == Type.init || expected == _types.error ? Type.init
            : _types.isOption(expected) ? _types.optionInner(expected)
            : _types.isErrorUnion(expected) ? _types.successOf(expected) : Type.init;
        auto called = callOn(expr, call, object, member, typeArgs, value, ctx, inner);
        if (called == _types.error) return called;
        auto promotion = object.id in _typing.promotions;
        _typing.safeCalls[expr.id] = SafeCall(called, promotion is null ? Type.init : *promotion);
        _typing.promotions.remove(object.id);
        return throughSafe(held, called);
    }

    /// The type of `a?.b` or `a?.f(...)`, with `a` of type `held`, when `b` or the call on `a`'s
    /// value is `inner`. It's flat: an option isn't wrapped again, and errors on both sides are
    /// listed together.
    private Type throughSafe(Type held, Type inner)
    {
        if (inner == _types.error) return inner;
        if (!_types.isErrorUnion(held)) return _types.isOption(inner) ? inner : _types.option(inner);
        auto reason = _types.errorOf(held);
        if (!_types.isErrorUnion(inner)) return _types.errorUnion(inner, reason);
        return _types.errorUnion(_types.successOf(inner), mergedErrors(reason, _types.errorOf(inner)));
    }

    /// `object.f(args)` with `object` of type `objectType`, as `methodCall` describes.
    private Type callOn(const Expr expr, const CallExpr call, const(Expr)* object, string member,
        const(TypeExpr)[] typeArgs, Type objectType, BodyContext ctx, Type expected)
    {
        Type asField()
        {
            rejectTypeArguments(typeArgs, member, call.callee.span);
            auto calleeType = fieldOf(*call.callee, member, objectType);
            _typing.exprTypes[call.callee.id] = calleeType;
            return applyCallee(calleeType, call, expr.span, ctx);
        }

        if (objectType == _types.error || hasField(objectType, member)) return asField();

        auto lookup = distinct(_resolutions.methodLookups[expr.id]);
        auto arguments = (cast(Expr*) object)[0 .. 1] ~ cast(Expr[]) call.args;
        auto mutables = call.mutableArgs.length > 0 ? false ~ call.mutableArgs.dup : null;
        auto rewritten = new const CallExpr(cast(Expr*) call.callee, arguments, mutables);
        _typing.methodCalls[expr.id] = rewritten;
        auto receiver = _declarer.requireTyped(objectType, object.span);
        auto typed = new Type[arguments.length];
        typed[0] = receiver;
        auto reported = _collector.diagnostics.length;
        scope (exit) noteOtherCounts(reported, *rewritten, lookup);

        Id!FunctionDecl function_;
        if (lookup.count == 1)
        {
            function_ = cast() lookup.groups.joiner.front;
        }
        else if (receiver != _types.error)
        {
            function_ = chooseFunction(*call.callee, member, typeArgs, lookup, *rewritten, typed, true, ctx, expected);
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
        if (!receiverFits(member, object.span, functionType, receiver, call.callee.span))
        {
            return applyCallee(_types.error, *rewritten, expr.span, ctx, typed);
        }
        if (isGenericFunction(function_))
        {
            Generic g;
            g.name = call.callee.id;
            g.span = call.callee.span;
            g.spelled = member;
            g.written = typeArgs;
            g.params = _resolutions.typeParamsOf(function_);
            g.writable = decl.typeParams.length;
            g.func = function_;
            g.type = functionType;
            return applyGeneric(expr, g, *rewritten, expected, ctx, typed, true);
        }
        rejectTypeArguments(typeArgs, member, call.callee.span);
        return applyCallee(functionType, *rewritten, expr.span, ctx, typed);
    }

    /// Whether a receiver of type `receiver` can be the first argument of a function of type
    /// `functionType`, reporting why not. Its type is checked as any argument's is.
    private bool receiverFits(string member, Span objectSpan, Type functionType, Type receiver, Span calleeSpan)
    {
        if (receiver == _types.error) return false;
        auto signature = _types[functionType].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "a function's type is a function type"),
        );
        if (signature.params.length == 0)
        {
            _collector.reportError(DiagnosticCode.WrongArgumentCount, calleeSpan,
                "`%s` takes no arguments, so it can't be called on a value".format(member));
            return false;
        }
        if (signature.isMutable(0))
        {
            _collector.reportError(DiagnosticCode.MutabilityMismatch, objectSpan,
                "`%s` changes its first argument, so the write has to show at the call; write `%s(mutable ...)`"
                    .format(member, member));
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
                }
                type = _declarer.fieldsOf(type)[indexes[i][depth]].type;
            }
        }
        if (checks.length == 0) return objectType;
        if (errors.canFind(_types.error)) return _types.error;
        auto reason = errors[0];
        foreach (error; errors[1 .. $]) reason = mergedErrors(reason, error);
        _typing.withChecks[expr.id] = checks.sort!((a, b) => a.length > b.length).release;
        return _types.errorUnion(objectType, reason);
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
        auto object = synthesize(*member.object, ctx);
        auto reported = _collector.diagnostics.length;
        auto type = fieldOf(expr, member.member, object);
        if (type == _types.error) sayModuleHidden(expr, reported);
        return type;
    }

    /// The field `member` names on a value of `objectType`, reported if there's none.
    private Type fieldOf(const Expr expr, string member, Type objectType)
    {
        if (objectType == _types.error) return _types.error;

        auto fields = _declarer.fieldsOf(objectType);
        foreach (i, field; fields)
        {
            if (field.name == member)
            {
                _typing.fieldIndexes[expr.id] = i;
                return field.type;
            }
        }
        _collector.reportError(DiagnosticCode.UnknownMember, expr.span,
            "Type `%s` has no member named `%s`".format(_types.describe(objectType), member));
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
        // The one the compiler builds for `a..b`, looped over as `a..b` is, which never needs its length.
        if (isInterval(type) && _types.isInteger(_types.nominalArgs(type)[0]))
        {
            _typing.intervalLoops[for_.id] = true;
            return _types.nominalArgs(type)[0];
        }
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
        /// Whether finding it was reported as an error.
        bool failed;

        bool found() const => use.found;
    }

    /// What `for` yields from a `type` that isn't an array or an interval: the element of the
    /// type's conformance to `lang`'s `Range`, whose `next` steps it. A type that isn't a `Range`
    /// and is an `Iterable` is stepped through the range its `iterate` gives. Inside a generic
    /// function, a type parameter's bounds say what it is. `Type.init` when there's no `lang`.
    private Type loopElement(const Expr for_, const Expr iterable, Type type, BodyContext ctx)
    {
        auto range = rangeDecl();
        if (!range.isValid) return Type.init;
        if (!_loopElement.id.isValid) _loopElement = TypeParam(_ids.next!TypeParam, "T", iterable.span);
        Substitution bound;
        auto found = lookUp(Goal(range, type, [_types.parameter(_loopElement.id, "T")]), [_loopElement], bound, ctx.site, 0);
        if (found.holds && _loopElement.id in bound)
        {
            auto next = found.witnesses[0];
            _typing.loops[for_.id] = LoopFunctions(FunctionUse(next.func, next.typeArgs, next.witnesses));
            noteUse(ctx.site, iterable.span, next.func, next.typeArgs, next.witnesses);
            return bound[_loopElement.id];
        }

        auto collection = iterableDecl();
        if (!_loopRange.id.isValid) _loopRange = TypeParam(_ids.next!TypeParam, "R", iterable.span);
        Substitution gives;
        auto made = lookUp(Goal(collection.isValid ? collection : range, type, [_types.parameter(_loopRange.id, "R")]),
            [_loopRange], gives, ctx.site, 0);
        if (collection.isValid && made.holds && _loopRange.id in gives)
        {
            auto stepped = gives[_loopRange.id];
            Substitution inner;
            auto steps = lookUp(Goal(range, stepped, [_types.parameter(_loopElement.id, "T")]), [_loopElement], inner, ctx.site, 0);
            if (!steps.holds || _loopElement.id !in inner)
            {
                _collector.reportError(DiagnosticCode.InvalidOperand, iterable.span,
                    "`for` loops over what `iterate` gives for a `%s`, and `%s` isn't a `Range`: %s".format(_types.describe(type),
                        _types.describe(stepped), steps.failure is null ? "nothing says what it gives" : steps.failure));
                return _types.error;
            }
            auto iterate = made.witnesses[0];
            auto next = steps.witnesses[0];
            _typing.loops[for_.id] = LoopFunctions(FunctionUse(next.func, next.typeArgs, next.witnesses),
                FunctionUse(iterate.func, iterate.typeArgs, iterate.witnesses));
            noteUse(ctx.site, iterable.span, iterate.func, iterate.typeArgs, iterate.witnesses);
            noteUse(ctx.site, iterable.span, next.func, next.typeArgs, next.witnesses);
            return inner[_loopElement.id];
        }

        _collector.reportError(DiagnosticCode.InvalidOperand, iterable.span, "`for` loops over a `Range` or an `Iterable`, and `%s` is neither: %s"
            .format(_types.describe(type), found.failure is null ? "nothing says what it gives" : found.failure));
        return _types.error;
    }

    /// The function `name` that `syntax` at `at` calls with `args`, chosen as a call is from the
    /// functions resolution found there, with its type arguments bound by the arguments. An
    /// argument with a type in `typed` has it already: it's been synthesized, or it's a placeholder
    /// for a value with no expression, which the caller checks. The rest are checked against their
    /// parameters. Not found when no function takes them, which is reported when `required`;
    /// failed when finding one reported an error. `shown` is the types a missing function is
    /// reported without, in place of the first argument's.
    private SyntaxUse syntaxFunction(const Expr at, Span span, string name, string syntax, const(Expr)[] args,
        Type[] typed, BodyContext ctx, bool required = true, Type[] shown = null)
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
            auto fit = typed[0] == Type.init ? shapeFit(args[0], params[0], typeParams)
                : typedFit(typed[0], params[0], typeParams, false);
            return params.length == args.length && fit != Fit.none;
        }
        if (lookup is null || !lookup.groups.joiner.any!takesFirst)
        {
            if (!required) return SyntaxUse.init;
            typeTheRest();
            auto taken = shown is null ? "a `%s`".format(_types.describe(typed[0]))
                : shown.map!(t => "`" ~ _types.describe(t) ~ "`").join(" and ");
            _collector.reportError(DiagnosticCode.InvalidOperand, shown is null && args[0].id.isValid ? args[0].span : span,
                "%s calls `%s`, and no `%s` here takes %s".format(syntax, name, name, taken));
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
        found.signature = signatureOf(_types.substitute(symbolType(SymbolId(function_)), bound));
        foreach (i, arg; args)
        {
            if (checked[i] || !arg.id.isValid) continue;
            if (typed[i] != Type.init) coerce(arg, typed[i], found.signature.params[i], ctx.site);
            else checkArgument(arg, found.signature.params[i], ctx);
        }
        return found;
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
        auto type = rangeBounds(expr, range, "`for` needs a range of integers", ctx);
        _typing.exprTypes[expr.id] = type;
        return type;
    }

    /// The one integer type of the bounds of `a..b`, where a literal takes the type of the number
    /// beside it. `problem` begins the error for bounds that aren't integers.
    private Type rangeBounds(const Expr expr, const RangeExpr range, string problem, BodyContext ctx)
    {
        auto startType = synthesize(*range.start, ctx);
        auto endType = rangeEnd(*range.end, synthesize(*range.end, ctx));
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
                "%s, got `%s`".format(problem, _types.describe(type)));
            type = _types.error;
        }
        return type;
    }

    /// The type `typed` gives the end of `a..b`. A method call written after a range is part of
    /// its end, since `0..10.map(f)` is `0..(10.map(f))`, so an error about the call itself, and
    /// not about something inside its receiver or arguments, says so.
    private Type rangeEnd(const Expr end, lazy Type typed)
    {
        auto reported = _collector.diagnostics.length;
        auto type = typed;
        auto call = end.kind.match!((ref const CallExpr c) => &c, _ => null);
        auto access = call is null ? null : (*call.callee).kind.match!((ref const MemberAccess a) => &a, _ => null);
        if (access is null || isModulePath(*access.object)) return type;

        bool inside(Span span, Span part) => span.start >= part.start && span.end <= part.end;
        bool aboutCall(const Diagnostic d)
        {
            auto receiver = access.object.span;
            if (inside(d.span, receiver) && d.span != receiver) return false;
            return !call.args.any!(a => inside(d.span, a.span));
        }
        auto method = access.member;
        auto hint = "`a..b.%s(...)` calls `%s` on `b`, so to call it on the range, write `(a..b).%s(...)`";
        // Reported once, as the call, and not again as a bound.
        auto amended = _collector.amendFirstErrorSince(reported, hint.format(method, method, method), &aboutCall);
        return amended ? _types.error : type;
    }

    /// `break` and `continue` act on the loop whose body holds them, so a condition or what a
    /// `for` loops over isn't part of this and they belong to any loop around it.
    private void checkLoopBody(const Expr body, BodyContext ctx)
    {
        ctx.inLoop = true;
        checkDiscarded(body, ctx);
    }

    /// What `dg` gives when it checks the true branch of `if_`, inside which what an `if type`
    /// asks holds for its type.
    private T trueBranch(T)(const IfExpr if_, scope T delegate() dg)
    {
        auto test = if_.test is null ? null : if_.trueBody.id in _testsByBranch;
        if (test is null) return dg();
        _activeTests ~= *test;
        scope (exit) _activeTests = _activeTests[0 .. $ - 1];
        return dg();
    }

    /// What the `if type` `if_` asks for its type, and the signatures of the functions that
    /// gives its true branch.
    private void declareTest(const IfExpr if_)
    {
        auto found = if_.trueBody.id in _testsByBranch;
        if (found is null || *found in _typing.testBounds) return;
        auto test = _resolutions.tests[*found];
        auto self = _declarer.parameterType(*_resolutions.declarations.typeParams[test.param]);
        auto asked = _declarer.boundsOn(if_.test.bounds, self);
        _typing.testBounds[*found] = asked;
        // What the type has to be here already, from its bounds and the tests around this one.
        Bound[] already = _typing.bounds.get(test.param, null).dup;
        Id!FunctionDecl[] outer = _resolutions.boundFunctions.get(test.owner, null).dup;
        foreach (around; _activeTests)
        {
            if (_resolutions.tests[around].param != test.param) continue;
            already ~= _typing.testBounds.get(around, null);
            outer ~= _resolutions.tests[around].functions;
        }
        rejectImpossibleBounds(if_.test.name, if_.test.span, already ~ asked, already.length);
        foreach (supplied; test.functions)
        {
            auto requirement = _resolutions.requirements[supplied];
            auto bound = asked[requirement.bound];
            _typing.symbolTypes[SymbolId(supplied)] = _types.substitute(_typing.symbolTypes[SymbolId(requirement.declared)],
                _declarer.substitutionOf(bound, self));
            // One that's supplied already, or by a bound before it here, is that one.
            auto name = _resolutions.declarations.functions[supplied].name;
            auto same = outer.find!(d => _resolutions.declarations.functions[d].name == name
                && (d !in _repeatedBounds) && _typing.symbolTypes.get(SymbolId(d), Type.init) == _typing.symbolTypes[SymbolId(supplied)]);
            if (!same.empty) _repeatedBounds[supplied] = same.front;
            outer ~= supplied;
        }
    }

    /// The condition, or the binding of an `if val`. An `if type` has neither.
    private void checkIfHead(const IfExpr if_, BodyContext ctx)
    {
        if (if_.test !is null)
        {
            declareTest(if_);
            return;
        }
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
            trueBranch(if_, () => checkDiscarded(*if_.trueBody, ctx));
            return _types.unit;
        }

        auto thenType = trueBranch(if_, () => synthesizeBeside(*if_.trueBody, errors, ctx));
        auto elseType = synthesizeBeside(*if_.falseBody, errors, ctx);
        auto joined = join(thenType, elseType, span, "Branches", ctx.site);
        if (joined != _types.error)
        {
            coerce(*if_.trueBody, thenType, joined);
            coerce(*if_.falseBody, elseType, joined);
        }
        return joined;
    }

    /// The type that both `a` and `b` fit, or `error` (reported at `span`) if there isn't one.
    /// `what` names the things that have these types, for the error.
    private Type join(Type a, Type b, Span span, string what, Site site = Site.init)
    {
        if (a == _types.error || b == _types.error) return _types.error;
        if (a == _types.never) return b;
        if (b == _types.never) return a;
        if (isAssignable(a, b)) return b;
        if (isAssignable(b, a)) return a;
        if (a == _types.none) return _declarer.optionOf(b, span);
        if (b == _types.none) return _declarer.optionOf(a, span);
        // A bare `Error(e)` beside a value that isn't an error union makes one.
        auto valued = (Type t) => !_types.isFailure(t) && !_types.isErrorUnion(t) && t != _types.emptyArray && t != _types.emptyDictionary;
        if (_types.isFailure(a) && valued(b)) return _types.errorUnion(b, _types.errorOf(a));
        if (_types.isFailure(b) && valued(a)) return _types.errorUnion(a, _types.errorOf(b));
        // Errors that meet are listed together, when the values are the same.
        auto fallible = (Type t) => _types.isFailure(t) || _types.isErrorUnion(t);
        if (fallible(a) && fallible(b))
        {
            auto value = (Type t) => _types.isFailure(t) ? _types.never : _types.successOf(t);
            auto x = value(a), y = value(b);
            if (x == y || x == _types.never || y == _types.never)
            {
                auto success = x == _types.never ? y : x;
                auto errors = mergedErrors(_types.errorOf(a), _types.errorOf(b));
                return success == _types.never ? _types.failure(errors) : _types.errorUnion(success, errors);
            }
        }

        if (_types.sameApartFromError(a, b)) return _types.error;
        auto erase = "";
        if (site.module_ !is null)
        {
            auto item = rangeItem(a, site);
            if (item != Type.init && item == rangeItem(b, site))
                erase = "; `.seq()` on each makes both a `Seq<%s>`".format(_types.describe(item));
        }
        _collector.reportError(DiagnosticCode.TypeMismatch, span,
            "%s have different types `%s` and `%s`%s".format(what, _types.describe(a), _types.describe(b), erase));
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

    /// The one member of `sum` that the option, array, dictionary or tuple written out as `expr` can be, or
    /// `Type.init` if `expr` isn't one of those or there's no single member.
    private Type memberForSyntax(const Expr expr, Type sum)
    {
        auto candidates = expr.kind.match!(
            (const SomeExpr _) => _declarer.membersOf(sum).filter!(m => _types.isOption(m)).array,
            (const NoneLiteral _) => _declarer.membersOf(sum).filter!(m => _types.isOption(m)).array,
            (const ArrayLiteral _) => _declarer.membersOf(sum).filter!(m => _types.isArray(m)).array,
            (const MapLiteral _) => _declarer.membersOf(sum).filter!(m => isDictionary(m)).array,
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
            return coerce(expr, typeLambda(expr, lambda, &data, ctx.site), expected, ctx.site);
        }
        // What's expected can say what a generic use's type arguments are, also through `!` and `?`.
        auto isMethod = expr.kind.match!((const CallExpr call) => isMethodCall(expr.id, *call.callee),
            (const SafeMemberAccess _) => true, _ => false);
        auto unwraps = expr.kind.match!((const AssertExpr _) => true, (const PropagateExpr _) => true, _ => false);
        if (isMethod || unwraps || genericUse(expr).found || isOverloadedUse(expr))
        {
            return coerce(expr, synthesizeExact(expr, ctx, expected), expected, ctx.site);
        }
        if (auto range = asRange(&expr))
        {
            // Also through `?` and `!`, as a number literal adapts through them.
            auto inner = expected;
            while (_types.isOption(inner) || _types.isErrorUnion(inner))
            {
                inner = _types.isOption(inner) ? _types.optionInner(inner) : _types.successOf(inner);
            }
            if (isInterval(inner) && _types.isInteger(_types.nominalArgs(inner)[0]))
            {
                checkBareRange(expr, *range, inner, ctx);
                if (inner != expected) _typing.promotions[expr.id] = expected;
                return expected;
            }
        }
        auto constructed = constructedDecl(expr);
        if (auto owner = _declarer.ownerOf(constructed))
        {
            auto member = _typing.nominalTypes[constructed];
            if (wantsMember(member, *owner, expected)) return coerce(expr, synthesizeExact(expr, ctx), expected, ctx.site);
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
            if (isOptionSyntax(expr) || isArraySyntax(expr) || isTupleLiteral(expr) || isLambda(expr) || isDictionaryLiteral(expr))
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
        if (isOption && (isArraySyntax(expr) || isTupleLiteral(expr) || isLambda(expr) || isDictionaryLiteral(expr)))
        {
            check(expr, _types.optionInner(expected), ctx);
            _typing.promotions[expr.id] = expected;
            return expected;
        }
        auto asDictionary = isDictionary(expected) && isDictionaryLiteral(expr);
        if (isNumeric(expected) || isOption || isArray || isTuple || _declarer.isSum(expected) || _declarer.isOwnedMember(expected)
            || _types.isFunction(expected) || _types.isErrorUnion(expected) || asDictionary)
        {
            auto passedDown = expr.kind.match!(
                (const IfExpr if_) => if_.falseBody !is null,
                (const BlockExpr _) => true,
                (const SomeExpr _) => isOption,
                (const ArrayLiteral _) => isArray,
                (const MapLiteral _) => asDictionary,
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
                    (const MapLiteral literal) {
                        auto entry = _types.nominalArgs(expected);
                        foreach (i, key; literal.keys)
                        {
                            check(key, entry[0], ctx);
                            check(literal.values[i], entry[1], ctx);
                        }
                        return builtDictionary(expr, literal, expected, ctx);
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

        return coerce(expr, synthesize(expr, ctx), expected, ctx.site);
    }

    /// Fits `expr`, already found to have type `type`, to `expected`: a literal adapts and a
    /// value that isn't an option yet is promoted, and anything else has to be assignable.
    private Type coerce(const Expr expr, Type type, Type expected, Site site = Site.init)
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
        else if (type == _types.emptyArray && _types.isArray(expected)
            || type == _types.emptyDictionary && isDictionary(expected))
        {
            _typing.promotions[expr.id] = expected;
            return expected;
        }
        requireAssignable(type, expected, expr.span, site);
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
            || _types.isFailure(type) || isBareLiteralType(type)) return false;
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
            joined = join(joined, type, match_.arms[i].body.span, "Match arms", ctx.site);
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

        if (_declarer.isNative(decl))
        {
            checkArgumentsAsUnknown();
            return reportPattern(pattern.span, "A native type isn't taken apart by a pattern; bind a value of it with `name: %s`"
                .format(printTypeExpr(constructor.type)));
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
        auto thenType = trueBranch(if_, () => check(*if_.trueBody, expected, ctx));
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
            (const NominalData _) => _declarer.membersOf(to).canFind(from)
                || from == _types.emptyDictionary && isDictionary(to) ? 1 : -1,
            // Both have the layout of an array with no elements, so no conversion hides here.
            (const ArrayData a) => from == _types.emptyArray
                || (_types.isArray(from) && _types.arrayElement(from) == _types.never) ? 1 : -1,
            _ => -1,
        );
    }

    private void requireAssignable(Type from, Type to, Span span, Site site = Site.init)
    {
        if (isAssignable(from, to) || _types.mentionsError(from) || _types.mentionsError(to)) return;
        auto opaque = _types.isParameter(to)
            ? ", which could be any type; only a value of type `%s` is one".format(_types.describe(to)) : "";
        auto collect = "";
        if (site.module_ !is null && _types.isArray(to) && !_types.isArray(from))
        {
            auto item = rangeItem(from, site);
            if (item != Type.init && isAssignable(item, _types.arrayElement(to))) collect = "; `.array()` collects it into one";
        }
        _collector.reportError(DiagnosticCode.TypeMismatch, span,
            "Type `%s` is not assignable to type `%s`%s%s".format(_types.describe(from), _types.describe(to), opaque, collect));
    }

    /// What `type` gives as a `Range`, or through the range its `Iterable` gives, as `site` sees
    /// it; `Type.init` when it's neither. Only for wording an error.
    private Type rangeItem(Type type, Site site)
    {
        auto range = rangeDecl();
        auto collection = iterableDecl();
        if (!range.isValid || _types.isParameter(type)) return Type.init;
        auto t = TypeParam(_ids.next!TypeParam, "T", Span.init);
        Substitution bound;
        if (lookUp(Goal(range, type, [_types.parameter(t.id, "T")]), [t], bound, site, 0).holds && t.id in bound)
            return bound[t.id];
        if (!collection.isValid) return Type.init;
        auto r = TypeParam(_ids.next!TypeParam, "R", Span.init);
        Substitution gives;
        if (!lookUp(Goal(collection, type, [_types.parameter(r.id, "R")]), [r], gives, site, 0).holds || r.id !in gives)
            return Type.init;
        Substitution inner;
        if (lookUp(Goal(range, gives[r.id], [_types.parameter(t.id, "T")]), [t], inner, site, 0).holds && t.id in inner)
            return inner[t.id];
        return Type.init;
    }

}

package Typing checkTypes(const ref Program program, const ref Resolution resolution, Collector collector, NodeIds ids)
{
    auto typeChecker = new TypeChecker(resolution, collector, ids);
    return typeChecker.checkProgram(program);
}