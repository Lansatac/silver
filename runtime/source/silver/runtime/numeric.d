/// The runtime's natives for `std.time`. `std.math`'s natives bind libm directly.
module silver.runtime.numeric;

import std.datetime.systime : Clock;
import silver.runtime.panic : panic;

extern (C) nothrow:

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
