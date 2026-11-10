/// The C functions the interpreter can call, by symbol: those the standard library's natives
/// bind. The math functions are libm's, as compiled programs call them, never dmd's `std.math`,
/// whose `sin(1e22)` is `1e22`.
module silver.interpreter.foreign;

import silver.interpreter.values;

alias ForeignFunction = Value function(Value[] args);

immutable ForeignFunction[string] foreignFunctions;

shared static this()
{
    import core.stdc.math : atan, cos, exp, log, pow, sin, sqrt;

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
    ];
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
