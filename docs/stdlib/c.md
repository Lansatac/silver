# std.c

The names [native declarations](../language/native.md) use for C's types: its integer and floating-point types, as the Silver type of the same width on the platform being compiled for, and its strings.

## Integer types

| Name | Is | C |
| --- | --- | --- |
| `CChar`, `CUChar` | `Int8`, `UInt8` | `char` (signed on every supported platform), `unsigned char` |
| `CShort`, `CUShort` | `Int16`, `UInt16` | `short`, `unsigned short` |
| `CInt`, `CUInt` | `Int32`, `UInt32` | `int`, `unsigned int` |
| `CLong`, `CULong` | `Int32` and `UInt32` on Windows, `Int64` and `UInt64` elsewhere | `long`, `unsigned long` |
| `CLongLong`, `CULongLong` | `Int64`, `UInt64` | `long long`, `unsigned long long` |
| `CSize` | `UInt64` | `size_t` |

Each is an alias, so a `CInt` is an `Int32` and converts and compares as one.

## Floating-point types

| Name | Is | C |
| --- | --- | --- |
| `CFloat` | `Float32` | `float` |
| `CDouble` | `Float` | `double` |

The same on every platform, so each is an alias too.

## Strings

A Silver `String` isn't NUL-terminated, so it is never passed to C directly. `CString` is a [native type](../language/native.md#native-types), with conversions that copy:

```silver
import std.c

native def getenv(name: CString): CString?

def home(): String? => fromCString(getenv(toCString("HOME"))?)

```

- `toCString(s: String): CString` copies every byte of `s` and adds a NUL. A `\0` inside `s` isn't an error: C reads up to the first NUL, so it ends the string there.
- `fromCString(s: CString): String?` copies the bytes up to the NUL. It's `None` when they aren't UTF-8, as for [`decode`](string.md).
- A `CString` from `toCString` stays valid while the program holds it. It's Silver's memory, so it must never be given to the library's `free`. One that a native returns, such as `getenv`'s, points into the library's memory and is valid for as long as the library says.
- A `CString` prints like any handle, as `CString(0x...)`, never as its text.

## Open questions

- Whether the `std.c` names should become distinct types. As aliases, `CLong` and `Int32` are interchangeable on Windows and not on Linux, so code can compile on one and fail on the other. They are aliases to begin with, to find out how much that matters in practice.

## Current implementation

- Everything above is built. `CLong`, `CULong` and `CString` with its conversions are declared in `lang.c`, which `std.c` forwards.
