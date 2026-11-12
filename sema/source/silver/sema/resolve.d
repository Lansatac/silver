/// Name resolution: links every identifier and module path to the declaration it names,
/// and records which function each direct call invokes.
module silver.sema.resolve;


import std.algorithm;
import std.array;
import std.string;
import std.sumtype;

import silver.ast;
import silver.sema.target : intrinsicAlias, intrinsicNamed, isIntrinsicType, Target;

/// An `Id!AliasDecl` is only ever in a scope: a use of one records what it stands for.
alias SymbolId = SumType!(Id!FunctionDecl, Id!Param, Id!VarDecl, Id!Module, Id!TypeDecl, Id!ConstDecl, Id!AliasDecl);

alias TypeSymbol = SumType!(Builtin, Id!TypeDecl, Id!AliasDecl, Id!TypeParam);

private bool isFunction(const SymbolId symbol)
{
    return symbol.match!((const Id!FunctionDecl _) => true, _ => false);
}

private bool isConversion(Builtin builtin)
{
    static immutable Builtin[] notConversions = [Builtin.Never, Builtin.Unit, Builtin.Bool, Builtin.Any];
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
    const(FunctionDecl)*[Id!FunctionDecl] functions;
    /// The module each function is declared in.
    string[Id!FunctionDecl] functionModules;
    const(TypeDecl)*[Id!TypeDecl] types;
    const(ConstDecl)*[Id!ConstDecl] constants;
    const(AliasDecl)*[Id!AliasDecl] aliases;
    const(VarDecl)*[Id!VarDecl] locals;
    const(Param)*[Id!Param] params;
    const(TypeParam)*[Id!TypeParam] typeParams;
}

/// What name resolution produced.
package struct Resolution
{
    SymbolId[Id!Expr] resolutions;
    TypeSymbol[Id!TypeExpr] typeResolutions;
    Id!FunctionDecl[Id!Expr] callees;
    Id!TypeDecl[Id!Expr] constructions;
    /// The locals and params each lambda uses from outside itself, in first-use order.
    const(SymbolId)[][Id!Expr] captures;
    /// Calls like `UInt8(x)`, by the type they convert to.
    Builtin[Id!Expr] conversions;
    /// For a call `x.f(...)` on a value, the functions a plain `f` finds at module level. The type
    /// checker decides whether one is used, since a field of `x` comes first.
    Candidates[Id!Expr] methodLookups;
    /// Names that could be more than one function, by the name's expression. The type checker
    /// chooses, so these have no entry in `resolutions`.
    Candidates[Id!Expr] overloads;
    /// For each `for` and each `x[i]`, by name, the functions that calls of `length`, `opIndex`,
    /// `opIndexAssign`, `opSlice` and `next` there would choose from, since that syntax means calls
    /// of them on anything but an array or `a..b`.
    Candidates[string][Id!Expr] operatorLookups;
    Declarations declarations;
    /// The `native library` of each module that names one.
    string[string] nativeLibraries;
}

/// The builtin or declared type `symbol` is another name for. It's still an alias if it stands
/// for a type with no name, like `[Int]`, or is recursive.
package TypeSymbol expandAlias(TypeSymbol symbol, const(AliasDecl*[Id!AliasDecl]) aliases,
    const(TypeSymbol[Id!TypeExpr]) typeResolutions)
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

    size_t count() const => groups.map!(g => g.length).sum;
}

/// Resolves every name in `program`, reporting problems to `collector`.
package Resolution resolveNames(const ref Program program, Collector collector, Target target)
{
    return new NameResolver(collector, target).resolveProgram(program);
}

private immutable Scope universal = new Scope(builtinTypes);

