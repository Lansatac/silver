/// Name resolution: links every identifier and module path to the declaration it names,
/// and records which function each direct call invokes.
module silver.sema.resolve;


import std.algorithm;
import std.array;
import std.range : chain, iota, walkLength;
import std.string;
import std.sumtype;

import silver.ast;
import silver.sema.target : intrinsicAlias, intrinsicNamed, isIntrinsicType, Target;
public import silver.sema.table : SideTable;

/// An `Id!AliasDecl` is only ever in a scope: a use of one records what it stands for.
alias SymbolId = SumType!(Id!FunctionDecl, Id!Param, Id!VarDecl, Id!Module, Id!TypeDecl, Id!ConstDecl, Id!AliasDecl);

alias TypeSymbol = SumType!(Builtin, Id!TypeDecl, Id!AliasDecl, Id!TypeParam, Id!InterfaceDecl);

private bool isFunction(const SymbolId symbol)
{
    return symbol.match!((const Id!FunctionDecl _) => true, _ => false);
}

private bool isConversion(Builtin builtin)
{
    static immutable Builtin[] notConversions = [Builtin.Never, Builtin.Unit, Builtin.Bool, Builtin.Char, Builtin.Any];
    return !notConversions.canFind(builtin);
}

/// `name` as a type that values can be converted to with `Name(x)`, if it is one.
/// Types can't be declared with these names, so nothing can hide them.
private const(Builtin)* conversionBuiltin(string name)
{
    import std.conv : to;
    import std.traits : EnumMembers;

    foreach (builtin; EnumMembers!Builtin)
    {
        if (builtin.to!string == name && isConversion(builtin))
        {
            return new Builtin(builtin);
        }
    }
    return null;
}

private TypeSymbol[string] builtinTypes() pure
{
    import std.conv : to;
    import std.traits : EnumMembers;

    TypeSymbol[string] types;
    foreach (builtin; EnumMembers!Builtin)
    {
        types[builtin.to!string] = TypeSymbol(builtin);
    }
    return types;
}

/// Every declaration in a program, by ID. The pointers are into the AST.
package struct Declarations
{
    SideTable!(Id!FunctionDecl, const(FunctionDecl)*) functions;
    /// The module each function is declared in.
    SideTable!(Id!FunctionDecl, string) functionModules;
    SideTable!(Id!TypeDecl, const(TypeDecl)*) types;
    /// The module each type is declared in.
    SideTable!(Id!TypeDecl, string) typeModules;
    SideTable!(Id!InterfaceDecl, const(InterfaceDecl)*) interfaces;
    SideTable!(Id!ConstDecl, const(ConstDecl)*) constants;
    SideTable!(Id!AliasDecl, const(AliasDecl)*) aliases;
    SideTable!(Id!VarDecl, const(VarDecl)*) locals;
    SideTable!(Id!Param, const(Param)*) params;
    SideTable!(Id!TypeParam, const(TypeParam)*) typeParams;
}

/// What name resolution produced.
package struct Resolution
{
    SideTable!(Id!Expr, SymbolId) resolutions;
    SideTable!(Id!TypeExpr, TypeSymbol) typeResolutions;
    SideTable!(Id!Expr, Id!FunctionDecl) callees;
    SideTable!(Id!Expr, Id!TypeDecl) constructions;
    /// The locals and params each lambda uses from outside itself, in first-use order.
    SideTable!(Id!Expr, const(SymbolId)[]) captures;
    /// Calls like `UInt8(x)`, by the type they convert to.
    SideTable!(Id!Expr, Builtin) conversions;
    /// For a call `x.f(...)` on a value, the functions a plain `f` finds at module level. The type
    /// checker decides whether one is used, since a field of `x` comes first.
    SideTable!(Id!Expr, Candidates) methodLookups;
    /// Names that could be more than one function, by the name's expression. The type checker
    /// chooses, so these have no entry in `resolutions`.
    SideTable!(Id!Expr, Candidates) overloads;
    /// For each `for` and each `x[i]`, by name, the functions that calls of `length`, `opIndex`,
    /// `opIndexAssign` and `next` there would choose from, since that syntax means calls
    /// of them on anything but an array or `a..b`.
    SideTable!(Id!Expr, Candidates[string]) operatorLookups;
    Declarations declarations;
    /// The `native library` of each module that names one.
    string[string] nativeLibraries;
    /// Each module's own top-level scope, by module name.
    const(Scope)[string] moduleScopes;
    /// The type parameters a function has beyond those it declares: one for each parameter whose
    /// type is an interface name, in parameter order. They come after the declared ones.
    SideTable!(Id!FunctionDecl, const(TypeParam)[]) hiddenParams;
    /// For a parameter type that's an interface name, the hidden type parameter it stands for,
    /// and for an interface name or `A & B` in a result type or a `val`'s annotation, its floor.
    SideTable!(Id!TypeExpr, Id!TypeParam) sugarParams;
    /// The floors in a function's result type: one for each interface name or `A & B` in it, an
    /// outer one before those in its type arguments. Each stands for the type the body gives
    /// there, which its bounds check, and none is a type parameter of the function.
    SideTable!(Id!FunctionDecl, const(TypeParam)[]) resultFloors;
    /// The same for a lambda's or nested `def`'s result type, and for a `val`'s annotation.
    SideTable!(Id!Expr, const(TypeParam)[]) lambdaFloors;
    SideTable!(Id!VarDecl, const(TypeParam)[]) bindingFloors;
    /// The functions a generic function's bounds supply inside it, in the order its witnesses are
    /// kept: by type parameter, then bound, then the interface's function.
    SideTable!(Id!FunctionDecl, Id!FunctionDecl[]) boundFunctions;
    /// What each of those functions stands for.
    SideTable!(Id!FunctionDecl, Requirement) requirements;
    /// What each module's `forward import`s pass on to its importers, by module and then name.
    Forward[][string][string] forwards;
    /// Names that are an alias of a generic type's instance, like `IntBox` after
    /// `alias IntBox = Box<Int>`, by the alias: `resolutions` has the type, and the alias its
    /// type arguments.
    SideTable!(Id!Expr, Id!AliasDecl) aliasedInstances;
    /// Each module's `forward import`s, in order.
    ForwardImport[][string] forwardImports;
    /// Each name each module's imports and forwards list, in order.
    ListedImport[][string] listedImports;
    /// For each `conform`, a function that isn't declared anywhere and holds the type parameters
    /// it introduces, with the bounds its `when` gives them, so they supply functions as a generic
    /// function's bounds do.
    SideTable!(Id!ConformDecl, Id!FunctionDecl) conformances;
    /// For each `if type`, by the `if`: the type parameter it asks about and the functions its
    /// bounds supply in its true branch, which a caller doesn't give witnesses for.
    SideTable!(Id!Expr, Test) tests;

    /// The type parameters of `func`: those it declares, then its hidden ones.
    const(TypeParam)[] typeParamsOf(Id!FunctionDecl func) const
    {
        return declarations.functions[func].typeParams ~ hiddenParams.get(func, null);
    }

    /// The module-level functions a plain `name` finds from the module `from`, grouped as for a
    /// plain name. Something else of that module's named `name` hides them all.
    Candidates functionsFrom(string from, string name) const
    {
        auto own = moduleScopes[from];
        if (auto symbol = own.resolveLocal(name))
        {
            if (!isFunction(*symbol)) return Candidates.init;
        }
        auto forwarded = forwardedGroup(forwardsOf(from, name), own, name, m => publicFunctions(m, name));
        return grouped(from, own.functionsNamed(name), forwarded, own.modulesProviding(name).array, m => broughtFunctions(m, name));
    }

    /// The functions named `name` that the module `m` declares and lets other modules see.
    Id!FunctionDecl[] publicFunctions(string m, string name) const
    {
        return moduleScopes[m].functionsNamed(name).filter!(f => !declarations.functions[f].isPrivate).array;
    }

    /// The functions named `name` that importing the module `m` brings: its own, then those it forwards.
    Id!FunctionDecl[] broughtFunctions(string m, string name) const
    {
        auto functions = publicFunctions(m, name);
        foreach (forward; forwardsOf(m, name)) functions ~= publicFunctions(forward.origin, name);
        return functions;
    }

    /// Where the module `m` forwards `name` from.
    const(Forward)[] forwardsOf(string m, string name) const
    {
        auto byName = m in forwards;
        if (byName is null) return null;
        auto found = name in *byName;
        return found is null ? null : *found;
    }
}

/// A module that another forwards a name from, with the `forward import` that says so. The module
/// is the one declaring the name, however many forwards it came through.
package struct Forward
{
    string origin;
    Span span;
    /// Whether that `forward import` lists the name, or a sum it carries the name as a member of.
    bool listed;
}

/// A `forward import`: the module, and the names it lists, which are none for a blanket one.
package struct ForwardImport
{
    string target;
    const(string)[] names;
    Span span;
}

/// A name an import or forward lists.
package struct ListedImport
{
    string target;
    string name;
    Span span;
    bool forward;
}

/// Something importing a module brings, and the module declaring it.
private struct Brought(Symbol)
{
    Symbol symbol;
    string owner;
}

/// The functions a module forwards as one name, which it ranks as one group as its importers do,
/// and the forward import that a message names them by.
private struct ForwardedGroup
{
    Id!FunctionDecl[] functions;
    string source;
}

/// What `forwards`, a module's forwards of `name`, bring it as functions, as `publicFunctions` of
/// each declaring module gives them. `moduleScope` is the module's.
private ForwardedGroup forwardedGroup(const(Forward)[] forwards, const Scope moduleScope, string name,
    scope Id!FunctionDecl[] delegate(string) publicFunctions)
{
    ForwardedGroup group;
    foreach (forward; forwards) group.functions ~= publicFunctions(forward.origin);
    auto sources = moduleScope.forwardsProviding(name);
    if (!sources.empty) group.source = sources.front;
    return group;
}

/// `own`, then the functions the module forwards and those each of `imports` brings that aren't
/// among them, a group each. The checker leaves out a group that brings nothing another doesn't, once
/// it knows what each import hides, so imports that lead to the same functions count once.
private Candidates grouped(string current, Id!FunctionDecl[] own, ForwardedGroup forwarded, const(string)[] imports,
    scope Id!FunctionDecl[] delegate(string) brought)
{
    Id!FunctionDecl[][] groups;
    string[] sources, exporters;
    void add(Id!FunctionDecl[] functions, string source, string exporter)
    {
        auto group = functions.filter!(f => !own.canFind(f)).array;
        if (group.length == 0) return;
        groups ~= group;
        sources ~= source;
        exporters ~= exporter;
    }
    add(forwarded.functions, forwarded.source, current);
    foreach (m; imports) add(brought(m), m, m);
    return Candidates(own ~ groups, [string.init] ~ sources, [string.init] ~ exporters, current);
}

/// A function that a bound supplies inside the generic function `owner`: the interface's function
/// `declared`, for the bound at `bound` among those of `param`. `index` is where its witness is
/// among `owner`'s.
package struct Requirement
{
    Id!FunctionDecl owner;
    Id!TypeParam param;
    size_t bound;
    Id!FunctionDecl declared;
    size_t index;
    /// For a function an `if type` supplies, the `if`; `index` is then where it is among the
    /// test's functions.
    Id!Expr test;
}

/// What an `if type` asks: whether `param`, a type parameter of `owner`, satisfies its bounds.
package struct Test
{
    Id!FunctionDecl owner;
    Id!TypeParam param;
    /// The true branch, where they hold.
    Id!Expr branch;
    /// The functions its bounds supply, by bound and then the interface's function.
    Id!FunctionDecl[] functions;
}

/// An interface a type parameter's bounds require without naming it: the `which`th interface that
/// the bound at `from` requires, in the list of bounds that this and the others extend.
package struct Implied
{
    size_t from;
    size_t which;
    Id!InterfaceDecl decl;
}

/// The interfaces the interfaces `written` require, directly or in turn, that aren't among them,
/// depth first from each, and each once. They follow `written` as bounds, so `from` counts them
/// too. `requiresOf` gives what an interface requires as written, invalid where that isn't an
/// interface.
package Implied[] impliedBounds(const(Id!InterfaceDecl)[] written,
    scope const(Id!InterfaceDecl)[] delegate(Id!InterfaceDecl) requiresOf)
{
    Implied[] implied;
    bool[Id!InterfaceDecl] seen;
    foreach (decl; written) if (decl.isValid) seen[decl] = true;
    void visit(size_t from, Id!InterfaceDecl decl)
    {
        foreach (which, required; requiresOf(decl))
        {
            if (!required.isValid || required in seen) continue;
            seen[required] = true;
            implied ~= Implied(from, which, required);
            visit(written.length + implied.length - 1, required);
        }
    }
    foreach (i, decl; written) if (decl.isValid) visit(i, decl);
    return implied;
}

/// The builtin or declared type `symbol` is another name for. It's still an alias if it stands
/// for a type with no name, like `[Int]`, or is recursive.
package TypeSymbol expandAlias(TypeSymbol symbol, const SideTable!(Id!AliasDecl, const(AliasDecl)*) aliases,
    const SideTable!(Id!TypeExpr, TypeSymbol) typeResolutions)
{
    foreach (_; 0 .. aliases.length)
    {
        auto next = symbol.match!(
            (const Id!AliasDecl a) => aliases[a].target.id in typeResolutions,
            _ => cast(const(TypeSymbol)*) null,
        );
        if (next is null) break;
        symbol = *next;
    }
    return symbol;
}

/// The functions a name could be. `groups[0]` is the current module's, which may be empty, and
/// each later group is one imported module's.
package struct Candidates
{
    Id!FunctionDecl[][] groups;
    /// The import that brought each group, where that's known. The first group has none.
    string[] sources;
    /// The module whose exports each group is, so the checker can leave out what a nearer function
    /// there hides: one it imports, or the module itself for what it forwards. Empty for none.
    string[] exporters;
    /// The module whose scope found them, for a plain name, whose imports' levels hide farther
    /// functions the same way.
    string scopeModule;

    /// How many different functions there are, since imports can lead to the same ones.
    size_t count() const
    {
        const(Id!FunctionDecl)[] seen;
        foreach (f; groups.joiner)
        {
            if (!seen.canFind(f)) seen ~= f;
        }
        return seen.length;
    }
}

