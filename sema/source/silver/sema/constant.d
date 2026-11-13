/// The values top-level constants evaluate to, and the operators on them. These follow the rules
/// the backends follow at runtime, with what would panic there failing here instead.
module silver.sema.constant;

import std.sumtype;
import std.traits : isSigned;

import silver.ast : BinaryOp, UnaryOp;
import silver.sema.type : IntegerInfo;

struct ConstInt
{
    long value;
}

struct ConstUInt
{
    ulong value;
}

struct ConstUnit
{
}

/// Wrapped like the integers: a bare `dchar` converts to `double`.
struct ConstChar
{
    dchar value;
}

/// The integers are wrapped because `long` and `ulong` convert implicitly, so a `match` couldn't
/// tell them apart. A narrower type's value is held sign- or zero-extended.
alias ConstValue = SumType!(ConstInt, ConstUInt, bool, double, string, ConstUnit, ConstChar);

/// An operation with no value, like an overflowing `+`. The message says why.
package final class ConstantFailure : Exception
{
    this(string message)
    {
        super(message);
    }
}

/// `value` as a string hole shows it, the same way the backends format it at runtime.
package string formatValue(const ConstValue value)
{
    import std.conv : to;

    return value.match!(
        (const ConstInt v) => v.value.to!string,
        (const ConstUInt v) => v.value.to!string,
        (const bool v) => v.to!string,
        (const double v) => v != v ? "nan" : v.to!string,
        (const string v) => v,
        (const ConstUnit _) => "()",
        (const ConstChar v) => [v.value].to!string,
    );
}

/// `lhs op rhs` for two values of one type, which sema has checked, or a shift by any integer
/// type. `op` isn't `&&` or `||`,
/// which short-circuit, so their caller decides whether there's a `rhs`. `info` describes the
/// type when it's an integer.
/// Throws: ConstantFailure if the operation would panic at runtime.
package ConstValue binaryValue(BinaryOp op, const ConstValue lhs, const ConstValue rhs, IntegerInfo info)
{
    if (op == BinaryOp.ShiftLeft || op == BinaryOp.ShiftRight)
    {
        return lhs.match!(
            (const ConstInt l) => integerShift(op, l.value, shiftAmount(rhs), info),
            (const ConstUInt l) => integerShift(op, l.value, shiftAmount(rhs), info),
            (_) => assert(0, "sema only shifts integers"),
        );
    }
    return lhs.match!(
        (const ConstInt l) => integerBinary(op, l.value, rhs.get!(const ConstInt).value, info),
        (const ConstUInt l) => integerBinary(op, l.value, rhs.get!(const ConstUInt).value, info),
        (const bool l) => equality!bool(op, l, rhs.get!(const bool)),
        (const double l) => floatBinary(op, l, rhs.get!(const double)),
        (const string l) => stringBinary(op, l, rhs.get!(const string)),
        (const ConstUnit _) => equality!bool(op, true, true),
        (const ConstChar l) => comparison!dchar(op, l.value, rhs.get!(const ConstChar).value),
    );
}

/// `op operand`. `info` describes the operand's type when it's an integer.
/// Throws: ConstantFailure if the operation would panic at runtime.
package ConstValue unaryValue(UnaryOp op, const ConstValue operand, IntegerInfo info)
{
    return operand.match!(
        (const ConstInt v) => integerUnary(op, v.value, info),
        (const ConstUInt v) => integerUnary(op, v.value, info),
        (const bool v) => ConstValue(!v),
        (const double v) => ConstValue(op == UnaryOp.Minus ? -v : v),
        (_) => assert(0, "sema only applies unary operators to numbers and Bools"),
    );
}

private ConstValue integerValue(T)(T value)
{
    static if (isSigned!T)
    {
        return ConstValue(ConstInt(value));
    }
    else
    {
        return ConstValue(ConstUInt(value));
    }
}

private ConstantFailure overflow()
{
    return new ConstantFailure("Integer overflow");
}

/// `value` cut down to the type's width, extended back to 64 bits as the type requires.
private T truncated(T)(T value, IntegerInfo info)
{
    auto unused = 64 - info.bits;
    return (value << unused) >> unused;
}

private bool fits(T)(T value, IntegerInfo info)
{
    static if (isSigned!T)
    {
        return value >= cast(T)(0 - info.minMagnitude) && value <= cast(T) info.maxValue;
    }
    else
    {
        return value <= info.maxValue;
    }
}

private T checked(string op, T)(T lhs, T rhs, IntegerInfo info)
{
    import core.checkedint : adds, addu, muls, mulu, subs, subu;

    bool overflowed;
    static if (isSigned!T)
    {
        static if (op == "+") T result = adds(lhs, rhs, overflowed);
        else static if (op == "-") T result = subs(lhs, rhs, overflowed);
        else T result = muls(lhs, rhs, overflowed);
    }
    else
    {
        static if (op == "+") T result = addu(lhs, rhs, overflowed);
        else static if (op == "-") T result = subu(lhs, rhs, overflowed);
        else T result = mulu(lhs, rhs, overflowed);
    }
    if (overflowed || !fits(result, info)) throw overflow();
    return result;
}

