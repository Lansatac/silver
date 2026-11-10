# Native functions

A native function is implemented outside Silver and reached through the platform's C calling convention. Any language that can export a C function can be called this way.

```silver
module std.math

native def sqrt(x: Float): Float
native("atan2") def angle(y: Float, x: Float): Float
```

`native def` has a signature and no body. It binds the symbol with the function's own name, or the one given in `native("...")`.

- A native function is called like any other, can be `private`, and can be used as a function value.
- It can't take a `mutable` parameter.
- It can't be called while a constant is being evaluated.
- A return type of `Never` is allowed, for a function such as `exit`.

Nothing checks that a declaration matches the function it names. A wrong signature, or a native that misbehaves, can break guarantees that hold everywhere else in Silver. A program's unchecked code is therefore its `native` declarations and its uses of `std.c`.

## Types at the boundary

Only types with a C equivalent can appear in a native signature:

| Silver | C |
| --- | --- |
| `Int8` to `Int64`, `UInt8` to `UInt64` | `int8_t` to `int64_t`, `uint8_t` to `uint64_t` |
| `Float` | `double` |
| `Bool` | `bool` |
| `Unit`, as a return type | `void` |
| A native type | A pointer |
| An option of a native type | A pointer that may be null |

`String`, arrays, tuples, user types, other options and function types can't cross. A string is converted explicitly, as described below.

C's own integer types differ between platforms: `long` is 32 bits on Windows and 64 on Linux. `std.c` names them (`CInt`, `CLong`, `CSize` and the rest), each an alias for the Silver type of the right width on the platform being compiled for.

## Native types

```silver
native type File

native def fopen(path: CString, mode: CString): File?
native def fclose(file: File): CInt
```

A native type is a handle to something a library owns. It has no fields, constructor or patterns, so a value of one only ever comes from a native function. It can be stored, passed and compared with `==`, which compares addresses.

A handle is never null. A native that can return a null pointer declares its result as an option, and null arrives as `None`.

Silver doesn't manage what a handle refers to. Releasing it is up to the program, through whatever the library provides.

## Strings

A Silver `String` isn't NUL-terminated, so it is never passed directly. `std.c` provides `CString`, a native type, with conversions that copy:

```silver
import std.c

val file = fopen(toCString("notes.txt"), toCString("r"))
val text = fromCString(getenv(toCString("HOME"))?)
```

## Libraries

```silver
module sdl.video
native library "SDL2"

native("SDL_Init") def init(flags: UInt32): CInt
```

`native library` names the library that provides every native function in the module. A module has at most one. Without it, natives are looked up in the C library and Silver's own runtime.

## Lifetimes

Anything passed to a native function is valid until that call returns. A library that keeps a pointer for longer must be given something the program keeps alive itself, such as a handle the library allocated.

## Intrinsics

```silver
intrinsic def panic(message: String): Never
```

`intrinsic def` declares a function the compiler implements itself. It exists so that built-in operations are ordinary names that can be imported, shadowed and qualified. It is available only inside the standard library.

`intrinsic alias Name` declares an alias the compiler defines for the platform being compiled for, which is how `std.c` names the C types whose width varies, such as `CLong`.

## Open questions

- Pointers to Silver data: `Ptr<T>`, passing an array or a string's bytes without copying, and types with a C layout. These wait on generics.
- Calling Silver from C: exporting a function under a C symbol, and passing one as a callback.
- Structures passed by value, and functions with variable arguments such as `printf`.
- Whether the `std.c` names should become distinct types. As aliases, `CLong` and `Int32` are interchangeable on Windows and not on Linux, so code can compile on one and fail on the other. They are aliases to begin with, to find out how much that matters in practice.
- Reading `errno`.
- A tool that writes native declarations from a C header.

## Current implementation

- `native def`, `native("...")`, `native library`, `intrinsic def`, `intrinsic alias` and `std.c` are available. `native type`, `CString` and its conversions aren't, so a native signature can use only the integer types, `Float` and `Bool`, with `Unit` or `Never` also allowed as the return type.
- The platform being compiled for is always the one the compiler runs on.
- A native function can't be used as a function value.
- Compiled programs call natives directly. The interpreter can call only the standard library's natives, which it has built in; calling any other native while interpreting is an error.
- A module's `native library` is passed to the linker when the program calls one of that module's natives.
