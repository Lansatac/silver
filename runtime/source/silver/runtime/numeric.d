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

long silver_monotonicNanos()
{
    import core.time : MonoTime, ticksToNSecs;

    return ticksToNSecs(MonoTime.currTime.ticks);
}

/// The local zone's offset in seconds at `unixSeconds`, clamped to the years 0000 to 9999.
long silver_localOffsetSeconds(long unixSeconds)
{
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    try
    {
        return localOffsetSeconds(unixSeconds);
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
    catch (Exception e)
    {
        panic("couldn't read the local time zone: " ~ e.msg);
    }
}

/// `interpreter/foreign.d` has a copy.
private long localOffsetSeconds(long unixSeconds)
{
    import std.algorithm.comparison : clamp;
    import std.datetime.timezone : LocalTime;

    auto seconds = clamp(unixSeconds, -62_167_219_200L, 253_402_300_799L);
    return LocalTime().utcOffsetAt(seconds * 10_000_000L + 621_355_968_000_000_000L).total!"seconds";
}
