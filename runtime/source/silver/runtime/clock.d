/// The runtime's natives for `std.time`, which `lang.time` declares. The interpreter compiles this
/// module in and calls them as compiled code does, so it uses nothing of the runtime's but
/// `silver.runtime.registers`.
module silver.runtime.clock;

import core.exception : OutOfMemoryError;
import silver.runtime.registers : SavedRegisters, silver_save_registers;

/// What running out of memory here does: the runtime's panic in a compiled program, which its entry
/// sets, or the interpreter's, which reports it once the call has returned.
__gshared void function() nothrow @nogc clockOutOfMemory;

extern (C) nothrow:

/// Nanoseconds since the Unix epoch, to the 100ns that Windows' clock counts in.
long silver_nowNanos() @nogc
{
    version (Windows)
    {
        import core.sys.windows.winbase : FILETIME, GetSystemTimeAsFileTime;

        // 100ns ticks since 1601.
        FILETIME now;
        GetSystemTimeAsFileTime(&now);
        auto ticks = (cast(long) now.dwHighDateTime << 32) | now.dwLowDateTime;
        return (ticks - 116_444_736_000_000_000L) * 100;
    }
    else
    {
        import core.sys.posix.time : clock_gettime, CLOCK_REALTIME, timespec;

        timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        return (now.tv_sec * 10_000_000L + now.tv_nsec / 100) * 100;
    }
}

long silver_monotonicNanos() @nogc
{
    import core.time : MonoTime, ticksToNSecs;

    return ticksToNSecs(MonoTime.currTime.ticks);
}

/// The local zone's offset in seconds at `unixSeconds`, clamped to the years 0000 to 9999.
long silver_localOffsetSeconds(long unixSeconds)
{
    import std.algorithm.comparison : clamp;
    import std.datetime.timezone : LocalTime;

    // The first use of `LocalTime` allocates.
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    auto seconds = clamp(unixSeconds, -62_167_219_200L, 253_402_300_799L);
    try return LocalTime().utcOffsetAt(seconds * 10_000_000L + 621_355_968_000_000_000L).total!"seconds";
    catch (OutOfMemoryError)
    {
        clockOutOfMemory();
        return 0;
    }
}
