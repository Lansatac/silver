/// Where the platform's C calling convention puts a native's arguments and finds its result. Both
/// backends follow the description made here: codegen declares the C symbol with the types it gives,
/// and the interpreter loads registers and stack words from it, so the two can't disagree with each
/// other, only both with C.
module silver.core.abi;

import silver.core.nodes : Native, Program;
import silver.sema : Type;

/// A C calling convention for x86-64.
enum Convention
{
    /// Windows': the first four arguments by position, each in its integer register or, for a
    /// floating-point one, its xmm register.
    win64,
    /// System V's, as Linux uses it: six integer and eight xmm registers, each filled in turn.
    systemV,
}

/// The convention of the platform the compiler runs on, which is the one it compiles for.
Convention hostConvention()
{
    version (Windows) return Convention.win64;
    else return Convention.systemV;
}

/// What kind of C value a type or a part of one is.
enum CKind
{
    void_,
    bool_,
    int8,
    uint8,
    int16,
    uint16,
    int32,
    uint32,
    int64,
    uint64,
    pointer,
    /// C's `float`, in the low 32 bits of an xmm register or a stack word.
    float_,
    double_,
    /// A structure, whose `CType.fields` say what it holds. Only a type is one, never a part.
    structure,
    /// A part that is some of a structure's bytes as an integer of `Part.size` bytes, in an integer
    /// register or stack word. Only a part is one.
    integer,
    /// A part that is two of a structure's `float`s, in the low 64 bits of an xmm register. Only a
    /// part is one.
    floatPair,
}

/// A C type: a scalar, or a structure laid out as the platform's C compiler lays it out.
struct CType
{
    CKind kind;
    /// A structure's fields in order, each at its offset.
    const(CField)[] fields;
    /// In bytes, as C's `sizeof` and `_Alignof` give them.
    uint size;
    uint alignment;
}

struct CField
{
    CType type;
    uint offset;
}

/// The C scalar `kind`.
CType scalar(CKind kind)
{
    final switch (kind)
    {
        case CKind.void_: return CType(kind, null, 0, 1);
        case CKind.bool_, CKind.int8, CKind.uint8: return CType(kind, null, 1, 1);
        case CKind.int16, CKind.uint16: return CType(kind, null, 2, 2);
        case CKind.int32, CKind.uint32, CKind.float_: return CType(kind, null, 4, 4);
        case CKind.int64, CKind.uint64, CKind.pointer, CKind.double_: return CType(kind, null, 8, 8);
        case CKind.structure, CKind.integer, CKind.floatPair: assert(0, "not a scalar");
    }
}

/// A structure of `fields` in order, each placed at the next offset its alignment allows, and its
/// size rounded up to the largest alignment, as C lays out a `struct` by default.
CType structure(const(CType)[] fields)
{
    assert(fields.length > 0, "a structure has fields");
    CField[] placed;
    uint offset, alignment = 1;
    foreach (field; fields)
    {
        offset = roundUp(offset, field.alignment);
        placed ~= CField(field, offset);
        offset += field.size;
        if (field.alignment > alignment) alignment = field.alignment;
    }
    return CType(CKind.structure, placed, roundUp(offset, alignment), alignment);
}

private uint roundUp(uint value, uint multiple)
{
    return (value + multiple - 1) / multiple * multiple;
}

/// How a `bool` or an integer narrower than an `int` is widened to 32 bits, as C expects: by the
/// caller for an argument, and by the callee for a result.
enum Extension
{
    none,
    zero,
    sign,
}

enum Where
{
    integerRegister,
    floatRegister,
    /// An 8-byte word of the arguments the caller puts on the stack.
    stack,
}

/// A register or stack word. An argument's integer registers are numbered in the convention's order
/// (`rcx`, `rdx`, `r8`, `r9` on Win64; `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9` on System V) and its
/// float registers from `xmm0`; a result's are `rax` then `rdx`, and `xmm0` then `xmm1`. A stack
/// word counts from the first argument the caller puts there, past Win64's 32 bytes of shadow space.
struct Place
{
    Where where;
    uint index;
}

