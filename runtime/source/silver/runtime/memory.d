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
import core.gc.config : config;
import core.internal.gc.impl.conservative.gc : ConservativeGC, Gcx, numCollections;
import core.internal.gc.proxy : gc_getProxy, gc_init_nothrow;
static import core.memory;
import core.stdc.string : memset;
import silver.runtime.panic : outOfMemory, panic, silver_panic;
import silver.runtime.registers : SavedRegisters, silver_save_registers;

alias BlkAttr = core.memory.GC.BlkAttr;
alias BlkInfo = core.memory.GC.BlkInfo;

// This calls druntime's internals, and leaves out the lock because of how they behave in this version,
// so a new one needs the argument in "One thread, no collector lock" in `notes/runtime.md` checked again.
static assert(__VERSION__ == 2113, "druntime changed: re-read ConservativeGC.qalloc, mallocNoSync, "
    ~ "addrOfNoSync and Gcx.fullcollect against collectable and blockOf, Gcx.updateCollectThresholds "
    ~ "against pace, and the argument in notes/runtime.md, before raising this");

/// druntime's collector itself, which its entry points call with the lock held.
private __gshared Gcx* heap;

/// Set while `heap` is allocating. druntime's entry points refuse a finalizer that allocates during
/// a collection, and going around them loses that check, so this keeps it.
private __gshared bool allocating;

/// Starts the collector, which druntime otherwise does at its first use, and finds it. It runs before
/// anything is allocated through here.
void takeHeap() nothrow
{
    gc_init_nothrow();
    auto collector = cast(ConservativeGC) gc_getProxy();
    if (collector is null) panic("the runtime needs druntime's conservative collector");
    heap = collector.gcx;
}

/// The collection `pace` last saw the end of.
private __gshared size_t pacedAfter;

/// Sets when the next collection happens, after one has. druntime paces small blocks (up to half a page)
/// and large ones apart: it collects once the pages in use for either reach `heapSizeFactor` times what
/// that kind had in use after the last collection. A program whose live data is mostly in large blocks
/// while it makes small short-lived ones (an array of a file's lines, then a few small arrays for each
/// line) then collects every time the small pages fill again, however little that is, and each
/// collection marks all the large data: quadratic in the data. So each kind may also grow by half of
/// what both have in use, `heapSizeFactor - 1` times over, which keeps the work of collecting in
/// proportion to what's allocated and the heap within about `heapSizeFactor` times its live data.
private void pace() nothrow @nogc
{
    pacedAfter = numCollections;
    immutable growth = (heap.usedSmallPages + heap.usedLargePages) * (config.heapSizeFactor - 1) / 2;
    immutable small = heap.usedSmallPages + growth;
    immutable large = heap.usedLargePages + growth;
    if (heap.smallCollectThreshold < small) heap.smallCollectThreshold = small;
    if (heap.largeCollectThreshold < large) heap.largeCollectThreshold = large;
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
        if (allocating) silver_panic(null, "allocated while the collector was busy");
        allocating = true;
        BlkInfo block;
        block.base = heap.alloc(size, block.size, attributes, null);
        allocating = false;
        if (numCollections != pacedAfter) pace();
        if (block.base is null) outOfMemory();
        // As `GC.qalloc` does: what the caller won't write mustn't look like pointers to the scan.
        if (!(attributes & BlkAttr.NO_SCAN)) memset(block.base + size, 0, block.size - size);
        block.attr = attributes;
        return block;
    }
    catch (OutOfMemoryError)
    {
        allocating = false;
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
