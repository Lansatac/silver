/// How a Float is printed: the fewest digits that read back as the same value, which is the nearest
/// such text to the value. Shared by the runtime, the interpreter and sema's constant folding, so
/// that every way of printing a Float agrees.
module silver.runtime.floattext;

pure nothrow:

/// `1.0`, `0.30000000000000004`, `1e16`, `1.5e-7`, `-0.0`, `inf`, `nan`. Positional for decimal
/// exponents from -4 to 15, and otherwise `d.ddde<exponent>`. Positional text always has a `.`,
/// so a Float never prints as an integer would; both forms are Silver and JSON number literals.
string floatText(double value)
{
    if (value != value) return "nan";
    if (value == double.infinity) return "inf";
    if (value == -double.infinity) return "-inf";
    ulong bits = () @trusted { return *cast(ulong*) &value; }();
    auto sign = (bits >> 63) ? "-" : "";
    auto biased = cast(int) ((bits >> 52) & 0x7ff);
    auto fraction = bits & ((1UL << 52) - 1);
    if (biased == 0 && fraction == 0) return sign ~ "0.0";
    ulong f = biased == 0 ? fraction : fraction | (1UL << 52);
    int e = biased == 0 ? -1074 : biased - 1075;

    char[17] digits;
    int count;
    int k;
    shortest(f, e, biased > 1, digits, count, k);
    auto d = digits[0 .. count].idup;
    // `d` is the digits of 0.d × 10^k.
    auto exponent = k - 1;
    if (exponent >= -4 && exponent < 16)
    {
        if (k <= 0) return sign ~ "0." ~ zeros(-k) ~ d;
        if (k >= count) return sign ~ d ~ zeros(k - count) ~ ".0";
        return sign ~ d[0 .. k] ~ "." ~ d[k .. $];
    }
    auto mantissa = count == 1 ? d : d[0 .. 1] ~ "." ~ d[1 .. $];
    return sign ~ mantissa ~ "e" ~ decimal(exponent);
}

private string zeros(int n)
{
    auto text = new char[n];
    text[] = '0';
    return text.idup;
}

private string decimal(int n)
{
    char[12] buffer;
    size_t at = buffer.length;
    auto magnitude = n < 0 ? -n : n;
    do
    {
        buffer[--at] = cast(char) ('0' + magnitude % 10);
        magnitude /= 10;
    }
    while (magnitude != 0);
    if (n < 0) buffer[--at] = '-';
    return buffer[at .. $].idup;
}

/// Burger and Dybvig's free-format algorithm ("Printing Floating-Point Numbers Quickly and
/// Accurately", 1996) on exact integers, for the positive value f × 2^e. `normal` is whether a
/// smaller exponent exists, which is when the gap below a power of two is half the gap above.
/// The value lies in (low, high), its rounding interval, with the ends included when f is even,
/// since a tie reads back as the even significand.
private void shortest(ulong f, int e, bool normal, ref char[17] digits, out int count, out int k)
{
    Big r, s, plus, minus;
    auto unequalGaps = normal && f == (1UL << 52);
    if (e >= 0)
    {
        r = Big.of(f);
        r.shiftLeft(e + (unequalGaps ? 2 : 1));
        s = Big.of(unequalGaps ? 4 : 2);
        minus = Big.of(1);
        minus.shiftLeft(e);
        plus = minus;
        if (unequalGaps) plus.shiftLeft(1);
    }
    else
    {
        r = Big.of(f);
        r.shiftLeft(unequalGaps ? 2 : 1);
        s = Big.of(1);
        s.shiftLeft(-e + (unequalGaps ? 2 : 1));
        minus = Big.of(1);
        plus = Big.of(unequalGaps ? 2 : 1);
    }
    auto inclusive = (f & 1) == 0;

    import std.math : ceil, log10;

    double value = f * 2.0 ^^ e;
    k = cast(int) ceil(log10(value) - 1e-10);
    if (k >= 0)
        s.multiplyPow10(k);
    else
    {
        r.multiplyPow10(-k);
        plus.multiplyPow10(-k);
        minus.multiplyPow10(-k);
    }
    // k is the least integer with high ≤ 10^k, or < when the ends are excluded.
    bool highReaches(ref const Big r, ref const Big plus, ref const Big s)
    {
        auto c = Big.sum(r, plus).compare(s);
        return inclusive ? c >= 0 : c > 0;
    }
    while (highReaches(r, plus, s))
    {
        s.multiplySmall(10);
        k++;
    }
    while (true)
    {
        auto r10 = r, plus10 = plus;
        r10.multiplySmall(10);
        plus10.multiplySmall(10);
        if (highReaches(r10, plus10, s)) break;
        r = r10;
        plus = plus10;
        minus.multiplySmall(10);
        k--;
    }

    count = 0;
    while (true)
    {
        r.multiplySmall(10);
        plus.multiplySmall(10);
        minus.multiplySmall(10);
        int digit = 0;
        while (r.compare(s) >= 0)
        {
            r.subtract(s);
            digit++;
        }
        auto low = r.compare(minus);
        auto lowEnds = inclusive ? low <= 0 : low < 0;
        auto highEnds = highReaches(r, plus, s);
        if (!lowEnds && !highEnds)
        {
            digits[count++] = cast(char) ('0' + digit);
            continue;
        }
        if (lowEnds && highEnds)
        {
            // Either last digit reads back as the value, so take the nearer, or the even one on a tie.
            auto twice = r;
            twice.shiftLeft(1);
            auto c = twice.compare(s);
            if (c > 0 || (c == 0 && digit % 2 == 1)) digit++;
        }
        else if (highEnds)
            digit++;
        digits[count++] = cast(char) ('0' + digit);
        return;
    }
}

