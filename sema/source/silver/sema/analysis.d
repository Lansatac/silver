module silver.sema.analysis;

import silver.ast;

import std.algorithm : any, canFind, sort, startsWith;
import std.array : join;
import std.string : format;
import std.sumtype : SumType, match;

alias SymbolId = SumType!(Id!FunctionDecl, Id!Param, Id!VarDecl, Id!Module);

version (unittest) import fluent.asserts;

/// Everything sema learned about a Program.
final class Analysis
{
    this(SymbolId[Id!Expr] resolutions, Id!FunctionDecl[Id!Expr] callees)
    {
        _resolutions = resolutions;
        _callees = callees;
    }

    private SymbolId[Id!Expr] _resolutions;
    const(SymbolId[Id!Expr]) resolutions() const
    {
        return _resolutions;
    }

    private Id!FunctionDecl[Id!Expr] _callees;
    /// The function each direct call invokes, keyed by the call expression. Calls through a
    /// value (e.g. a function-typed param) have no entry. Kept apart from `resolutions` so
    /// that overloading, if added, only changes who picks the entry: the type checker.
    const(Id!FunctionDecl[Id!Expr]) callees() const
    {
        return _callees;
    }
}

/// The names declared in one module, function, or block. Lookups fall back to the parent.
final class Scope
{
    private SymbolId[string] _scopeTable;
    private Scope _parent;
    this(Scope parent = null)
    {
        _parent = parent;
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

final class Analyzer
{
    private enum preludeName = "prelude";

    private SymbolId[Id!Expr] _resolutions;
    private Id!FunctionDecl[Id!Expr] _callees;
    private Collector _collector;
    /// Each module's own top-level declarations, by module name.
    private Scope[string] _moduleScopes;
    private Id!Module[string] _moduleIds;
    /// The modules each module can see: its imports, plus the prelude.
    private string[][string] _visibleModules;
    /// The module whose function bodies are being resolved.
    private string _currentModule;

    this(Collector collector)
    {
        _collector = collector;
    }

    Analysis analyzeProgram(const Program program)
    {
        // Sorted so diagnostics come out in the same order every run.
        auto names = program.modules.keys.sort;
        foreach (name; names)
        {
            declareModule(name, *program.modules[name], (preludeName in program.modules) !is null);
        }
        foreach (name; names)
        {
            analyzeModule(name, *program.modules[name]);
        }
        return new Analysis(_resolutions, _callees);
    }

    private void declareModule(string name, const Module mod, bool hasPrelude)
    {
        auto moduleScope = new Scope();
        string[] visible = hasPrelude && name != preludeName ? [preludeName] : [];
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
                (const ImportStmt importStmt) {
                    auto imported = importStmt.path.join(".");
                    if (!visible.canFind(imported))
                    {
                        visible ~= imported;
                    }
                },
            );
        }
        _moduleScopes[name] = moduleScope;
        _moduleIds[name] = mod.id;
        _visibleModules[name] = visible;

        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl func) => reportModuleRootClash(func.name, func.nameSpan, visible),
                (const ImportStmt _) {},
            );
        }
    }

    private void analyzeModule(string name, const Module mod)
    {
        _currentModule = name;
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl func) => analyzeFunction(func, _moduleScopes[name]),
                (const ImportStmt _) {},
            );
        }
    }

    private void analyzeFunction(const FunctionDecl func, Scope moduleScope)
    {
        auto functionScope = new Scope(moduleScope);
        foreach (param; func.params)
        {
            declareLocal(param.name, param.nameSpan, SymbolId(param.id), functionScope,
                DiagnosticCode.DuplicateParameter, "'%s' is already a parameter of this function");
        }
        if (func.body !is null)
        {
            analyzeExpr(*func.body, functionScope);
        }
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
            reportModuleRootClash(name, span, _visibleModules[_currentModule]);
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

    void analyzeStmt(const Stmt stmt, Scope scopeTable)
    {
        stmt.kind.match!(
            (const VarDecl varDecl) {
                analyzeExpr(varDecl.value, scopeTable);
                declareLocal(varDecl.name, varDecl.nameSpan, SymbolId(varDecl.id), scopeTable,
                    DiagnosticCode.DuplicateDeclaration, "'%s' is already declared in this scope");
            },
            (const ExprStmt exprStmt) {
                analyzeExpr(exprStmt.expr, scopeTable);
            },
            (const AssignStmt assignStmt) {
                analyzeExpr(assignStmt.target, scopeTable);
                analyzeExpr(assignStmt.value, scopeTable);
            },
            (const ReturnStmt returnStmt) {
                analyzeExpr(returnStmt.value, scopeTable);
            },
            (const FunctionDecl funcDecl) {
                _collector.reportError(DiagnosticCode.InternalError, funcDecl.nameSpan,
                    "Nested function declarations are not supported yet");
            },
        );
    }

    void analyzeExpr(const Expr expr, Scope scopeTable)
    {
        expr.kind.match!(
            (const BlockExpr block) {
                Scope blockScope = new Scope(scopeTable);
                foreach (stmt; block.statements)
                {
                    analyzeStmt(stmt, blockScope);
                }
                if (block.value !is null)
                {
                    analyzeExpr(*block.value, blockScope);
                }
            },
            (const Identifier _) => requireValue(expr, resolvePath(expr, scopeTable)),
            (const MemberAccess _) => requireValue(expr, resolvePath(expr, scopeTable)),
            (const CallExpr call) {
                analyzeExpr(*call.callee, scopeTable);
                if (auto symbol = call.callee.id in _resolutions)
                {
                    (*symbol).match!(
                        (const Id!FunctionDecl func) { _callees[expr.id] = func; },
                        (_) {},
                    );
                }
                foreach (arg; call.args)
                {
                    analyzeExpr(arg, scopeTable);
                }
            },
            (const UnaryExpr unary) {
                analyzeExpr(*unary.operand, scopeTable);
            },
            (const BinaryExpr binary) {
                analyzeExpr(*binary.left, scopeTable);
                analyzeExpr(*binary.right, scopeTable);
            },
            (const IfExpr ifExpr) {
                analyzeExpr(*ifExpr.condition, scopeTable);
                analyzeExpr(*ifExpr.trueBody, scopeTable);
                if (ifExpr.falseBody !is null)
                {
                    analyzeExpr(*ifExpr.falseBody, scopeTable);
                }
            },
            (const WhileExpr whileExpr) {
                analyzeExpr(*whileExpr.condition, scopeTable);
                analyzeExpr(*whileExpr.body, scopeTable);
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
                analyzeExpr(expr, scopeTable);
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
        foreach (m; visibleModules)
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

        if (auto path = modulePath(expr, name))
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
            if (visibleModules.canFind(nested))
            {
                return *modulePath(expr, nested);
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
            if (auto path = modulePath(expr, name))
            {
                return *path;
            }
            _collector.reportError(DiagnosticCode.UnknownName, expr.span,
                "No imported module is named '%s'".format(name));
            return Path(Path.Kind.Error);
        }
    }

    /// `name` as a visible module (recording the resolution) or a prefix of one, else null.
    private Path* modulePath(const Expr expr, string name)
    {
        if (visibleModules.canFind(name))
        {
            _resolutions[expr.id] = SymbolId(_moduleIds[name]);
            return new Path(Path.Kind.Module, name);
        }
        if (visibleModules.any!(m => m.startsWith(name ~ ".")))
        {
            return new Path(Path.Kind.Package, name);
        }
        return null;
    }

    private const(string)[] visibleModules()
    {
        return _visibleModules[_currentModule];
    }
}

/// Analyzes every module in `program`, reporting problems to `collector`.
Analysis analyze(const ref Program program, Collector collector)
{
    import silver.sema.entry : checkEntryPoint;

    checkEntryPoint(program, collector);
    auto analyzer = new Analyzer(collector);
    return analyzer.analyzeProgram(program);
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

@("analyze accepts a minimal program")
unittest
{
    auto collector = analyzeSource("def main(): Unit => ()");
    collector.diagnostics.length.should.equal(0);
}

@("analyze reports a function declared twice in the entry module, at the second name")
unittest
{
    import std.array : array;
    import std.string : lastIndexOf;

    auto source = "def twice(): Int => 1
def twice(): Int => 2
def main(): Unit => ()";
    auto errors = analyzeSource(source).errors.array;

    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.DuplicateDeclaration);
    errors[0].message.should.contain("'twice'");
    auto secondName = source.lastIndexOf("twice");
    errors[0].span.should.equal(Span("main.ag", secondName, secondName + "twice".length));
}