/// One scalar of an argument or result, in its place: a scalar value's whole, or for a structure the
/// `size` bytes at `offset` of its C layout.
struct Part
{
    CKind type;
    Place place;
    Extension extension;
    uint offset;
    uint size;
}

/// How an argument or result crosses.
enum Passing
{
    /// Nothing does: a `void` result.
    nothing,
    /// The value itself, each of its parts in its place.
    value,
    /// The address of a copy the caller makes, as the one part. Win64 passes a structure that isn't
    /// 1, 2, 4 or 8 bytes this way.
    copy,
    /// Copied onto the stack, each part being one of the words it fills, in order. System V passes a
    /// structure this way when it's over 16 bytes or the registers it needs have run out.
    stack,
    /// A result the callee writes where the caller says, by a pointer passed as the one part ahead of
    /// every argument. A structure that can't come back in registers comes back this way.
    hidden,
}

struct Crossing
{
    Passing passing;
    Part[] parts;
    /// What crosses, whose layout a structure's parts are taken from.
    CType type;
}

/// Where everything of one call goes.
struct CallDescription
{
    Convention convention;
    Crossing[] arguments;
    Crossing result;
    /// How many 8-byte words of arguments go on the stack.
    uint stackWords;
}

/// A call of `native`, as it's declared.
CallDescription describeCall(const ref Program program, const ref Native native, Convention convention)
{
    return describeCall(program, native.params, native.result, convention);
}

/// The call of a native taking `params` and returning `result`, which are its Core types as declared.
CallDescription describeCall(const ref Program program, const(Type)[] params, Type result, Convention convention)
{
    CType[] types;
    foreach (param; params) types ~= cTypeOf(program, param);
    return describeCall(types, cTypeOf(program, result), convention);
}

/// The call of a C function taking `params` and returning `result`.
CallDescription describeCall(const(CType)[] params, CType result, Convention convention)
{
    final switch (convention)
    {
        case Convention.win64: return describeWin64(params, result);
        case Convention.systemV: return describeSystemV(params, result);
    }
}

private CallDescription describeWin64(const(CType)[] params, CType result)
{
    CallDescription call;
    call.convention = Convention.win64;
    // Each argument has a position, and the first four a register of it.
    uint position;
    Place next(bool float_)
    {
        scope (exit) position++;
        if (position >= 4) return Place(Where.stack, call.stackWords++);
        return Place(float_ ? Where.floatRegister : Where.integerRegister, position);
    }

    call.result = resultScalar(result);
    if (result.kind == CKind.structure)
    {
        if (isRegisterSized(result.size))
        {
            call.result = Crossing(Passing.value,
                [Part(CKind.integer, Place(Where.integerRegister, 0), Extension.none, 0, result.size)], result);
        }
        else call.result = Crossing(Passing.hidden, [pointerPart(next(false))], result);
    }
    foreach (param; params)
    {
        assert(param.kind != CKind.void_, "a parameter can't be void");
        if (param.kind != CKind.structure)
        {
            call.arguments ~= Crossing(Passing.value, [scalarPart(param.kind, next(isFloat(param.kind)))], param);
        }
        else if (isRegisterSized(param.size))
        {
            call.arguments ~= Crossing(Passing.value, [Part(CKind.integer, next(false), Extension.none, 0, param.size)], param);
        }
        else call.arguments ~= Crossing(Passing.copy, [pointerPart(next(false))], param);
    }
    return call;
}

/// Whether Win64 passes a structure of `size` bytes in a register, as an integer of its size.
private bool isRegisterSized(uint size)
{
    return size == 1 || size == 2 || size == 4 || size == 8;
}

