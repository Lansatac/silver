module silver.interpreter.environment;

import std.variant : Variant;
import silver.sema : SymbolId;

/// One scope's variables, by declaration, chained to the scope it's nested in. The root holds
/// every module's declarations. Sema has already resolved each use to its declaration, so a
/// lookup that fails here is a bug.
class Environment
{
    Variant[SymbolId] variables;
    Environment parent;

    this(Environment parent = null)
    {
        this.parent = parent;
    }

    void define(SymbolId symbol, Variant value)
    {
        assert(symbol !in variables, "a declaration only runs once per scope");
        variables[symbol] = value;
    }

    void set(SymbolId symbol, Variant value)
    {
        for (auto current = this; current !is null; current = current.parent)
        {
            if (auto slot = symbol in current.variables)
            {
                *slot = value;
                return;
            }
        }
        assert(0, "sema only lets a local be assigned");
    }

    Variant get(SymbolId symbol)
    {
        for (auto current = this; current !is null; current = current.parent)
        {
            if (auto value = symbol in current.variables) return *value;
        }
        assert(0, "sema resolves every name to a declaration in scope");
    }
}
