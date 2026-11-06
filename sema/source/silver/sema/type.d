module silver.sema.type;

import std.sumtype;

import silver.ast : Id, TypeDecl;

struct Type { private uint index; }

final class TypeTable
{
    private int nextIndex = 1;

    Type error, never, unit, bool_, int_, float_, string_, any;
    Type int8, int16, int32, uint8, uint16, uint32, uint_;

    this()
    {
        int8 = registerTypeData(TypeData(Primitive(Primitive.Kind.Int8)));
        int16 = registerTypeData(TypeData(Primitive(Primitive.Kind.Int16)));
        int32 = registerTypeData(TypeData(Primitive(Primitive.Kind.Int32)));
        uint8 = registerTypeData(TypeData(Primitive(Primitive.Kind.UInt8)));
        uint16 = registerTypeData(TypeData(Primitive(Primitive.Kind.UInt16)));
        uint32 = registerTypeData(TypeData(Primitive(Primitive.Kind.UInt32)));
        uint_ = registerTypeData(TypeData(Primitive(Primitive.Kind.UInt)));
        error = registerTypeData(TypeData(ErrorType()));
        never = registerTypeData(TypeData(Primitive(Primitive.Kind.Never)));
        unit = registerTypeData(TypeData(Primitive(Primitive.Kind.Unit)));
        bool_ = registerTypeData(TypeData(Primitive(Primitive.Kind.Bool)));
        int_ = registerTypeData(TypeData(Primitive(Primitive.Kind.Int)));
        float_ = registerTypeData(TypeData(Primitive(Primitive.Kind.Float)));
        string_ = registerTypeData(TypeData(Primitive(Primitive.Kind.String)));
        any = registerTypeData(TypeData(Primitive(Primitive.Kind.Any)));
    }

    private TypeData[int] _types;
    private Type[TypeData] _interned;
    private string[Id!TypeDecl] _nominalNames;


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

    /// The type declared by `decl`. `name` is only for `describe`, so it isn't part of the type's identity.
    Type nominal(const(Id!TypeDecl) decl, string name)
    {
        _nominalNames[decl] = name;
        return registerTypeData(TypeData(NominalData(decl)));
    }
    
    const(TypeData) opIndex(Type t) const
    {
        return _types[t.index];
    }

    bool isInteger(Type t) const
    {
        return _types[t.index].match!(
            (const Primitive p) => integerInfo(p.kind).bits != 0,
            _ => false,
        );
    }

    /// The size and signedness of the integer type `t`.
    IntegerInfo integerOf(Type t) const
    {
        return _types[t.index].match!(
            (const Primitive p) => integerInfo(p.kind),
            (_) => assert(0, "not an integer type"),
        );
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
            (const NominalData nd) => _nominalNames[nd.decl],
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
        Any,
        Int8,
        Int16,
        Int32,
        UInt8,
        UInt16,
        UInt32,
        UInt,
    }
    Kind kind;
}

struct IntegerInfo
{
    uint bits;
    bool signed;

    ulong maxValue() const
    {
        return signed ? (1UL << (bits - 1)) - 1 : ulong.max >> (64 - bits);
    }

    /// The most negative value, as a magnitude. Zero for an unsigned type.
    ulong minMagnitude() const
    {
        return signed ? 1UL << (bits - 1) : 0;
    }
}

/// `bits` is 0 for a kind that isn't an integer.
private IntegerInfo integerInfo(Primitive.Kind kind)
{
    switch (kind)
    {
        case Primitive.Kind.Int8: return IntegerInfo(8, true);
        case Primitive.Kind.Int16: return IntegerInfo(16, true);
        case Primitive.Kind.Int32: return IntegerInfo(32, true);
        case Primitive.Kind.Int: return IntegerInfo(64, true);
        case Primitive.Kind.UInt8: return IntegerInfo(8, false);
        case Primitive.Kind.UInt16: return IntegerInfo(16, false);
        case Primitive.Kind.UInt32: return IntegerInfo(32, false);
        case Primitive.Kind.UInt: return IntegerInfo(64, false);
        default: return IntegerInfo(0, false);
    }
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

struct NominalData
{
    Id!TypeDecl decl;
}

struct ErrorType
{
}

alias TypeData = SumType!(Primitive, OptionData, FunctionData, NominalData, ErrorType);