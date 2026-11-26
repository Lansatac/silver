/// Rounding a float literal to a `Float32`, which every place that needs one calls, so that a literal
/// has the same bits wherever it's used.
module silver.sema.floatliteral;

import std.bigint : BigInt, toDecimalString;
import std.math : abs, copysign, frexp, ldexp, nextDown, nextUp;

import silver.ast : FloatLiteral, IntLiteral;

/// The float literal of the same value as `literal`, an integer literal too large for 64 bits, for
/// where only a float type fits it: its digits in decimal, read as a float literal's are, so it's
/// rounded once to whichever float type it becomes.
FloatLiteral floatOfInteger(const IntLiteral literal)
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;

    BigInt value = 0;
    foreach (c; literal.digits)
    {
        auto digit = c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
        value = value * literal.radix + digit;
    }
    auto text = value.toDecimalString;
    return FloatLiteral(strtod(text.toStringz, null), text);
}

/// The `Float32` nearest the text of `literal`, rounded once from the text. The lexer's `double` is
/// the nearest `double` to the text, and rounding that to a `float` is the nearest `float` to the
/// text except when the `double` sits exactly on a midpoint between two `float`s: the text may be a
/// little above or below it. Only then is the text compared with the midpoint exactly, and a true
/// tie goes to the even neighbour, as `cast(float)` does. Near the top of the range the midpoint
/// that matters is the one between the largest `float` and 2^128, which rounds to infinity.
float float32Of(const FloatLiteral literal)
{
    double written = literal.value;
    if (written != written) return cast(float) written;
    auto negative = literal.text.length > 0 && literal.text[0] == '-' || literal.text.length == 0 && copysign(1.0, written) < 0;
    double d = abs(written);
    float magnitude = magnitudeOf(d, literal.text);
    return negative ? -magnitude : magnitude;
}

private float magnitudeOf(double d, string text)
{
    float f = cast(float) d;
    if (d == double.infinity || text.length == 0) return f;

    double midpoint;
    float other;
    if (f == float.infinity)
    {
        other = float.max;
        midpoint = cast(double) float.max + 2.0 ^^ 103;
    }
    else
    {
        double held = f;
        if (held == d) return f;
        other = d > held ? nextUp(f) : nextDown(f);
        midpoint = (held + cast(double) other) / 2;
    }
    if (d != midpoint) return f;

    auto order = compareToMidpoint(text, midpoint);
    if (order == 0) return f;
    auto lower = f < other ? f : other;
    auto upper = f < other ? other : f;
    return order < 0 ? lower : upper;
}

/// Whether the number written as `text` is less than (-1), equal to (0) or greater than (1) the
/// positive `double` `midpoint`, both as exact numbers.
private int compareToMidpoint(string text, double midpoint)
{
    BigInt digits = 0;
    long exponent = 0;
    auto seenPoint = false;
    size_t at = 0;
    if (at < text.length && (text[at] == '-' || text[at] == '+')) at++;
    for (; at < text.length; at++)
    {
        auto c = text[at];
        if (c >= '0' && c <= '9')
        {
            digits = digits * 10 + (c - '0');
            if (seenPoint) exponent--;
        }
        else if (c == '.') seenPoint = true;
        else break;
    }
    if (at < text.length && (text[at] == 'e' || text[at] == 'E'))
    {
        at++;
        auto negative = false;
        if (at < text.length && (text[at] == '-' || text[at] == '+')) negative = text[at++] == '-';
        long written = 0;
        for (; at < text.length && written < 100_000; at++) written = written * 10 + (text[at] - '0');
        exponent += negative ? -written : written;
    }

    int binary;
    auto fraction = frexp(midpoint, binary);
    auto mantissa = BigInt(cast(long) ldexp(fraction, 53));
    long scale = binary - 53;

    auto left = digits;
    auto right = mantissa;
    if (exponent >= 0) left *= BigInt(10) ^^ cast(ulong) exponent;
    else right *= BigInt(10) ^^ cast(ulong) -exponent;
    if (scale >= 0) right <<= cast(size_t) scale;
    else left <<= cast(size_t) -scale;
    return left < right ? -1 : left > right ? 1 : 0;
}

version (unittest)
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;

    /// The literal for `n` × 10^`exponent`, written as text.
    private FloatLiteral literalOf(BigInt n, long exponent, string sign = "")
    {
        import std.conv : to;

        auto text = sign ~ n.to!string ~ "e" ~ exponent.to!string;
        return FloatLiteral(strtod(text.toStringz, null), text);
    }
}

