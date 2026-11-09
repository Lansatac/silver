module silver.interpreter.environment;

import std.variant : Variant;
import silver.sema : SymbolId;

/// The storage of a mutable variable that a lambda shares with the code around it
/// (`Analysis.isBoxed`). The variable's environment and each capturing closure's hold the same box.
final class Box
{
    Variant value;

    this(Variant value)
    {
        this.value = value;
    }
}

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

    void define(SymbolId symbol, Variant value, bool boxed = false)
    {
        assert(symbol !in variables, "a declaration only runs once per scope");
        variables[symbol] = boxed ? Variant(new Box(value)) : value;
    }

    void set(SymbolId symbol, Variant value)
    {
        for (auto current = this; current !is null; current = current.parent)
        {
            if (auto slot = symbol in current.variables)
            {
                if (auto box = slot.peek!Box) box.value = value;
                else *slot = value;
                return;
            }
        }
        assert(0, "sema only lets a local be assigned");
    }

    Variant get(SymbolId symbol)
    {
        auto slot = stored(symbol);
        if (auto box = slot.peek!Box) return box.value;
        return slot;
    }

    /// What the scope holds for `symbol`: its value, or its box when it has one. A closure
    /// captures this, so it copies a value and shares a box.
    Variant stored(SymbolId symbol)
    {
        for (auto current = this; current !is null; current = current.parent)
        {
            if (auto value = symbol in current.variables) return *value;
        }
        assert(0, "sema resolves every name to a declaration in scope");
    }
}
