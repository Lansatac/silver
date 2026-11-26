/// Every heap allocation generated code makes for an object goes through here, and for a String
/// or array through `silver.runtime.buffer`, so the allocator can change (to a collector of
/// Silver's own, say) without touching codegen.
///
/// The collector is druntime's, and what it can't see of generated code's registers is saved first,
/// by `silver.runtime.registers`.
///
/// Its own entry points (`GC.qalloc`, `GC.query`) take a lock on every call, which a Silver program
/// doesn't need: only one thread uses the collector while it runs (see "One thread, no collector
/// lock" in `notes/runtime.md`). So allocation and the block lookup go to the collector's
/// implementation directly, without the lock.
module silver.runtime.memory;

import core.exception : OutOfMemoryError;
import core.gc.gcinterface : GC;
import core.internal.gc.impl.conservative.gc : ConservativeGC, Gcx;
static import core.memory;
import core.stdc.string : memset;
import silver.runtime.panic : outOfMemory, panic;
import silver.runtime.registers : SavedRegisters, silver_save_registers;

alias BlkAttr = core.memory.GC.BlkAttr;
alias BlkInfo = core.memory.GC.BlkInfo;

private extern (C) void gc_init_nothrow() nothrow;
private extern (C) GC gc_getProxy() nothrow @nogc;

/// druntime's collector itself, which its entry points call with the lock held.
private __gshared Gcx* heap;

/// Starts the collector, which druntime otherwise does at its first use, and finds it. It runs before
/// anything is allocated through here.
void takeHeap() nothrow
{
    gc_init_nothrow();
    auto collector = cast(ConservativeGC) gc_getProxy();
    if (collector is null) panic("the runtime needs druntime's conservative collector");
    heap = collector.gcx;
}

/// Memory the collector owns, at least `size` bytes, after making the caller's registers visible
/// to it. Every allocation the runtime asks for by name comes through here; a function that
/// allocates through D's library instead (`to!string`, `~`, `readln`) saves them itself.
BlkInfo collectable(size_t size, uint attributes) nothrow
{
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    try
    {
        BlkInfo block;
        block.base = heap.alloc(size, block.size, attributes, null);
        if (block.base is null) outOfMemory();
        // As `GC.qalloc` does: what the caller won't write mustn't look like pointers to the scan.
        if (!(attributes & BlkAttr.NO_SCAN)) memset(block.base + size, 0, block.size - size);
        block.attr = attributes;
        return block;
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
}

/// The start of the collector's block that `p` points into, or null if it isn't in one.
void* blockOf(const(void)* p) nothrow @nogc
{
    return heap.findBase(cast(void*) p);
}

/// `size` bytes for an object of fixed size, which no pointer walks along: see `buffer` for what
/// an array needs past its end.
extern (C) void* silver_alloc(size_t size) nothrow
{
    return collectable(size, BlkAttr.NONE).base;
}
