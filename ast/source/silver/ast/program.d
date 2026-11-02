module silver.ast.program;

import silver.ast.diagnostic : SourceMap;
import silver.ast.nodes : FunctionDecl, Module, NodeIds;
import silver.ast.span : Span;

/// Every module a program needs, parsed: the file it was started from, the prelude, and
/// every module imported (transitively). None of them is special; the program's entry
/// point is whichever module defines `main`.
struct Program
{
    /// By dotted name, e.g. "std.math". A file without a `module` line is named after the file.
    /// Pointers because with `Module[string]`, dmd's unittest build of this package
    /// fails to link (a missing `__equals!(Expr, Expr)` instance).
    Module*[string] modules;
    SourceMap sources;
    /// Where every node in the program got its ID, for passes that create nodes later.
    NodeIds ids;
}

auto sortedModules(const ref Program program)
{
    import std.array;
    import std.algorithm;
    import std.range;
    return program.modules.byKey.array.sort!((a, b) => a < b).map!(k => *program.modules[k]);
}

/// A top-level `def main` somewhere in a program.
struct MainFunction
{
    string moduleName;
    Span nameSpan;
}

/// Every top-level `main` in `program`, ordered by module name. A program that runs has exactly one.
MainFunction[] mainFunctions(const ref Program program)
{
    import std.algorithm : sort;
    import std.sumtype : match;

    MainFunction[] found;
    foreach (name, m; program.modules)
    {
        foreach (declaration; m.declarations)
        {
            declaration.kind.match!(
                (const FunctionDecl f) {
                    if (f.name == "main")
                    {
                        found ~= MainFunction(name, f.nameSpan);
                    }
                },
                (_) {},
            );
        }
    }
    found.sort!((a, b) => a.moduleName < b.moduleName);
    return found;
}