private ConstValue integerBinary(T)(BinaryOp op, T lhs, T rhs, IntegerInfo info)
{
    switch (op)
    {
    case BinaryOp.Add:
        return integerValue(checked!"+"(lhs, rhs, info));
    case BinaryOp.Subtract:
        return integerValue(checked!"-"(lhs, rhs, info));
    case BinaryOp.Multiply:
        return integerValue(checked!"*"(lhs, rhs, info));
    case BinaryOp.WrappingAdd:
        return integerValue(truncated!T(lhs + rhs, info));
    case BinaryOp.WrappingSubtract:
        return integerValue(truncated!T(lhs - rhs, info));
    case BinaryOp.WrappingMultiply:
        return integerValue(truncated!T(lhs * rhs, info));
    case BinaryOp.Divide:
    case BinaryOp.Modulo:
        if (rhs == 0) throw new ConstantFailure("Division by zero");
        static if (isSigned!T)
        {
            if (lhs == cast(T)(0 - info.minMagnitude) && rhs == -1) throw overflow();
        }
        return integerValue!T(op == BinaryOp.Divide ? lhs / rhs : lhs % rhs);
    case BinaryOp.BitAnd:
        return integerValue!T(lhs & rhs);
    case BinaryOp.BitOr:
        return integerValue!T(lhs | rhs);
    case BinaryOp.BitXor:
        return integerValue!T(lhs ^ rhs);
    default:
        return comparison!T(op, lhs, rhs);
    }
}

/// As unsigned, so a negative amount counts as too large.
private ulong shiftAmount(const ConstValue amount)
{
    return amount.match!(
        (const ConstInt v) => cast(ulong) v.value,
        (const ConstUInt v) => v.value,
        (_) => assert(0, "sema only shifts by integers"),
    );
}

private ConstValue integerShift(T)(BinaryOp op, T lhs, ulong amount, IntegerInfo info)
{
    if (amount >= info.bits) throw new ConstantFailure("Shift amount is out of range");
    auto count = cast(int) amount;
    return integerValue(op == BinaryOp.ShiftLeft ? truncated!T(lhs << count, info) : cast(T)(lhs >> count));
}

private ConstValue integerUnary(T)(UnaryOp op, T value, IntegerInfo info)
{
    final switch (op)
    {
    case UnaryOp.Plus:
        return integerValue(value);
    case UnaryOp.BitNot:
        return integerValue(truncated!T(~value, info));
    case UnaryOp.Minus:
        static if (isSigned!T)
        {
            if (value == cast(T)(0 - info.minMagnitude)) throw overflow();
            return integerValue!T(-value);
        }
        else
        {
            assert(0, "sema doesn't let an unsigned value be negated");
        }
    case UnaryOp.Not:
        assert(0, "sema only applies `!` to a Bool");
    }
}

private ConstValue floatBinary(BinaryOp op, double lhs, double rhs)
{
    switch (op)
    {
    case BinaryOp.Add:
        return ConstValue(lhs + rhs);
    case BinaryOp.Subtract:
        return ConstValue(lhs - rhs);
    case BinaryOp.Multiply:
        return ConstValue(lhs * rhs);
    case BinaryOp.Divide:
        return ConstValue(lhs / rhs);
    case BinaryOp.Modulo:
        return ConstValue(lhs % rhs);
    default:
        return comparison!double(op, lhs, rhs);
    }
}

private ConstValue stringBinary(BinaryOp op, string lhs, string rhs)
{
    if (op == BinaryOp.Concat) return ConstValue(lhs ~ rhs);
    return comparison!string(op, lhs, rhs);
}

private ConstValue comparison(T)(BinaryOp op, T lhs, T rhs)
{
    switch (op)
    {
    case BinaryOp.Less:
        return ConstValue(lhs < rhs);
    case BinaryOp.LessEqual:
        return ConstValue(lhs <= rhs);
    case BinaryOp.Greater:
        return ConstValue(lhs > rhs);
    case BinaryOp.GreaterEqual:
        return ConstValue(lhs >= rhs);
    default:
        return equality!T(op, lhs, rhs);
    }
}

private ConstValue equality(T)(BinaryOp op, T lhs, T rhs)
{
    switch (op)
    {
    case BinaryOp.Equal:
        return ConstValue(lhs == rhs);
    case BinaryOp.NotEqual:
        return ConstValue(lhs != rhs);
    default:
        assert(0, "sema checked the operator against the operands' type");
    }
}
