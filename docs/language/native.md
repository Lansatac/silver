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

A native type is a handle to something a library owns. It has no fields, constructor or patterns, so a value of one only ever comes from a native function. It can be private, but can't take type parameters.

A handle is an ordinary value otherwise. It can be stored in a product, a tuple, an array, an option, a `Ref` or a dictionary, and be a member of a sum (`type Source = :File | Path(text: String)`), and it can be passed to and returned from any function.

- `==` compares addresses: two handles are equal when they point to the same place.
- A handle hashes by its address, so it can be a dictionary key. Handles aren't ordered, so `<` on two is an error.
- A handle prints as its type's name and its address in hexadecimal, as a product with one field would: `File(0x1f4a3c02340)`, or `Some(File(0x1f4a3c02340))` inside an option. `String(f)` and a hole `{f}` give the same text. The address differs from run to run.
- A native type's module can replace its equality, hashing or printing with `opEquals`, `opHash` and `opString`, as for any declared type (see [Equality and hashing](functions.md#equality-and-hashing)).

A handle is never null. A native that can return a null pointer declares its result as an option, and null arrives as `None`. An option of a native type taken as a parameter is passed as null when it's `None`. Only one level crosses: `File?` is a pointer that may be null, and `File??`, `[File]` or a tuple of handles can't appear in a native signature. Nothing checks a native declared to return `File` that returns null.

Silver doesn't manage what a handle refers to. Releasing it is up to the program, through whatever the library provides.

## Strings

A Silver `String` isn't NUL-terminated, so it is never passed directly. `std.c` provides `CString`, a native type, with conversions that copy:

```silver
import std.c

native def getenv(name: CString): CString?

def home(): String? => fromCString(getenv(toCString("HOME"))?)

val file = fopen(toCString("notes.txt"), toCString("r"))
```

- `toCString(s: String): CString` copies every byte of `s` and adds a NUL. A `\0` inside `s` isn't an error: C reads up to the first NUL, so it ends the string there.
- `fromCString(s: CString): String?` copies the bytes up to the NUL. It's `None` when they aren't UTF-8, as for [`decode`](strings.md).
- A `CString` from `toCString` stays valid while the program holds it. One that a native returns, such as `getenv`'s, points into the library's memory and is valid for as long as the library says.
- A `CString` prints like any handle, as `CString(0x...)`, never as its text.

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

`intrinsic def` declares a function the compiler implements itself. It exists so that built-in operations are ordinary names that can be imported, shadowed and qualified. It is available only inside [`lang`](modules.md#the-package-the-compiler-knows), the package the compiler knows. An intrinsic's name says which operation it is, so two intrinsics of one name are an error, except the two forms of `assert`.

`intrinsic alias Name` declares an alias the compiler defines for the platform being compiled for, which is how `lang.c` declares the C types whose width varies, `CLong` and `CULong`, for `std.c` to forward.

`intrinsic type Name<T>(value: T)` declares a type the compiler implements, which is how `lang.ref` declares `Ref`, which `std.ref` forwards. The parameter list is its constructor's: a value of an intrinsic type has no fields and isn't taken apart by a pattern.

## Open questions

- Pointers to Silver data: `Ptr<T>`, passing an array or a string's bytes without copying, and types with a C layout. These wait on generics.
- Calling Silver from C: exporting a function under a C symbol, and passing one as a callback.
- Structures passed by value, and functions with variable arguments such as `printf`.
- Whether the `std.c` names should become distinct types. As aliases, `CLong` and `Int32` are interchangeable on Windows and not on Linux, so code can compile on one and fail on the other. They are aliases to begin with, to find out how much that matters in practice.
- Reading `errno`.
- A tool that writes native declarations from a C header.

## Current implementation

- `native def`, `native("...")`, `native library`, `native type`, `intrinsic def`, `intrinsic alias`, `intrinsic type`, `std.c`, `CString` and its conversions are available.
- The platform being compiled for is always the one the compiler runs on.
- Compiled programs call natives directly. The interpreter can call only the natives it has built in: those that `lang` and the standard library declare, and the C library's `strlen`, `strcmp`, `strchr`, `getenv`, `malloc` and `free`. Calling any other native while interpreting is an error.
- A module's `native library` is passed to the linker when the program calls one of that module's natives or uses one as a value.
- An intrinsic with an `Any` parameter, such as `print`, can only be called, not used as a value.