private CallDescription describeSystemV(const(CType)[] params, CType result)
{
    CallDescription call;
    call.convention = Convention.systemV;
    uint integers, floats;

    call.result = resultScalar(result);
    if (result.kind == CKind.structure)
    {
        auto pieces = piecesOf(result);
        if (pieces is null) call.result = Crossing(Passing.hidden, [pointerPart(Place(Where.integerRegister, integers++))], result);
        else
        {
            uint resultIntegers, resultFloats;
            foreach (ref piece; pieces)
            {
                piece.place = isFloat(piece.type) ? Place(Where.floatRegister, resultFloats++)
                    : Place(Where.integerRegister, resultIntegers++);
            }
            call.result = Crossing(Passing.value, pieces, result);
        }
    }
    foreach (param; params)
    {
        assert(param.kind != CKind.void_, "a parameter can't be void");
        if (param.kind != CKind.structure)
        {
            Place place;
            if (isFloat(param.kind) && floats < 8) place = Place(Where.floatRegister, floats++);
            else if (!isFloat(param.kind) && integers < 6) place = Place(Where.integerRegister, integers++);
            else place = Place(Where.stack, call.stackWords++);
            call.arguments ~= Crossing(Passing.value, [scalarPart(param.kind, place)], param);
            continue;
        }
        auto pieces = piecesOf(param);
        uint neededIntegers, neededFloats;
        foreach (piece; pieces)
        {
            if (isFloat(piece.type)) neededFloats++;
            else neededIntegers++;
        }
        // A structure that doesn't fit in the registers left goes on the stack whole, and leaves them
        // for the arguments after it.
        if (pieces is null || integers + neededIntegers > 6 || floats + neededFloats > 8)
        {
            Part[] words;
            for (uint offset = 0; offset < param.size; offset += 8)
            {
                words ~= Part(CKind.integer, Place(Where.stack, call.stackWords++), Extension.none, offset,
                    offset + 8 <= param.size ? 8 : param.size - offset);
            }
            call.arguments ~= Crossing(Passing.stack, words, param);
            continue;
        }
        foreach (ref piece; pieces)
        {
            piece.place = isFloat(piece.type) ? Place(Where.floatRegister, floats++) : Place(Where.integerRegister, integers++);
        }
        call.arguments ~= Crossing(Passing.value, pieces, param);
    }
    return call;
}

/// A `void` or scalar result, in `rax` or `xmm0`; a structure's is worked out by the convention.
private Crossing resultScalar(CType result)
{
    if (result.kind == CKind.void_) return Crossing(Passing.nothing, null, result);
    if (result.kind == CKind.structure) return Crossing.init;
    auto place = Place(isFloat(result.kind) ? Where.floatRegister : Where.integerRegister, 0);
    return Crossing(Passing.value, [scalarPart(result.kind, place)], result);
}

private Part scalarPart(CKind kind, Place place)
{
    return Part(kind, place, extensionOf(kind), 0, scalar(kind).size);
}

private Part pointerPart(Place place)
{
    return Part(CKind.pointer, place, Extension.none, 0, 8);
}

/// A scalar of a structure, at its offset from the structure's start.
private struct Leaf
{
    CKind kind;
    uint offset;
}

/// Every scalar of the structure `type`, a structure inside it taken apart, in order.
private Leaf[] leavesOf(const CType type, uint at = 0)
{
    Leaf[] leaves;
    foreach (field; type.fields)
    {
        if (field.type.kind == CKind.structure) leaves ~= leavesOf(field.type, at + field.offset);
        else leaves ~= Leaf(field.type.kind, at + field.offset);
    }
    return leaves;
}

