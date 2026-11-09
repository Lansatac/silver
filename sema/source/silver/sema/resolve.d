/// Name resolution: links every identifier and module path to the declaration it names,
/// and records which function each direct call invokes.
module silver.sema.resolve;


import std.algorithm;
import std.array;
import std.string;
import std.sumtype;

import silver.ast;

/// An `Id!AliasDecl` is only ever in a scope: a use of one records what it stands for.
alias SymbolId = SumType!(Id!FunctionDecl, Id!Param, Id!VarDecl, Id!Module, Id!TypeDecl, Id!ConstDecl, Id!AliasDecl);

alias TypeSymbol = SumType!(Builtin, Id!TypeDecl, Id!AliasDecl);

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
    const(TypeDecl)*[Id!TypeDecl] types;
    const(ConstDecl)*[Id!ConstDecl] constants;
    const(AliasDecl)*[Id!AliasDecl] aliases;
    const(VarDecl)*[Id!VarDecl] locals;
    const(Param)*[Id!Param] params;
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
    /// For a call `x.f(...)` on a value, what a plain `f` finds at module level. The type
    /// checker decides whether it's used, since a field of `x` comes first.
    MethodLookup[Id!Expr] methodLookups;
    Declarations declarations;
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

package struct MethodLookup
{
    const(SymbolId)[] found;
    /// The module of each entry of `found`, when it's more than one import.
    string[] owners;
}

/// Resolves every name in `program`, reporting problems to `collector`.
package Resolution resolveNames(const ref Program program, Collector collector)
{
    return new NameResolver(collector).resolveProgram(program);
}

private immutable Scope universal = new Scope(builtinTypes);

