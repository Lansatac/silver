module silver.interpreter.values;

import std.variant : Variant;
import silver.ast : FunctionDecl;
import silver.interpreter.environment : Environment;

/// The runtime value of `()`, e.g. a block that doesn't end in an expression.
struct Unit
{
    string toString() const
    {
        return "()";
    }
}

/// The D implementation behind a `native def`. Arguments are already
/// evaluated and their count checked against the declaration.
alias NativeFunction = Variant delegate(Variant[] args);

class Function
{
    const FunctionDecl declaration;
    Environment closure;
    /// Set when the declaration is `native`; the body is null then.
    NativeFunction native;

    this(const FunctionDecl declaration, Environment closure, NativeFunction native = null)
    {
        this.declaration = declaration;
        this.closure = closure;
        this.native = native;
    }

    override string toString() const
    {
        return declaration.name;
    }
}

/// An imported module, e.g. `math` after `import math`.
class ModuleValue
{
    string name;
    Environment environment;

    this(string name, Environment environment)
    {
        this.name = name;
        this.environment = environment;
    }

    /// Looks up a name defined at the module's top level.
    /// Deliberately does not search parent environments.
    Variant member(string memberName)
    {
        import std.format : format;

        if (auto value = memberName in environment.variables)
        {
            return *value;
        }
        throw new Exception("Module %s has no member %s".format(name, memberName));
    }

    override string toString() const
    {
        return name;
    }
}
