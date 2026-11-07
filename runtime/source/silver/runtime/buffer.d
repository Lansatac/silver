/// The buffers behind Strings and arrays, and the frontier rule that makes `~=` amortized O(1)
/// with values that never change.
///
/// A buffer is a GC block starting with a Header. A value is a slice of it and only ever covers
/// bytes below `used`. Appending to a value that ends exactly at `used`, the frontier, writes past
/// it and bumps `used`: no existing value reaches those bytes, so none can see the write, and when
/// two values share the frontier the first append moves it and the second copies.
///
/// Every value's pointer is null, into a private global, or into a buffer. That's what lets
/// `headerOf` trust whatever GC block a pointer is in, so memory from anywhere else (`to!string`,
/// `readln`) has to be copied in first. `newString` does that.
module silver.runtime.buffer;

import core.memory : GC;
import core.stdc.string : memcpy;

private struct Header
{
    /// Bytes of elements written so far.
    size_t used;
    /// Bytes of elements the block has room for.
    size_t capacity;
}

// Elements are at most 16-aligned, like the block itself.
static assert(Header.sizeof == 16);

/// The last block looked up or allocated, since the lookup takes the GC lock and an append in a
/// loop keeps asking about the same one. Thread-local, and as a GC root it keeps the block alive,
/// so its memory can't be reused for a block with other bounds while it's cached.
private Header* lastBlock;

private char* elementsOf(Header* header) nothrow @nogc
{
    return cast(char*)(header + 1);
}

/// The header of the buffer `data` points into, or null if it isn't on the heap. `data` must point
/// at an element: one past the last element of a full block is already in the next block.
private Header* headerOf(const(void)* data) nothrow
{
    auto cached = lastBlock;
    if (cached !is null && data >= elementsOf(cached) && data < elementsOf(cached) + cached.capacity)
    {
        return cached;
    }
    auto block = GC.query(cast(void*) data);
    if (block.base is null) return null;
    lastBlock = cast(Header*) block.base;
    return lastBlock;
}

extern (C) nothrow:

/// `(data, length)` followed by `sourceLength` elements from `source`, in place if `data` ends at
/// its buffer's frontier with room, and otherwise in a new buffer whose frontier the result owns.
/// A null `source` leaves the new elements for the caller to write. Lengths count elements of
/// `elementSize` bytes, which isn't 0: arrays with nothing to store have no buffer. `grow` leaves
/// slack for further appends.
void silver_array_append(const(void)* data, size_t length, const(void)* source, size_t sourceLength,
    size_t elementSize, bool grow, const(void)** resultData, size_t* resultLength)
{
    if (sourceLength == 0)
    {
        *resultData = data;
        *resultLength = length;
        return;
    }

    auto existing = length * elementSize;
    auto added = sourceLength * elementSize;
    *resultLength = length + sourceLength;

    // Without elements, `data` may be one past the end of a full block, so it says nothing.
    if (length > 0)
    {
        auto header = headerOf(data);
        if (header !is null && cast(const(char)*) data + existing == elementsOf(header) + header.used
            && header.capacity - header.used >= added)
        {
            if (source !is null) memcpy(elementsOf(header) + header.used, source, added);
            header.used += added;
            *resultData = data;
            return;
        }
    }

    auto total = existing + added;
    // A block of single bytes can't hold a pointer, so the GC needn't look through a String's text.
    auto attributes = elementSize == 1 ? GC.BlkAttr.NO_SCAN : GC.BlkAttr.NONE;
    auto block = GC.qalloc(Header.sizeof + (grow ? total * 2 : total), attributes);
    auto header = cast(Header*) block.base;
    header.used = total;
    header.capacity = block.size - Header.sizeof;
    lastBlock = header;

    auto elements = elementsOf(header);
    if (existing > 0) memcpy(elements, data, existing);
    if (source !is null) memcpy(elements + existing, source, added);
    *resultData = elements;
}

extern (D):

/// `text` as a String in a buffer of its own.
void newString(const(char)[] text, const(char)** data, size_t* length) nothrow
{
    silver_array_append(null, 0, text.ptr, text.length, 1, false, cast(const(void)**) data, length);
}
