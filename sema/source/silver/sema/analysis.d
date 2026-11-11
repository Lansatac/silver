module silver.sema.analysis;

import silver.ast;
import silver.sema.check;
import silver.sema.constant : ConstValue;
import silver.sema.resolve;
import silver.sema.target : Intrinsic, intrinsicNamed, Target;
import silver.sema.type;

import std.algorithm : map;
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

/// Analyzes every module in `program`, reporting problems to `collector`.
Analysis analyze(const ref Program program, Collector collector, Target target = Target.host)
{
    import silver.sema.entry : checkEntryPoint, checkEntryPointReturn;
    import silver.sema.resolve : resolveNames;

    auto entryPoint = checkEntryPoint(program, collector);
    auto resolution = resolveNames(program, collector, target);
    auto typing = checkTypes(program, resolution, collector);
    checkEntryPointReturn(entryPoint, resolution, typing, collector);
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
