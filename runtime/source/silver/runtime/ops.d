/// Operators the IR can't do in one instruction.
module silver.runtime.ops;

import core.stdc.string : memcmp;

extern (C) nothrow @nogc:

/// Negative, zero or positive as `a` sorts before, equals or sorts after `b`: by unsigned bytes,
/// then by length, which is how D compares the interpreter's strings.
int silver_string_compare(const(char)* a, size_t aLength, const(char)* b, size_t bLength)
{
    auto common = aLength < bLength ? aLength : bLength;
    // An empty string's pointer can be null, which memcmp doesn't allow even for no bytes.
    auto order = common == 0 ? 0 : memcmp(a, b, common);
    if (order != 0) return order;
    return aLength < bLength ? -1 : aLength > bLength;
}

/// A String's hash: FNV-1a over its bytes, then mixed by MurmurHash3's finalizer, as the
/// interpreter's is. Codegen mixes other primitives' bits with the finalizer itself.
ulong silver_hash_string(const(ubyte)* bytes, size_t length)
{
    ulong hash = 0xcbf29ce484222325;
    foreach (b; bytes[0 .. length]) hash = (hash ^ b) * 0x100000001b3;
    hash ^= hash >> 33;
    hash *= 0xff51afd7ed558ccd;
    hash ^= hash >> 33;
    hash *= 0xc4ceb9fe1a85ec53;
    return hash ^ (hash >> 33);
}
