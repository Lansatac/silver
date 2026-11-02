module silver.sema.type;

import std.sumtype;

struct Type { private uint index; }

final class TypeTable
{
    int nextIndex = 1;

    Type error, never, unit, bool_, int_, float_, string_, any;

    this()
    {
        error = registerTypeData(TypeData(ErrorType()));
        never = registerTypeData(TypeData(Primitive(Primitive.Kind.Never)));
        unit = registerTypeData(TypeData(Primitive(Primitive.Kind.Unit)));
        bool_ = registerTypeData(TypeData(Primitive(Primitive.Kind.Bool)));
        int_ = registerTypeData(TypeData(Primitive(Primitive.Kind.Int)));
        float_ = registerTypeData(TypeData(Primitive(Primitive.Kind.Float)));
        string_ = registerTypeData(TypeData(Primitive(Primitive.Kind.String)));
        any = registerTypeData(TypeData(Primitive(Primitive.Kind.Any)));
    }

    TypeData[int] _types;
    Type[TypeData] _interned;


    private Type registerTypeData(TypeData data)
    {
        if (auto existing = data in _interned) return *existing;
        auto type = Type(nextIndex);
        nextIndex += 1;
        _types[type.index] = data;
        _interned[data] = type;
        return type;
    }
    
    Type option(Type inner)
    {
        return registerTypeData(TypeData(OptionData(inner)));
    }

    Type function_(const(Type)[] params, Type ret)
    {
        return registerTypeData(TypeData(FunctionData(params.idup, ret)));
    }
    
    const(TypeData) opIndex(Type t) const
    {
        return _types[t.index];
    }

    string describe(Type t) const
    {
        import std.conv : text;
        import std.array : join;
        import std.algorithm : map;
        return _types[t.index].match!(
            (const Primitive p) => p.kind.text,
            (const OptionData o) => describe(o.inner) ~ "?",
            (const FunctionData f) => "(" ~ f.params.map!(p => describe(p)).join(", ") ~ ") -> " ~ describe(f.ret),
            (const ErrorType e) => "Error",
        );
    }
}

struct Primitive
{
    enum Kind : uint
    {
        Never,
        Unit,
        Bool,
        Int,
        Float,
        String,
        Any
    }
    Kind kind;
}

struct OptionData
{
    Type inner;
}

struct FunctionData
{
    immutable(Type)[] params;
    Type ret;
}

struct ErrorType
{
}

alias TypeData = SumType!(Primitive, OptionData, FunctionData, ErrorType);