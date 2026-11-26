/// Every heap allocation generated code makes for an object goes through here, and for a String
/// or array through `silver.runtime.buffer`, so the allocator can change (to a collector of
/// Silver's own, say) without touching codegen.
///
/// The collector is druntime's, and what it can't see of generated code's registers is saved first,
/// by `silver.runtime.registers`.
module silver.runtime.memory;

import core.exception : OutOfMemoryError;
import core.memory : GC;
import silver.runtime.panic : outOfMemory;
import silver.runtime.registers : SavedRegisters, silver_save_registers;

/// Memory the collector owns, at least `size` bytes, after making the caller's registers visible
/// to it. Every allocation the runtime asks for by name comes through here; a function that
/// allocates through D's library instead (`to!string`, `~`, `readln`) saves them itself.
GC.BlkInfo collectable(size_t size, uint attributes) nothrow
{
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    try
    {
        auto block = GC.qalloc(size, attributes);
        if (block.base is null) outOfMemory();
        return block;
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
}

/// `size` bytes for an object of fixed size, which no pointer walks along: see `buffer` for what
/// an array needs past its end.
extern (C) void* silver_alloc(size_t size) nothrow
{
    return collectable(size, GC.BlkAttr.NONE).base;
}
