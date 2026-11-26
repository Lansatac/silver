/// `lang.c`'s conversions between a String and a `CString`, and how a native type's value prints.
module silver.runtime.c;

import core.exception : OutOfMemoryError;
import core.memory : GC;
import core.stdc.string : memcpy, strlen;

import silver.runtime.buffer : newString;
import silver.runtime.memory : collectable;
import silver.runtime.registers : SavedRegisters, silver_save_registers;
import silver.runtime.panic : outOfMemory;

extern (C) nothrow:

/// A copy of the String's bytes followed by a NUL, in a block the collector keeps while the
/// `CString` points to it. A NUL inside the String ends the C string early.
const(char)* silver_toCString(const(char)* data, size_t length)
{
    auto block = cast(char*) collectable(length + 1, GC.BlkAttr.NO_SCAN).base;
    if (length > 0) memcpy(block, data, length);
    block[length] = 0;
    return block;
}

/// Copies the bytes up to the NUL into a String, if they're UTF-8.
bool silver_fromCString(const(char)* text, const(char)** data, size_t* length)
{
    import std.utf : UTFException, validate;

    SavedRegisters saved = void;
    silver_save_registers(&saved);
    *data = null;
    *length = 0;
    auto bytes = text[0 .. strlen(text)];
    try
    {
        try validate(bytes);
        catch (UTFException) return false;
    }
    catch (OutOfMemoryError)
    {
        outOfMemory();
    }
    catch (Exception)
    {
        return false;
    }
    newString(bytes, data, length);
    return true;
}

/// `0x` and the address in lowercase hex digits.
void silver_format_address(const(void)* address, const(char)** data, size_t* length)
{
    char[2 + 2 * size_t.sizeof] buffer = void;
    newString(addressText(address, buffer[]), data, length);
}

extern (D):

/// The address's text, written into `buffer`, which has room for every digit.
package const(char)[] addressText(const(void)* address, char[] buffer) nothrow @nogc
{
    auto value = cast(size_t) address;
    auto at = buffer.length;
    do
    {
        buffer[--at] = "0123456789abcdef"[value & 0xf];
        value >>= 4;
    }
    while (value != 0);
    buffer[--at] = 'x';
    buffer[--at] = '0';
    return buffer[at .. $];
}