/// For System V, the 8-byte pieces of the structure `type` that registers hold, as parts with no
/// place yet, each typed as clang types it; null when it's over 16 bytes and goes in memory. A
/// piece of only floating-point fields goes in an xmm register, and any other in an integer one.
private Part[] piecesOf(const CType type)
{
    if (type.size > 16) return null;
    auto leaves = leavesOf(type);

    const(Leaf)* leafAt(uint offset)
    {
        foreach (ref leaf; leaves) if (leaf.offset == offset) return &leaf;
        return null;
    }

    bool anyBetween(uint from, uint to)
    {
        foreach (leaf; leaves) if (leaf.offset >= from && leaf.offset < to) return true;
        return false;
    }

    Part[] pieces;
    for (uint start = 0; start < type.size; start += 8)
    {
        bool integer;
        foreach (leaf; leaves)
        {
            if (leaf.offset >= start && leaf.offset < start + 8 && !isFloat(leaf.kind)) integer = true;
        }
        auto first = leafAt(start);
        auto left = type.size - start;
        if (integer)
        {
            // A pointer, or an integer with nothing after it in the piece, is its own type; any other
            // piece is an integer of the bytes the structure has there.
            if (first !is null && first.kind == CKind.pointer)
            {
                pieces ~= Part(CKind.pointer, Place.init, Extension.none, start, 8);
                continue;
            }
            if (first !is null)
            {
                auto width = scalar(first.kind).size;
                if (width < 8 && !anyBetween(start + width, start + 8))
                {
                    pieces ~= Part(CKind.integer, Place.init, Extension.none, start, width);
                    continue;
                }
            }
            pieces ~= Part(CKind.integer, Place.init, Extension.none, start, left < 8 ? left : 8);
        }
        else if (first is null || first.kind == CKind.double_)
        {
            pieces ~= Part(CKind.double_, Place.init, Extension.none, start, 8);
        }
        else
        {
            auto second = leafAt(start + 4);
            if (left > 4 && second !is null && second.kind == CKind.float_)
            {
                pieces ~= Part(CKind.floatPair, Place.init, Extension.none, start, 8);
            }
            else pieces ~= Part(CKind.float_, Place.init, Extension.none, start, 4);
        }
    }
    return pieces;
}

/// Whether calls of `a` and `b` pass the same things the same way under `convention`, and neither or
/// both never return: each part in the same place, of the same machine type and extended alike, and
/// a structure in memory of the same size and alignment. So signedness matters only where it decides
/// the extension, and `Int64` and `UInt64` cross alike while `Int8` and `UInt8`, or a pointer and a
/// `UInt64`, don't.
bool crossesAlike(const ref Program program, const ref Native a, const ref Native b, Convention convention)
{
    bool alike(const Crossing x, const Crossing y)
    {
        if (x.passing != y.passing || x.parts.length != y.parts.length) return false;
        if ((x.passing == Passing.copy || x.passing == Passing.stack || x.passing == Passing.hidden)
            && (x.type.size != y.type.size || x.type.alignment != y.type.alignment)) return false;
        foreach (i, part; x.parts)
        {
            auto other = y.parts[i];
            if (part.place != other.place || part.extension != other.extension || part.offset != other.offset
                || machineType(part) != machineType(other)) return false;
        }
        return true;
    }

    auto x = describeCall(program, a, convention);
    auto y = describeCall(program, b, convention);
    if (x.arguments.length != y.arguments.length || !alike(x.result, y.result)) return false;
    foreach (i, argument; x.arguments)
    {
        if (!alike(argument, y.arguments[i])) return false;
    }
    auto never = program.types.never;
    return (a.result == never) == (b.result == never);
}

/// What machine value `part` is, with the signedness of an integer left out, which only its extension
/// says, and a structure's bytes taken as the integer of their size.
private CKind machineType(const Part part)
{
    switch (part.type)
    {
        case CKind.uint8: return CKind.int8;
        case CKind.uint16: return CKind.int16;
        case CKind.uint32: return CKind.int32;
        case CKind.uint64: return CKind.int64;
        case CKind.integer:
            switch (part.size)
            {
                case 1: return CKind.int8;
                case 2: return CKind.int16;
                case 4: return CKind.int32;
                case 8: return CKind.int64;
                default: return CKind.integer;
            }
        default: return part.type;
    }
}

