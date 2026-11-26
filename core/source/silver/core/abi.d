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

/// What C calls a native's parameter or result.
enum CType
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

/// One scalar of an argument or result, in its place.
struct Part
{
    CType type;
    Place place;
    Extension extension;
}

/// How an argument or result crosses.
enum Passing
{
    /// Nothing does: a `void` result.
    nothing,
    /// The value itself, each of its parts in its place.
    value,
}

struct Crossing
{
    Passing passing;
    Part[] parts;
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
    assert(!params.canFindVoid, "a parameter can't be void");
    CallDescription call;
    call.convention = convention;
    uint integers, floats;
    foreach (position, param; params)
    {
        Place place;
        final switch (convention)
        {
            case Convention.win64:
                if (position < 4) place = Place(isFloat(param) ? Where.floatRegister : Where.integerRegister, cast(uint) position);
                else place = Place(Where.stack, call.stackWords++);
                break;
            case Convention.systemV:
                if (isFloat(param) && floats < 8) place = Place(Where.floatRegister, floats++);
                else if (!isFloat(param) && integers < 6) place = Place(Where.integerRegister, integers++);
                else place = Place(Where.stack, call.stackWords++);
                break;
        }
        call.arguments ~= Crossing(Passing.value, [Part(param, place, extensionOf(param))]);
    }
    if (result == CType.void_) call.result = Crossing(Passing.nothing);
    else
    {
        auto place = Place(isFloat(result) ? Where.floatRegister : Where.integerRegister, 0);
        call.result = Crossing(Passing.value, [Part(result, place, extensionOf(result))]);
    }
    return call;
}

/// Whether C passes the parameters and result of `a` and `b` alike, and neither or both never return.
bool sameCSignature(const ref Program program, const ref Native a, const ref Native b)
{
    if (a.params.length != b.params.length) return false;
    foreach (i, param; a.params)
    {
        if (cTypeOf(program, param) != cTypeOf(program, b.params[i])) return false;
    }
    auto never = program.types.never;
    return cTypeOf(program, a.result) == cTypeOf(program, b.result) && (a.result == never) == (b.result == never);
}

/// The C type of `type`, which sema allows in a native's signature.
CType cTypeOf(const ref Program program, Type type)
{
    auto types = program.types;
    if (type == types.unit || type == types.never) return CType.void_;
    if (type == types.bool_) return CType.bool_;
    if (type == types.float_) return CType.double_;
    if (type == types.float32) return CType.float_;
    if (types.isInteger(type))
    {
        auto info = types.integerOf(type);
        switch (info.bits)
        {
            case 8: return info.signed ? CType.int8 : CType.uint8;
            case 16: return info.signed ? CType.int16 : CType.uint16;
            case 32: return info.signed ? CType.int32 : CType.uint32;
            case 64: return info.signed ? CType.int64 : CType.uint64;
            default: assert(0, "an integer is 8, 16, 32 or 64 bits");
        }
    }
    auto handle = types.isOption(type) ? types.optionInner(type) : type;
    assert((handle in program.nativeTypes) !is null, "sema lets only these types cross into C");
    return CType.pointer;
}

bool isFloat(CType type)
{
    return type == CType.float_ || type == CType.double_;
}

private Extension extensionOf(CType type)
{
    switch (type)
    {
        case CType.bool_, CType.uint8, CType.uint16: return Extension.zero;
        case CType.int8, CType.int16: return Extension.sign;
        default: return Extension.none;
    }
}

private bool canFindVoid(const(CType)[] types)
{
    foreach (type; types) if (type == CType.void_) return true;
    return false;
}

version (unittest)
{
    private Part inInteger(CType type, uint index, Extension extension = Extension.none)
    {
        return Part(type, Place(Where.integerRegister, index), extension);
    }

    private Part inFloat(CType type, uint index)
    {
        return Part(type, Place(Where.floatRegister, index));
    }

    private Part onStack(CType type, uint index)
    {
        return Part(type, Place(Where.stack, index));
    }

    private Part[] partsOf(const CallDescription call)
    {
        Part[] parts;
        foreach (argument; call.arguments) parts ~= argument.parts;
        return parts;
    }
}

@("Win64 gives each of the first four arguments the register of its position, and the rest stack words in order")
unittest
{
    with (CType)
    {
        auto call = describeCall([int64, double_, float_, pointer, int32, double_, float_], double_, Convention.win64);
        assert(partsOf(call) == [inInteger(int64, 0), inFloat(double_, 1), inFloat(float_, 2), inInteger(pointer, 3),
            onStack(int32, 0), onStack(double_, 1), onStack(float_, 2)]);
        assert(call.stackWords == 3);
        assert(call.result == Crossing(Passing.value, [inFloat(double_, 0)]));

        call = describeCall([double_, double_, double_, double_, double_], int32, Convention.win64);
        assert(partsOf(call) == [inFloat(double_, 0), inFloat(double_, 1), inFloat(double_, 2), inFloat(double_, 3),
            onStack(double_, 0)]);
        assert(call.result == Crossing(Passing.value, [inInteger(int32, 0)]));
    }
}

@("System V fills six integer and eight float registers each in turn, and puts what's left on the stack in order")
unittest
{
    with (CType)
    {
        CType[] params = [int64, double_, int32, float_, pointer, uint64, bool_, int64];
        foreach (i; 0 .. 8) params ~= double_;
        params ~= [int64, float_];
        auto call = describeCall(params, float_, Convention.systemV);
        auto expected = [inInteger(int64, 0), inFloat(double_, 0), inInteger(int32, 1), inFloat(float_, 1),
            inInteger(pointer, 2), inInteger(uint64, 3), inInteger(bool_, 4, Extension.zero), inInteger(int64, 5)];
        foreach (i; 0 .. 6) expected ~= inFloat(double_, i + 2);
        expected ~= [onStack(double_, 0), onStack(double_, 1), onStack(int64, 2), onStack(float_, 3)];
        assert(partsOf(call) == expected);
        assert(call.stackWords == 4);
        assert(call.result == Crossing(Passing.value, [inFloat(float_, 0)]));
    }
}

@("a void result is nothing, and a narrow value or a bool is extended by the caller on either convention")
unittest
{
    foreach (convention; [Convention.win64, Convention.systemV])
    {
        with (CType)
        {
            auto call = describeCall([int8, uint16, bool_], void_, convention);
            assert(partsOf(call) == [inInteger(int8, 0, Extension.sign), inInteger(uint16, 1, Extension.zero),
                inInteger(bool_, 2, Extension.zero)]);
            assert(call.result == Crossing(Passing.nothing));
            assert(call.stackWords == 0);
            assert(describeCall([], uint8, convention).result == Crossing(Passing.value, [inInteger(uint8, 0, Extension.zero)]));
        }
    }
}