/// Which names one module's imports of another give it unqualified: every name, or only those a
/// selective import lists. Imports of one module combine, and any of them gives qualified access.
package struct ModuleAccess
{
    string name;
    bool everyName;
    const(string)[] names;

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

    /// The imported modules a bare `name` can come from.
    auto modulesProviding(string name) const
    {
        return _imports.filter!(i => i.provides(name)).map!(i => i.name);
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

    private SymbolId[Id!Expr] _resolutions;
    private TypeSymbol[Id!TypeExpr] _typeResolutions;
    private Id!FunctionDecl[Id!Expr] _callees;
    private Id!TypeDecl[Id!Expr] _constructions;
    private const(SymbolId)[][Id!Expr] _captures;
    private Builtin[Id!Expr] _conversions;
    private Candidates[Id!Expr] _methodLookups;
    private Candidates[Id!Expr] _overloads;
    private Candidates[string][Id!Expr] _operatorLookups;
    private Declarations _declarations;
    private Collector _collector;
    /// Each module's own top-level declarations, by module name.
    private Scope[string] _moduleScopes;
    private Id!Module[string] _moduleIds;
    /// The call whose callee is being resolved, since only there can an alias of a builtin be a value.
    private Id!Expr _call;
    private Id!Expr _callee;
    private bool[Id!AliasDecl] _recursiveAliases;
    /// The module being resolved, which is the one that sees its own private declarations.
    private string _currentModule;

    private Target _target;
    private string[string] _nativeLibraries;

    this(Collector collector, Target target)
    {
        _collector = collector;
        _target = target;
    }

    Resolution resolveProgram(const Program program)
    {
        // Sorted so diagnostics come out in the same order every run.
        auto modules = program.sortedModules;
        foreach (mod; modules)
        {
            declareModule(mod.name, mod, (preludeName in program.modules) !is null);
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
        foreach (mod; modules)
        {
            resolveModule(mod.name, mod);
        }
        return Resolution(_resolutions, _typeResolutions, _callees, _constructions, _captures, _conversions, _methodLookups, _overloads,
            _operatorLookups, _declarations, _nativeLibraries);
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
                (const ImportStmt importStmt) {
                    auto imported = importStmt.path.join(".");
                    auto index = imports.countUntil!(i => i.name == imported);
                    if (index < 0)
                    {
                        imports ~= ModuleAccess(imported);
                        index = imports.length - 1;
                    }
                    auto access = &imports[index];
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
                (ref const TypeDecl type) {
                    _declarations.types[type.id] = &type;
                    if (type.intrinsic) checkIntrinsic(name, type.nameSpan, "intrinsic type", isIntrinsicType(type.name));
                    if (moduleScope.resolveLocalType(type.name) !is null || moduleScope.resolveLocal(type.name) !is null)
                    {
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, type.nameSpan, type.implicitMarker
                            ? "`%s` is already a member of another sum in this module; declare `type %s` on its own to share it"
                                .format(type.name, type.name)
                            : "'%s' is already declared in this module".format(type.name));
                    }
                    else if (universal.resolveLocalType(type.name) !is null || type.name == "Some" || type.name == "None")
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
                    else if (universal.resolveLocalType(alias_.name) !is null || alias_.name == "Some" || alias_.name == "None")
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
                (const ImportStmt _) {},
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
        return moduleName == preludeName || moduleName == "std" || moduleName.startsWith("std.");
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
            (const ArrayType array) => reaches(*array.element, target, seen),
            (const FunctionType func) => through(func.params) || reaches(*func.returnType, target, seen),
            (const UnitType _) => false,
            (const TupleType tuple) => through(tuple.elements),
        );
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
                    foreach (ref param; func.params)
                    {
                        _declarations.params[param.id] = &param;
                        resolveTypeExpr(param.type, declScope);
                    }
                    resolveTypeExpr(func.returnType, declScope);
                    if (!func.isPrivate)
                    {
                        foreach (ref param; func.params)
                        {
                            reportPrivateType(param.type, "a public function's signature");
                        }
                        reportPrivateType(func.returnType, "a public function's signature");
                    }

                    if (func.body !is null)
                    {
                        resolveBody(func.params, *func.body, declScope, Id!Expr.init, Id!VarDecl.init,
                            func.invariantOf.isValid);
                    }
                },
                (ref const TypeDecl type) {
                    auto declScope = genericScope(type.typeParams, _moduleScopes[name], type.inheritsParams);
                    foreach (member; type.members)
                    {
                        resolveTypeExpr(member.type, declScope);
                        if (!type.isPrivate) reportPrivateType(member.type, "a public sum's members");
                    }
                    if (type.implicitMarker) reportImportedMember(type, _moduleScopes[name]);
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
                (const ImportStmt _) {},
            );
        }
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
            else if (universal.resolveLocalType(param.name) !is null || param.name == "Some" || param.name == "None")
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
        if (m == _currentModule) return true;
        return !symbol.match!(
            (const Id!FunctionDecl f) => _declarations.functions[f].isPrivate,
            (const Id!TypeDecl t) => _declarations.types[t].isPrivate,
            (const Id!ConstDecl c) => _declarations.constants[c].isPrivate,
            (const Id!AliasDecl a) => _declarations.aliases[a].isPrivate,
            _ => false,
        );
    }

    private bool isVisible(TypeSymbol symbol, string m)
    {
        if (m == _currentModule) return true;
        return !symbol.match!(
            (const Id!TypeDecl t) => _declarations.types[t].isPrivate,
            (const Id!AliasDecl a) => _declarations.aliases[a].isPrivate,
            (const Builtin _) => false,
            (const Id!TypeParam _) => false,
        );
    }

    /// What the name `name` is in module `m`, if the module being resolved can see it: the first
    /// visible function, for a name of functions.
    private const(SymbolId)* visibleSymbol(string m, string name)
    {
        auto symbol = _moduleScopes[m].resolveLocal(name);
        if (symbol is null) return null;
        if (isFunction(*symbol))
        {
            auto functions = visibleFunctions(m, name);
            return functions.length == 0 ? null : new SymbolId(functions[0]);
        }
        return isVisible(*symbol, m) ? symbol : null;
    }

    /// The functions named `name` in module `m` that the module being resolved can see.
    private Id!FunctionDecl[] visibleFunctions(string m, string name)
    {
        return _moduleScopes[m].functionsNamed(name).filter!(f => isVisible(SymbolId(f), m)).array;
    }

    /// The visible functions named `name` in each imported module that has any, a group per module.
    private Id!FunctionDecl[][] importedFunctions(string name, const Scope scopeTable)
    {
        return scopeTable.modulesProviding(name).map!(m => visibleFunctions(m, name)).filter!(g => g.length > 0).array;
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
        auto symbol = _moduleScopes[m].resolveLocalType(name);
        return symbol !is null && isVisible(*symbol, m) ? symbol : null;
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
            (const ArrayType array) => reportPrivateType(*array.element, where),
            (const FunctionType func) {
                foreach (param; func.params) reportPrivateType(param, where);
                reportPrivateType(*func.returnType, where);
            },
            (const UnitType _) {},
            (const TupleType tuple) {
                foreach (element; tuple.elements) reportPrivateType(element, where);
            },
        );
    }

    /// A bare name in a sum declares a marker, so one an import also provides would quietly be a new type.
    private void reportImportedMember(const TypeDecl marker, const Scope current)
    {
        auto owners = current.modulesProviding(marker.name).filter!(m => visibleType(m, marker.name) !is null).array;
        if (owners.length == 0) return;
        _collector.reportError(DiagnosticCode.AmbiguousName, marker.nameSpan,
            "`%s` is also a type in `%s`; write `%s.%s` to use that one, or rename this member"
                .format(marker.name, owners[0], owners[0], marker.name));
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
        resolveTypeExpr(*constant.type, current);

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
                );
            },
            _ => false,
        );
    }

    private void resolveTypeExpr(const TypeExpr type, const Scope current)
    {
        type.kind.match!(
            (const NamedType named) {
                foreach (arg; named.args)
                {
                    resolveTypeExpr(arg, current);
                }
                auto name = named.path.back;
                const(TypeSymbol)* resolvedType;
                if (named.path.length == 1)
                {
                    resolvedType = current.resolveType(name);
                    if (resolvedType is null)
                    {
                        auto owners = current.modulesProviding(name)
                            .filter!(m => visibleType(m, name) !is null)
                            .array;
                        if (owners.length > 1)
                        {
                            _collector.reportError(DiagnosticCode.AmbiguousName, type.span, ambiguityMessage(name, owners));
                            return;
                        }
                        if (owners.length == 1)
                        {
                            resolvedType = visibleType(owners[0], name);
                        }
                    }
                }
                else
                {
                    auto moduleName = named.path[0 .. $ - 1].join(".");
                    if (current.importedModules.canFind(moduleName))
                    {
                        resolvedType = _moduleScopes[moduleName].resolveLocalType(name);
                        if (resolvedType !is null && !isVisible(*resolvedType, moduleName))
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
                _typeResolutions[type.id] = *resolvedType;
            },
            (const OptionType option) => resolveTypeExpr(*option.inner, current),
            (const ArrayType array) => resolveTypeExpr(*array.element, current),
            (const FunctionType func) {
                foreach (param; func.params)
                {
                    resolveTypeExpr(param, current);
                }
                resolveTypeExpr(*func.returnType, current);
            },
            (const UnitType _) {},
            (const TupleType tuple) {
                foreach (element; tuple.elements)
                {
                    resolveTypeExpr(element, current);
                }
            },
        );
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
                if (varDecl.type !is null) resolveTypeExpr(*varDecl.type, scopeTable);
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
                    if (param.annotated) resolveTypeExpr(param.type, scopeTable);
                }
                if (lambda.returnType !is null) resolveTypeExpr(*lambda.returnType, scopeTable);
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
                if (ifExpr.binding is null)
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
                recordOperators(expr, ["opIndex", "opIndexAssign", "opSlice", "length"], scopeTable);
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
                if (binding.type !is null) resolveTypeExpr(*binding.type, scopeTable);
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
                resolveTypeExpr(constructor.type, scopeTable);
                foreach (ref argument; constructor.arguments)
                {
                    declarePattern(argument, scopeTable);
                }
            },
            (ref const SomePattern some) => declarePattern(*some.inner, scopeTable),
            (ref const NonePattern _) {},
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
        Id!FunctionDecl[] own;
        if (auto symbol = scopeTable.resolveInModule(name))
        {
            if (!isFunction(*symbol)) return Candidates.init;
            own = visibleFunctions(_currentModule, name);
        }
        return candidatesFor(name, own, scopeTable);
    }

    /// This module's functions `own` named `name`, then a group per imported module.
    private Candidates candidatesFor(string name, Id!FunctionDecl[] own, const Scope scopeTable)
    {
        return Candidates(own ~ importedFunctions(name, scopeTable));
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
        if (auto local = scopeTable.resolve(name))
        {
            // A nested def is a local, so a function found here is one of this module's, and
            // imported functions of the name are tried when none of this module's fits.
            if (isFunction(*local))
            {
                auto own = visibleFunctions(_currentModule, name);
                return recordFunctions(expr, name, candidatesFor(name, own, scopeTable));
            }
            recordCapture(*local, name, expr.span, scopeTable);
            return recordValue(expr, name, *local);
        }

        const(SymbolId)[] found;
        string[] owners;
        foreach (m; scopeTable.modulesProviding(name))
        {
            if (auto symbol = visibleSymbol(m, name))
            {
                found ~= *symbol;
                owners ~= m;
            }
        }
        if (found.length > 0 && found.all!(f => isFunction(f)))
        {
            return recordFunctions(expr, name, candidatesFor(name, null, scopeTable));
        }
        if (found.length == 1)
        {
            return recordValue(expr, name, found[0]);
        }
        if (found.length > 1)
        {
            _collector.reportError(DiagnosticCode.AmbiguousName, expr.span, ambiguityMessage(name, owners));
            return Path(Path.Kind.Error);
        }

        if (auto path = modulePath(expr, name, scopeTable))
        {
            return *path;
        }
        _collector.reportError(DiagnosticCode.UnknownName, expr.span, name == "Some"
            ? "`Some` takes exactly one value, and can't be used as a function"
            : "Unknown name '%s'".format(name));
        return Path(Path.Kind.Error);
    }

    /// The error for a bare `name` that more than one of `owners` provides.
    private static string ambiguityMessage(string name, const string[] owners)
    {
        return "'%s' is defined in more than one imported module (%s); qualify it, e.g. '%s.%s'"
            .format(name, owners.join(", "), owners[0], name);
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

        // A value of the type would have to know the alias's type arguments, which a name can't carry.
        if (auto instance = aliasedInstance(alias_))
        {
            _collector.reportError(DiagnosticCode.AliasIsNotAValue, expr.span,
                "`%s` is an alias of `%s`, and its name can't give a value those type arguments; write `%s` instead"
                    .format(name, printTypeExpr(*instance), printTypeExpr(*instance)));
            return Path(Path.Kind.Error);
        }
        auto isValue = expandAlias(TypeSymbol(alias_), _declarations.aliases, _typeResolutions).match!(
            (const Id!TypeDecl type) { _resolutions[expr.id] = SymbolId(type); return true; },
            (const Builtin builtin) {
                if (expr.id != _callee || !isConversion(builtin)) return false;
                _conversions[_call] = builtin;
                return true;
            },
            (const Id!AliasDecl _) => false,
            (const Id!TypeParam _) => false,
        );
        if (isValue) return Path(Path.Kind.Value);

        _collector.reportError(DiagnosticCode.AliasIsNotAValue, expr.span,
            "`%s` is an alias of `%s`, which can't be used as a value here"
                .format(name, printTypeExpr(_declarations.aliases[alias_].target)));
        return Path(Path.Kind.Error);
    }

    /// The generic type with type arguments that `alias_` stands for, directly or through other
    /// aliases, or null if it doesn't stand for one.
    private const(TypeExpr)* aliasedInstance(Id!AliasDecl alias_)
    {
        foreach (_; 0 .. _declarations.aliases.length)
        {
            auto target = &_declarations.aliases[alias_].target;
            auto hasArgs = target.kind.match!((const NamedType n) => n.args.length > 0, _ => false);
            if (hasArgs) return target;
            auto next = target.id in _typeResolutions;
            if (next is null) return null;
            alias_ = (*next).match!((const Id!AliasDecl a) => a, _ => Id!AliasDecl.init);
            if (!alias_.isValid) return null;
        }
        return null;
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
            if (auto symbol = visibleSymbol(object.name, access.member))
            {
                if (isFunction(*symbol))
                {
                    return recordFunctions(expr, access.member, Candidates([visibleFunctions(object.name, access.member)]));
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