/// The C type of `type`, which sema allows in a native's signature or a structure's field.
CType cTypeOf(const ref Program program, Type type)
{
    auto types = program.types;
    if (type == types.unit || type == types.never) return scalar(CKind.void_);
    if (type == types.bool_) return scalar(CKind.bool_);
    if (type == types.float_) return scalar(CKind.double_);
    if (type == types.float32) return scalar(CKind.float_);
    if (types.isInteger(type))
    {
        auto info = types.integerOf(type);
        switch (info.bits)
        {
            case 8: return scalar(info.signed ? CKind.int8 : CKind.uint8);
            case 16: return scalar(info.signed ? CKind.int16 : CKind.uint16);
            case 32: return scalar(info.signed ? CKind.int32 : CKind.uint32);
            case 64: return scalar(info.signed ? CKind.int64 : CKind.uint64);
            default: assert(0, "an integer is 8, 16, 32 or 64 bits");
        }
    }
    if (type in program.nativeStructures)
    {
        CType[] fields;
        foreach (field; program.recordFields[type]) fields ~= cTypeOf(program, field);
        return structure(fields);
    }
    auto handle = types.isOption(type) ? types.optionInner(type) : type;
    assert((handle in program.nativeTypes) !is null, "sema lets only these types cross into C");
    return scalar(CKind.pointer);
}

bool isFloat(CKind kind)
{
    return kind == CKind.float_ || kind == CKind.double_ || kind == CKind.floatPair;
}

private Extension extensionOf(CKind kind)
{
    switch (kind)
    {
        case CKind.bool_, CKind.uint8, CKind.uint16: return Extension.zero;
        case CKind.int8, CKind.int16: return Extension.sign;
        default: return Extension.none;
    }
}

version (unittest)
{
    private Part inInteger(CKind type, uint index, Extension extension = Extension.none)
    {
        return Part(type, Place(Where.integerRegister, index), extension, 0, scalar(type).size);
    }

    private Part inFloat(CKind type, uint index)
    {
        return Part(type, Place(Where.floatRegister, index), Extension.none, 0, scalar(type).size);
    }

    private Part onStack(CKind type, uint index)
    {
        return Part(type, Place(Where.stack, index), Extension.none, 0, scalar(type).size);
    }

    /// A part of a structure: its `size` bytes at `offset`, in `place`.
    private Part piece(CKind type, Place place, uint offset, uint size)
    {
        return Part(type, place, Extension.none, offset, size);
    }

    private Place integerRegister(uint index) => Place(Where.integerRegister, index);
    private Place floatRegister(uint index) => Place(Where.floatRegister, index);
    private Place stackWord(uint index) => Place(Where.stack, index);

    private CType[] scalars(const CKind[] kinds)
    {
        CType[] types;
        foreach (kind; kinds) types ~= scalar(kind);
        return types;
    }

    private Part[] partsOf(const CallDescription call)
    {
        Part[] parts;
        foreach (argument; call.arguments) parts ~= argument.parts;
        return parts;
    }

    private CType structureOf(const CKind[] kinds...)
    {
        return structure(scalars(kinds));
    }

    // The shapes both conventions are tested over, as C declares them.
    private CType color() => structureOf(CKind.uint8, CKind.uint8, CKind.uint8, CKind.uint8);
    private CType vector2() => structureOf(CKind.float_, CKind.float_);
    private CType rectangle() => structureOf(CKind.float_, CKind.float_, CKind.float_, CKind.float_);
    private CType fiveInts() => structureOf(CKind.int32, CKind.int32, CKind.int32, CKind.int32, CKind.int32);
    private CType intAndFloat() => structureOf(CKind.int32, CKind.float_);
    private CType doubleAndLong() => structureOf(CKind.double_, CKind.int64);
    private CType threeFloats() => structureOf(CKind.float_, CKind.float_, CKind.float_);
    private CType threeBytes() => structureOf(CKind.uint8, CKind.uint8, CKind.uint8);
    private CType line() => structure([vector2, vector2]);
    private CType handles() => structureOf(CKind.pointer, CKind.pointer);
    private CType flags() => structureOf(CKind.bool_, CKind.bool_, CKind.int32);
}

