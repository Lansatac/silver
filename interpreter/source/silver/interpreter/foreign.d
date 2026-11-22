/// The C functions the interpreter can call, by symbol: those the standard library's natives
/// bind, and a few of the C library's that take and give pointers. The math functions are libm's,
/// as compiled programs call them, never dmd's `std.math`, whose `sin(1e22)` is `1e22`.
///
/// Each is described by its C signature, so the evaluator can serve any declaration that C's
/// calling convention passes the same way: a pointer can be declared as a native type, an option of
/// one, or a 64-bit integer, and an integer as any integer type.
module silver.interpreter.foreign;

/// How C passes a parameter or result.
enum CKind
{
    integer,
    pointer,
    float_,
    /// `void`, as a result.
    none,
}

/// A C value of whichever kind the signature says.
struct CValue
{
    long integer;
    void* pointer;
    double float_;
}

struct ForeignFunction
{
    CKind[] params;
    CKind result;
    CValue function(CValue[] args) call;
}

immutable ForeignFunction[string] foreignFunctions;

private CValue integerValue(long value) => CValue(value, null, 0);
private CValue pointerValue(void* value) => CValue(0, value, 0);
private CValue floatValue(double value) => CValue(0, null, value);
private char* text(CValue value) => cast(char*) value.pointer;

shared static this()
{
    import core.stdc.math : atan, cos, exp, log, pow, sin, sqrt;
    import core.stdc.stdlib : free, getenv, malloc;
    import core.stdc.string : strchr, strcmp, strlen;

    static ForeignFunction unary(alias f)()
    {
        return ForeignFunction([CKind.float_], CKind.float_, (CValue[] args) => floatValue(f(args[0].float_)));
    }

    alias integer = CKind.integer, pointer = CKind.pointer, float_ = CKind.float_, none = CKind.none;
    ForeignFunction[string] table = [
        "sqrt": unary!sqrt,
        "exp": unary!exp,
        "log": unary!log,
        "sin": unary!sin,
        "cos": unary!cos,
        "atan": unary!atan,
        "pow": ForeignFunction([float_, float_], float_, (CValue[] args) => floatValue(pow(args[0].float_, args[1].float_))),
        "silver_nowNanos": ForeignFunction([], integer, (CValue[] _) => integerValue(nowNanos())),
        "strlen": ForeignFunction([pointer], integer, (CValue[] args) => integerValue(cast(long) strlen(text(args[0])))),
        "strcmp": ForeignFunction([pointer, pointer], integer,
            (CValue[] args) => integerValue(strcmp(text(args[0]), text(args[1])))),
        "strchr": ForeignFunction([pointer, integer], pointer,
            (CValue[] args) => pointerValue(strchr(text(args[0]), cast(int) args[1].integer))),
        "getenv": ForeignFunction([pointer], pointer, (CValue[] args) => pointerValue(getenv(text(args[0])))),
        "malloc": ForeignFunction([integer], pointer, (CValue[] args) => pointerValue(malloc(cast(size_t) args[0].integer))),
        "free": ForeignFunction([pointer], none, (CValue[] args) {
            free(args[0].pointer);
            return CValue.init;
        }),
    ];
    foreignFunctions = cast(immutable) table;
}

/// A copy of `text`'s bytes followed by a NUL, as the runtime's `silver_toCString` makes it. The
/// collector keeps it while a `Handle` points to it.
void* toCString(const(char)[] text)
{
    auto copy = new char[text.length + 1];
    copy[0 .. text.length] = text;
    copy[text.length] = 0;
    return copy.ptr;
}

/// The bytes up to the NUL as a String, or null if they aren't UTF-8. An empty String is not null.
string fromCString(const(void)* pointer)
{
    import core.stdc.string : strlen;

    auto bytes = (cast(const(ubyte)*) pointer)[0 .. strlen(cast(const(char)*) pointer)];
    if (!isUtf8(bytes)) return null;
    return bytes.length == 0 ? "" : (cast(const(char)[]) bytes).idup;
}

/// Whether `bytes` are UTF-8, as `std.utf.validate` decides it but without the exception it
/// throws, which costs milliseconds: no overlong form, surrogate, or code point past U+10FFFF.
private bool isUtf8(const(ubyte)[] bytes)
{
    size_t i = 0;
    while (i < bytes.length)
    {
        auto lead = bytes[i];
        if (lead < 0x80)
        {
            i++;
            continue;
        }
        size_t following;
        uint lowest;
        if ((lead & 0xE0) == 0xC0)
        {
            following = 1;
            lowest = 0x80;
        }
        else if ((lead & 0xF0) == 0xE0)
        {
            following = 2;
            lowest = 0x800;
        }
        else if ((lead & 0xF8) == 0xF0)
        {
            following = 3;
            lowest = 0x10000;
        }
        else return false;
        if (bytes.length - i <= following) return false;
        uint code = lead & (0x3F >> following);
        foreach (b; bytes[i + 1 .. i + 1 + following])
        {
            if ((b & 0xC0) != 0x80) return false;
            code = (code << 6) | (b & 0x3F);
        }
        if (code < lowest || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return false;
        i += 1 + following;
    }
    return true;
}

/// `0x` and the address in lowercase hex digits, as the runtime prints a native type's value.
string addressText(const(void)* address)
{
    import std.format : format;

    return format("0x%x", cast(size_t) address);
}

/// As the runtime's `silver_nowNanos` computes it. `currStdTime` counts 100ns ticks from the year 1.
private long nowNanos()
{
    import std.datetime.systime : Clock;

    return (Clock.currStdTime - 621_355_968_000_000_000L) * 100;
}

@("the interpreter calls libm for the math natives")
unittest
{
    assert(foreignFunctions["sin"].call([floatValue(1e22)]).float_ != 1e22);
    assert(foreignFunctions["pow"].call([floatValue(2.0), floatValue(10.0)]).float_ == 1024);
}

@("a C string is a copy with a NUL, and comes back only if it's UTF-8")
unittest
{
    auto copy = cast(char*) toCString("a\0b");
    assert(copy[0 .. 4] == "a\0b\0");
    assert(fromCString(toCString("héllo")) == "héllo");
    assert(fromCString(toCString("")) !is null);
    assert(addressText(cast(void*) 0xab12) == "0xab12");
    // Overlong, surrogate, past U+10FFFF, five bytes, cut short, a stray continuation, a bad lead.
    foreach (bad; ["\xff", "\xC0\x80", "\xE0\x80\x80", "\xED\xA0\x80", "\xF4\x90\x80\x80", "\xF8\x88\x80\x80\x80",
        "\xE2\x82", "a\x80", "\xC3("])
    {
        assert(fromCString(toCString(bad)) is null, bad);
    }
    foreach (good; ["߿", "퟿", "", "￿", "\U0010FFFF", "aé日"])
    {
        assert(fromCString(toCString(good)) == good, good);
    }
}
