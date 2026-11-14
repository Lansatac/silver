/// Every heap allocation generated code makes for an object goes through here, and for a String
/// or array through `silver.runtime.buffer`, so the allocator can change (to a collector of
/// Silver's own, say) without touching codegen.
///
/// The collector is druntime's, which finds what generated code holds by scanning its stack and
/// the general-purpose registers. On Win64, xmm6 to xmm15 also survive a call, optimized code keeps
/// pointers in them (two adjacent ones loaded as a vector), and druntime doesn't look there. So
/// every runtime function that can start a collection puts them in its own frame first, with
/// `SavedRegisters`: see "What the collector can see" in `notes/runtime.md`.
module silver.runtime.memory;

import core.memory : GC;

version (Win64) version (X86_64) version = CalleeSavedVectorRegisters;

version (CalleeSavedVectorRegisters)
{
    version (D_InlineAsm_X86_64) {}
    else static assert(0, "saving xmm6 to xmm15 for the collector needs an assembler for this compiler");

    /// The registers a callee must preserve that druntime's stack scan doesn't save. It has to be a
    /// local of a frame that is still running when the collector does.
    struct SavedRegisters
    {
        align(16) size_t[20] words = void;
    }

    extern (C) void silver_save_registers(SavedRegisters* into) nothrow @nogc
    {
        asm nothrow @nogc
        {
            naked;
            movups [RCX], XMM6;
            movups [RCX + 16], XMM7;
            movups [RCX + 32], XMM8;
            movups [RCX + 48], XMM9;
            movups [RCX + 64], XMM10;
            movups [RCX + 80], XMM11;
            movups [RCX + 96], XMM12;
            movups [RCX + 112], XMM13;
            movups [RCX + 128], XMM14;
            movups [RCX + 144], XMM15;
            ret;
        }
    }
}
else
{
    // The System V x86-64 ABI preserves no vector register across a call, so a pointer in one is
    // on the caller's stack by the time anything here runs.
    struct SavedRegisters
    {
    }

    extern (C) void silver_save_registers(SavedRegisters* into) nothrow @nogc
    {
    }
}

/// Memory the collector owns, at least `size` bytes, after making the caller's registers visible
/// to it. Every allocation the runtime asks for by name comes through here; a function that
/// allocates through D's library instead (`to!string`, `~`, `readln`) saves them itself.
GC.BlkInfo collectable(size_t size, uint attributes) nothrow
{
    SavedRegisters saved = void;
    silver_save_registers(&saved);
    return GC.qalloc(size, attributes);
}

/// `size` bytes for an object of fixed size, which no pointer walks along: see `buffer` for what
/// an array needs past its end.
extern (C) void* silver_alloc(size_t size) nothrow
{
    return collectable(size, GC.BlkAttr.NONE).base;
}
