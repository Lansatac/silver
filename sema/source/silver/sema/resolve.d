/// Name resolution: links every identifier and module path to the declaration it names,
/// and records which function each direct call invokes.
module silver.sema.resolve;


import std.algorithm;
import std.array;
import std.string;
import std.sumtype;

import silver.ast;

alias SymbolId = SumType!(Id!FunctionDecl, Id!Param, Id!VarDecl, Id!Module);

/// What name resolution produced.
package struct Resolution
{
    SymbolId[Id!Expr] resolutions;
    Id!FunctionDecl[Id!Expr] callees;
}

/// Resolves every name in `program`, reporting problems to `collector`.
package Resolution resolveNames(const ref Program program, Collector collector)
{
    return new NameResolver(collector).resolveProgram(program);
}

/// The names declared in one module, function, or block. Lookups fall back to the parent.
package final class Scope
{
    private SymbolId[string] _scopeTable;
    private Scope _parent;
    /// The modules visible from here: the enclosing module's imports, plus the prelude.
    private const(string)[] _visibleModules;

    /// A module's top-level scope.
    this(const(string)[] visibleModules)
    {
        _visibleModules = visibleModules;
    }

    /// A function, lambda, or block scope inside `parent`, seeing the same modules.
    this(Scope parent)
    {
        _parent = parent;
        _visibleModules = parent._visibleModules;
    }

    const(string)[] visibleModules() const
    {
        return _visibleModules;
    }

    const(SymbolId)* resolveLocal(string name) const
    {
        return name in _scopeTable;
    }

    const(SymbolId)* resolve(string name) const
    {
        if (auto found = name in _scopeTable)
        {
            return found;
        }
        return _parent is null ? null : _parent.resolve(name);
    }

    void declare(string name, SymbolId id)
    {
        _scopeTable[name] = id;
    }

    override string toString() const
    {
        import std.algorithm : map;
        import std.array : array;

        auto entries = _scopeTable.byKeyValue.map!(kv => format("%s: %s", kv.key, kv.value)).array;
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
    private Id!FunctionDecl[Id!Expr] _callees;
    private Collector _collector;
    /// Each module's own top-level declarations, by module name.
    private Scope[string] _moduleScopes;
    private Id!Module[string] _moduleIds;

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
        foreach (mod; modules)
        {
            resolveModule(mod.name, mod);
        }
        return Resolution(_resolutions, _callees);
    }

    private void declareModule(string name, const Module mod, bool hasPrelude)
    {
        string[] visible = hasPrelude && name != preludeName ? [preludeName] : [];
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl _) {},
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
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl func) {
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
                (const ImportStmt _) {},
            );
        }
        _moduleScopes[name] = moduleScope;
        _moduleIds[name] = mod.id;

        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl func) => reportModuleRootClash(func.name, func.nameSpan, visible),
                (const ImportStmt _) {},
            );
        }
    }

    private void resolveModule(string name, const Module mod)
    {
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl func) {
                    if (func.body !is null)
                    {
                        resolveBody(func.params, *func.body, _moduleScopes[name]);
                    }
                },
                (const ImportStmt _) {},
            );
        }
    }

    /// Resolves a function or lambda body in a new scope holding its params, inside `enclosing`.
    private void resolveBody(const Param[] params, const Expr body, Scope enclosing)
    {
        auto functionScope = new Scope(enclosing);
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
            // Nested defs aren't supported, so a function found here is a module-level one.
            auto what = (*outer).match!(
                (const Id!FunctionDecl _) => "a function in this module",
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

    void resolveStmt(const Stmt stmt, Scope scopeTable)
    {
        stmt.kind.match!(
            (const VarDecl varDecl) {
                resolveExpr(varDecl.value, scopeTable);
                declareLocal(varDecl.name, varDecl.nameSpan, SymbolId(varDecl.id), scopeTable,
                    DiagnosticCode.DuplicateDeclaration, "'%s' is already declared in this scope");
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
            (const FunctionDecl funcDecl) {
                _collector.reportError(DiagnosticCode.InternalError, funcDecl.nameSpan,
                    "Nested function declarations are not supported yet");
            },
        );
    }

    void resolveExpr(const Expr expr, Scope scopeTable)
    {
        expr.kind.match!(
            (const BlockExpr block) {
                Scope blockScope = new Scope(scopeTable);
                foreach (stmt; block.statements)
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
                resolveExpr(*call.callee, scopeTable);
                if (auto symbol = call.callee.id in _resolutions)
                {
                    (*symbol).match!(
                        (const Id!FunctionDecl func) { _callees[expr.id] = func; },
                        (_) {},
                    );
                }
                foreach (arg; call.args)
                {
                    resolveExpr(arg, scopeTable);
                }
            },
            (const UnaryExpr unary) {
                resolveExpr(*unary.operand, scopeTable);
            },
            (const BinaryExpr binary) {
                resolveExpr(*binary.left, scopeTable);
                resolveExpr(*binary.right, scopeTable);
            },
            (const IfExpr ifExpr) {
                resolveExpr(*ifExpr.condition, scopeTable);
                resolveExpr(*ifExpr.trueBody, scopeTable);
                if (ifExpr.falseBody !is null)
                {
                    resolveExpr(*ifExpr.falseBody, scopeTable);
                }
            },
            (const WhileExpr whileExpr) {
                resolveExpr(*whileExpr.condition, scopeTable);
                resolveExpr(*whileExpr.body, scopeTable);
            },
            (const BoolLiteral _) {},
            (const IntLiteral _) {},
            (const FloatLiteral _) {},
            (const StringLiteral _) {},
            (const UnitLiteral _) {},
        );
    }

    private void requireValue(const Expr expr, Path path)
    {
        if (path.kind == Path.Kind.Module || path.kind == Path.Kind.Package)
        {
            _collector.reportError(DiagnosticCode.ModuleIsNotAValue, expr.span,
                "'%s' is a module, not a value".format(path.name));
        }
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
            _resolutions[expr.id] = *local;
            return Path(Path.Kind.Value);
        }

        const(SymbolId)[] found;
        string[] owners;
        foreach (m; scopeTable.visibleModules)
        {
            if (auto symbol = _moduleScopes[m].resolveLocal(name))
            {
                found ~= *symbol;
                owners ~= m;
            }
        }
        if (found.length == 1)
        {
            _resolutions[expr.id] = found[0];
            return Path(Path.Kind.Value);
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
        _collector.reportError(DiagnosticCode.UnknownName, expr.span, "Unknown name '%s'".format(name));
        return Path(Path.Kind.Error);
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
            if (auto symbol = _moduleScopes[object.name].resolveLocal(access.member))
            {
                _resolutions[expr.id] = *symbol;
                return Path(Path.Kind.Value);
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
