module silver.ast.program;

import silver.ast.diagnostic : SourceMap;
import silver.ast.nodes : Module;

/// Every module a program needs, parsed: the entry module, plus the prelude and
/// every module imported (transitively), by dotted name, e.g. "math" or "a.b".
/// `modules` doesn't include `main`, even if a module imports it by name.
struct Program
{
    Module main;
    /// Pointers because with `Module[string]`, dmd's unittest build of this package
    /// fails to link (a missing `__equals!(Expr, Expr)` instance).
    Module*[string] modules;
    SourceMap sources;
}
