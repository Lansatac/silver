module silver.sema.type;

import std.algorithm : any, map, maxElement;
import std.array : join;
static import std.array;
import std.sumtype;

import silver.ast : Id, TypeDecl, TypeParam;

/// What each type parameter stands for, in a use of a generic declaration.
alias Substitution = Type[Id!TypeParam];

struct Type { private uint index; }

final class TypeTable
{
    private int nextIndex = 1;

    Type error, never, unit, bool_, int_, float_, string_, char_, any;
    Type int8, int16, int32, uint8, uint16, uint32, uint_;
    /// The type of a bare `None`, assignable to every option. No value keeps it: each one is
    /// promoted to the option it lands in.
    Type none;
    /// The type of a bare `[]`, assignable to every array. Its one use is as a promotion's source,
    /// like `none`, but it has a layout: every array has the same one.
    Type emptyArray;

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
        char_ = registerTypeData(TypeData(Primitive(Primitive.Kind.Char)));
        any = registerTypeData(TypeData(Primitive(Primitive.Kind.Any)));
        none = registerTypeData(TypeData(NoneType()));
        emptyArray = registerTypeData(TypeData(EmptyArrayType()));
    }

    private TypeData[int] _types;
    private Type[TypeData] _interned;
    private string[Id!TypeDecl] _nominalNames;
    private string[Id!TypeParam] _parameterNames;


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

    /// `success ! error`. The error side is a type, or a list made by `errorList`.
    Type errorUnion(Type success, Type error)
    {
        return registerTypeData(TypeData(ErrorUnionData(success, error)));
    }

    /// The error list of `members`, which is its one member when there's only one. A member that's
    /// a list itself, as a type parameter can become, contributes its own members, and order and
    /// repeats don't matter.
    Type errorList(const(Type)[] members)
    {
        import std.algorithm : sort, uniq;

        Type[] flat;
        foreach (member; members)
        {
            flat ~= listed(member);
        }
        auto sorted = std.array.array(flat.sort!((a, b) => a.index < b.index).uniq);
        if (sorted.length == 1) return sorted[0];
        return registerTypeData(TypeData(ErrorListData(sorted.idup)));
    }

    /// The type of a bare `Error(e)` with `e: error`, which every error union it fits takes.
    Type failure(Type error)
    {
        return registerTypeData(TypeData(FailureData(error)));
    }

    bool isErrorUnion(Type t) const
    {
        return _types[t.index].match!((const ErrorUnionData _) => true, _ => false);
    }

    /// The `T` of the error union `t`.
    Type successOf(Type t) const
    {
        return _types[t.index].match!(
            (const ErrorUnionData u) => u.success,
            (_) => assert(0, "not an error union"),
        );
    }

    /// The `E` of the error union or failure type `t`.
    Type errorOf(Type t) const
    {
        return _types[t.index].match!(
            (const ErrorUnionData u) => u.error,
            (const FailureData f) => f.error,
            (_) => assert(0, "not an error union"),
        );
    }

    bool isFailure(Type t) const
    {
        return _types[t.index].match!((const FailureData _) => true, _ => false);
    }

    bool isErrorList(Type t) const
    {
        return _types[t.index].match!((const ErrorListData _) => true, _ => false);
    }

    /// What `t` lists, as a list of one when it isn't an error list.
    immutable(Type)[] listed(Type t) const
    {
        return _types[t.index].match!((const ErrorListData l) => l.members, _ => [t].idup);
    }

    Type array(Type element)
    {
        return registerTypeData(TypeData(ArrayData(element)));
    }

    /// `mutables` says which params are `mutable`; it is stored empty when none is, so equal
    /// signatures intern to one type however they were built.
    Type function_(const(Type)[] params, Type ret, const(bool)[] mutables = null)
    {
        import std.algorithm : canFind;

        auto stored = mutables.canFind(true) ? mutables.idup : null;
        return registerTypeData(TypeData(FunctionData(params.idup, ret, stored)));
    }

    bool isFunction(Type t) const
    {
        return _types[t.index].match!((const FunctionData _) => true, _ => false);
    }

    Type tuple(const(Type)[] elements)
    {
        return registerTypeData(TypeData(TupleData(elements.idup)));
    }

    bool isTuple(Type t) const
    {
        return _types[t.index].match!((const TupleData _) => true, _ => false);
    }

    /// The element types of the tuple type `t`.
    immutable(Type)[] tupleElements(Type t) const
    {
        return _types[t.index].match!(
            (const TupleData tuple) => tuple.elements,
            (_) => assert(0, "not a tuple type"),
        );
    }

    /// The type declared by `decl`, with `args` for its type parameters. `name` is only for `describe`,
    /// so it isn't part of the type's identity.
    Type nominal(const(Id!TypeDecl) decl, string name, const(Type)[] args = null)
    {
        _nominalNames[decl] = name;
        return registerTypeData(TypeData(NominalData(decl, args.idup)));
    }

    /// The type a type parameter stands for inside the declaration it belongs to, about which
    /// nothing is known.
    Type parameter(const(Id!TypeParam) param, string name)
    {
        _parameterNames[param] = name;
        return registerTypeData(TypeData(TypeParamData(param)));
    }

    bool isParameter(Type t) const
    {
        return _types[t.index].match!((const TypeParamData _) => true, _ => false);
    }

    /// Whether `t` is or holds a type parameter, so that generic code knows nothing about its values.
    bool mentionsParameter(Type t) const
    {
        return _types[t.index].match!(
            (const TypeParamData _) => true,
            (const OptionData o) => mentionsParameter(o.inner),
            (const ErrorUnionData u) => mentionsParameter(u.success) || mentionsParameter(u.error),
            (const ErrorListData l) => l.members.any!(m => mentionsParameter(m)),
            (const FailureData f) => mentionsParameter(f.error),
            (const ArrayData a) => mentionsParameter(a.element),
            (const FunctionData f) => f.params.any!(p => mentionsParameter(p)) || mentionsParameter(f.ret),
            (const TupleData tuple) => tuple.elements.any!(e => mentionsParameter(e)),
            (const NominalData nominal) => nominal.args.any!(a => mentionsParameter(a)),
            _ => false,
        );
    }

    /// Whether `t` is or holds the type parameter `param`.
    bool mentionsParameter(Type t, Id!TypeParam param) const
    {
        return _types[t.index].match!(
            (const TypeParamData p) => p.param == param,
            (const OptionData o) => mentionsParameter(o.inner, param),
            (const ErrorUnionData u) => mentionsParameter(u.success, param) || mentionsParameter(u.error, param),
            (const ErrorListData l) => l.members.any!(m => mentionsParameter(m, param)),
            (const FailureData f) => mentionsParameter(f.error, param),
            (const ArrayData a) => mentionsParameter(a.element, param),
            (const FunctionData f) => f.params.any!(p => mentionsParameter(p, param)) || mentionsParameter(f.ret, param),
            (const TupleData tuple) => tuple.elements.any!(e => mentionsParameter(e, param)),
            (const NominalData nominal) => nominal.args.any!(a => mentionsParameter(a, param)),
            _ => false,
        );
    }

    /// Whether `t` is or holds `error`, which stands for a type that's already been reported.
    bool mentionsError(Type t) const
    {
        if (t == error) return true;
        return _types[t.index].match!(
            (const OptionData o) => mentionsError(o.inner),
            (const ErrorUnionData u) => mentionsError(u.success) || mentionsError(u.error),
            (const ErrorListData l) => l.members.any!(m => mentionsError(m)),
            (const FailureData f) => mentionsError(f.error),
            (const ArrayData a) => mentionsError(a.element),
            (const FunctionData f) => f.params.any!(p => mentionsError(p)) || mentionsError(f.ret),
            (const TupleData tuple) => tuple.elements.any!(e => mentionsError(e)),
            (const NominalData nominal) => nominal.args.any!(a => mentionsError(a)),
            _ => false,
        );
    }

    /// How deeply other types nest inside `t`: 0 for one with nothing inside it.
    size_t depth(Type t) const
    {
        size_t deepest(const(Type)[] inner) => inner.length == 0 ? 0 : 1 + inner.map!(i => depth(i)).maxElement;
        return _types[t.index].match!(
            (const OptionData o) => deepest([o.inner]),
            (const ErrorUnionData u) => deepest([u.success, u.error]),
            (const ErrorListData l) => deepest(l.members),
            (const FailureData f) => deepest([f.error]),
            (const ArrayData a) => deepest([a.element]),
            (const FunctionData f) => deepest(f.params ~ f.ret),
            (const TupleData tuple) => deepest(tuple.elements),
            (const NominalData nominal) => deepest(nominal.args),
            _ => size_t(0),
        );
    }

    /// `t` with each type parameter in `substitution` replaced by what it stands for.
    Type substitute(Type t, const Substitution substitution)
    {
        if (substitution.length == 0) return t;
        return _types[t.index].match!(
            (const TypeParamData p) {
                auto replaced = p.param in substitution;
                return replaced is null ? t : *replaced;
            },
            (const OptionData o) => option(substitute(o.inner, substitution)),
            (const ErrorUnionData u) => errorUnion(substitute(u.success, substitution), substitute(u.error, substitution)),
            (const ErrorListData l) => errorList(std.array.array(l.members.map!(m => substitute(m, substitution)))),
            (const FailureData f) => failure(substitute(f.error, substitution)),
            (const ArrayData a) => array(substitute(a.element, substitution)),
            (const FunctionData f) => function_(std.array.array(f.params.map!(p => substitute(p, substitution))),
                substitute(f.ret, substitution), f.mutables),
            (const TupleData tuple) => this.tuple(std.array.array(tuple.elements.map!(e => substitute(e, substitution)))),
            (const NominalData nominal) => nominal.args.length == 0 ? t
                : registerTypeData(TypeData(NominalData(nominal.decl,
                    std.array.array(nominal.args.map!(a => substitute(a, substitution))).idup))),
            _ => t,
        );
    }

    /// The type arguments of the declared type `t`, empty for one that isn't generic.
    immutable(Type)[] nominalArgs(Type t) const
    {
        return _types[t.index].match!(
            (const NominalData nominal) => nominal.args,
            (_) => assert(0, "not a declared type"),
        );
    }
    
    const(TypeData) opIndex(Type t) const
    {
        return _types[t.index];
    }

    bool isOption(Type t) const
    {
        return _types[t.index].match!((const OptionData _) => true, _ => false);
    }

    /// The `T` of the option type `t`.
    Type optionInner(Type t) const
    {
        return _types[t.index].match!(
            (const OptionData o) => o.inner,
            (_) => assert(0, "not an option type"),
        );
    }

    bool isArray(Type t) const
    {
        return _types[t.index].match!((const ArrayData _) => true, _ => false);
    }

    /// The `T` of the array type `t`.
    Type arrayElement(Type t) const
    {
        return _types[t.index].match!(
            (const ArrayData a) => a.element,
            (_) => assert(0, "not an array type"),
        );
    }

    bool isInteger(Type t) const
    {
        return _types[t.index].match!(
            (const Primitive p) => p.kind != Primitive.Kind.Char && integerInfo(p.kind).bits != 0,
            _ => false,
        );
    }

    /// The size and signedness of the integer type `t`, or of the integer a `Char` is held as.
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
        import std.range : iota;
        return _types[t.index].match!(
            (const Primitive p) => p.kind.text,
            (const OptionData o) => describeOptionInner(o.inner) ~ "?",
            (const ErrorUnionData u) => describeGrouped(u.success) ~ " ! " ~ describe(u.error),
            (const ErrorListData l) => l.members.map!(m => describeGrouped(m)).join(" | "),
            (const FailureData f) => "Error(" ~ describe(f.error) ~ ")",
            (const NoneType _) => "None",
            (const ArrayData a) => "[" ~ describe(a.element) ~ "]",
            (const EmptyArrayType _) => "[]",
            (const FunctionData f) => "(" ~ f.params.length.iota.map!(i => (f.isMutable(i) ? "mutable " : "") ~ describe(f.params[i])).join(", ")
                ~ ") -> " ~ describe(f.ret),
            (const TupleData t) => "(" ~ t.elements.map!(e => describe(e)).join(", ") ~ ")",
            (const NominalData nd) => _nominalNames[nd.decl]
                ~ (nd.args.length == 0 ? "" : "<" ~ nd.args.map!(a => describe(a)).join(", ") ~ ">"),
            (const TypeParamData p) => _parameterNames[p.param],
            (const ErrorType e) => "Error",
        );
    }

    /// `Int??` doesn't parse and `(Int) -> Int?` returns an option, so these need parentheses.
    private string describeOptionInner(Type inner) const
    {
        auto needsParens = _types[inner.index].match!(
            (const OptionData _) => true,
            (const FunctionData _) => true,
            (const ErrorUnionData _) => true,
            (const ErrorListData _) => true,
            _ => false,
        );
        return needsParens ? "(" ~ describe(inner) ~ ")" : describe(inner);
    }

    /// A type carries one `!`, and `(Int) -> Int ! E` returns an error union, so the success side
    /// or a listed error that's one of those needs parentheses.
    private string describeGrouped(Type part) const
    {
        auto needsParens = _types[part.index].match!(
            (const ErrorUnionData _) => true,
            (const FunctionData _) => true,
            _ => false,
        );
        return needsParens ? "(" ~ describe(part) ~ ")" : describe(part);
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
        Char,
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

/// `bits` is 0 for a kind that isn't held as an integer. A `Char` is, without being one.
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
        case Primitive.Kind.UInt32, Primitive.Kind.Char: return IntegerInfo(32, false);
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
    immutable(bool)[] mutables;

    bool isMutable(size_t i) const => mutables.length > 0 && mutables[i];
}

struct TupleData
{
    immutable(Type)[] elements;
}

struct NominalData
{
    Id!TypeDecl decl;
    /// For a generic type, what its parameters stand for, in order.
    immutable(Type)[] args;
}

/// A type parameter, inside the declaration it belongs to.
struct TypeParamData
{
    Id!TypeParam param;
}

struct NoneType
{
}

struct ArrayData
{
    Type element;
}

struct EmptyArrayType
{
}

struct ErrorType
{
}

/// `T ! E`.
struct ErrorUnionData
{
    Type success;
    Type error;
}

/// `A | B` after `!`: at least two types, ordered by their index so the order written doesn't
/// matter. It's a sum whose members are those types.
struct ErrorListData
{
    immutable(Type)[] members;
}

/// A bare `Error(e)`, before the error union it lands in gives it a success type.
struct FailureData
{
    Type error;
}

alias TypeData = SumType!(Primitive, OptionData, NoneType, ArrayData, EmptyArrayType, FunctionData, NominalData, TupleData,
    ErrorType, TypeParamData, ErrorUnionData, ErrorListData, FailureData);