/// Resolves every name in `program`, reporting problems to `collector`.
/// The nodes resolution makes get their IDs from `ids`.
package Resolution resolveNames(const ref Program program, Collector collector, Target target, NodeIds ids)
{
    return new NameResolver(collector, target, ids).resolveProgram(program);
}

private immutable Scope universal = new Scope(builtinTypes);

/// Which names one module's imports of another give it unqualified: every name, or only those a
/// selective import lists. Imports of one module combine, and any of them gives qualified access.
package struct ModuleAccess
{
    string name;
    bool everyName;
    const(string)[] names;
    /// Whether one of them is a `forward import`.
    bool forwards;

    bool provides(string member) const
    {
        return everyName || names.canFind(member);
    }
}

/// The names declared in one module, function, or block. Lookups fall back to the parent.
package final class Scope
{
    private SymbolId[string] _scopeTable;
    private const Scope _parent;
    /// The enclosing module's imports, plus the prelude.
    private const(ModuleAccess)[] _imports;
    private const(string)[] _importedModules;
    private TypeSymbol[string] _typeTable;
    /// Every function of each name, in declaration order, for a module's scope.
    private Id!FunctionDecl[][string] _functions;
    /// For a generic function's scope, the functions its bounds supply, by name.
    private Id!FunctionDecl[][string] _boundFunctions;
    /// The lambda this is the outermost scope of, if any, and the local that lambda is bound to
    /// when it's a nested `def`.
    Id!Expr lambda;
    Id!VarDecl selfBinding;

    this(TypeSymbol[string] builtInTypes) pure
    {
        _parent = null;
        _typeTable = builtInTypes.dup;
    }

    /// A module's top-level scope.
    this(const(ModuleAccess)[] imports)
    {
        _parent = universal;
        _imports = imports;
        _importedModules = imports.map!(i => i.name).array;
    }

    /// A function, lambda, or block scope inside `parent`, seeing the same modules.
    this(const Scope parent)
    {
        _parent = parent;
        _imports = parent._imports;
        _importedModules = parent._importedModules;
    }

    const(Scope) parent() const
    {
        return _parent;
    }

    /// The imported modules, whose members can be named as `a.b.name`.
    const(string)[] importedModules() const
    {
        return _importedModules;
    }

    /// Each imported module, with which of its names are given unqualified.
    const(ModuleAccess)[] imports() const
    {
        return _imports;
    }

    /// The imported modules a bare `name` can come from.
    auto modulesProviding(string name) const
    {
        return _imports.filter!(i => i.provides(name)).map!(i => i.name);
    }

    /// The imported modules a bare `name` can come from, nearest first: those whose imports list
    /// it, then those whose imports bring every name.
    const(string)[][] modulesProvidingByLevel(string name) const
    {
        auto listing = _imports.filter!(i => i.names.canFind(name)).map!(i => i.name).array;
        auto blanket = _imports.filter!(i => i.everyName && !i.names.canFind(name)).map!(i => i.name).array;
        return [listing, blanket];
    }

    /// The modules this one forward imports that a bare `name` can come from.
    auto forwardsProviding(string name) const
    {
        return _imports.filter!(i => i.forwards && i.provides(name)).map!(i => i.name);
    }

    /// Has the imports of `m` give `names` unqualified too.
    void provide(string m, const(string)[] names)
    {
        if (names.length == 0) return;
        auto imports = _imports.dup;
        foreach (ref access; imports)
        {
            if (access.name == m) access.names ~= names;
        }
        _imports = imports;
    }

    /// Every name declared here, as a value or as a type. One that's both is there twice.
    auto names() const
    {
        return chain(_scopeTable.byKey, _typeTable.byKey);
    }

    const(SymbolId)* resolveLocal(string name) const
    {
        return name in _scopeTable;
    }

    /// `name` among the declarations of the module this scope is in, skipping any locals.
    const(SymbolId)* resolveInModule(string name) const
    {
        if (_parent is null) return null;
        return _parent._parent is null ? name in _scopeTable : _parent.resolveInModule(name);
    }

    const(SymbolId)* resolve(string name) const
    {
        if (auto found = name in _scopeTable)
        {
            return found;
        }
        return _parent is null ? null : _parent.resolve(name);
    }

    const(TypeSymbol)* resolveLocalType(string name) const
    {
        return name in _typeTable;
    }

    const(TypeSymbol)* resolveType(string name) const
    {
        if (auto found = name in _typeTable)
        {
            return found;
        }
        return _parent is null ? null : _parent.resolveType(name);
    }

    void declare(string name, SymbolId id)
    {
        _scopeTable[name] = id;
    }

    void declare(string name, TypeSymbol type)
    {
        _typeTable[name] = type;
    }

    void declareFunction(string name, Id!FunctionDecl func)
    {
        if (name !in _scopeTable) _scopeTable[name] = SymbolId(func);
        _functions[name] ~= func;
    }

    Id!FunctionDecl[] functionsNamed(string name) const
    {
        return _functions.get(name, null).dup;
    }

    void declareBoundFunction(string name, Id!FunctionDecl func)
    {
        _boundFunctions[name] ~= func;
    }

    /// The functions named `name` that the bounds of the function this is inside supply.
    Id!FunctionDecl[] boundFunctionsNamed(string name) const
    {
        if (auto found = name in _boundFunctions) return (*found).dup;
        return _parent is null ? null : _parent.boundFunctionsNamed(name);
    }

    override string toString() const
    {
        import std.algorithm : map;
        import std.array : array;

        auto entries = _scopeTable.byKeyValue.map!(kv => format("%s: %s", kv.key, kv.value)).array;
        entries ~= _typeTable.byKeyValue.map!(kv => format("type %s: %s", kv.key, kv.value)).array;
        if (_parent !is null)
        {
            entries ~= "Parent: " ~ _parent.toString();
        }
        return "[" ~ entries.join(", ") ~ "]";
    }
}

/// What a name or dotted chain turned out to be. A module or package path is only valid
/// as the object of a member access; anything else is a value.
private struct Path
{
    enum Kind
    {
        Value,
        Module,
        /// A prefix of an imported module's name that isn't a module itself, like `std`.
        Package,
        /// Already reported, so callers shouldn't report it again.
        Error,
    }

    Kind kind;
    /// The dotted name, for a module or package.
    string name;
}

private final class NameResolver
{
    private enum preludeName = "prelude";

    private SideTable!(Id!Expr, SymbolId) _resolutions;
    private SideTable!(Id!TypeExpr, TypeSymbol) _typeResolutions;
    private SideTable!(Id!Expr, Id!FunctionDecl) _callees;
    private SideTable!(Id!Expr, Id!TypeDecl) _constructions;
    private SideTable!(Id!Expr, const(SymbolId)[]) _captures;
    private SideTable!(Id!Expr, Builtin) _conversions;
    private SideTable!(Id!Expr, Candidates) _methodLookups;
    private SideTable!(Id!Expr, Candidates) _overloads;
    private SideTable!(Id!Expr, Candidates[string]) _operatorLookups;
    private Declarations _declarations;
    private Collector _collector;
    /// Each module's own top-level declarations, by module name.
    private Scope[string] _moduleScopes;
    private Id!Module[string] _moduleIds;
    /// The call whose callee is being resolved, since only there can an alias of a builtin be a value.
    private Id!Expr _call;
    private Id!Expr _callee;
    private SideTable!(Id!AliasDecl, bool) _recursiveAliases;
    /// The module being resolved, which is the one that sees its own private declarations.
    private string _currentModule;

    private Target _target;
    private string[string] _nativeLibraries;
    private SideTable!(Id!FunctionDecl, const(TypeParam)[]) _hiddenParams;
    private SideTable!(Id!TypeExpr, Id!TypeParam) _sugarParams;
    private SideTable!(Id!FunctionDecl, const(TypeParam)[]) _resultFloors;
    private SideTable!(Id!Expr, const(TypeParam)[]) _lambdaFloors;
    private SideTable!(Id!VarDecl, const(TypeParam)[]) _bindingFloors;
    private SideTable!(Id!FunctionDecl, Id!FunctionDecl[]) _boundFunctions;
    private SideTable!(Id!FunctionDecl, Requirement) _requirements;
    private Forward[][string][string] _forwards;
    private SideTable!(Id!Expr, Id!AliasDecl) _aliasedInstances;
    private ForwardImport[][string] _forwardImports;
    /// The `forward import`s that close a cycle of forwards, by where they're written. Each is
    /// reported, and forwards nothing.
    private bool[Span] _cyclicForwards;
    private ListedImport[][string] _listedImports;
    private SideTable!(Id!ConformDecl, Id!FunctionDecl) _conformances;
    private SideTable!(Id!Expr, Test) _tests;
    /// The module-level function whose body is being resolved.
    private Id!FunctionDecl _bodyOf;
    /// Where the nodes resolution makes up get their IDs.
    private NodeIds _ids;

    this(Collector collector, Target target, NodeIds ids)
    {
        _collector = collector;
        _target = target;
        _ids = ids;
    }

    Resolution resolveProgram(const Program program)
    {
        // Sorted so diagnostics come out in the same order every run.
        auto modules = program.sortedModules;
        foreach (mod; modules)
        {
            declareModule(mod.name, mod, (preludeName in program.modules) !is null);
        }
        reportForwardCycles(modules);
        forwardNames(modules);
        foreach (mod; modules)
        {
            provideCarriedMembers(mod);
            reportForwardClashes(mod.name);
        }
        keepExported();
        foreach (mod; modules)
        {
            reportListedClashes(mod);
        }
        // First, so that what uses an alias can see what it stands for.
        foreach (mod; modules)
        {
            resolveAliases(mod.name, mod);
        }
        foreach (mod; modules)
        {
            reportRecursiveAliases(mod);
        }
        // Before any bound, since a bound supplies what its interface requires too.
        foreach (mod; modules)
        {
            resolveRequires(mod.name, mod);
        }
        foreach (mod; modules)
        {
            reportRequiringItself(mod);
        }
        foreach (mod; modules)
        {
            resolveModule(mod.name, mod);
        }
        return Resolution(_resolutions, _typeResolutions, _callees, _constructions, _captures, _conversions, _methodLookups, _overloads,
            _operatorLookups, _declarations, _nativeLibraries, cast(const(Scope)[string]) _moduleScopes, _hiddenParams, _sugarParams,
            _resultFloors, _lambdaFloors, _bindingFloors, _boundFunctions, _requirements, _forwards, _aliasedInstances, _forwardImports, _listedImports, _conformances, _tests);
    }

    /// Works out what every module forwards. A blanket forward passes on what its module forwards
    /// too, so this works it out again from the last result until that's what it gives, which is
    /// also what ends a cycle of them. Each pass reads what a target gives by `exportOrigins`, so
    /// a target's own nearer declarations hide what it forwards from farther away.
    private void forwardNames(R)(R modules)
    {
        foreach (pass; 0 .. 2 * modules.length + 2)
        {
            auto first = pass == 0;
            Forward[][string][string] next;
            foreach (mod; modules)
            {
                foreach (decl; mod.declarations)
                {
                    decl.kind.match!(
                        (const ImportStmt forward) {
                            auto target = forward.path.join(".");
                            if (!forward.forward || target !in _moduleScopes || decl.span in _cyclicForwards) return;
                            if (first) _forwardImports[mod.name] ~= ForwardImport(target, forward.names.map!(n => n.name).array, decl.span);
                            foreach (selected; forward.names)
                            {
                                forwardName(next, mod.name, target, selected.name, selected.span, true);
                                foreach (member; carriedMembers(target, selected.name))
                                {
                                    forwardName(next, mod.name, member.origin, member.name, selected.span, true);
                                }
                            }
                            if (forward.names.length > 0) return;
                            foreach (name; publicNames(target))
                            {
                                forwardName(next, mod.name, target, name, decl.span, false);
                            }
                        },
                        (_) {},
                    );
                }
            }
            auto settled = sameForwards(next, _forwards);
            _forwards = next;
            if (settled) return;
        }
        assert(false, "forwards with no cycle settle");
    }

