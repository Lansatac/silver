module silver.sema.analysis;

import silver.ast;
import silver.sema.check : checkTypes;
import silver.sema.typing;
import silver.sema.constant : ConstValue;
import silver.sema.resolve;
import silver.sema.table : SideTable;
import silver.sema.target : Intrinsic, intrinsicNamed, Target;
import silver.sema.type;

import std.algorithm : all, canFind, map;
import std.range : iota;
import std.array : array;
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

    /// ditto
    Type typeOf(Id!ConstDecl constant) const
    {
        return typeOf(SymbolId(constant));
    }

    /// The option type `expr`'s value is wrapped into after it's evaluated, or null if it isn't.
    /// `typeOf(expr)` stays the type before wrapping.
    const(Type)* promotionOf(Id!Expr expr) const
    {
        return expr in _typing.promotions;
    }

    /// The type of the value `expr` hands to whatever uses it: `typeOf`, after any promotion.
    Type valueTypeOf(Id!Expr expr) const
    {
        if (auto option = promotionOf(expr)) return *option;
        return typeOf(expr);
    }

    /// What `constant` evaluated to. An analysis with no errors has one for every constant.
    const(ConstValue) valueOf(Id!ConstDecl constant) const
    {
        return _typing.constants[constant];
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

    /// ditto, for a lambda.
    FunctionData signatureOf(Id!Expr lambda) const
    {
        return _typing.types[typeOf(lambda)].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "A lambda's type should always be a function type"),
        );
    }

    /// The locals and params `lambda` uses from outside itself. Each is immutable, so it can be
    /// copied when the lambda is created.
    const(SymbolId)[] capturesOf(Id!Expr lambda) const
    {
        return _resolution.captures.get(lambda, null);
    }

    /// The declaration a name or module-rooted member chain refers to, or null if it was
    /// left unresolved (e.g. `x.f` on a value, which types decide).
    const(SymbolId)* resolutionOf(Id!Expr use) const
    {
        if (auto chosen = use in _typing.chosenSymbols) return chosen;
        return use in _resolution.resolutions;
    }

    /// The function a call invokes directly, or null for a call through a value (e.g. a
    /// function-typed param). The type checker chooses it when the name is overloaded.
    const(Id!FunctionDecl)* calleeOf(Id!Expr call) const
    {
        if (auto method = call in _typing.methodCallees) return method;
        if (auto chosen = call in _typing.chosenCallees) return chosen;
        return call in _resolution.callees;
    }

    /// Whether `func` shares its name with another function of its module, so a name built from
    /// its own isn't enough to tell them apart.
    bool isOverloaded(Id!FunctionDecl func) const
    {
        return (func in _typing.overloaded) !is null;
    }

    /// The call `f(x, y)` that `x.f(y)` means, or null if `call` isn't one of those. Its callee is
    /// still the member access, so use `calleeOf` for the function.
    const(CallExpr)* methodCallOf(Id!Expr call) const
    {
        if (auto method = call in _typing.methodCalls) return *method;
        return null;
    }

    /// Whether the `for` loop `for_` is over an `Interval` value, which it loops over as over `a..b`.
    bool isIntervalLoop(Id!Expr for_) const
    {
        return (for_ in _typing.intervalLoops) !is null;
    }

    /// The function the comparison `binary` calls, or null if it compares two numbers, Strings or
    /// Chars, or isn't `<`, `<=`, `>` or `>=`.
    const(FunctionUse)* comparisonOf(Id!Expr binary) const
    {
        return binary in _typing.comparisons;
    }

    /// How the call `call` of `derivedCompare` orders its type.
    const(DerivedOrder)* derivedOrderOf(Id!Expr call) const
    {
        return call in _typing.derivedOrders;
    }

    /// The functions the `for` loop `for_` calls, or null if it loops over an array or `a..b`.
    const(LoopFunctions)* loopOf(Id!Expr for_) const
    {
        return for_ in _typing.loops;
    }

    /// The functions that build the dictionary literal `literal`.
    const(DictionaryFunctions)* dictionaryOf(Id!Expr literal) const
    {
        return literal in _typing.dictionaryLiterals;
    }

    /// The function that makes the dictionary a value of type `emptyDictionary` is promoted to.
    Id!FunctionDecl emptyDictionaryFunction() const
    {
        return _typing.emptyDictionary;
    }

    /// The functions `index` calls, or null if it indexes an array.
    const(IndexFunctions)* indexingOf(Id!Expr index) const
    {
        return index in _typing.indexing;
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

    /// What the type parameters of the generic function or constructor that `name` uses stand for,
    /// in its declaration's order, or null if it isn't one. Inside a generic function they can
    /// mention its own type parameters.
    const(Type)[] typeArgumentsOf(Id!Expr name) const
    {
        return _typing.typeArguments.get(name, null);
    }

    /// The function found for each function that the bounds of the generic function `name` uses
    /// declare, in the order `witnessIndexOf` indexes, or null if it has no bounds. Inside a
    /// generic function they're in terms of its type parameters, and one whose function is a
    /// function a bound of it supplies stands for the witness the instance was given.
    const(Witness)[] witnessesOf(Id!Expr name) const
    {
        return _typing.witnesses.get(name, null);
    }

    /// For a function that a bound supplies inside a generic function, where its witness is among
    /// those of each instance of that function; null for any other function.
    const(size_t)* witnessIndexOf(Id!FunctionDecl func) const
    {
        auto requirement = func in _resolution.requirements;
        return requirement is null || requirement.test.isValid ? null : &requirement.index;
    }

    /// For the `if type` `if_`: the type it asks about, in terms of the type parameters of the
    /// function it's in.
    Type testedType(Id!Expr if_) const
    {
        auto param = _resolution.declarations.typeParams[_resolution.tests[if_].param];
        return (cast(TypeTable) _typing.types).parameter(param.id, param.name);
    }

    /// What the `if type` `if_` asks its type to satisfy, as `testedType` is: the bounds written,
    /// then what they require.
    const(Bound)[] testBoundsOf(Id!Expr if_) const
    {
        return _typing.testBounds[if_];
    }

    /// The functions the bounds of the `if type` `if_` supply in its true branch, in the order of
    /// the witnesses `conforms` finds for its bounds, one after another.
    const(Id!FunctionDecl)[] testFunctionsOf(Id!Expr if_) const
    {
        return _resolution.tests[if_].functions;
    }

    /// Whether `self`, which mentions no type parameter, satisfies `bound`, whose arguments don't
    /// either, by the program's conformances; and if so the function behind each of the
    /// interface's, which mention none either.
    bool conforms(const Bound bound, Type self, out Witness[] witnesses) const
    {
        Substitution open;
        return lookUp(bound.decl, self, bound.args, open, witnesses);
    }

    /// `conforms` for `args` that can mention type parameters that aren't in `open` yet, which
    /// the conformance found binds there.
    private bool lookUp(Id!InterfaceDecl decl, Type self, const(Type)[] args, ref Substitution open, out Witness[] witnesses) const
    {
        auto table = cast(TypeTable) _typing.types;
        foreach (entry; _typing.conformances.get(decl, null))
        {
            Substitution s;
            if (!matchType(entry.self, self, s)) continue;
            // An argument already known says what the conformance's parameters in it are.
            auto fits = args.length.iota.all!((k) {
                auto known = table.substitute(args[k], open);
                return table.mentionsParameter(known) || matchType(entry.bound.args[k], known, s);
            });
            Witness[] supplied;
            if (!fits || !solveWhen(entry.holder, s, supplied)) continue;
            auto opened = open.dup;
            fits = args.length.iota.all!((k) {
                auto declared = table.substitute(entry.bound.args[k], s);
                auto known = table.substitute(args[k], opened);
                return matchType(known, declared, opened) && table.substitute(known, opened) == declared;
            });
            if (!fits) continue;
            foreach (param, type; opened) open[param] = type;
            witnesses = entry.witnesses.map!(w => given(w, s, supplied, entry.holder)).array;
            return true;
        }
        return false;
    }

    /// Looks up the `when` bounds of the conformance whose type parameters `holder` holds, as `s`
    /// binds them, binding those that only a `when` bound decides. Whether they hold, and the
    /// witness for each function they supply.
    private bool solveWhen(Id!FunctionDecl holder, ref Substitution s, out Witness[] supplied) const
    {
        // As the checker's `conformanceOf` does, so the two agree.
        supplied = new Witness[_resolution.boundFunctions.get(holder, null).length];
        auto slots = boundSlots(_resolution, _typing, holder);
        auto decided = new bool[slots.length];
        for (auto progress = true; progress;)
        {
            progress = false;
            foreach (i, slot; slots)
            {
                if (decided[i]) continue;
                auto self = slot.param in s;
                if (self is null) continue;
                auto declared = _typing.bounds[slot.param][slot.bound];
                Witness[] found;
                if (!lookUp(declared.decl, *self, declared.args, s, found)) return false;
                supplied[slot.start .. slot.end] = found[];
                decided[i] = true;
                progress = true;
            }
        }
        return !decided.canFind(false);
    }

    /// `witness`, found for a conformance, for its type parameters as `s` binds them: what one of
    /// `holder`'s `when` bounds supplies is what `supplied` gives for it.
    private Witness given(const Witness witness, const Substitution s, const(Witness)[] supplied, Id!FunctionDecl holder) const
    {
        if (auto requirement = witness.func in _resolution.requirements)
        {
            if (requirement.owner == holder) return cast() supplied[requirement.index];
        }
        auto table = cast(TypeTable) _typing.types;
        return Witness(witness.func, witness.typeArgs.map!(t => table.substitute(t, s)).array,
            witness.witnesses.map!(w => given(w, s, supplied, holder)).array);
    }

    /// Binds the type parameters `pattern` mentions that `s` doesn't bind yet so that it's
    /// `actual`. Whether it can be.
    private bool matchType(Type pattern, Type actual, ref Substitution s) const
    {
        if (pattern == actual) return true;
        auto table = types;
        bool all(const(Type)[] patterns, const(Type)[] actuals, ref Substitution into)
        {
            if (patterns.length != actuals.length) return false;
            foreach (i, p; patterns)
            {
                if (!matchType(p, actuals[i], into)) return false;
            }
            return true;
        }
        auto data = table[actual];
        return table[pattern].match!(
            (const TypeParamData p) {
                if (auto known = p.param in s) return *known == actual;
                s[p.param] = actual;
                return true;
            },
            (const OptionData o) => data.match!((const OptionData a) => matchType(o.inner, a.inner, s), _ => false),
            (const ArrayData a) => data.match!((const ArrayData b) => matchType(a.element, b.element, s), _ => false),
            (const TupleData t) => data.match!((const TupleData u) => all(t.elements, u.elements, s), _ => false),
            (const NominalData n) => data.match!((const NominalData m) => m.decl == n.decl && all(n.args, m.args, s), _ => false),
            (const ErrorUnionData u) => data.match!(
                (const ErrorUnionData v) => matchType(u.success, v.success, s) && matchType(u.error, v.error, s), _ => false),
            (const FunctionData f) => data.match!((const FunctionData g) => f.mutables == g.mutables
                && all(f.params ~ f.ret, g.params ~ g.ret, s), _ => false),
            _ => false,
        );
    }

    /// The type parameters of `func`, which its type arguments are in the order of: those it
    /// declares, then one for each parameter whose type is an interface name.
    const(TypeParam)[] typeParametersOf(Id!FunctionDecl func) const
    {
        return _resolution.typeParamsOf(func);
    }

    /// `type` with the type parameters in `substitution` replaced, which interns types the checker
    /// never saw, like `Box<[Int]>` for an instance. Interning only adds to the table: no type
    /// already handed out changes, so this is still a query.
    Type instantiate(Type type, const Substitution substitution) const
    {
        if (substitution.length == 0) return type;
        return (cast(TypeTable) _typing.types).substitute(type, substitution);
    }

    /// What each type parameter of the declared type `type` stands for in it.
    Substitution substitutionOf(Type type) const
    {
        Substitution substitution;
        _typing.types[type].match!(
            (const NominalData nominal) {
                foreach (i, param; declarationOf(nominal.decl).typeParams) substitution[param.id] = nominal.args[i];
            },
            (_) {},
        );
        return substitution;
    }

    /// The `opEquals` that the module of `type` wrote for it, as this instance of the type uses
    /// it, or one that isn't `found` when its equality is the structural one.
    FunctionUse equalityOf(Type type) const => written(_typing.equalsFunctions, type);
    /// ditto, for its `opHash`.
    FunctionUse hashOf(Type type) const => written(_typing.hashFunctions, type);
    /// ditto, for its `opString`.
    FunctionUse stringOf(Type type) const => written(_typing.stringFunctions, type);

    private FunctionUse written(const ref SideTable!(Id!TypeDecl, Id!FunctionDecl) table, Type type) const
    {
        return _typing.types[type].match!(
            (const NominalData nominal) {
                auto func = nominal.decl in table;
                if (func is null) return FunctionUse.init;
                Substitution s;
                auto fits = matchType(signatureOf(*func).params[0], type, s);
                assert(fits, "a type's own function takes every instance of it");
                return FunctionUse(*func, typeParametersOf(*func).map!(p => s[p.id]).array, null);
            },
            _ => FunctionUse.init,
        );
    }

    /// The operands of the `~` chain `concat` heads, flattened, so that `a ~ b ~ c` is one
    /// allocation. The `~`s nested inside it are only reached through this.
    const(Expr)[] concatOperands(Id!Expr concat) const
    {
        return _typing.concatOperands[concat];
    }

    /// The declared type `decl` introduces.
    Type typeOf(Id!TypeDecl decl) const
    {
        return _typing.nominalTypes[decl];
    }

    /// What values of the sum `type` can be, in order, which is what a tag indexes. Empty for
    /// anything that isn't a sum.
    const(Type)[] membersOf(Type type) const
    {
        return _typing.types[type].match!(
            (const NominalData nominal) => _typing.members.get(nominal.decl, null).map!(m => instantiate(m, substitutionOf(type))).array,
            (const ErrorListData list) => list.members.dup,
            _ => (Type[]).init,
        );
    }

    /// Which member of the sum `sum` a value of `from` is promoted to: `from` itself, or the one
    /// option or array member that a `None` or `[]` takes on.
    size_t memberIndexFor(Type sum, Type from) const
    {
        import std.algorithm : countUntil;

        auto members = membersOf(sum);
        auto exact = members.countUntil(from);
        if (exact >= 0) return exact;
        if (from == types.none) return members.countUntil!(m => types.isOption(m));
        assert(from == types.emptyArray, "sema only promotes a member of the sum");
        return members.countUntil!(m => types.isArray(m));
    }

    /// The member `expr` builds on the way to being its sum, or null if it doesn't. `typeOf(expr)`
    /// is the sum, and only a constructor of a member the sum owns does this.
    const(Type)* constructedMemberOf(Id!Expr expr) const
    {
        return expr in _typing.constructedMembers;
    }

    /// The type of the value arriving at `pattern`.
    Type subjectOf(Id!Pattern pattern) const
    {
        return _typing.patternSubjects[pattern];
    }

    /// Which member of its subject, a sum, `pattern` tests for, or null if it doesn't test one.
    const(size_t)* memberTestOf(Id!Pattern pattern) const
    {
        return pattern in _typing.patternMembers;
    }

    /// For a pattern on an error list that reaches through a declared sum the list names, the list
    /// and which of its members that sum is, which is tested before the pattern. Null otherwise.
    const(size_t)* listMemberThrough(Id!Pattern pattern, out Type list) const
    {
        auto index = pattern in _typing.patternsThrough;
        if (index !is null) list = _typing.patternListSubjects[pattern];
        return index;
    }

    /// The declaration a constructor pattern takes apart.
    Id!TypeDecl constructorOf(Id!Pattern pattern) const
    {
        return _typing.patternConstructors[pattern];
    }

    /// The fields of the declared type `type`, in declaration order, with its type arguments filled in.
    const(FieldInfo)[] fieldsOf(Type type) const
    {
        return _typing.types[type].match!(
            (const NominalData nominal) => _typing.fields[nominal.decl]
                .map!(f => FieldInfo(f.name, instantiate(f.type, substitutionOf(type)))).array,
            (_) => assert(0, "only a declared type has fields"),
        );
    }

    /// Where in `fieldsOf` the field read or assigned by the member access `access` is. Only
    /// for a member of a value: `geo.Origin` is a resolution (see `resolutionOf`) and has no index.
    size_t fieldIndexOf(Id!Expr access) const
    {
        return _typing.fieldIndexes[access];
    }

    /// For each update of the `with` expression `with_`, the field index of each step of its path.
    const(size_t[])[] updatePathsOf(Id!Expr with_) const
    {
        return _typing.updatePaths[with_];
    }

    /// The places of the values a `with` checks the invariants of, longest first, the empty path being
    /// the whole value. Empty when it checks none, and its type is the object's.
    const(size_t[])[] withChecksOf(Id!Expr with_) const
    {
        return _typing.withChecks.get(with_, null);
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
    const(ConstDecl)* declarationOf(Id!ConstDecl constant) const
    {
        return _resolution.declarations.constants[constant];
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

    /// The name of the module `func` is declared in.
    string moduleOf(Id!FunctionDecl func) const
    {
        return _resolution.declarations.functionModules[func];
    }

    /// The library a `native def` is found in: its module's `native library`, or null for the
    /// C library and the runtime.
    string libraryOf(Id!FunctionDecl native) const
    {
        auto library = moduleOf(native) in _resolution.nativeLibraries;
        return library is null ? null : *library;
    }

    /// The operation an `intrinsic def` names, which sema has checked the compiler implements.
    Intrinsic intrinsicOf(Id!FunctionDecl intrinsic) const
    {
        auto decl = declarationOf(intrinsic);
        assert(decl.kind == FunctionKind.intrinsic, decl.name ~ " isn't an intrinsic");
        return *intrinsicNamed(decl.name);
    }
}

/// Analyzes every module in `program`, reporting problems to `collector`. With `testing`, the
/// program is run for its tests, so it needn't have a `main`.
Analysis analyze(const ref Program program, Collector collector, Target target = Target.host, bool testing = false)
{
    import silver.sema.entry : checkEntryPoint, checkEntryPointSignature;
    import silver.sema.resolve : resolveNames;

    auto entryPoint = checkEntryPoint(program, collector, testing);
    // The nodes sema makes, which no module's source has. Modules' ASTs can be shared between
    // programs, so nothing is added to them.
    auto made = new NodeIds(ModuleKey.analysis);
    auto resolution = resolveNames(program, collector, target, made);
    auto typing = checkTypes(program, resolution, collector, made);
    checkEntryPointSignature(entryPoint, resolution, typing, collector);
    return new Analysis(resolution, typing, entryPoint);
}

version (unittest)
{
    import silver.loader : load, Packages, standardPrelude, withStandardLibrary;

    /// Loads `source` as the entry module (with the real stdlib) and analyzes it.
    /// Load errors fail the test, so a test only ever sees sema's diagnostics.
    Collector analyzeSource(string source)
    {
        auto context = new SourceContext;
        auto program = load(source, "main.ag", Packages(withStandardLibrary([])), standardPrelude, context);
        assert(!context.collector.hasErrors, "The test program failed to load");
        analyze(program, context.collector);
        return context.collector;
    }
}

@("analyze requires main to return Unit, however that's spelled")
unittest
{
    foreach (source; ["def main(): Int => 1", "def main(): Never => panic(\"x\")"])
    {
        auto collector = analyzeSource(source);
        collector.diagnostics.length.should.equal(1);
        collector.diagnostics[0].code.should.equal(DiagnosticCode.MainInvalidDefinition);
    }
    analyzeSource("alias Empty = Unit\ndef main(): Empty => ()").diagnostics.length.should.equal(0);
}

@("analyze requires main's parameter to be a [String], however that's spelled")
unittest
{
    foreach (source; ["def main(a: Int): Unit {}", "def main(a: [String]?): Unit {}", "def main(a: [Char]): Unit {}"])
    {
        auto collector = analyzeSource(source);
        collector.diagnostics.length.should.equal(1);
        collector.diagnostics[0].code.should.equal(DiagnosticCode.MainInvalidDefinition);
    }
    analyzeSource("alias Words = [String]\ndef main(words: Words): Unit {}").diagnostics.length.should.equal(0);
    // A generic main is told it can't be generic, and nothing about its parameter's type.
    analyzeSource("def main<T>(args: [T]): Unit {}").diagnostics.length.should.equal(1);
    auto unknown = analyzeSource("def main(args: [Nope]): Unit {}");
    unknown.diagnostics.length.should.equal(1);
    unknown.diagnostics[0].code.should.equal(DiagnosticCode.UnknownType);
}

@("analyze doesn't report main's return type when it's already unknown")
unittest
{
    auto collector = analyzeSource("def main(): Nope => ()");
    collector.diagnostics.length.should.equal(1);
    collector.diagnostics[0].code.should.equal(DiagnosticCode.UnknownType);
}

@("analyze rejects a type that can only be built from itself")
unittest
{
    import std.algorithm : map;
    import std.array : array;

    const(DiagnosticCode)[] reported(string declarations)
    {
        return analyzeSource(declarations ~ "\ndef main(): Unit => ()").diagnostics.map!(d => d.code).array;
    }

    with (DiagnosticCode)
    {
        reported("type A(a: A)").should.equal([UninhabitedType]);
        reported("type A(pair: (Int, A))").should.equal([UninhabitedType]);
        reported("type A(b: B)\ntype B(a: A)").should.equal([UninhabitedType, UninhabitedType]);
        reported("type S = X(s: S) | Y(s: S)").should.equal([UninhabitedType]);
        reported("type S = X(x: X) | Nothing").should.equal([UninhabitedType]);
    }

    reported("type A(a: A?)").length.should.equal(0);
    reported("type A(a: [A])").length.should.equal(0);
    reported("type A(a: () -> A)").length.should.equal(0);
    reported("type S = X(s: S) | Nothing").length.should.equal(0);
    reported("type A(a: B)\ntype B(n: Int)").length.should.equal(0);
}

@("analyze accepts a minimal program")
unittest
{
    auto collector = analyzeSource("def main(): Unit => ()");
    collector.diagnostics.length.should.equal(0);
}
