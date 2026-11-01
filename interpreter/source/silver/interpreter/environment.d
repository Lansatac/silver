module silver.interpreter.environment;

import std.format : format;
import std.variant : Variant;
import silver.interpreter.values : ModuleValue;

/// One scope's variables, chained to the scope it's nested in.
class Environment
{
    Variant[string] variables;
    /// Names declared with `val`, which can't be reassigned.
    bool[string] immutables;
    Environment parent;

    this(Environment parent = null)
    {
        this.parent = parent;
    }

    void defineVariable(string name, Variant value, bool mutable = true)
    {
        if (name in variables)
        {
            throw new Exception("Duplicate declaration of variable %s".format(name));
        }
        variables[name] = value;
        if (!mutable)
        {
            immutables[name] = true;
        }
    }

    void setVariable(string name, Variant value)
    {
        if (name in variables)
        {
            if (name in immutables)
            {
                throw new Exception("Cannot assign to val '%s'. Declare as 'mutable val' to reassign it.".format(name));
            }
            variables[name] = value;
        }
        else if (parent !is null)
        {
            parent.setVariable(name, value);
        }
        else
        {
            throw new Exception("Variable '%s' not found".format(name));
        }
    }

    Variant resolveVariable(string name)
    {
        if (auto value = find(name))
        {
            return *value;
        }
        throw new Exception("Variable '%s' not found".format(name));
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

/// The names a module gets from its imports and then the prelude, searched after the
/// module's own definitions. Each module has its own, so imports aren't transitive.
class ImportScope : Environment
{
    /// By dotted name.
    ModuleValue[string] modules;
    /// Searched after every import, so an import can shadow the prelude. Null for the prelude itself.
    Environment prelude;

    this(Environment prelude)
    {
        super(null);
        this.prelude = prelude;
    }

    /// Throws: if more than one imported module defines `name`.
    override Variant* find(string name)
    {
        import std.algorithm : sort;
        import std.array : join;

        Variant* found;
        string[] owners;
        foreach (moduleName, imported; modules)
        {
            if (auto value = name in imported.environment.variables)
            {
                found = value;
                owners ~= moduleName;
            }
        }
        if (owners.length > 1)
        {
            throw new Exception("'%s' is ambiguous: it's defined in %s".format(name, owners.sort.join(", ")));
        }
        if (found is null && prelude !is null)
        {
            found = name in prelude.variables;
        }
        return found;
    }

    override void setVariable(string name, Variant value)
    {
        if (find(name) !is null)
        {
            throw new Exception("Cannot assign to imported '%s'".format(name));
        }
        throw new Exception("Variable '%s' not found".format(name));
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