    /// Reports each `forward import` that leads back to its own module through the forwards of
    /// the modules it forwards, and records it so it forwards nothing.
    private void reportForwardCycles(R)(R modules)
    {
        ForwardImport[][string] edges;
        foreach (mod; modules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const ImportStmt i) {
                        auto target = i.path.join(".");
                        if (i.forward && target in _moduleScopes) edges[mod.name] ~= ForwardImport(target, null, decl.span);
                    },
                    (_) {},
                );
            }
        }
        enum Visit { unseen, open, done }
        Visit[string] state;
        string[] path;
        void visit(string m)
        {
            state[m] = Visit.open;
            path ~= m;
            foreach (forward; edges.get(m, null))
            {
                auto seen = state.get(forward.target, Visit.unseen);
                if (seen == Visit.unseen) visit(forward.target);
                else if (seen == Visit.open)
                {
                    auto cycle = path[path.countUntil(forward.target) .. $] ~ forward.target;
                    _cyclicForwards[forward.span] = true;
                    _collector.reportError(DiagnosticCode.ForwardCycle, forward.span,
                        ("A forward can't lead back to the module that forwards it, and this one does: %-(%s forwards %); "
                            ~ "make one of them a plain `import`").format(cycle));
                }
            }
            path = path[0 .. $ - 1];
            state[m] = Visit.done;
        }
        foreach (mod; modules)
        {
            if (state.get(mod.name, Visit.unseen) == Visit.unseen) visit(mod.name);
        }
    }

    private static bool sameForwards(const Forward[][string][string] a, const Forward[][string][string] b)
    {
        if (a.length != b.length) return false;
        foreach (m, names; a)
        {
            auto other = m in b;
            if (other is null || names.length != other.length) return false;
            foreach (name, forwards; names)
            {
                auto those = name in *other;
                if (those is null || forwards.length != those.length) return false;
                if (!forwards.all!(f => (*those).canFind!(g => g.origin == f.origin && g.listed == f.listed))) return false;
            }
        }
        return true;
    }

    /// Has `from` forward, in `into`, what `target` gives its importers as `name`.
    private void forwardName(ref Forward[][string][string] into, string from, string target, string name, Span span, bool listed)
    {
        foreach (origin; exportOrigins(target, name))
        {
            if (origin == from) continue;
            auto forwards = &into.require(from).require(name);
            auto existing = (*forwards).countUntil!(f => f.origin == origin);
            if (existing < 0)
            {
                *forwards ~= Forward(origin, span, listed);
            }
            else if (listed && !(*forwards)[existing].listed)
            {
                (*forwards)[existing] = Forward(origin, span, true);
            }
        }
    }

    /// The modules declaring what importing `m` brings as `name`, by what the name means in `m`:
    /// its own public declarations, then what it forwards by listing the name, then what its
    /// blanket forwards bring. The nearest of those that has the name decides; a constant or type
    /// there hides everything farther, and functions there merge with functions from every level.
    private string[] exportOrigins(string m, string name)
    {
        auto ownFunctions = _moduleScopes[m].functionsNamed(name).any!(f => isPublic(SymbolId(f)));
        auto ownOther = declaresPublic(m, name) && !ownFunctions;
        if (ownOther) return [m];
        auto forwards = forwardsOf(m, name);
        string[] functionOrigins = forwards.filter!(f => hasPublicFunctions(f.origin, name)).map!(f => f.origin.idup).array;
        if (ownFunctions) return [m] ~ functionOrigins;
        if (forwards.length == 0) return null;
        auto nearest = forwards.any!(f => f.listed);
        auto atNearest = forwards.filter!(f => f.listed == nearest).array;
        if (atNearest.any!(f => !hasPublicFunctions(f.origin, name))) return atNearest.map!(f => f.origin.idup).array;
        return functionOrigins;
    }

    private bool hasPublicFunctions(string m, string name)
    {
        return _moduleScopes[m].functionsNamed(name).any!(f => isPublic(SymbolId(f)));
    }

    /// Keeps of what each module forwards only what it gives its importers, once what it gives
    /// that's an error has been reported.
    private void keepExported()
    {
        Forward[][string][string] kept;
        foreach (m, names; _forwards)
        {
            foreach (name, forwards; names)
            {
                auto origins = exportOrigins(m, name);
                auto exported = forwards.filter!(f => origins.canFind(f.origin)).array;
                if (exported.length > 0) kept.require(m)[name] = exported;
            }
        }
        _forwards = kept;
    }

    /// A member of a sum that a forward carries with it, and the module that gives it.
    private static struct Carried
    {
        string origin;
        string name;
    }

    /// The members that forwarding `name` from `target` carries, when it's a sum: those written
    /// as a plain name that the sum's module gives its importers.
    private Carried[] carriedMembers(string target, string name)
    {
        auto type = publicType(target, name);
        if (type is null) return null;
        auto sum = (*type).match!((const Id!TypeDecl t) => t, _ => Id!TypeDecl.init);
        if (!sum.isValid) return null;
        auto origin = _declarations.typeModules[sum];
        Carried[] carried;
        foreach (member; _declarations.types[sum].members)
        {
            auto named = member.type.kind.match!((const NamedType n) => n.path.length == 1 ? n.path[0] : null, _ => null);
            if (named is null) continue;
            if (declaresPublic(origin, named) || forwardsOf(origin, named).length > 0) carried ~= Carried(origin, named);
        }
        return carried;
    }

    /// The type importing `m` brings as `name`, whichever module is being resolved.
    private const(TypeSymbol)* publicType(string m, string name)
    {
        auto symbol = _moduleScopes[m].resolveLocalType(name);
        if (symbol !is null && isPublic(*symbol)) return symbol;
        foreach (forward; forwardsOf(m, name))
        {
            auto forwarded = _moduleScopes[forward.origin].resolveLocalType(name);
            if (forwarded !is null && isPublic(*forwarded)) return forwarded;
        }
        return null;
    }

    /// Lets `mod` see unqualified the members its selective forwards carry, as its importers do.
    private void provideCarriedMembers(const Module mod)
    {
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const ImportStmt forward) {
                    auto target = forward.path.join(".");
                    if (!forward.forward || target !in _moduleScopes) return;
                    foreach (selected; forward.names)
                    {
                        _moduleScopes[mod.name].provide(target, carriedMembers(target, selected.name).map!(c => c.name).array);
                    }
                },
                (_) {},
            );
        }
    }

    private const(Forward)[] forwardsOf(string m, string name)
    {
        auto byName = m in _forwards;
        if (byName is null) return null;
        auto found = name in *byName;
        return found is null ? null : *found;
    }

    /// Every name importing `m` brings, sorted.
    private string[] publicNames(string m)
    {
        auto own = _moduleScopes[m].names.filter!(n => declaresPublic(m, n)).array;
        return (own ~ _forwards.get(m, null).keys).sort.uniq.array;
    }

    /// Whether `m` itself declares something public named `name`.
    private bool declaresPublic(string m, string name)
    {
        auto moduleScope = _moduleScopes[m];
        if (moduleScope.functionsNamed(name).any!(f => isPublic(SymbolId(f)))) return true;
        auto symbol = moduleScope.resolveLocal(name);
        if (symbol !is null && !isFunction(*symbol) && isPublic(*symbol)) return true;
        auto type = moduleScope.resolveLocalType(name);
        return type !is null && isPublic(*type);
    }

    /// Reports each name `m` forwards that its importers couldn't use: one that's also a different
    /// declaration of `m`'s own, or that two of its forwards listing it bring as different declarations.
    /// Functions of one name are overloads wherever they're from, so those are left to the checker.
    private void reportForwardClashes(string m)
    {
        static struct Brought
        {
            string origin;
            Span span;
            bool listed = true;
        }

        foreach (name; _forwards.get(m, null).keys.sort)
        {
            auto brought = (declaresPublic(m, name) ? [Brought(m)] : [])
                ~ _forwards[m][name].map!(f => Brought(f.origin, f.span, f.listed)).array;
            foreach (i, later; brought)
            {
                // What a blanket forward brings is hidden by the module's own declaration and by what
                // a forward lists, and clashes with another blanket forward's only where it's used.
                auto clash = brought[0 .. i].find!(earlier => earlier.listed && later.listed
                    && differ(earlier.origin, later.origin, name));
                if (clash.empty) continue;
                auto earlier = clash.front.origin;
                if (earlier == m)
                {
                    _collector.reportError(DiagnosticCode.DuplicateDeclaration, later.span,
                        "'%s' from '%s' can't be forwarded, since this module declares a '%s' of its own"
                            .format(name, later.origin, name));
                }
                else
                {
                    _collector.reportError(DiagnosticCode.AmbiguousName, later.span,
                        ("'%s' would be forwarded from both '%s' and '%s', which declare different things by that name; "
                            ~ "forward it from only one of them").format(name, earlier, later.origin));
                }
                break;
            }
        }
    }

    /// Reports each name that two of `mod`'s imports list for different declarations, which the
    /// module asked for both of. Two forwards that do are reported with what it forwards.
    private void reportListedClashes(const Module mod)
    {
        static struct Listing
        {
            string target;
            Span span;
            bool forward;
        }

        _currentModule = mod.name;
        Listing[][string] listings;
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const ImportStmt importStmt) {
                    auto target = importStmt.path.join(".");
                    if (target !in _moduleScopes) return;
                    foreach (selected; importStmt.names)
                    {
                        listings[selected.name] ~= Listing(target, selected.span, importStmt.forward);
                        _listedImports[mod.name] ~= ListedImport(target, selected.name, selected.span, importStmt.forward);
                    }
                },
                (_) {},
            );
        }
        foreach (name; listings.keys.sort)
        {
            auto listed = listings[name];
            // An import or forward listing a name the module declares, of any visibility, asks for both.
            // A forward's against a public declaration was reported with what it forwards.
            foreach (listing; listed.filter!(l => !l.forward || !declaresPublic(mod.name, name)))
            {
                if (!ownDiffers(mod.name, listing.target, name)) continue;
                _collector.reportError(DiagnosticCode.DuplicateDeclaration, listing.span,
                    "'%s' from '%s' can't be %s, since this module declares a '%s' of its own"
                        .format(name, listing.target, listing.forward ? "forwarded" : "imported by name", name));
            }
            foreach (i, later; listed)
            {
                auto clash = listed[0 .. i].find!(earlier => earlier.target != later.target
                    && !(earlier.forward && later.forward) && exportsDiffer(earlier.target, later.target, name));
                if (clash.empty) continue;
                _collector.reportError(DiagnosticCode.AmbiguousName, later.span,
                    ("'%s' is listed in imports of both '%s' and '%s', which give different things by that name; "
                        ~ "list it in only one of them").format(name, clash.front.target, later.target));
                break;
            }
        }
    }

    /// Whether `m`'s own declaration of `name`, of any visibility, and what importing `target`
    /// gives by it can't both be what the name means: they're not all functions.
    private bool ownDiffers(string m, string target, string name)
    {
        auto moduleScope = _moduleScopes[m];
        auto ownFunctions = moduleScope.functionsNamed(name).length > 0;
        auto ownValue = moduleScope.resolveLocal(name);
        auto ownOther = (ownValue !is null && !isFunction(*ownValue)) || moduleScope.resolveLocalType(name) !is null;
        if (!ownFunctions && !ownOther) return false;
        auto brought = visibleSymbols(target, name);
        auto bringsOther = brought.any!(b => !isFunction(b.symbol)) || visibleTypes(target, name).length > 0;
        // What a cycle of forwards brings back is the same declaration.
        if (brought.all!(b => b.owner == m) && visibleTypes(target, name).all!(t => t.owner == m)) return false;
        return ownOther ? brought.length > 0 || bringsOther : bringsOther;
    }

    /// Whether what importing `a` gives as `name` and what importing `b` does can't both be what
    /// the name means: they're not all functions, and not the same declarations.
    private bool exportsDiffer(string a, string b, string name)
    {
        auto symbolsA = visibleSymbols(a, name), symbolsB = visibleSymbols(b, name);
        auto valuesA = symbolsA.filter!(s => !isFunction(s.symbol)).map!(s => s.symbol).array;
        auto valuesB = symbolsB.filter!(s => !isFunction(s.symbol)).map!(s => s.symbol).array;
        auto functionsA = symbolsA.any!(s => isFunction(s.symbol)), functionsB = symbolsB.any!(s => isFunction(s.symbol));
        if (valuesA.length > 0 && valuesB.length > 0 && !valuesA.all!(v => valuesB.canFind(v))) return true;
        if ((valuesA.length > 0 && functionsB) || (valuesB.length > 0 && functionsA)) return true;
        auto typesA = visibleTypes(a, name).map!(t => t.symbol).array, typesB = visibleTypes(b, name).map!(t => t.symbol).array;
        return typesA.length > 0 && typesB.length > 0 && !typesA.all!(t => typesB.canFind(t));
    }

    /// Whether the public `name` of module `a` and that of module `b` can't both be what one module
    /// gives its importers: they're not all functions, and not one declaration.
    private bool differ(string a, string b, string name)
    {
        const(SymbolId)* value(string m)
        {
            auto symbol = _moduleScopes[m].resolveLocal(name);
            return symbol !is null && !isFunction(*symbol) && isPublic(*symbol) ? symbol : null;
        }
        const(TypeSymbol)* type(string m)
        {
            auto symbol = _moduleScopes[m].resolveLocalType(name);
            return symbol !is null && isPublic(*symbol) ? symbol : null;
        }
        bool functions(string m) => _moduleScopes[m].functionsNamed(name).any!(f => isPublic(SymbolId(f)));

        auto valueA = value(a), valueB = value(b);
        if (valueA !is null && valueB !is null && *valueA != *valueB) return true;
        if ((valueA !is null && functions(b)) || (valueB !is null && functions(a))) return true;
        auto typeA = type(a), typeB = type(b);
        return typeA !is null && typeB !is null && *typeA != *typeB;
    }

    private void declareModule(string name, const Module mod, bool hasPrelude)
    {
        ModuleAccess[] imports = hasPrelude && name != preludeName ? [ModuleAccess(preludeName, true)] : [];
        if (mod.library !is null) _nativeLibraries[name] = mod.library.name;
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl _) {},
                (const TypeDecl _) {},
                (const ConstDecl _) {},
                (const AliasDecl _) {},
                (const InterfaceDecl _) {},
                (const ConformDecl _) {},
                (const ImportStmt importStmt) {
                    auto imported = importStmt.path.join(".");
                    auto index = imports.countUntil!(i => i.name == imported);
                    if (index < 0)
                    {
                        imports ~= ModuleAccess(imported);
                        index = imports.length - 1;
                    }
                    auto access = &imports[index];
                    if (importStmt.forward) access.forwards = true;
                    if (importStmt.names.length > 0)
                    {
                        access.names ~= importStmt.names.map!(n => n.name).array;
                        return;
                    }
                    access.everyName = true;
                },
            );
        }

        auto moduleScope = new Scope(imports);
        auto visible = moduleScope.importedModules;
        foreach (ref decl; mod.declarations)
        {
            decl.kind.match!(
                (ref const FunctionDecl func) {
                    _declarations.functions[func.id] = &func;
                    _declarations.functionModules[func.id] = name;
                    if (func.kind == FunctionKind.intrinsic) checkIntrinsic(name, func.nameSpan, "intrinsic def",
                        intrinsicNamed(func.name) !is null);
                    if (func.isPrivate && func.name == "main")
                    {
                        _collector.reportError(DiagnosticCode.MainInvalidDefinition, func.nameSpan,
                            "`main` can't be private");
                    }
                    // Overloads with the same parameter types are reported once types are known.
                    auto existing = moduleScope.resolveLocal(func.name);
                    auto overloads = existing !is null && func.name != "main" && isFunction(*existing);
                    if (existing !is null && !overloads)
                    {
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, func.nameSpan,
                            "'%s' is already declared in this module".format(func.name));
                    }
                    else
                    {
                        moduleScope.declareFunction(func.name, func.id);
                    }
                },
                (ref const InterfaceDecl interface_) {
                    _declarations.interfaces[interface_.id] = &interface_;
                    _declarations.typeParams[interface_.self.id] = &interface_.self;
                    foreach (ref func; interface_.functions)
                    {
                        _declarations.functions[func.id] = &func;
                        _declarations.functionModules[func.id] = name;
                    }
                    if (moduleScope.resolveLocalType(interface_.name) !is null)
                    {
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, interface_.nameSpan,
                            "'%s' is already declared in this module".format(interface_.name));
                    }
                    else if (universal.resolveLocalType(interface_.name) !is null || isReserved(interface_.name)
                        || interface_.name == selfName)
                    {
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, interface_.nameSpan,
                            "'%s' is a built-in name".format(interface_.name));
                    }
                    else
                    {
                        moduleScope.declare(interface_.name, TypeSymbol(interface_.id));
                    }
                },
                (ref const TypeDecl type) {
                    _declarations.types[type.id] = &type;
                    _declarations.typeModules[type.id] = name;
                    if (type.intrinsic) checkIntrinsic(name, type.nameSpan, "intrinsic type", isIntrinsicType(type.name));
                    auto existing = moduleScope.resolveLocalType(type.name);
                    if (existing !is null || moduleScope.resolveLocal(type.name) !is null)
                    {
                        auto existingMarker = existing !is null && (*existing).match!(
                            (const Id!TypeDecl t) => _declarations.types[t].implicitMarker,
                            _ => false,
                        );
                        string message;
                        if (type.implicitMarker && existingMarker)
                        {
                            message = "`%s` is already a member of another sum in this module; declare `type %s` on its own and write `:%s` in each sum"
                                .format(type.name, type.name, type.name);
                        }
                        else if (type.implicitMarker || existingMarker)
                        {
                            message = "'%s' is already declared in this module; a sum refers to it as `:%s`"
                                .format(type.name, type.name);
                        }
                        else
                        {
                            message = "'%s' is already declared in this module".format(type.name);
                        }
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, type.nameSpan, message);
                    }
                    else if (universal.resolveLocalType(type.name) !is null || isReserved(type.name) || type.name == selfName)
                    {
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, type.nameSpan,
                            "'%s' is a built-in name".format(type.name));
                        // `Some` and `None` aren't types, so a sum naming one would also report an unknown type.
                        if (universal.resolveLocalType(type.name) is null) moduleScope.declare(type.name, TypeSymbol(type.id));
                    }
                    else
                    {
                        if (type.emptyParens)
                        {
                            _collector.reportError(DiagnosticCode.TypeEmptyParens, type.nameSpan,
                                "a type with no fields should be `type %s`".format(type.name));
                        }
                        moduleScope.declare(type.name, TypeSymbol(type.id));
                        moduleScope.declare(type.name, SymbolId(type.id));
                    }
                },
                (ref const AliasDecl alias_) {
                    _declarations.aliases[alias_.id] = &alias_;
                    if (alias_.intrinsic) checkIntrinsic(name, alias_.nameSpan, "intrinsic alias",
                        intrinsicAlias(alias_.name, _target) !is null);
                    if (moduleScope.resolveLocalType(alias_.name) !is null)
                    {
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, alias_.nameSpan,
                            "'%s' is already declared in this module".format(alias_.name));
                    }
                    else if (universal.resolveLocalType(alias_.name) !is null || isReserved(alias_.name) || alias_.name == selfName)
                    {
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, alias_.nameSpan,
                            "'%s' is a built-in name".format(alias_.name));
                    }
                    else
                    {
                        moduleScope.declare(alias_.name, TypeSymbol(alias_.id));
                        moduleScope.declare(alias_.name, SymbolId(alias_.id));
                    }
                },
                (ref const ConstDecl constant) {
                    _declarations.constants[constant.id] = &constant;
                    if (moduleScope.resolveLocal(constant.name) !is null)
                    {
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, constant.nameSpan,
                            "'%s' is already declared in this module".format(constant.name));
                    }
                    else
                    {
                        moduleScope.declare(constant.name, SymbolId(constant.id));
                    }
                },
                (const ImportStmt _) {},
                (const ConformDecl _) {},
            );
        }
        _moduleScopes[name] = moduleScope;
        _moduleIds[name] = mod.id;

        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl func) => reportModuleRootClash(func.name, func.nameSpan, visible),
                (const ConstDecl constant) => reportModuleRootClash(constant.name, constant.nameSpan, visible),
                (const TypeDecl _) {},
                (const AliasDecl _) {},
                (const InterfaceDecl _) {},
                (const ImportStmt _) {},
                (const ConformDecl _) {},
            );
        }
    }

    /// Reports an intrinsic declared outside the standard library, or one the compiler doesn't implement.
    private void checkIntrinsic(string moduleName, Span nameSpan, string form, bool known)
    {
        if (!isStandardLibrary(moduleName))
        {
            _collector.reportError(DiagnosticCode.IntrinsicOutsideStandardLibrary, nameSpan,
                "`%s` is only available in the standard library".format(form));
        }
        else if (!known)
        {
            _collector.reportError(DiagnosticCode.UnknownIntrinsic, nameSpan,
                "The compiler has no `%s` with this name".format(form));
        }
    }

    private static bool isStandardLibrary(string moduleName)
    {
        return moduleName == preludeName
        || moduleName == "std"
        || moduleName.startsWith("std.")
        || moduleName == "intrinsics"
        || moduleName.startsWith("intrinsics.");
    }

    private void resolveAliases(string name, const Module mod)
    {
        _currentModule = name;
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const AliasDecl alias_) {
                    if (alias_.intrinsic)
                    {
                        if (auto builtin = intrinsicAlias(alias_.name, _target)) _typeResolutions[alias_.target.id] = TypeSymbol(*builtin);
                        return;
                    }
                    resolveTypeExpr(alias_.target, _moduleScopes[name]);
                    if (!alias_.isPrivate) reportPrivateType(alias_.target, "a public alias");
                },
                (_) {},
            );
        }
    }

    /// Reports each cycle of aliases once, at its first. One that only names such an alias is left alone.
    private void reportRecursiveAliases(const Module mod)
    {
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const AliasDecl alias_) {
                    bool[Id!AliasDecl] seen;
                    if (!reaches(alias_.target, alias_.id, seen)) return;
                    auto reported = _recursiveAliases.byKey.any!((known) {
                        bool[Id!AliasDecl] visited;
                        return reaches(alias_.target, known, visited);
                    });
                    _recursiveAliases[alias_.id] = true;
                    if (reported) return;
                    _collector.reportError(DiagnosticCode.RecursiveAlias, alias_.nameSpan,
                        "the alias `%s` refers to itself; a `type` can do that, but an alias can't".format(alias_.name));
                },
                (_) {},
            );
        }
    }

    /// Whether `type` mentions `target`, directly or through other aliases.
    private bool reaches(const TypeExpr type, Id!AliasDecl target, ref bool[Id!AliasDecl] seen)
    {
        bool through(const(TypeExpr)[] types)
        {
            foreach (t; types)
            {
                if (reaches(t, target, seen)) return true;
            }
            return false;
        }

        return type.kind.match!(
            (const NamedType named) {
                if (through(named.args)) return true;
                auto symbol = type.id in _typeResolutions;
                if (symbol is null) return false;
                return (*symbol).match!(
                    (const Id!AliasDecl a) {
                        if (a == target) return true;
                        if (a in seen) return false;
                        seen[a] = true;
                        return reaches(_declarations.aliases[a].target, target, seen);
                    },
                    _ => false,
                );
            },
            (const OptionType option) => reaches(*option.inner, target, seen),
            (const ErrorUnionType u) => reaches(*u.success, target, seen) || through(u.errors),
            (const ArrayType array) => reaches(*array.element, target, seen),
            (const FunctionType func) => through(func.params) || reaches(*func.returnType, target, seen),
            (const UnitType _) => false,
            (const TupleType tuple) => through(tuple.elements),
            (const JoinedType joined) => through(joined.parts),
        );
    }

    /// Resolves the interfaces each interface of `mod` requires, in its own scope.
    private void resolveRequires(string name, const Module mod)
    {
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (ref const InterfaceDecl interface_) {
                    if (interface_.requires.length == 0) return;
                    auto declScope = new Scope(_moduleScopes[name]);
                    foreach (ref param; interface_.typeParams) declScope.declare(param.name, TypeSymbol(param.id));
                    foreach (required; interface_.requires)
                    {
                        resolveTypeExpr(required, declScope, InterfaceUse.bound);
                        if (!interface_.isPrivate) reportPrivateType(required, "a public interface");
                    }
                },
                (_) {},
            );
        }
    }

    /// What `decl` requires as written, invalid where that isn't an interface.
    private const(Id!InterfaceDecl)[] requiresOf(Id!InterfaceDecl decl)
    {
        return _declarations.interfaces[decl].requires.map!((r) {
            auto interface_ = interfaceNamed(r);
            return interface_ is null ? Id!InterfaceDecl.init : interface_.id;
        }).array;
    }

    /// Reports each interface of `mod` that requires itself, directly or through others.
    private void reportRequiringItself(const Module mod)
    {
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (ref const InterfaceDecl interface_) {
                    bool[Id!InterfaceDecl] seen;
                    string[] path;
                    bool reaches(Id!InterfaceDecl from)
                    {
                        foreach (required; requiresOf(from))
                        {
                            if (!required.isValid) continue;
                            if (required == interface_.id) return true;
                            if (required in seen) continue;
                            seen[required] = true;
                            path ~= _declarations.interfaces[required].name;
                            if (reaches(required)) return true;
                            path = path[0 .. $ - 1];
                        }
                        return false;
                    }
                    if (!reaches(interface_.id)) return;
                    _collector.reportError(DiagnosticCode.RequiresItself, interface_.requires[0].span, path.length == 0
                        ? "`%s` requires itself".format(interface_.name)
                        : "`%s` requires itself, through %-(`%s`%|, %)".format(interface_.name, path));
                },
                (_) {},
            );
        }
    }

    private void resolveModule(string name, const Module mod)
    {
        _currentModule = name;
        foreach (decl; mod.declarations)
        {
            decl.kind.match!((const ImportStmt importStmt) => checkSelectedNames(importStmt), (_) {});
        }
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (ref const FunctionDecl func) {
                    auto declScope = genericScope(func.typeParams, _moduleScopes[name], false);
                    foreach (ref typeParam; func.typeParams)
                    {
                        foreach (bound; typeParam.bounds) resolveTypeExpr(bound, declScope, InterfaceUse.bound);
                    }
                    // Only a module-level `def` can stand in a type parameter for an interface name.
                    auto sugared = func.kind == FunctionKind.ordinary && func.testName is null && !func.invariantOf.isValid;
                    foreach (ref param; func.params)
                    {
                        _declarations.params[param.id] = &param;
                        resolveTypeExpr(param.type, declScope, sugared ? InterfaceUse.parameter
                            : func.body is null ? InterfaceUse.bodilessParameter : InterfaceUse.none);
                    }
                    auto floored = sugared && func.body !is null;
                    resolveTypeExpr(func.returnType, declScope, floored ? InterfaceUse.floor
                        : func.body is null ? InterfaceUse.bodilessResult : InterfaceUse.none);
                    if (floored)
                    {
                        if (auto floors = floorsIn(func.returnType)) _resultFloors[func.id] = floors;
                    }
                    if (!func.isPrivate)
                    {
                        foreach (ref typeParam; func.typeParams)
                        {
                            foreach (bound; typeParam.bounds) reportPrivateType(bound, "a public function's signature");
                        }
                        foreach (ref param; func.params)
                        {
                            reportPrivateType(param.type, "a public function's signature");
                        }
                        reportPrivateType(func.returnType, "a public function's signature");
                    }
                    declScope = declareBounds(func, declScope, name, sugared);

                    if (func.body !is null)
                    {
                        auto outer = _bodyOf;
                        _bodyOf = func.id;
                        resolveBody(func.params, *func.body, declScope, Id!Expr.init, Id!VarDecl.init,
                            func.invariantOf.isValid);
                        _bodyOf = outer;
                    }
                },
                (ref const TypeDecl type) {
                    auto declScope = genericScope(type.typeParams, _moduleScopes[name], type.inheritsParams);
                    foreach (member; type.members)
                    {
                        resolveTypeExpr(member.type, declScope);
                        if (!type.isPrivate) reportPrivateType(member.type, "a public sum's members");
                    }
                    bool[string] seen;
                    foreach (field; type.fields)
                    {
                        if (field.name in seen)
                        {
                            _collector.reportError(DiagnosticCode.DuplicateField, field.nameSpan,
                                "'%s' is already a field of this type".format(field.name));
                        }
                        seen[field.name] = true;
                        resolveTypeExpr(field.type, declScope);
                        if (!type.isPrivate) reportPrivateType(field.type, "a public field");
                    }
                },
                (const ConstDecl constant) {
                    resolveConstantType(constant, _moduleScopes[name]);
                    resolveExpr(constant.value, _moduleScopes[name]);
                },
                (const AliasDecl _) {},
                (ref const InterfaceDecl interface_) {
                    auto declScope = genericScope(interface_.typeParams, _moduleScopes[name], false);
                    if (declScope is _moduleScopes[name]) declScope = new Scope(declScope);
                    declScope.declare(selfName, TypeSymbol(interface_.self.id));
                    foreach (ref func; interface_.functions)
                    {
                        foreach (ref param; func.params)
                        {
                            _declarations.params[param.id] = &param;
                            resolveTypeExpr(param.type, declScope, InterfaceUse.interfaceParameter);
                            if (!interface_.isPrivate) reportPrivateType(param.type, "a public interface");
                        }
                        resolveTypeExpr(func.returnType, declScope, InterfaceUse.interfaceResult);
                        if (!interface_.isPrivate) reportPrivateType(func.returnType, "a public interface");
                    }
                },
                (const ImportStmt _) {},
                (ref const ConformDecl conform) => resolveConformance(conform, name),
            );
        }
    }

    /// Resolves a `conform` declared in `moduleName`: the names in its type that aren't types are
    /// the type parameters it introduces, which a function made for it holds with the bounds its
    /// `when` gives them, so they supply functions where the conformance's functions are looked for.
    private void resolveConformance(ref const ConformDecl conform, string moduleName)
    {
        auto moduleScope = _moduleScopes[moduleName];
        TypeParam[] introduced;
        void collect(const TypeExpr type)
        {
            type.kind.match!(
                (const NamedType named) {
                    foreach (arg; named.args) collect(arg);
                    if (named.path.length != 1 || named.args.length > 0 || namesType(named.path[0], moduleScope)) return;
                    if (introduced.canFind!(p => p.name == named.path[0])) return;
                    auto written = conform.when.find!(p => p.name == named.path[0]);
                    introduced ~= written.empty ? TypeParam(_ids.next!TypeParam, named.path[0], type.span) : cast() written.front;
                },
                (const OptionType option) => collect(*option.inner),
                (const ArrayType array) => collect(*array.element),
                (const TupleType tuple) {
                    foreach (element; tuple.elements) collect(element);
                },
                (const FunctionType function_) {
                    foreach (param; function_.params) collect(param);
                    collect(*function_.returnType);
                },
                (_) {},
            );
        }
        collect(conform.type);
        // A `when` bound can decide a type parameter the type doesn't mention, which the checker makes sure of.
        foreach (ref written; conform.when)
        {
            foreach (bound; written.bounds)
            {
                bound.kind.match!((const NamedType n) { foreach (arg; n.args) collect(arg); }, (_) {});
            }
        }
        foreach (ref written; conform.when)
        {
            if (introduced.canFind!(p => p.id == written.id)) continue;
            _collector.reportError(DiagnosticCode.UnknownWhenParameter, written.span, namesType(written.name, moduleScope)
                ? "`%s` is a type, and a `when` bound goes on a type parameter that the conforming type introduces".format(written.name)
                : "`%s` isn't in the conforming type or a `when` bound's arguments, so it isn't a type parameter this conformance introduces".format(written.name));
        }

        auto declScope = genericScope(introduced, moduleScope, false);
        resolveTypeExpr(conform.type, declScope);
        foreach (interface_; conform.interfaces) resolveTypeExpr(interface_, declScope, InterfaceUse.bound);
        foreach (ref param; introduced)
        {
            foreach (bound; param.bounds) resolveTypeExpr(bound, declScope, InterfaceUse.bound);
        }
        auto whole = conform.type.kind.match!((const NamedType n) => n.path.length == 1 && n.args.length == 0 ? n.path[0] : null,
            _ => cast(string) null);
        if (whole !is null && introduced.canFind!(p => p.name == whole))
        {
            _collector.reportError(DiagnosticCode.ConformsTypeParameter, conform.type.span,
                ("`%s` isn't a type, so this would conform every type; conform a named type, a built-in one, "
                    ~ "or one of those with type parameters in its arguments").format(whole));
        }

        auto holder = new FunctionDecl(_ids.next!FunctionDecl, "conform", conform.type.span, null, null, cast() conform.type,
            FunctionKind.required);
        holder.typeParams = introduced;
        _declarations.functions[holder.id] = holder;
        _declarations.functionModules[holder.id] = moduleName;
        _conformances[conform.id] = holder.id;
        declareBounds(*holder, declScope, moduleName, false);
    }

    /// Whether `name` is a type where `current` is, as a type written there would find it.
    private bool namesType(string name, const Scope current)
    {
        if (current.resolveType(name) !is null) return true;
        foreach (level, modules; current.modulesProvidingByLevel(name))
        {
            foreach (m; modules)
            {
                if (visibleTypes(m, name).length > 0) return true;
            }
        }
        return false;
    }

    /// Gives `func` a hidden type parameter for each parameter whose type is an interface name, and
    /// declares the functions its bounds supply in its scope, which is `declScope` or a new one
    /// inside it.
    private Scope declareBounds(ref const FunctionDecl func, Scope declScope, string moduleName, bool sugared)
    {
        TypeParam[] hidden;
        foreach (ref param; sugared ? func.params : null)
        {
            auto bounds = param.type.kind.match!(
                (const JoinedType joined) => cast(TypeExpr[]) joined.parts,
                _ => interfaceNamed(param.type) is null ? null : [cast() param.type],
            );
            if (bounds.length == 0) continue;
            hidden ~= TypeParam(_ids.next!TypeParam, printTypeExpr(param.type), param.type.span, bounds);
            _sugarParams[param.type.id] = hidden[$ - 1].id;
        }
        foreach (ref param; hidden) _declarations.typeParams[param.id] = &param;
        if (hidden.length > 0) _hiddenParams[func.id] = hidden;

        Scope bodyScope;
        size_t index;
        foreach (ref typeParam; func.typeParams ~ hidden)
        {
            auto written = typeParam.bounds.map!((b) {
                auto interface_ = interfaceNamed(b);
                return interface_ is null ? Id!InterfaceDecl.init : interface_.id;
            }).array;
            // What the bounds require comes after them, supplied where the bound that leads to it is written.
            Span[] spans = typeParam.bounds.map!(b => cast() b.span).array;
            auto decls = written.dup;
            foreach (implied; impliedBounds(written, &requiresOf))
            {
                decls ~= implied.decl;
                spans ~= spans[implied.from];
            }
            foreach (b, decl; decls)
            {
                if (!decl.isValid) continue;
                foreach (ref declared; _declarations.interfaces[decl].functions)
                {
                    auto supplied = new FunctionDecl(_ids.next!FunctionDecl, declared.name, spans[b], cast(Param[]) declared.params,
                        null, cast() declared.returnType, FunctionKind.required);
                    _declarations.functions[supplied.id] = supplied;
                    _declarations.functionModules[supplied.id] = moduleName;
                    _requirements[supplied.id] = Requirement(func.id, typeParam.id, b, declared.id, index++);
                    _boundFunctions[func.id] ~= supplied.id;
                    if (bodyScope is null) bodyScope = new Scope(declScope);
                    bodyScope.declareBoundFunction(declared.name, supplied.id);
                }
            }
        }
        return bodyScope is null ? declScope : bodyScope;
    }

    /// Resolves what the `if type` `test` of the `if` `expr` asks, and gives its true branch, `branch`, a scope
    /// inside `current` in which its bounds supply their functions, beside what's supplied already.
    private Scope declareTest(Id!Expr expr, const TypeTest test, Id!Expr branch, Scope current)
    {
        foreach (bound; test.bounds) resolveTypeExpr(bound, current, InterfaceUse.bound);
        auto symbol = current.resolveType(test.name);
        auto param = symbol is null ? Id!TypeParam.init
            : (*symbol).match!((const Id!TypeParam p) => p, _ => Id!TypeParam.init);
        auto owner = _bodyOf;
        if (!param.isValid || !owner.isValid || !_declarations.functions[owner].typeParams.canFind!(p => p.id == param))
        {
            if (symbol is null)
            {
                _collector.reportError(DiagnosticCode.UnknownType, test.span, "Unknown type `%s`".format(test.name));
            }
            else
            {
                _collector.reportError(DiagnosticCode.TestsNonParameter, test.span,
                    "`if type` asks about a type parameter of the function it's in, and `%s` isn't one".format(test.name));
            }
            return current;
        }
        auto written = test.bounds.map!((b) {
            auto interface_ = interfaceNamed(b);
            return interface_ is null ? Id!InterfaceDecl.init : interface_.id;
        }).array;
        Span[] spans = test.bounds.map!(b => cast() b.span).array;
        auto decls = written.dup;
        foreach (implied; impliedBounds(written, &requiresOf))
        {
            decls ~= implied.decl;
            spans ~= spans[implied.from];
        }
        auto branchScope = new Scope(current);
        Test asked = Test(owner, param, branch);
        foreach (b, decl; decls)
        {
            if (!decl.isValid) continue;
            foreach (ref declared; _declarations.interfaces[decl].functions)
            {
                auto supplied = new FunctionDecl(_ids.next!FunctionDecl, declared.name, spans[b], cast(Param[]) declared.params,
                    null, cast() declared.returnType, FunctionKind.required);
                _declarations.functions[supplied.id] = supplied;
                _declarations.functionModules[supplied.id] = _currentModule;
                _requirements[supplied.id] = Requirement(owner, param, b, declared.id, asked.functions.length, expr);
                asked.functions ~= supplied.id;
                // What's supplied outside is still supplied inside.
                if (declared.name !in branchScope._boundFunctions)
                {
                    foreach (outer; current.boundFunctionsNamed(declared.name)) branchScope.declareBoundFunction(declared.name, outer);
                }
                branchScope.declareBoundFunction(declared.name, supplied.id);
            }
        }
        _tests[expr] = asked;
        return branchScope;
    }

    /// The interface `type` names, or null if it doesn't name one.
    private const(InterfaceDecl)* interfaceNamed(const TypeExpr type)
    {
        auto symbol = type.id in _typeResolutions;
        if (symbol is null) return null;
        return (*symbol).match!(
            (const Id!InterfaceDecl i) => _declarations.interfaces[i],
            _ => cast(const(InterfaceDecl)*) null,
        );
    }

    /// Reports each name a selective import lists that its module doesn't have, or keeps private.
    private void checkSelectedNames(const ImportStmt importStmt)
    {
        auto imported = importStmt.path.join(".");
        auto moduleScope = imported in _moduleScopes;
        if (moduleScope is null) return;
        foreach (selected; importStmt.names)
        {
            if (visibleSymbol(imported, selected.name) !is null || visibleType(imported, selected.name) !is null) continue;
            if ((*moduleScope).resolveLocal(selected.name) !is null || (*moduleScope).resolveLocalType(selected.name) !is null)
            {
                _collector.reportError(DiagnosticCode.PrivateMember, selected.span,
                    "'%s' is private to '%s'".format(selected.name, imported));
            }
            else
            {
                _collector.reportError(DiagnosticCode.UnknownModuleMember, selected.span,
                    "Module '%s' has no '%s'".format(imported, selected.name));
            }
        }
    }

    /// The scope of a declaration with `params`, inside `moduleScope`: the module's own, if it has
    /// none. Parameters a member inherits from its sum were reported with the sum's.
    private Scope genericScope(const(TypeParam)[] params, Scope moduleScope, bool inherited)
    {
        if (params.length == 0) return moduleScope;
        auto declScope = new Scope(moduleScope);
        foreach (ref param; params)
        {
            _declarations.typeParams[param.id] = &param;
            if (inherited)
            {
                declScope.declare(param.name, TypeSymbol(param.id));
                continue;
            }
            string problem;
            if (declScope.resolveLocalType(param.name) !is null)
            {
                problem = "`%s` is already a type parameter of this declaration";
            }
            else if (universal.resolveLocalType(param.name) !is null || isReserved(param.name) || param.name == selfName)
            {
                problem = "'%s' is a built-in name";
            }
            else if (moduleScope.resolveLocalType(param.name) !is null)
            {
                problem = "`%s` is already a type in this module, so it can't also name a type parameter";
            }
            if (problem !is null)
            {
                _collector.reportError(DiagnosticCode.DuplicateDeclaration, param.span, problem.format(param.name));
                continue;
            }
            declScope.declare(param.name, TypeSymbol(param.id));
        }
        return declScope;
    }

    /// Whether `m`'s declaration `symbol` can be seen from the module being resolved.
    private bool isVisible(SymbolId symbol, string m)
    {
        return m == _currentModule || isPublic(symbol);
    }

    private bool isVisible(TypeSymbol symbol, string m)
    {
        return m == _currentModule || isPublic(symbol);
    }

    private bool isPublic(SymbolId symbol)
    {
        return !symbol.match!(
            (const Id!FunctionDecl f) => _declarations.functions[f].isPrivate,
            (const Id!TypeDecl t) => _declarations.types[t].isPrivate,
            (const Id!ConstDecl c) => _declarations.constants[c].isPrivate,
            (const Id!AliasDecl a) => _declarations.aliases[a].isPrivate,
            _ => false,
        );
    }

    private bool isPublic(TypeSymbol symbol)
    {
        return !symbol.match!(
            (const Id!TypeDecl t) => _declarations.types[t].isPrivate,
            (const Id!AliasDecl a) => _declarations.aliases[a].isPrivate,
            (const Id!InterfaceDecl i) => _declarations.interfaces[i].isPrivate,
            (const Builtin _) => false,
            (const Id!TypeParam _) => false,
        );
    }

    /// What the name `name` is in module `m` or among what it forwards, if the module being
    /// resolved can see it: the first visible function, for a name of functions.
    private const(SymbolId)* visibleSymbol(string m, string name)
    {
        auto found = visibleSymbols(m, name);
        return found.length == 0 ? null : &[found[0].symbol][0];
    }

    /// The different things importing `m` brings as `name` that the module being resolved can
    /// see, with the module declaring each. Functions are overloads of each other, so they're one.
    /// A declaration of `m`'s own hides what it forwards, which clashes at the `forward import`;
    /// more than one is what `m` forwards clashing, which a use of the name reports.
    private Brought!SymbolId[] visibleSymbols(string m, string name)
    {
        auto symbol = _moduleScopes[m].resolveLocal(name);
        if (symbol !is null && !isFunction(*symbol) && isVisible(*symbol, m)) return [Brought!SymbolId(*symbol, m)];
        Brought!SymbolId[] found;
        auto functions = visibleFunctions(m, name);
        if (functions.length > 0) found ~= Brought!SymbolId(SymbolId(functions[0]), _declarations.functionModules[functions[0]]);
        foreach (forward; forwardsOf(m, name))
        {
            auto forwarded = _moduleScopes[forward.origin].resolveLocal(name);
            if (forwarded is null || isFunction(*forwarded) || !isPublic(*forwarded)) continue;
            if (!found.canFind!(b => b.symbol == *forwarded)) found ~= Brought!SymbolId(*forwarded, forward.origin);
        }
        return found;
    }

    /// The functions named `name` in module `m` that the module being resolved can see, then
    /// those `m` forwards.
    private Id!FunctionDecl[] visibleFunctions(string m, string name)
    {
        auto functions = _moduleScopes[m].functionsNamed(name).filter!(f => isVisible(SymbolId(f), m)).array;
        foreach (forward; forwardsOf(m, name))
        {
            functions ~= _moduleScopes[forward.origin].functionsNamed(name).filter!(f => isPublic(SymbolId(f))).array;
        }
        return functions;
    }

    /// Records `expr` as naming one of `candidates`, or as naming the function when there's one.
    private Path recordFunctions(const Expr expr, string name, Candidates candidates)
    {
        if (candidates.count == 1) return recordValue(expr, name, SymbolId(candidates.groups.joiner.front));
        _overloads[expr.id] = candidates;
        return Path(Path.Kind.Value);
    }

    private const(TypeSymbol)* visibleType(string m, string name)
    {
        auto found = visibleTypes(m, name);
        return found.length == 0 ? null : &[found[0].symbol][0];
    }

    /// The different types importing `m` brings as `name`, as `visibleSymbols` finds values.
    private Brought!TypeSymbol[] visibleTypes(string m, string name)
    {
        auto symbol = _moduleScopes[m].resolveLocalType(name);
        if (symbol !is null && isVisible(*symbol, m)) return [Brought!TypeSymbol(*symbol, m)];
        Brought!TypeSymbol[] found;
        foreach (forward; forwardsOf(m, name))
        {
            auto forwarded = _moduleScopes[forward.origin].resolveLocalType(name);
            if (forwarded is null || !isPublic(*forwarded)) continue;
            if (!found.canFind!(b => b.symbol == *forwarded)) found ~= Brought!TypeSymbol(*forwarded, forward.origin);
        }
        return found;
    }

    /// Reports each private type that the resolved `type` mentions, which `where` would expose.
    private void reportPrivateType(const TypeExpr type, string where)
    {
        type.kind.match!(
            (const NamedType named) {
                foreach (arg; named.args) reportPrivateType(arg, where);
                auto symbol = type.id in _typeResolutions;
                if (symbol is null) return;
                auto isPrivate = (*symbol).match!(
                    (const Id!TypeDecl t) => _declarations.types[t].isPrivate,
                    (const Id!AliasDecl a) => _declarations.aliases[a].isPrivate,
                    (const Id!InterfaceDecl i) => _declarations.interfaces[i].isPrivate,
                    (const Builtin _) => false,
                    (const Id!TypeParam _) => false,
                );
                if (isPrivate)
                {
                    _collector.reportError(DiagnosticCode.PrivateTypeExposed, type.span,
                        "`%s` is private, so it can't appear in %s".format(named.path.join("."), where));
                }
            },
            (const OptionType option) => reportPrivateType(*option.inner, where),
            (const ErrorUnionType u) {
                reportPrivateType(*u.success, where);
                foreach (error; u.errors) reportPrivateType(error, where);
            },
            (const ArrayType array) => reportPrivateType(*array.element, where),
            (const FunctionType func) {
                foreach (param; func.params) reportPrivateType(param, where);
                reportPrivateType(*func.returnType, where);
            },
            (const UnitType _) {},
            (const TupleType tuple) {
                foreach (element; tuple.elements) reportPrivateType(element, where);
            },
            (const JoinedType joined) {
                foreach (part; joined.parts) reportPrivateType(part, where);
            },
        );
    }

    /// Reports a constant with no type or one that sema can't evaluate a value of.
    private void resolveConstantType(const ConstDecl constant, const Scope current)
    {
        if (constant.type is null)
        {
            _collector.reportError(DiagnosticCode.MissingConstantType, constant.nameSpan,
                "a top-level constant needs a type: `val %s: Type = ...`".format(constant.name));
            return;
        }
        resolveTypeExpr(*constant.type, current, InterfaceUse.constant);

        if (!isConstantType(*constant.type))
        {
            _collector.reportError(DiagnosticCode.InvalidConstantType, constant.type.span,
                "a top-level constant must be a Bool, integer, Float, String or Unit, not `%s`"
                    .format(printTypeExpr(*constant.type)));
        }
    }

    private bool isConstantType(const TypeExpr type)
    {
        return type.kind.match!(
            (const UnitType _) => true,
            (const NamedType _) {
                auto symbol = type.id in _typeResolutions;
                // An unknown type has already been reported.
                if (symbol is null) return true;
                return expandAlias(*symbol, _declarations.aliases, _typeResolutions).match!(
                    (const Builtin builtin) => builtin != Builtin.Any && builtin != Builtin.Never,
                    (const Id!TypeDecl _) => false,
                    (const Id!AliasDecl a) => (a in _recursiveAliases) !is null || isConstantType(_declarations.aliases[a].target),
                    (const Id!TypeParam _) => false,
                    (const Id!InterfaceDecl _) => false,
                );
            },
            // Already reported as no type at all.
            (const JoinedType _) => true,
            _ => false,
        );
    }

    /// `use` says what the type as a whole is for. The types inside it are an interface's place
    /// only where the whole is a floor.
    private void resolveTypeExpr(const TypeExpr type, const Scope current, InterfaceUse use = InterfaceUse.none)
    {
        auto inside = within(use);
        type.kind.match!(
            (const NamedType named) {
                foreach (arg; named.args)
                {
                    resolveTypeExpr(arg, current, inside);
                }
                auto name = named.path.back;
                const(TypeSymbol)* resolvedType;
                if (named.path.length == 1)
                {
                    resolvedType = current.resolveType(name);
                    if (resolvedType is null)
                    {
                        Brought!TypeSymbol[] found;
                        string[] vias;
                        bool listed;
                        // An import that lists the name beats one that brings every name.
                        foreach (level, modules; current.modulesProvidingByLevel(name))
                        {
                            foreach (m; modules)
                            {
                                foreach (brought; visibleTypes(m, name))
                                {
                                    // One type reached through two imports is one type.
                                    if (found.canFind!(b => b.symbol == brought.symbol)) continue;
                                    found ~= brought;
                                    vias ~= m;
                                }
                            }
                            listed = level == 0;
                            if (found.length > 0) break;
                        }
                        // Two listed imports of different types were reported at the second.
                        if (found.length > 1 && !(listed && vias.dup.sort.uniq.walkLength == vias.length))
                        {
                            _collector.reportError(DiagnosticCode.AmbiguousName, type.span,
                                ambiguityMessage(name, found.map!(b => b.owner).array, vias));
                            return;
                        }
                        if (found.length > 0)
                        {
                            resolvedType = &[found[0].symbol][0];
                        }
                    }
                }
                else
                {
                    auto moduleName = named.path[0 .. $ - 1].join(".");
                    if (current.importedModules.canFind(moduleName))
                    {
                        auto found = visibleTypes(moduleName, name);
                        if (found.length > 1)
                        {
                            _collector.reportError(DiagnosticCode.AmbiguousName, type.span,
                                ambiguityMessage(name, found.map!(b => b.owner).array, found.map!(b => moduleName).array));
                            return;
                        }
                        resolvedType = visibleType(moduleName, name);
                        if (resolvedType is null && _moduleScopes[moduleName].resolveLocalType(name) !is null)
                        {
                            _collector.reportError(DiagnosticCode.PrivateMember, type.span,
                                "`%s` is private to `%s`".format(name, moduleName));
                            return;
                        }
                    }
                }
                if (resolvedType is null)
                {
                    _collector.reportError(DiagnosticCode.UnknownType, type.span,
                        "Unknown type `%s`".format(named.path.join(".")));
                    return;
                }
                auto isInterface = (*resolvedType).match!((const Id!InterfaceDecl _) => true, _ => false);
                auto part = use == InterfaceUse.joined || use == InterfaceUse.joinedInFloor;
                auto allowed = isInterface
                    ? part || use == InterfaceUse.bound || use == InterfaceUse.parameter || isFloor(use)
                    : !part && use != InterfaceUse.bound;
                if (!allowed)
                {
                    reportInterfaceUse(printTypeExpr(type), type.span, use);
                    return;
                }
                _typeResolutions[type.id] = *resolvedType;
            },
            (const OptionType option) => resolveTypeExpr(*option.inner, current, inside),
            (const ErrorUnionType u) {
                // Only the success side of a whole result type or annotation is a floor's place.
                auto part = isFloor(inside) ? InterfaceUse.floorInErrorUnion : inside;
                resolveTypeExpr(*u.success, current, use == InterfaceUse.floor ? InterfaceUse.floorPart : part);
                foreach (error; u.errors) resolveTypeExpr(error, current, part);
            },
            (const ArrayType array) => resolveTypeExpr(*array.element, current, inside),
            (const FunctionType func) {
                auto part = isFloor(inside) ? InterfaceUse.floorInFunction : inside;
                foreach (param; func.params)
                {
                    resolveTypeExpr(param, current, part);
                }
                resolveTypeExpr(*func.returnType, current, part);
            },
            (const UnitType _) {},
            (const TupleType tuple) {
                foreach (element; tuple.elements)
                {
                    resolveTypeExpr(element, current, inside);
                }
            },
            (const JoinedType joined) {
                auto partUse = isFloor(use) ? InterfaceUse.joinedInFloor : InterfaceUse.joined;
                foreach (i, part; joined.parts)
                {
                    auto named = part.kind.match!((const NamedType _) => true, _ => false);
                    auto optional = i + 1 == joined.parts.length ? part.kind.match!(
                        (const OptionType option) => option.inner,
                        _ => cast(const(TypeExpr)*) null,
                    ) : null;
                    if (named) resolveTypeExpr(part, current, partUse);
                    else if (optional !is null)
                    {
                        _collector.reportError(DiagnosticCode.NotAnInterface, part.span,
                            "`?` here is on `%s` alone, and `&` joins interfaces; for an option of the two together, write `(%s)?`"
                                .format(printTypeExpr(*optional), (joined.parts[0 .. $ - 1].map!(p => printTypeExpr(p)).array
                                    ~ printTypeExpr(*optional)).join(" & ")));
                    }
                    else reportInterfaceUse(printTypeExpr(part), part.span, partUse);
                }
                if (!isFloor(use) && use != InterfaceUse.parameter) reportInterfaceUse(printTypeExpr(type), type.span, use, true);
            },
        );
    }

    /// What `use` makes of the types inside the type it describes.
    private static InterfaceUse within(InterfaceUse use)
    {
        final switch (use)
        {
            case InterfaceUse.floor:
            case InterfaceUse.floorPart:
            case InterfaceUse.joinedInFloor:
                return InterfaceUse.floorPart;
            case InterfaceUse.floorInFunction:
            case InterfaceUse.floorInErrorUnion:
            case InterfaceUse.interfaceResult:
            case InterfaceUse.bodilessResult:
            case InterfaceUse.patternBinding:
                return use;
            case InterfaceUse.none:
            case InterfaceUse.bound:
            case InterfaceUse.joined:
            case InterfaceUse.parameter:
            case InterfaceUse.lambdaParameter:
            case InterfaceUse.bodilessParameter:
            case InterfaceUse.interfaceParameter:
            case InterfaceUse.constant:
                return InterfaceUse.none;
        }
    }

    private static bool isFloor(InterfaceUse use)
    {
        return use == InterfaceUse.floor || use == InterfaceUse.floorPart;
    }

    /// A floor for each interface name or `A & B` that `type`, resolved as one that can have
    /// them, has where one is allowed. Null when it has none.
    private const(TypeParam)[] floorsIn(const TypeExpr type)
    {
        TypeParam[] floors;
        void visit(const TypeExpr t)
        {
            void add(const(TypeExpr)[] bounds)
            {
                floors ~= TypeParam(_ids.next!TypeParam, printTypeExpr(t), t.span, cast(TypeExpr[]) bounds);
                _sugarParams[t.id] = floors[$ - 1].id;
            }
            t.kind.match!(
                (const NamedType named) {
                    if (interfaceNamed(t) !is null) add([cast() t]);
                    foreach (arg; named.args) visit(arg);
                },
                (const JoinedType joined) {
                    add(joined.parts);
                    foreach (part; joined.parts)
                    {
                        part.kind.match!(
                            (const NamedType named) {
                                foreach (arg; named.args) visit(arg);
                            },
                            (_) {},
                        );
                    }
                },
                (const OptionType option) => visit(*option.inner),
                (const ArrayType array) => visit(*array.element),
                (const TupleType tuple) {
                    foreach (element; tuple.elements) visit(element);
                },
                (_) {},
            );
        }
        type.kind.match!((const ErrorUnionType u) => visit(*u.success), (_) => visit(type));
        foreach (ref floor; floors) _declarations.typeParams[floor.id] = &floor;
        return floors;
    }

    /// Reports the interface `name` where a type is wanted, or a type where a bound wants an interface.
    /// `joined` says `name` is several interfaces joined with `&`.
    private void reportInterfaceUse(string name, Span span, InterfaceUse use, bool joined = false)
    {
        auto what = joined ? "joins interfaces" : "is an interface";
        final switch (use)
        {
            case InterfaceUse.bound:
                _collector.reportError(DiagnosticCode.NotAnInterface, span,
                    "`%s` is a type, and a bound names an interface".format(name));
                return;
            case InterfaceUse.joined:
            case InterfaceUse.joinedInFloor:
                _collector.reportError(DiagnosticCode.NotAnInterface, span,
                    "`%s` is a type, and `&` joins interfaces".format(name));
                return;
            case InterfaceUse.lambdaParameter:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span,
                    ("`%s` %s, and only a module-level `def` can take any type that satisfies one; "
                        ~ "name the type this parameter takes").format(name, what));
                return;
            case InterfaceUse.bodilessParameter:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span,
                    ("`%s` %s, and only a module-level `def` with a body can take any type that satisfies %s; "
                        ~ "name the type this parameter takes").format(name, what, joined ? "them" : "one"));
                return;
            case InterfaceUse.interfaceParameter:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span,
                    ("`%s` %s, and a function of an interface can't take any type that satisfies %s, since it has no "
                        ~ "type parameters of its own; make the type a parameter of the interface").format(name, what,
                            joined ? "them" : "one"));
                return;
            case InterfaceUse.floorInFunction:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span,
                    ("`%s` %s, which can't stand for a type inside a function type; name the type with a type "
                        ~ "parameter that has the bound, as in `<T: %s>`").format(name, what, name));
                return;
            case InterfaceUse.floorInErrorUnion:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span,
                    ("`%s` %s, which an error union takes only on its success side, and only where the error union "
                        ~ "is the whole type; write the type out").format(name, what));
                return;
            case InterfaceUse.bodilessResult:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span,
                    ("`%s` %s, which stands for the type a function's body returns, and this function has no body; "
                        ~ "write the type it returns").format(name, what));
                return;
            case InterfaceUse.patternBinding:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span,
                    ("`%s` %s, which a binding in a pattern can't have as its type; write the type out, or bind "
                        ~ "the value with a `val` of its own").format(name, what));
                return;
            case InterfaceUse.constant:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span,
                    "`%s` %s, and a top-level constant is a Bool, integer, Float, String or Unit".format(name, what));
                return;
            case InterfaceUse.interfaceResult:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span,
                    ("`%s` %s, and a function of an interface can't return one, since each function that conforms "
                        ~ "would return a different type; make the type a parameter of the interface").format(name, what));
                return;
            case InterfaceUse.none:
            case InterfaceUse.parameter:
            case InterfaceUse.floor:
            case InterfaceUse.floorPart:
                _collector.reportError(DiagnosticCode.InterfaceIsNotAType, span, joined
                    ? ("`%s` joins interfaces, which only a `def`'s result type, a `val`'s annotation or the whole type "
                        ~ "of a module-level `def`'s parameter can; use a type parameter with the bounds, as in `<T: %s>`")
                        .format(name, name)
                    : ("`%s` is an interface, which stands for a type only as a `def`'s result type, a `val`'s annotation "
                        ~ "or the whole type of a module-level `def`'s parameter; use a type parameter with a bound, as in "
                        ~ "`<T: %s>`, or a sum type of the types it holds").format(name, name));
                return;
        }
    }

    /// Resolves a function or lambda body in a new scope holding its params, inside `enclosing`.
    /// An invariant's params are the type's fields, which hide what they're named like.
    private void resolveBody(const Param[] params, const Expr body, Scope enclosing,
        Id!Expr lambda = Id!Expr.init, Id!VarDecl selfBinding = Id!VarDecl.init, bool isInvariant = false)
    {
        auto functionScope = new Scope(enclosing);
        functionScope.lambda = lambda;
        functionScope.selfBinding = selfBinding;
        foreach (param; params)
        {
            if (param.name == discardName) continue;
            if (isInvariant)
            {
                functionScope.declare(param.name, SymbolId(param.id));
                continue;
            }
            declareLocal(param.name, param.nameSpan, SymbolId(param.id), functionScope,
                DiagnosticCode.DuplicateParameter, "'%s' is already a parameter of this function");
        }
        resolveExpr(body, functionScope);
    }

    /// Declares a param or local, reporting it if it clashes with anything visible from `current`
    /// except imported names, which locals may hide.
    private void declareLocal(string name, Span span, SymbolId symbol, Scope current,
        DiagnosticCode duplicateCode, string duplicateMessage)
    {
        if (current.resolveLocal(name) !is null)
        {
            _collector.reportError(duplicateCode, span, duplicateMessage.format(name));
            return;
        }
        if (auto outer = current.resolve(name))
        {
            // A nested def is a local, so a function found here is a module-level one.
            auto what = (*outer).match!(
                (const Id!FunctionDecl _) => "a function in this module",
                (const Id!ConstDecl _) => "a constant in this module",
                _ => "a declaration in an enclosing scope",
            );
            _collector.reportError(DiagnosticCode.ShadowedDeclaration, span,
                "'%s' has the same name as %s".format(name, what));
        }
        else
        {
            reportModuleRootClash(name, span, current.importedModules);
        }
        // Declared even after a clash, so later uses resolve to what the user meant here.
        current.declare(name, symbol);
    }

    /// Reports `name` if it would hide an imported module path like `std` in `std.math.pow`.
    private void reportModuleRootClash(string name, Span span, const string[] visible)
    {
        if (visible.any!(m => m == name || m.startsWith(name ~ ".")))
        {
            _collector.reportError(DiagnosticCode.ShadowedDeclaration, span,
                "'%s' has the same name as an imported module".format(name));
        }
    }

    void resolveStmt(const ref Stmt stmt, Scope scopeTable)
    {
        stmt.kind.match!(
            (ref const VarDecl varDecl) {
                _declarations.locals[varDecl.id] = &varDecl;
                if (varDecl.type !is null)
                {
                    resolveTypeExpr(*varDecl.type, scopeTable, InterfaceUse.floor);
                    if (auto floors = floorsIn(*varDecl.type)) _bindingFloors[varDecl.id] = floors;
                }
                auto recursive = varDecl.value.kind.match!((const Lambda l) => l.self == varDecl.id, _ => false);
                if (recursive)
                {
                    declareLocal(varDecl.name, varDecl.nameSpan, SymbolId(varDecl.id), scopeTable,
                        DiagnosticCode.DuplicateDeclaration, "'%s' is already declared in this scope");
                }
                resolveExpr(varDecl.value, scopeTable);
                if (!recursive && varDecl.name != discardName)
                {
                    declareLocal(varDecl.name, varDecl.nameSpan, SymbolId(varDecl.id), scopeTable,
                        DiagnosticCode.DuplicateDeclaration, "'%s' is already declared in this scope");
                }
            },
            (const ExprStmt exprStmt) {
                resolveExpr(exprStmt.expr, scopeTable);
            },
            (const AssignStmt assignStmt) {
                resolveTarget(assignStmt.target, scopeTable);
                resolveExpr(assignStmt.value, scopeTable);
            },
            (const ReturnStmt returnStmt) {
                resolveExpr(returnStmt.value, scopeTable);
            },
            (const BreakStmt _) {},
            (const ContinueStmt _) {},
            (ref const PatternDecl patternDecl) {
                // The value is resolved first, so it can't see the names the pattern declares.
                resolveExpr(patternDecl.value, scopeTable);
                declarePattern(patternDecl.pattern, scopeTable);
            },
            (const FunctionDecl funcDecl) {
                _collector.reportError(DiagnosticCode.InternalError, funcDecl.nameSpan, "%s function has to be declared at the top level"
                    .format(funcDecl.kind == FunctionKind.native ? "A native" : "An intrinsic"));
            },
        );
    }

    void resolveExpr(const Expr expr, Scope scopeTable)
    {
        expr.kind.match!(
            (const BlockExpr block) {
                Scope blockScope = new Scope(scopeTable);
                foreach (ref stmt; block.statements)
                {
                    resolveStmt(stmt, blockScope);
                }
                if (block.value !is null)
                {
                    resolveExpr(*block.value, blockScope);
                }
            },
            (const Identifier _) => requireValue(expr, resolvePath(expr, scopeTable)),
            (const MemberAccess _) => requireValue(expr, resolvePath(expr, scopeTable)),
            (const CallExpr call) {
                auto target = (*call.callee).kind.match!(
                    (const Identifier id) => conversionBuiltin(id.name),
                    (_) => cast(const(Builtin)*) null,
                );
                if (target !is null)
                {
                    _conversions[expr.id] = *target;
                }
                else
                {
                    _call = expr.id;
                    _callee = call.callee.id;
                    resolveExpr(*call.callee, scopeTable);
                }
                if (auto symbol = call.callee.id in _resolutions)
                {
                    (*symbol).match!(
                        (const Id!FunctionDecl func) { _callees[expr.id] = func; },
                        (const Id!TypeDecl type) { _constructions[expr.id] = type; },
                        (_) {},
                    );
                }
                else if (call.callee.id !in _overloads)
                {
                    (*call.callee).kind.match!(
                        (const MemberAccess access) => lookUpMethod(expr.id, access.member, scopeTable),
                        (_) {},
                    );
                }
                foreach (arg; call.args)
                {
                    resolveExpr(arg, scopeTable);
                }
            },
            (const Lambda lambda) {
                foreach (ref param; lambda.params)
                {
                    _declarations.params[param.id] = &param;
                    if (param.annotated) resolveTypeExpr(param.type, scopeTable, InterfaceUse.lambdaParameter);
                }
                if (lambda.returnType !is null)
                {
                    resolveTypeExpr(*lambda.returnType, scopeTable, InterfaceUse.floor);
                    if (auto floors = floorsIn(*lambda.returnType)) _lambdaFloors[expr.id] = floors;
                }
                resolveBody(lambda.params, *lambda.body, scopeTable, expr.id, lambda.self);
            },
            (const UnaryExpr unary) {
                resolveExpr(*unary.operand, scopeTable);
            },
            (const BinaryExpr binary) {
                resolveExpr(*binary.left, scopeTable);
                resolveExpr(*binary.right, scopeTable);
            },
            (const IfExpr ifExpr) {
                auto trueScope = scopeTable;
                if (ifExpr.test !is null)
                {
                    trueScope = declareTest(expr.id, *ifExpr.test, ifExpr.trueBody.id, scopeTable);
                }
                else if (ifExpr.binding is null)
                {
                    resolveExpr(*ifExpr.condition, scopeTable);
                }
                else
                {
                    trueScope = declareHeadBinding(*ifExpr.binding, ifExpr.binding, scopeTable);
                }
                resolveExpr(*ifExpr.trueBody, trueScope);
                if (ifExpr.falseBody !is null)
                {
                    resolveExpr(*ifExpr.falseBody, scopeTable);
                }
            },
            (const WhileExpr whileExpr) {
                auto bodyScope = scopeTable;
                if (whileExpr.binding is null)
                {
                    resolveExpr(*whileExpr.condition, scopeTable);
                }
                else
                {
                    bodyScope = declareHeadBinding(*whileExpr.binding, whileExpr.binding, scopeTable);
                }
                resolveExpr(*whileExpr.body, bodyScope);
            },
            (const ForExpr forExpr) {
                recordOperators(expr, ["length", "opIndex", "next"], scopeTable);
                auto bodyScope = declareHeadBinding(*forExpr.binding, forExpr.binding, scopeTable);
                resolveExpr(*forExpr.body, bodyScope);
            },
            (const BoolLiteral _) {},
            (const IntLiteral _) {},
            (const FloatLiteral _) {},
            (const StringLiteral _) {},
            (const CharLiteral _) {},
            (const InterpolatedString interpolated) {
                foreach (part; interpolated.parts)
                {
                    resolveExpr(part, scopeTable);
                }
            },
            (const UnitLiteral _) {},
            (const SomeExpr some) => resolveExpr(*some.value, scopeTable),
            (const NoneLiteral _) {},
            (const PropagateExpr propagate) => resolveExpr(*propagate.operand, scopeTable),
            (const OkExpr ok) => resolveExpr(*ok.value, scopeTable),
            (const ErrorExpr error) => resolveExpr(*error.value, scopeTable),
            (const AssertExpr assertion) => resolveExpr(*assertion.operand, scopeTable),
            (const SafeMemberAccess access) => resolveExpr(*access.object, scopeTable),
            (const ArrayLiteral literal) {
                foreach (element; literal.elements)
                {
                    resolveExpr(element, scopeTable);
                }
            },
            (const MapLiteral literal) {
                foreach (i, key; literal.keys)
                {
                    resolveExpr(key, scopeTable);
                    resolveExpr(literal.values[i], scopeTable);
                }
            },
            (const IndexExpr index) {
                recordOperators(expr, ["opIndex", "opIndexAssign", "length"], scopeTable);
                resolveExpr(*index.object, scopeTable);
                resolveExpr(*index.index, scopeTable);
            },
            (const RangeExpr range) {
                if (range.start !is null) resolveExpr(*range.start, scopeTable);
                if (range.end !is null) resolveExpr(*range.end, scopeTable);
            },
            (const TupleLiteral literal) {
                foreach (element; literal.elements)
                {
                    resolveExpr(element, scopeTable);
                }
            },
            (const WithExpr with_) {
                resolveExpr(*with_.object, scopeTable);
                foreach (update; with_.updates)
                {
                    resolveExpr(update.value, scopeTable);
                }
            },
            (const MatchExpr match_) {
                resolveExpr(*match_.subject, scopeTable);
                foreach (ref arm; match_.arms)
                {
                    auto armScope = new Scope(scopeTable);
                    declarePattern(arm.pattern, armScope);
                    resolveExpr(arm.body, armScope);
                }
            },
        );
    }

    /// Resolves an assignment's target, in which a `_` inside a tuple names nothing.
    private void resolveTarget(const Expr target, Scope scopeTable)
    {
        target.kind.match!(
            (const TupleLiteral tuple) {
                foreach (element; tuple.elements) resolveTarget(element, scopeTable);
            },
            (const Identifier name) {
                if (name.name != discardName) resolveExpr(target, scopeTable);
            },
            (_) => resolveExpr(target, scopeTable),
        );
    }

    /// Declares each binding in `pattern` in `scopeTable`, as `val` would.
    private void declarePattern(ref const Pattern pattern, Scope scopeTable)
    {
        pattern.kind.match!(
            (ref const VarDecl binding) {
                _declarations.locals[binding.id] = &binding;
                if (binding.type !is null) resolveTypeExpr(*binding.type, scopeTable, InterfaceUse.patternBinding);
                if (binding.name != discardName)
                {
                    declareLocal(binding.name, binding.nameSpan, SymbolId(binding.id), scopeTable,
                        DiagnosticCode.DuplicateDeclaration, "'%s' is already declared in this scope");
                }
            },
            (ref const TuplePattern tuple) {
                foreach (ref element; tuple.elements)
                {
                    declarePattern(element, scopeTable);
                }
            },
            (ref const ConstructorPattern constructor) {
                auto named = constructor.type.kind.match!((const NamedType n) => n, (_) => NamedType.init);
                if (named.path.length == 1 && isReserved(named.path[0]) && named.args.length > 0)
                {
                    _collector.reportError(DiagnosticCode.UnknownType, constructor.type.span,
                        "`%s` takes no type arguments, since the value's type gives them".format(named.path[0]));
                }
                else resolveTypeExpr(constructor.type, scopeTable);
                foreach (ref argument; constructor.arguments)
                {
                    declarePattern(argument, scopeTable);
                }
            },
            (ref const SomePattern some) => declarePattern(*some.inner, scopeTable),
            (ref const NonePattern _) {},
            (ref const OkPattern ok) => declarePattern(*ok.inner, scopeTable),
            (ref const ErrorPattern error) => declarePattern(*error.inner, scopeTable),
            (ref const LiteralPattern _) {},
        );
    }

    /// The scope holding an `if val`, `while val` or `for` binding, which only its body sees: the
    /// initializer can't.
    private Scope declareHeadBinding(const VarDecl binding, const(VarDecl)* pointer, Scope scopeTable)
    {
        resolveExpr(binding.value, scopeTable);
        _declarations.locals[binding.id] = pointer;
        auto bindingScope = new Scope(scopeTable);
        if (binding.name != discardName)
        {
            declareLocal(binding.name, binding.nameSpan, SymbolId(binding.id), bindingScope,
                DiagnosticCode.DuplicateDeclaration, "'%s' is already declared in this scope");
        }
        return bindingScope;
    }

    private void requireValue(const Expr expr, Path path)
    {
        if (path.kind == Path.Kind.Module || path.kind == Path.Kind.Package)
        {
            _collector.reportError(DiagnosticCode.ModuleIsNotAValue, expr.span,
                "'%s' is a module, not a value".format(path.name));
        }
    }

    /// The functions `f` could be in `x.f(...)`, grouped as for a plain name. Anything else of this
    /// module's named `f` hides imported functions, and leaves `f` to be a field.
    private void lookUpMethod(Id!Expr call, string name, const Scope scopeTable)
    {
        auto candidates = moduleFunctions(name, scopeTable);
        if (candidates.count > 0) _methodLookups[call] = candidates;
    }

    /// The functions syntax at `expr` could call by each of `names`, as `operatorLookups` keeps them.
    private void recordOperators(const Expr expr, const string[] names, const Scope scopeTable)
    {
        foreach (name; names)
        {
            auto candidates = moduleFunctions(name, scopeTable);
            if (candidates.count > 0) _operatorLookups.require(expr.id)[name] = candidates;
        }
    }

    /// The module-level functions a plain `name` finds, grouped as for a plain name.
    private Candidates moduleFunctions(string name, const Scope scopeTable)
    {
        auto own = scopeTable.boundFunctionsNamed(name);
        if (auto symbol = scopeTable.resolveInModule(name))
        {
            if (!isFunction(*symbol)) return Candidates.init;
            own ~= _moduleScopes[_currentModule].functionsNamed(name);
        }
        return candidatesFor(name, own, scopeTable);
    }

    /// This module's functions `own` named `name`, then those it forwards, then a group per
    /// imported module.
    private Candidates candidatesFor(string name, Id!FunctionDecl[] own, const Scope scopeTable)
    {
        auto forwarded = forwardedGroup(forwardsOf(_currentModule, name), scopeTable, name,
            m => _moduleScopes[m].functionsNamed(name).filter!(f => isPublic(SymbolId(f))).array);
        return grouped(_currentModule, own, forwarded, scopeTable.modulesProviding(name).array, m => visibleFunctions(m, name));
    }

    /// Resolves an identifier or a member access chain, which may start with a module path.
    private Path resolvePath(const Expr expr, Scope scopeTable)
    {
        return expr.kind.match!(
            (const Identifier id) {
                foreach (arg; id.typeArgs) resolveTypeExpr(arg, scopeTable);
                return resolveName(expr, id.name, scopeTable);
            },
            (const MemberAccess access) {
                foreach (arg; access.typeArgs) resolveTypeExpr(arg, scopeTable);
                return resolveMember(expr, access, scopeTable);
            },
            (_) {
                resolveExpr(expr, scopeTable);
                return Path(Path.Kind.Value);
            },
        );
    }

    /// Looks `name` up in the scope chain (locals, params, then this module's defs), then in
    /// every visible module, then as a module path.
    private Path resolveName(const Expr expr, string name, Scope scopeTable)
    {
        // What a bound supplies is one of this module's functions, inside the function with the bound.
        auto supplied = scopeTable.boundFunctionsNamed(name);
        if (auto local = scopeTable.resolve(name))
        {
            // A nested def is a local, so a function found here is one of this module's, and
            // imported functions of the name are tried when none of this module's fits.
            if (isFunction(*local))
            {
                auto own = supplied ~ _moduleScopes[_currentModule].functionsNamed(name);
                return recordFunctions(expr, name, candidatesFor(name, own, scopeTable));
            }
            recordCapture(*local, name, expr.span, scopeTable);
            return recordValue(expr, name, *local);
        }
        if (supplied.length > 0) return recordFunctions(expr, name, candidatesFor(name, supplied, scopeTable));

        Brought!SymbolId[] found;
        string[] vias;
        bool listed;
        // An import that lists the name beats one that brings every name.
        foreach (level, modules; scopeTable.modulesProvidingByLevel(name))
        {
            foreach (m; modules)
            {
                foreach (brought; visibleSymbols(m, name))
                {
                    // One declaration reached through two imports is one declaration.
                    if (found.canFind!(b => b.symbol == brought.symbol)) continue;
                    found ~= brought;
                    vias ~= m;
                }
            }
            listed = level == 0;
            if (found.length > 0) break;
        }
        if (found.length > 0 && found.all!(f => isFunction(f.symbol)))
        {
            return recordFunctions(expr, name, candidatesFor(name, null, scopeTable));
        }
        // Two listed imports of different declarations were reported at the second.
        if (found.length == 1 || (listed && vias.dup.sort.uniq.walkLength == vias.length))
        {
            auto value = found.find!(f => !isFunction(f.symbol));
            return recordValue(expr, name, value.empty ? found[0].symbol : value.front.symbol);
        }
        if (found.length > 1)
        {
            _collector.reportError(DiagnosticCode.AmbiguousName, expr.span,
                ambiguityMessage(name, found.map!(b => b.owner).array, vias));
            return Path(Path.Kind.Error);
        }

        if (auto path = modulePath(expr, name, scopeTable))
        {
            return *path;
        }
        _collector.reportError(DiagnosticCode.UnknownName, expr.span, isReserved(name) && name != "None"
            ? "`%s` takes exactly one value, and can't be used as a function".format(name)
            : "Unknown name '%s'".format(name));
        return Path(Path.Kind.Error);
    }

    /// The error for a bare `name` that declarations in each of `owners` provide, each through the
    /// import of the same place in `vias`. One import bringing two is a clash in what it forwards,
    /// which qualifying by that import doesn't settle.
    private static string ambiguityMessage(string name, const string[] owners, const string[] vias)
    {
        if (vias.dup.sort.uniq.walkLength == vias.length)
        {
            return "'%s' is defined in more than one imported module (%s); qualify it, e.g. '%s.%s'"
                .format(name, vias.join(", "), vias[0], name);
        }
        auto labels = owners.length.iota.map!(i => owners[i] == vias[i] ? owners[i] : owners[i] ~ " through " ~ vias[i]);
        return "'%s' is defined in more than one module (%-(%s, %)); import the one you mean and qualify it, e.g. '%s.%s'"
            .format(name, labels, owners[0], name);
    }

    /// Records that `expr` names `symbol`. An alias stands for its type, so the name of a product
    /// or marker constructs it and a builtin's converts to it, as the type's own name would.
    private Path recordValue(const Expr expr, string name, SymbolId symbol)
    {
        auto alias_ = symbol.match!((const Id!AliasDecl a) => a, _ => Id!AliasDecl.init);
        if (!alias_.isValid)
        {
            _resolutions[expr.id] = symbol;
            return Path(Path.Kind.Value);
        }

        auto isValue = expandAlias(TypeSymbol(alias_), _declarations.aliases, _typeResolutions).match!(
            (const Id!TypeDecl type) {
                _resolutions[expr.id] = SymbolId(type);
                if (aliasesInstance(alias_)) _aliasedInstances[expr.id] = alias_;
                return true;
            },
            (const Builtin builtin) {
                if (expr.id != _callee || !isConversion(builtin)) return false;
                _conversions[_call] = builtin;
                return true;
            },
            (const Id!AliasDecl _) => false,
            (const Id!TypeParam _) => false,
            (const Id!InterfaceDecl _) => false,
        );
        if (isValue) return Path(Path.Kind.Value);

        _collector.reportError(DiagnosticCode.AliasIsNotAValue, expr.span,
            "`%s` is an alias of `%s`, which can't be used as a value here"
                .format(name, printTypeExpr(_declarations.aliases[alias_].target)));
        return Path(Path.Kind.Error);
    }

    /// Whether `alias_` stands for a generic type with type arguments, directly or through other
    /// aliases.
    private bool aliasesInstance(Id!AliasDecl alias_)
    {
        foreach (_; 0 .. _declarations.aliases.length)
        {
            auto target = &_declarations.aliases[alias_].target;
            if (target.kind.match!((const NamedType n) => n.args.length > 0, _ => false)) return true;
            auto next = target.id in _typeResolutions;
            if (next is null) return false;
            alias_ = (*next).match!((const Id!AliasDecl a) => a, _ => Id!AliasDecl.init);
            if (!alias_.isValid) return false;
        }
        return false;
    }

    /// Notes `symbol`, just found from `from`, as captured by each lambda between the two.
    private void recordCapture(SymbolId symbol, string name, Span span, const Scope from)
    {
        import std.typecons : Rebindable;

        bool isLocal = true;
        auto mutable = symbol.match!(
            (const Id!VarDecl local) => _declarations.locals[local].mutable,
            (const Id!Param param) => _declarations.params[param].mutable,
            (_) { isLocal = false; return false; },
        );
        if (!isLocal) return;

        for (Rebindable!(const Scope) current = from; current.resolveLocal(name) is null; current = current.parent)
        {
            if (!current.lambda.isValid || symbol == SymbolId(current.selfBinding)) continue;
            if (mutable)
            {
                _collector.reportError(DiagnosticCode.CapturedMutable, span,
                    "A lambda can't capture `%s`, which is mutable; copy it into a `val` first, or pass it as an argument".format(name));
                return;
            }
            if (!_captures.get(current.lambda, null).canFind(symbol)) _captures[current.lambda] ~= symbol;
        }
    }

    private Path resolveMember(const Expr expr, const MemberAccess access, Scope scopeTable)
    {
        auto object = resolvePath(*access.object, scopeTable);
        final switch (object.kind)
        {
        case Path.Kind.Value:
        case Path.Kind.Error:
            // A member of a value depends on its type, so the type checker resolves it.
            return object;
        case Path.Kind.Module:
            auto nested = object.name ~ "." ~ access.member;
            if (scopeTable.importedModules.canFind(nested))
            {
                return *modulePath(expr, nested, scopeTable);
            }
            auto brought = visibleSymbols(object.name, access.member);
            if (brought.length > 1 && !brought.all!(b => isFunction(b.symbol)))
            {
                _collector.reportError(DiagnosticCode.AmbiguousName, expr.span, ambiguityMessage(access.member,
                    brought.map!(b => b.owner).array, brought.map!(b => object.name).array));
                return Path(Path.Kind.Error);
            }
            if (auto symbol = visibleSymbol(object.name, access.member))
            {
                if (isFunction(*symbol))
                {
                    return recordFunctions(expr, access.member, Candidates([visibleFunctions(object.name, access.member)], null,
                        [object.name == _currentModule ? string.init : object.name]));
                }
                return recordValue(expr, access.member, *symbol);
            }
            // `a.b` on the way to `a.b.c`, when `a` and `a.b.c` are imported but `a.b` isn't.
            if (auto path = modulePath(expr, nested, scopeTable))
            {
                return *path;
            }
            if (_moduleScopes[object.name].resolveLocal(access.member) !is null)
            {
                _collector.reportError(DiagnosticCode.PrivateMember, expr.span,
                    "'%s' is private to '%s'".format(access.member, object.name));
                return Path(Path.Kind.Error);
            }
            _collector.reportError(DiagnosticCode.UnknownModuleMember, expr.span,
                "Module '%s' has no '%s'".format(object.name, access.member));
            return Path(Path.Kind.Error);
        case Path.Kind.Package:
            auto name = object.name ~ "." ~ access.member;
            if (auto path = modulePath(expr, name, scopeTable))
            {
                return *path;
            }
            _collector.reportError(DiagnosticCode.UnknownName, expr.span,
                "No imported module is named '%s'".format(name));
            return Path(Path.Kind.Error);
        }
    }

    /// `name` as a visible module (recording the resolution) or a prefix of one, else null.
    private Path* modulePath(const Expr expr, string name, const Scope scopeTable)
    {
        if (scopeTable.importedModules.canFind(name))
        {
            _resolutions[expr.id] = SymbolId(_moduleIds[name]);
            return new Path(Path.Kind.Module, name);
        }
        if (scopeTable.importedModules.any!(m => m.startsWith(name ~ ".")))
        {
            return new Path(Path.Kind.Package, name);
        }
        return null;
    }
}