@("Win64 gives each of the first four arguments the register of its position, and the rest stack words in order")
unittest
{
    with (CKind)
    {
        auto call = describeCall(scalars([int64, double_, float_, pointer, int32, double_, float_]), scalar(double_), Convention.win64);
        assert(partsOf(call) == [inInteger(int64, 0), inFloat(double_, 1), inFloat(float_, 2), inInteger(pointer, 3),
            onStack(int32, 0), onStack(double_, 1), onStack(float_, 2)]);
        assert(call.stackWords == 3);
        assert(call.result == Crossing(Passing.value, [inFloat(double_, 0)], scalar(double_)));

        call = describeCall(scalars([double_, double_, double_, double_, double_]), scalar(int32), Convention.win64);
        assert(partsOf(call) == [inFloat(double_, 0), inFloat(double_, 1), inFloat(double_, 2), inFloat(double_, 3),
            onStack(double_, 0)]);
        assert(call.result == Crossing(Passing.value, [inInteger(int32, 0)], scalar(int32)));
    }
}

@("System V fills six integer and eight float registers each in turn, and puts what's left on the stack in order")
unittest
{
    with (CKind)
    {
        CKind[] params = [int64, double_, int32, float_, pointer, uint64, bool_, int64];
        foreach (i; 0 .. 8) params ~= double_;
        params ~= [int64, float_];
        auto call = describeCall(scalars(params), scalar(float_), Convention.systemV);
        auto expected = [inInteger(int64, 0), inFloat(double_, 0), inInteger(int32, 1), inFloat(float_, 1),
            inInteger(pointer, 2), inInteger(uint64, 3), inInteger(bool_, 4, Extension.zero), inInteger(int64, 5)];
        foreach (i; 0 .. 6) expected ~= inFloat(double_, i + 2);
        expected ~= [onStack(double_, 0), onStack(double_, 1), onStack(int64, 2), onStack(float_, 3)];
        assert(partsOf(call) == expected);
        assert(call.stackWords == 4);
        assert(call.result == Crossing(Passing.value, [inFloat(float_, 0)], scalar(float_)));
    }
}

@("a void result is nothing, and a narrow value or a bool is extended by the caller on either convention")
unittest
{
    foreach (convention; [Convention.win64, Convention.systemV])
    {
        with (CKind)
        {
            auto call = describeCall(scalars([int8, uint16, bool_]), scalar(void_), convention);
            assert(partsOf(call) == [inInteger(int8, 0, Extension.sign), inInteger(uint16, 1, Extension.zero),
                inInteger(bool_, 2, Extension.zero)]);
            assert(call.result.passing == Passing.nothing && call.result.parts.length == 0);
            assert(call.stackWords == 0);
            assert(describeCall([], scalar(uint8), convention).result.parts == [inInteger(uint8, 0, Extension.zero)]);
        }
    }
}

@("a structure is laid out as C lays it out: each field at the next offset its alignment allows, and the size rounded to the largest")
unittest
{
    with (CKind)
    {
        assert(color.size == 4 && color.alignment == 1);
        assert(vector2.size == 8 && vector2.alignment == 4 && vector2.fields[1].offset == 4);
        assert(fiveInts.size == 20 && fiveInts.alignment == 4);
        assert(threeBytes.size == 3 && threeBytes.alignment == 1);
        assert(threeFloats.size == 12);
        assert(line.size == 16 && line.fields[1].offset == 8);
        assert(flags.size == 8 && flags.fields[2].offset == 4);
        auto padded = structureOf(uint8, double_, int16);
        assert(padded.fields[1].offset == 8 && padded.fields[2].offset == 16 && padded.size == 24 && padded.alignment == 8);
    }
}

