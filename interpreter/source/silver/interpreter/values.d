module silver.interpreter.values;

import std.variant : Variant;
import silver.ast : Expr, Param, TypeDecl;
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
/// evaluated, and sema has checked them against the declaration.
alias NativeFunction = Variant delegate(Variant[] args);

class Function
{
    string name;
    const(Param)[] params;
    /// Null when `native` is set.
    const(Expr)* body;
    /// A Unit function's value is dropped, whatever its body ended in.
    bool returnsUnit;
    Environment closure;
    NativeFunction native;

    this(string name, const(Param)[] params, const(Expr)* body, bool returnsUnit, Environment closure,
        NativeFunction native = null)
    {
        this.name = name;
        this.params = params;
        this.body = body;
        this.returnsUnit = returnsUnit;
        this.closure = closure;
        this.native = native;
    }

    override string toString() const
    {
        return name;
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

    Variant fieldAt(size_t index)
    {
        return fields[index];
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
        foreach (i, field; constructor.declaration.fields)
        {
            if (field.name == name)
            {
                return i;
            }
        }
        assert(0, "sema reports an unknown field");
    }

    override string toString()
    {
        import std.algorithm : map;
        import std.array : join;
        import silver.interpreter.stack : checkStack;

        checkStack();
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

/// A value of an array type: a slice of a D array. Like an Instance it never changes, and appending
/// is safe to share, since D only extends a slice in place when it ends where its buffer's used part does.
final class ArrayValue
{
    Variant[] elements;

    this(Variant[] elements)
    {
        this.elements = elements;
    }

    override string toString()
    {
        import std.algorithm : map;
        import std.array : join;

        return "[" ~ elements.map!(e => e.toString()).join(", ") ~ "]";
    }
}

/// A value of a sum type: which member it is, and that member's value. Like an Instance it never changes.
final class SumValue
{
    size_t index;
    Variant member;

    this(size_t index, Variant member)
    {
        this.index = index;
        this.member = member;
    }

    override string toString()
    {
        return member.toString();
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
        auto value = memberName in environment.variables;
        assert(value !is null, "sema reports an unknown module member");
        return *value;
    }

    override string toString() const
    {
        return name;
    }
}

/// A value of a tuple type. Like an Instance it never changes.
final class TupleValue
{
    Variant[] elements;

    this(Variant[] elements)
    {
        this.elements = elements;
    }

    override string toString()
    {
        import std.algorithm : map;
        import std.array : join;

        return "(" ~ elements.map!(e => e.toString()).join(", ") ~ ")";
    }
}
