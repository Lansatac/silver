module silver.ast.program;

import silver.ast.diagnostic : SourceMap;
import silver.ast.id : Id;
import silver.ast.nodes : FunctionDecl, Module;
import silver.ast.span : Span;

/// Every module a program needs, parsed: the file it was started from, `lang`, the prelude, and
/// every module imported (transitively). The program's entry point is whichever module defines
/// `main`.
struct Program
{
    /// The module every module outside `lang` imports without saying so, as the build named it,
    /// or null for none.
    string prelude;
    /// By dotted name, e.g. "std.math". A file without a `module` line is named after the file.
    /// Pointers because with `Module[string]`, dmd's unittest build of this package
    /// fails to link (a missing `__equals!(Expr, Expr)` instance).
    Module*[string] modules;
    SourceMap sources;
    /// The module loading started from, whose tests `silver test` runs.
    string entryModule;
}

auto sortedModules(const ref Program program)
{
    import std.array;
    import std.algorithm;
    import std.range;
    return program.modules.byKey.array.sort!((a, b) => a < b).map!(k => *program.modules[k]);
}

/// The package the compiler knows by name, which ships with it. Its root module is imported by
/// every other module without saying so, and only its modules may declare intrinsics.
enum langPackage = "lang";

/// Whether the module `name` belongs to `lang`.
bool isInLang(string name)
{
    import std.algorithm : startsWith;
    return name == langPackage || name.startsWith(langPackage ~ ".");
}

/// What the companion test file of the module `name` is called among a program's modules. No
/// import can name it, and it's in `lang` when its module is.
string companionName(string name)
{
    return name ~ ".(test)";
}

/// A top-level `def main` somewhere in a program.
struct MainFunction
{
    Id!FunctionDecl id;
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
                        found ~= MainFunction(f.id, name, f.nameSpan);
                    }
                },
                (_) {},
            );
        }
    }
    found.sort!((a, b) => a.moduleName < b.moduleName);
    return found;
}