@("Win64 passes a structure of 1, 2, 4 or 8 bytes as an integer of its size, and any other as the address of a copy")
unittest
{
    with (CKind)
    {
        auto call = describeCall([color, vector2, intAndFloat, structureOf(bool_, bool_), rectangle, threeBytes,
            threeFloats, fiveInts, doubleAndLong, line, handles], scalar(void_), Convention.win64);
        assert(call.arguments[0] == Crossing(Passing.value, [piece(integer, integerRegister(0), 0, 4)], color));
        assert(call.arguments[1].parts == [piece(integer, integerRegister(1), 0, 8)]);
        assert(call.arguments[2].parts == [piece(integer, integerRegister(2), 0, 8)]);
        assert(call.arguments[3].parts == [piece(integer, integerRegister(3), 0, 2)]);
        foreach (i, argument; call.arguments[4 .. $])
        {
            assert(argument.passing == Passing.copy);
            assert(argument.parts == [piece(pointer, stackWord(cast(uint) i), 0, 8)]);
        }
        assert(call.stackWords == 7);
    }
}

@("Win64 returns a structure of 1, 2, 4 or 8 bytes in rax, and any other through a hidden first argument")
unittest
{
    with (CKind)
    {
        auto call = describeCall([vector2], vector2, Convention.win64);
        assert(call.result == Crossing(Passing.value, [piece(integer, integerRegister(0), 0, 8)], vector2));
        assert(call.arguments[0].parts == [piece(integer, integerRegister(0), 0, 8)]);

        foreach (result; [rectangle, fiveInts, threeBytes, threeFloats])
        {
            call = describeCall([scalar(double_), color, scalar(int32), scalar(double_)], result, Convention.win64);
            assert(call.result == Crossing(Passing.hidden, [piece(pointer, integerRegister(0), 0, 8)], result));
            assert(partsOf(call) == [inFloat(double_, 1), piece(integer, integerRegister(2), 0, 4), inInteger(int32, 3),
                onStack(double_, 0)]);
        }
    }
}

@("System V passes a structure of up to 16 bytes in 8-byte pieces, each in an xmm register if it's all floating point and an integer register if not, typed as clang types it")
unittest
{
    with (CKind)
    {
        Part[] partsFor(CType type)
        {
            return describeCall([type], scalar(void_), Convention.systemV).arguments[0].parts;
        }

        assert(partsFor(color) == [piece(integer, integerRegister(0), 0, 4)]);
        assert(partsFor(vector2) == [piece(floatPair, floatRegister(0), 0, 8)]);
        assert(partsFor(rectangle) == [piece(floatPair, floatRegister(0), 0, 8), piece(floatPair, floatRegister(1), 8, 8)]);
        assert(partsFor(line) == partsFor(rectangle));
        assert(partsFor(intAndFloat) == [piece(integer, integerRegister(0), 0, 8)]);
        assert(partsFor(doubleAndLong) == [piece(double_, floatRegister(0), 0, 8), piece(integer, integerRegister(0), 8, 8)]);
        assert(partsFor(threeFloats) == [piece(floatPair, floatRegister(0), 0, 8), piece(float_, floatRegister(1), 8, 4)]);
        assert(partsFor(threeBytes) == [piece(integer, integerRegister(0), 0, 3)]);
        assert(partsFor(handles) == [piece(pointer, integerRegister(0), 0, 8), piece(pointer, integerRegister(1), 8, 8)]);
        assert(partsFor(flags) == [piece(integer, integerRegister(0), 0, 8)]);
        assert(partsFor(structureOf(bool_, bool_)) == [piece(integer, integerRegister(0), 0, 2)]);
        // An integer with nothing after it in its piece is that integer, as clang has it.
        assert(partsFor(structureOf(int32, int64)) == [piece(integer, integerRegister(0), 0, 4), piece(integer, integerRegister(1), 8, 8)]);
        assert(partsFor(structureOf(pointer, int32)) == [piece(pointer, integerRegister(0), 0, 8), piece(integer, integerRegister(1), 8, 4)]);
        assert(partsFor(structureOf(float_, double_)) == [piece(float_, floatRegister(0), 0, 4), piece(double_, floatRegister(1), 8, 8)]);

        auto call = describeCall([fiveInts], scalar(void_), Convention.systemV);
        assert(call.arguments[0] == Crossing(Passing.stack, [piece(integer, stackWord(0), 0, 8), piece(integer, stackWord(1), 8, 8),
            piece(integer, stackWord(2), 16, 4)], fiveInts));
        assert(call.stackWords == 3);
    }
}

