/// Every heap allocation generated code makes for an object goes through here, and for a String
/// or array through `silver.runtime.buffer`, so the allocator can change (to a collector of
/// Silver's own, say) without touching codegen.
module silver.runtime.memory;

import core.memory : GC;

/// `size` bytes from druntime's GC. It scans Silver's stack frames conservatively, like any
/// other stack, so memory reachable from generated code stays alive.
extern (C) void* silver_alloc(size_t size) nothrow
{
    return GC.malloc(size);
}
