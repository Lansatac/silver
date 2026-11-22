/// The C functions the interpreter can call, by symbol: those the standard library's natives
/// bind, and a few of the C library's that take and give pointers. The math functions are libm's,
/// as compiled programs call them, never dmd's `std.math`, whose `sin(1e22)` is `1e22`. A pointer
/// is a `Handle`, null for `None`: the evaluator converts an option of a native type.
module silver.interpreter.foreign;

import silver.interpreter.values;

alias ForeignFunction = Value function(Value[] args);

immutable ForeignFunction[string] foreignFunctions;

shared static this()
{
    import core.stdc.math : atan, cos, exp, log, pow, sin, sqrt;
    import core.stdc.stdlib : free, getenv, malloc;
    import core.stdc.string : strchr, strcmp, strlen;

    static char* text(Value value) => cast(char*) value.as!Handle.address;

    static ForeignFunction unary(alias f)()
    {
        return (Value[] args) => Value(f(args[0].as!double));
    }

    foreignFunctions = [
        "sqrt": unary!sqrt,
        "exp": unary!exp,
        "log": unary!log,
        "sin": unary!sin,
        "cos": unary!cos,
        "atan": unary!atan,
        "pow": (Value[] args) => Value(pow(args[0].as!double, args[1].as!double)),
        "silver_nowNanos": (Value[] _) => Value(nowNanos()),
        "strlen": (Value[] args) => Value(cast(long) strlen(text(args[0]))),
        "strcmp": (Value[] args) => Value(cast(long) strcmp(text(args[0]), text(args[1]))),
        "strchr": (Value[] args) => Value(Handle(strchr(text(args[0]), cast(int) args[1].as!long))),
        "getenv": (Value[] args) => Value(Handle(getenv(text(args[0])))),
        "malloc": (Value[] args) => Value(Handle(malloc(cast(size_t) args[0].as!long))),
        "free": (Value[] args) {
            free(args[0].as!Handle.address);
            return Value(Unit());
        },
    ];
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
    import std.utf : UTFException, validate;

    auto bytes = (cast(const(char)*) pointer)[0 .. strlen(cast(const(char)*) pointer)];
    try validate(bytes);
    catch (UTFException) return null;
    return bytes.length == 0 ? "" : bytes.idup;
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
    assert(foreignFunctions["sin"]([Value(1e22)]).as!double != 1e22);
    assert(foreignFunctions["pow"]([Value(2.0), Value(10.0)]).as!double == 1024);
}

@("a C string is a copy with a NUL, and comes back only if it's UTF-8")
unittest
{
    auto copy = cast(char*) toCString("a\0b");
    assert(copy[0 .. 4] == "a\0b\0");
    assert(fromCString(toCString("héllo")) == "héllo");
    assert(fromCString(toCString("")) !is null);
    assert(fromCString(toCString("\xff")) is null);
    assert(addressText(cast(void*) 0xab12) == "0xab12");
}
