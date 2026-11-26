/// `lang.process`'s intrinsics: ending the program with a status, and reading the environment.
module silver.runtime.process;

import core.exception : OutOfMemoryError;
import core.stdc.stdio : fflush, stdout;
import core.stdc.stdlib : exit;

import silver.runtime.buffer : newString;
import silver.runtime.environment : environmentValue;
import silver.runtime.registers : SavedRegisters, silver_save_registers;
import silver.runtime.panic : outOfMemory;
import silver.runtime.testing : exitInTest;

extern (C) nothrow:

/// Writes out what the program has printed and ends it with `status`. In a test it fails the test, at
/// `location`, where the call was.
noreturn silver_exit(ubyte status, const(char)* location, size_t locationLength) @nogc
{
    exitInTest(status, location, locationLength);
    fflush(stdout);
    exit(status);
}

/// `readEnvironment` in `lang.process`: 0 and the value through the out slots, or 1 when the variable
/// is none (not set, or not UTF-8).
int silver_readEnvironment(const(char)* name, size_t nameLength, const(char)** data, size_t* length)
{
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    *data = null;
    *length = 0;
    try
    {
        auto value = environmentValue(name[0 .. nameLength]);
        if (value is null) return 1;
        newString(value, data, length);
        return 0;
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
    return 1;
}
