module silver.interpreter.environment;

import std.format : format;
import std.variant : Variant;

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
        if (name in variables)
        {
            return variables[name];
        }
        else if (parent !is null)
        {
            return parent.resolveVariable(name);
        }
        else
        {
            throw new Exception("Variable '%s' not found".format(name));
        }
    }
}
