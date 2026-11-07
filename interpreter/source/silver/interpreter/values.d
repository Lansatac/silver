module silver.interpreter.values;

import std.variant : Variant;
import silver.ast : DiagnosticCode, FunctionDecl, TypeDecl;
import silver.interpreter.environment : Environment;
import silver.interpreter.errors : CodedException;

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

/// What a `type` declaration with fields binds its name to.
class Constructor
{
    const TypeDecl declaration;

    this(const TypeDecl declaration)
    {
        this.declaration = declaration;
    }

    override string toString() const
    {
        return declaration.name;
    }
}

/// A value of a `type`. Never changes once built, so sharing one between bindings can't be
/// observed: that's what gives `type` value semantics. Field assignment builds a new one.
class Instance
{
    private Constructor constructor;
    private Variant[] fields;

    this(Constructor constructor, Variant[] fields)
    {
        this.constructor = constructor;
        this.fields = fields;
    }

    Variant field(string name)
    {
        return fields[indexOf(name)];
    }

    /// A copy of this value with the field `name` replaced.
    Instance withField(string name, Variant value)
    {
        auto copy = fields.dup;
        copy[indexOf(name)] = value;
        return new Instance(constructor, copy);
    }

    /// Whether each field equals the same field of `other`, a value of the same type.
    bool fieldsEqual(Instance other, scope bool delegate(Variant, Variant) equal)
    {
        foreach (i, field; fields)
        {
            if (!equal(field, other.fields[i]))
            {
                return false;
            }
        }
        return true;
    }

    private size_t indexOf(string name)
    {
        import std.format : format;

        foreach (i, field; constructor.declaration.fields)
        {
            if (field.name == name)
            {
                return i;
            }
        }
        throw new CodedException(DiagnosticCode.UnknownMember, "%s has no member %s".format(constructor, name));
    }

    override string toString()
    {
        import std.algorithm : map;
        import std.array : join;

        auto name = constructor.toString();
        return fields.length == 0 ? name : name ~ "(" ~ fields.map!(f => f.toString()).join(", ") ~ ")";
    }
}

/// A value of an option type, which is never a D null. Like an Instance it never changes.
final class OptionValue
{
    private bool _present;
    private Variant _payload;

    private this(bool present, Variant payload)
    {
        _present = present;
        _payload = payload;
    }

    static OptionValue some(Variant payload)
    {
        return new OptionValue(true, payload);
    }

    static OptionValue none()
    {
        return new OptionValue(false, Variant.init);
    }

    bool present()
    {
        return _present;
    }

    Variant payload()
    {
        return _payload;
    }

    override string toString()
    {
        return _present ? "Some(" ~ _payload.toString() ~ ")" : "None";
    }
}

/// A loaded module. Not a Silver value: `std.math` is resolved by name, never evaluated.
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
        throw new CodedException(DiagnosticCode.UnknownModuleMember, "Module %s has no member %s".format(name, memberName));
    }

    override string toString() const
    {
        return name;
    }
}
