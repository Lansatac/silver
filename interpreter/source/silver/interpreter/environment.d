module silver.interpreter.environment;

import std.variant : Variant;
import silver.interpreter.values : ModuleValue;

/// One scope's variables, chained to the scope it's nested in. Sema has already checked every
/// declaration and assignment, so a lookup that fails here is a bug.
class Environment
{
    Variant[string] variables;
    Environment parent;

    this(Environment parent = null)
    {
        this.parent = parent;
    }

    void defineVariable(string name, Variant value)
    {
        assert(name !in variables, "sema reports a duplicate declaration");
        variables[name] = value;
    }

    void setVariable(string name, Variant value)
    {
        if (name in variables)
        {
            variables[name] = value;
            return;
        }
        assert(parent !is null, "sema only lets a local be assigned");
        parent.setVariable(name, value);
    }

    /// The variable `name` in this scope or an enclosing one, or null.
    Variant* find(string name)
    {
        if (auto value = name in variables)
        {
            return value;
        }
        return parent is null ? null : parent.find(name);
    }
}

/// The names a module gets from its imports, the prelude among them, searched after the
/// module's own definitions. Each module has its own, so imports aren't transitive.
class ImportScope : Environment
{
    /// By dotted name.
    ModuleValue[string] modules;

    override Variant* find(string name)
    {
        Variant* found;
        foreach (imported; modules)
        {
            if (auto value = name in imported.environment.variables)
            {
                assert(found is null, "sema reports a name that's ambiguous between imports");
                found = value;
            }
        }
        return found;
    }

    /// The import scope that `environment`'s lookups end in.
    static ImportScope of(Environment environment)
    {
        for (auto current = environment; current !is null; current = current.parent)
        {
            if (auto imports = cast(ImportScope) current)
            {
                return imports;
            }
        }
        assert(false, "Every environment chain ends in an ImportScope");
    }
}