/// What an interface calls the type that conforms to it.
private enum selfName = "Self";

/// What a type expression is there for, which says whether it can name an interface.
private enum InterfaceUse
{
    /// A type, which an interface isn't.
    none,
    /// A bound, which has to be an interface.
    bound,
    /// The whole type of a module-level `def`'s parameter, where an interface name stands for a
    /// hidden type parameter with that bound.
    parameter,
    /// The whole type of a lambda's or nested `def`'s parameter, which can't be generic.
    lambdaParameter,
    /// The whole type of a parameter of a function with no body, or of an interface's function.
    bodilessParameter,
    interfaceParameter,
    /// A part of `A & B`, which has to be an interface.
    joined,
    /// A part of an `A & B` that's a floor, whose type arguments are a floor's place too.
    joinedInFloor,
    /// The whole of a result type or a `val`'s annotation, where an interface name or `A & B` is
    /// a floor, as it is on the success side of an error union that's the whole type.
    floor,
    /// Inside one of those: a tuple's element, an option's or array's type, or a type argument.
    floorPart,
    /// Inside a function type in one of those, or an error union that isn't the whole type or
    /// its errors, where there's no floor.
    floorInFunction,
    floorInErrorUnion,
    /// The result type of an interface's function.
    interfaceResult,
    /// The result type of a function with no body to take the type from.
    bodilessResult,
    /// The annotation of a binding in a pattern.
    patternBinding,
    /// A top-level constant's type.
    constant,
}

/// The names the language gives meaning to, which no declaration can take.
private bool isReserved(string name)
{
    return name == "Some" || name == "None" || name == "Ok" || name == "Error";
}
