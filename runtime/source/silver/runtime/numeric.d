/// The runtime's natives for `std.time`. `std.math`'s natives bind libm directly.
module silver.runtime.numeric;

import core.exception : OutOfMemoryError;
import std.datetime.systime : Clock;
import silver.runtime.memory : SavedRegisters, silver_save_registers;
import silver.runtime.panic : outOfMemory, panic;

extern (C) nothrow:

/// Nanoseconds since the Unix epoch. `currStdTime` counts 100ns ticks from the year 1.
long silver_nowNanos()
{
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    try
    {
        return (Clock.currStdTime - 621_355_968_000_000_000L) * 100;
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
    catch (Exception e)
    {
        panic("couldn't read the clock: " ~ e.msg);
    }
}