/// The names declared in one module, function, or block. Lookups fall back to the parent.
package final class Scope
{
    private SymbolId[string] _scopeTable;
    private const Scope _parent;
    /// The modules visible from here: the enclosing module's imports, plus the prelude.
    private const(string)[] _visibleModules;
    private TypeSymbol[string] _typeTable;
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
    this(const(string)[] visibleModules)
    {
        _parent = universal;
        _visibleModules = visibleModules;
    }

    /// A function, lambda, or block scope inside `parent`, seeing the same modules.
    this(const Scope parent)
    {
        _parent = parent;
        _visibleModules = parent._visibleModules;
    }

    const(Scope) parent() const
    {
        return _parent;
    }

    const(string)[] visibleModules() const
    {
        return _visibleModules;
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
    private MethodLookup[Id!Expr] _methodLookups;
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

    this(Collector collector)
    {
        _collector = collector;
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
        return Resolution(_resolutions, _typeResolutions, _callees, _constructions, _captures, _conversions, _methodLookups, _declarations);
    }

    private void declareModule(string name, const Module mod, bool hasPrelude)
    {
        string[] visible = hasPrelude && name != preludeName ? [preludeName] : [];
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl _) {},
                (const TypeDecl _) {},
                (const ConstDecl _) {},
                (const AliasDecl _) {},
                (const ImportStmt importStmt) {
                    auto imported = importStmt.path.join(".");
                    if (!visible.canFind(imported))
                    {
                        visible ~= imported;
                    }
                },
            );
        }

        auto moduleScope = new Scope(visible);
        foreach (ref decl; mod.declarations)
        {
            decl.kind.match!(
                (ref const FunctionDecl func) {
                    _declarations.functions[func.id] = &func;
                    if (func.isPrivate && func.name == "main")
                    {
                        _collector.reportError(DiagnosticCode.MainInvalidDefinition, func.nameSpan,
                            "`main` can't be private");
                    }
                    if (moduleScope.resolveLocal(func.name) !is null)
                    {
                        _collector.reportError(DiagnosticCode.DuplicateDeclaration, func.nameSpan,
                            "'%s' is already declared in this module".format(func.name));
                    }
                    else
                    {
                        moduleScope.declare(func.name, SymbolId(func.id));
                    }
                },
                (ref const TypeDecl type) {
                    _declarations.types[type.id] = &type;
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

    private void resolveAliases(string name, const Module mod)
    {
        _currentModule = name;
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const AliasDecl alias_) {
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
            decl.kind.match!(
                (const FunctionDecl func) {
                    foreach (ref param; func.params)
                    {
                        _declarations.params[param.id] = &param;
                        resolveTypeExpr(param.type, _moduleScopes[name]);
                    }
                    resolveTypeExpr(func.returnType, _moduleScopes[name]);
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
                        resolveBody(func.params, *func.body, _moduleScopes[name]);
                    }
                },
                (const TypeDecl type) {
                    foreach (member; type.members)
                    {
                        resolveTypeExpr(member.type, _moduleScopes[name]);
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
                        resolveTypeExpr(field.type, _moduleScopes[name]);
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
        );
    }

    /// What the name `name` is in module `m`, if the module being resolved can see it.
    private const(SymbolId)* visibleSymbol(string m, string name)
    {
        auto symbol = _moduleScopes[m].resolveLocal(name);
        return symbol !is null && isVisible(*symbol, m) ? symbol : null;
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
        auto owners = current.visibleModules.filter!(m => visibleType(m, marker.name) !is null).array;
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
                        auto owners = current.visibleModules
                            .filter!(m => visibleType(m, name) !is null)
                            .array;
                        if (owners.length > 1)
                        {
                            _collector.reportError(DiagnosticCode.AmbiguousName, type.span,
                                "'%s' is defined in more than one imported module (%s); qualify it, e.g. '%s.%s'"
                                    .format(name, owners.join(", "), owners[0], name));
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
                    if (current.visibleModules.canFind(moduleName))
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
    private void resolveBody(const Param[] params, const Expr body, Scope enclosing,
        Id!Expr lambda = Id!Expr.init, Id!VarDecl selfBinding = Id!VarDecl.init)
    {
        auto functionScope = new Scope(enclosing);
        functionScope.lambda = lambda;
        functionScope.selfBinding = selfBinding;
        foreach (param; params)
        {
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
            reportModuleRootClash(name, span, current.visibleModules);
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
                resolveExpr(assignStmt.target, scopeTable);
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
                _collector.reportError(DiagnosticCode.InternalError, funcDecl.nameSpan,
                    "A native function has to be declared at the top level");
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
                else
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
                resolveExpr(*index.object, scopeTable);
                resolveExpr(*index.index, scopeTable);
            },
            (const RangeExpr range) {
                resolveExpr(*range.start, scopeTable);
                resolveExpr(*range.end, scopeTable);
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

    /// What `f` would be in `x.f(...)`. Own declarations beat imports, as for a plain name.
    private void lookUpMethod(Id!Expr call, string name, const Scope scopeTable)
    {
        if (auto own = scopeTable.resolveInModule(name))
        {
            _methodLookups[call] = MethodLookup([*own]);
            return;
        }
        MethodLookup lookup;
        foreach (m; scopeTable.visibleModules)
        {
            if (auto symbol = visibleSymbol(m, name))
            {
                lookup.found ~= *symbol;
                lookup.owners ~= m;
            }
        }
        if (lookup.found.length > 0) _methodLookups[call] = lookup;
    }

    /// Resolves an identifier or a member access chain, which may start with a module path.
    private Path resolvePath(const Expr expr, Scope scopeTable)
    {
        return expr.kind.match!(
            (const Identifier id) => resolveName(expr, id.name, scopeTable),
            (const MemberAccess access) => resolveMember(expr, access, scopeTable),
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
            recordCapture(*local, name, expr.span, scopeTable);
            return recordValue(expr, name, *local);
        }

        const(SymbolId)[] found;
        string[] owners;
        foreach (m; scopeTable.visibleModules)
        {
            if (auto symbol = visibleSymbol(m, name))
            {
                found ~= *symbol;
                owners ~= m;
            }
        }
        if (found.length == 1)
        {
            return recordValue(expr, name, found[0]);
        }
        if (found.length > 1)
        {
            _collector.reportError(DiagnosticCode.AmbiguousName, expr.span,
                "'%s' is defined in more than one imported module (%s); qualify it, e.g. '%s.%s'"
                    .format(name, owners.join(", "), owners[0], name));
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
            (const Id!TypeDecl type) { _resolutions[expr.id] = SymbolId(type); return true; },
            (const Builtin builtin) {
                if (expr.id != _callee || !isConversion(builtin)) return false;
                _conversions[_call] = builtin;
                return true;
            },
            (const Id!AliasDecl _) => false,
        );
        if (isValue) return Path(Path.Kind.Value);

        _collector.reportError(DiagnosticCode.AliasIsNotAValue, expr.span,
            "`%s` is an alias of `%s`, which can't be used as a value here"
                .format(name, printTypeExpr(_declarations.aliases[alias_].target)));
        return Path(Path.Kind.Error);
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
            if (scopeTable.visibleModules.canFind(nested))
            {
                return *modulePath(expr, nested, scopeTable);
            }
            if (auto symbol = visibleSymbol(object.name, access.member))
            {
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
        if (scopeTable.visibleModules.canFind(name))
        {
            _resolutions[expr.id] = SymbolId(_moduleIds[name]);
            return new Path(Path.Kind.Module, name);
        }
        if (scopeTable.visibleModules.any!(m => m.startsWith(name ~ ".")))
        {
            return new Path(Path.Kind.Package, name);
        }
        return null;
    }
}
