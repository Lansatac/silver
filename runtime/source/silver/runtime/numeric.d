/// Natives for `toInt`, `toFloat` and `std.math`. Each is the same D expression the
/// interpreter's binding evaluates, so the two backends agree by construction.
///
/// The math functions come from libm because dmd's `std.math` uses x87 instructions for
/// some of them, which are wrong for large arguments: its `sin(1e22)` returns `1e22`.
module silver.runtime.numeric;

import core.stdc.math : atan, cos, exp, log, sin, sqrt;
import silver.runtime.panic : panic;

extern (C) nothrow:

long silver_toInt(double value)
{
    if (!(value >= -0x1p63 && value < 0x1p63))
    {
        panic("toInt: the value is NaN or outside Int's range");
    }
    return cast(long) value;
}

double silver_toFloat(long value) { return cast(double) value; }

double silver_sqrt(double x) { return sqrt(x); }
double silver_exp(double x) { return exp(x); }
double silver_log(double x) { return log(x); }
double silver_sin(double x) { return sin(x); }
double silver_cos(double x) { return cos(x); }
double silver_atan(double x) { return atan(x); }