unittest
{
    // 1 + 2^-24 is the midpoint between 1 and 1 + 2^-23, which is (2^24 + 1) × 5^24 / 10^24.
    auto tie = BigInt(2) ^^ 24 + 1;
    tie *= BigInt(5) ^^ 24;
    assert(float32Of(literalOf(tie, -24)) == 1.0f, "a tie goes to the even neighbour, 1");
    assert(float32Of(literalOf(tie * 10 - 1, -25)) == 1.0f, "just below goes down");
    assert(float32Of(literalOf(tie * 10 + 1, -25)) == nextUp(1.0f), "just above goes up, though the double is the midpoint");
    assert(float32Of(literalOf(tie * 10 + 1, -25, "-")) == -nextUp(1.0f), "a negative literal rounds the same way");
}

unittest
{
    // 1 + 3 × 2^-24 is the midpoint between 1 + 2^-23 (odd) and 1 + 2^-22 (even).
    auto tie = BigInt(2) ^^ 24 + 3;
    tie *= BigInt(5) ^^ 24;
    auto odd = nextUp(1.0f);
    auto even = nextUp(odd);
    assert(float32Of(literalOf(tie, -24)) == even, "a tie goes to the even neighbour, which is the upper one here");
    assert(float32Of(literalOf(tie * 10 - 1, -25)) == odd);
    assert(float32Of(literalOf(tie * 10 + 1, -25)) == even);
}

unittest
{
    // The overflow midpoint, (2 - 2^-24) × 2^127, is where the largest float stops being the nearest.
    auto midpoint = (BigInt(2) ^^ 25 - 1) * BigInt(2) ^^ 103;
    assert(float32Of(literalOf(midpoint - 1, 0)) == float.max);
    assert(float32Of(literalOf(midpoint, 0)) == float.infinity, "the tie rounds to infinity, which is even");
    assert(float32Of(literalOf(midpoint + 1, 0)) == float.infinity);
    assert(float32Of(literalOf(midpoint - 1, 0, "-")) == -float.max);
    assert(float32Of(literalOf(midpoint, 0, "-")) == -float.infinity);
    assert(float32Of(FloatLiteral(1e40, "1e40")) == float.infinity);
    assert(float32Of(FloatLiteral(double.infinity, "1e400")) == float.infinity);
}

unittest
{
    // 2^-150 is the midpoint between zero and the smallest subnormal, 2^-149; 3 × 2^-150 the one above it.
    auto half = BigInt(5) ^^ 150;
    assert(float32Of(literalOf(half, -150)) == 0.0f);
    assert(float32Of(literalOf(half * 10 + 1, -151)) == float.min_normal * float.epsilon);
    assert(float32Of(literalOf(half * 10 - 1, -151)) == 0.0f);
    auto smallest = float.min_normal * float.epsilon;
    assert(float32Of(literalOf(half * 3, -150)) == 2 * smallest, "a tie goes to the even one");
    assert(float32Of(literalOf(half * 30 - 1, -151)) == smallest);
    assert(float32Of(literalOf(half * 30 + 1, -151)) == 2 * smallest);
}

unittest
{
    // What isn't near a midpoint is the nearest float to the double, and the text's sign counts for a zero.
    assert(float32Of(FloatLiteral(0.1, "0.1")) == 0.1f);
    assert(float32Of(FloatLiteral(3.4028235e38, "3.4028235e38")) == float.max);
    assert(float32Of(FloatLiteral(0.0, "0.0")) == 0.0f);
    auto negativeZero = float32Of(FloatLiteral(-0.0, "-0.0"));
    assert(negativeZero == 0.0f && copysign(1.0f, negativeZero) < 0);
}

unittest
{
    // The lexer's strtod is correctly rounded: 1 + 2^-53 is the midpoint between two doubles, so it ties to 1.
    auto tie = BigInt(2) ^^ 53 + 1;
    tie *= BigInt(5) ^^ 53;
    assert(literalOf(tie, -53).value == 1.0);
    assert(literalOf(tie * 10 + 1, -54).value == nextUp(1.0));
    assert(literalOf(tie * 10 - 1, -54).value == 1.0);
    auto odd = BigInt(2) ^^ 53 + 3;
    odd *= BigInt(5) ^^ 53;
    assert(literalOf(odd, -53).value == nextUp(nextUp(1.0)));
}

unittest
{
    import std.array : replicate;

    // An integer literal too large for 64 bits is the float literal of its value, in any base.
    auto decimal = floatOfInteger(IntLiteral(0, true, "99999999999999999999", 10));
    assert(decimal.text == "99999999999999999999" && decimal.value == 1e20);
    assert(floatOfInteger(IntLiteral(0, true, "100000000000000000000", 16)).value == 2.0 ^^ 80);
    assert(floatOfInteger(IntLiteral(0, true, "1" ~ "0".replicate(64), 2)).value == 2.0 ^^ 64);
    // 2^64 + 2^40 + 1 is past the midpoint between two floats, so it rounds up from its text.
    auto above = floatOfInteger(IntLiteral(0, true, "1" ~ "0".replicate(23) ~ "1" ~ "0".replicate(39) ~ "1", 2));
    assert(float32Of(above) == nextUp(cast(float) 2.0 ^^ 64));
}