@("System V puts a structure on the stack whole when the registers it needs have run out, and leaves the rest for later arguments")
unittest
{
    with (CKind)
    {
        // Five doubles leave three xmm registers: a rectangle takes two, the next doesn't fit in one.
        auto params = scalars([double_, double_, double_, double_, double_]) ~ [rectangle, rectangle, scalar(float_)];
        auto call = describeCall(params, scalar(void_), Convention.systemV);
        assert(call.arguments[5].parts == [piece(floatPair, floatRegister(5), 0, 8), piece(floatPair, floatRegister(6), 8, 8)]);
        assert(call.arguments[6] == Crossing(Passing.stack, [piece(integer, stackWord(0), 0, 8), piece(integer, stackWord(1), 8, 8)],
            rectangle));
        assert(call.arguments[7].parts == [inFloat(float_, 7)]);

        // Five integers leave one register, and a structure of two integer pieces needs two.
        params = scalars([int64, int64, int64, int64, int64]) ~ [handles, scalar(int32)];
        call = describeCall(params, scalar(void_), Convention.systemV);
        assert(call.arguments[5].passing == Passing.stack);
        assert(call.arguments[6].parts == [inInteger(int32, 5)]);

        // A mixed structure needs one of each.
        params = scalars([int64, int64, int64, int64, int64, int64]) ~ [doubleAndLong, vector2];
        call = describeCall(params, scalar(void_), Convention.systemV);
        assert(call.arguments[6].passing == Passing.stack);
        assert(call.arguments[7].parts == [piece(floatPair, floatRegister(0), 0, 8)]);
    }
}

@("System V returns a structure of up to 16 bytes in rax, rdx, xmm0 and xmm1 by its pieces, and a larger one through a hidden pointer in rdi")
unittest
{
    with (CKind)
    {
        CallDescription returning(CType result)
        {
            return describeCall([scalar(int64), rectangle], result, Convention.systemV);
        }

        assert(returning(vector2).result.parts == [piece(floatPair, floatRegister(0), 0, 8)]);
        assert(returning(rectangle).result.parts == [piece(floatPair, floatRegister(0), 0, 8), piece(floatPair, floatRegister(1), 8, 8)]);
        assert(returning(doubleAndLong).result.parts == [piece(double_, floatRegister(0), 0, 8), piece(integer, integerRegister(0), 8, 8)]);
        assert(returning(structureOf(int64, double_)).result.parts == [piece(integer, integerRegister(0), 0, 8),
            piece(double_, floatRegister(0), 8, 8)]);
        assert(returning(handles).result.parts == [piece(pointer, integerRegister(0), 0, 8), piece(pointer, integerRegister(1), 8, 8)]);
        assert(returning(threeBytes).result.parts == [piece(integer, integerRegister(0), 0, 3)]);
        assert(returning(color).arguments[0].parts == [inInteger(int64, 0)]);

        auto call = returning(fiveInts);
        assert(call.result == Crossing(Passing.hidden, [piece(pointer, integerRegister(0), 0, 8)], fiveInts));
        assert(partsOf(call) == [inInteger(int64, 1), piece(floatPair, floatRegister(0), 0, 8), piece(floatPair, floatRegister(1), 8, 8)]);
    }
}
