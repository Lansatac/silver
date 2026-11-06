/// Natives for `std.math` and `std.time`. Each is the same D expression the interpreter's
/// binding evaluates, so the two backends agree by construction.
///
/// The math functions come from libm because dmd's `std.math` uses x87 instructions for
/// some of them, which are wrong for large arguments: its `sin(1e22)` returns `1e22`.
module silver.runtime.numeric;

import core.stdc.math : atan, cos, exp, log, pow, sin, sqrt;
import std.datetime.systime : Clock;
import silver.runtime.panic : panic;

extern (C) nothrow:

double silver_pow(double base, double exponent) { return pow(base, exponent); }
double silver_sqrt(double x) { return sqrt(x); }
double silver_exp(double x) { return exp(x); }
double silver_log(double x) { return log(x); }
double silver_sin(double x) { return sin(x); }
double silver_cos(double x) { return cos(x); }
double silver_atan(double x) { return atan(x); }

/// Nanoseconds since the Unix epoch. `currStdTime` counts 100ns ticks from the year 1.
long silver_nowNanos()
{
    try
    {
        return (Clock.currStdTime - 621_355_968_000_000_000L) * 100;
    }
    catch (Exception e)
    {
        panic("couldn't read the clock: " ~ e.msg);
    }
}