/// A non-negative integer of up to 1,280 bits, which holds the largest any step above needs
/// (about 1,140 bits, scaling a subnormal by 10^323).
private struct Big
{
pure nothrow:
    uint[40] words;
    uint length;

    static Big of(ulong value)
    {
        Big b;
        b.words[0] = cast(uint) value;
        b.words[1] = cast(uint) (value >> 32);
        b.length = b.words[1] != 0 ? 2 : b.words[0] != 0 ? 1 : 0;
        return b;
    }

    static Big sum(ref const Big a, ref const Big b)
    {
        Big result = a;
        result.add(b);
        return result;
    }

    void add(ref const Big other)
    {
        auto n = length > other.length ? length : other.length;
        ulong carry = 0;
        foreach (i; 0 .. n)
        {
            ulong t = cast(ulong) words[i] + other.words[i] + carry;
            words[i] = cast(uint) t;
            carry = t >> 32;
        }
        length = n;
        if (carry != 0) push(cast(uint) carry);
    }

    /// For `other` no larger than this.
    void subtract(ref const Big other)
    {
        long borrow = 0;
        foreach (i; 0 .. length)
        {
            long t = cast(long) words[i] - (i < other.length ? other.words[i] : 0) - borrow;
            borrow = t < 0;
            words[i] = cast(uint) (t + (borrow << 32));
        }
        assert(borrow == 0);
        trim();
    }

    void multiplySmall(uint factor)
    {
        ulong carry = 0;
        foreach (i; 0 .. length)
        {
            ulong t = cast(ulong) words[i] * factor + carry;
            words[i] = cast(uint) t;
            carry = t >> 32;
        }
        if (carry != 0) push(cast(uint) carry);
    }

    void multiplyPow10(int n)
    {
        for (; n >= 9; n -= 9) multiplySmall(1_000_000_000);
        uint rest = 1;
        foreach (_; 0 .. n) rest *= 10;
        multiplySmall(rest);
    }

    void shiftLeft(int bits)
    {
        if (length == 0) return;
        auto whole = bits / 32;
        auto part = bits % 32;
        assert(length + whole + 1 <= words.length);
        if (part != 0)
        {
            words[length] = 0;
            foreach_reverse (i; 0 .. length + 1)
                words[i] = (words[i] << part) | (i > 0 ? words[i - 1] >> (32 - part) : 0);
            length++;
        }
        if (whole != 0)
        {
            foreach_reverse (i; 0 .. length) words[i + whole] = words[i];
            words[0 .. whole] = 0;
            length += whole;
        }
        trim();
    }

    int compare(ref const Big other) const
    {
        if (length != other.length) return length < other.length ? -1 : 1;
        foreach_reverse (i; 0 .. length)
            if (words[i] != other.words[i]) return words[i] < other.words[i] ? -1 : 1;
        return 0;
    }

    private void push(uint word)
    {
        assert(length < words.length);
        words[length++] = word;
    }

    private void trim()
    {
        while (length > 0 && words[length - 1] == 0) length--;
    }
}

unittest
{
    assert(floatText(1.0) == "1.0");
    assert(floatText(-0.0) == "-0.0");
    double tenth = 0.1;
    assert(floatText(tenth + 0.2) == "0.30000000000000004");
    assert(floatText(1234567.0) == "1234567.0");
    assert(floatText(0.0001) == "0.0001");
    assert(floatText(0.00001) == "1e-5");
    assert(floatText(1e16) == "1e16");
    assert(floatText(123456789012345680.0) == "1.2345678901234568e17");
    assert(floatText(double.max) == "1.7976931348623157e308");
    assert(floatText(double.min_normal) == "2.2250738585072014e-308");
    assert(floatText(5e-324) == "5e-324");
    assert(floatText(2.0 ^^ 52) == "4503599627370496.0");
    assert(floatText(double.nan) == "nan");
    assert(floatText(-double.infinity) == "-inf");
}
