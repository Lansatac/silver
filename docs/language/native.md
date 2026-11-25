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
| `Float32` | `float` |
| A native type with no fields | A pointer |
| An option of a native type with no fields | A pointer that may be null |
| A native type with fields | A `struct` passed by value |

`String`, arrays, tuples, other user types, other options and function types can't cross. A string is converted explicitly, as described below.

C's own integer types differ between platforms: `long` is 32 bits on Windows and 64 on Linux. [`std.c`](../stdlib/c.md) names them (`CInt`, `CLong`, `CSize` and the rest), each an alias for the Silver type of the right width on the platform being compiled for.

A parameter has to be declared with the C function's own width. A C function taking an `int` is declared with `CInt`, not `Int8`: Windows' calling convention leaves the upper bits of a narrower argument undefined, so the function would read garbage. A result can be declared narrower than C's, or as `Bool` for one that is only ever 0 or 1, and is cut down to it.

## Native types

```silver
native type File

native def fopen(path: CString, mode: CString): File?
native def fclose(file: File): CInt
```

A native type is a handle to something a library owns. It has no fields, constructor or patterns, so a value of one only ever comes from a native function. It can be private, but can't take type parameters.

A handle is an ordinary value otherwise. It can be stored in a product, a tuple, an array, an option, a `Ref` or a dictionary, and be a member of a sum (`type Source = :File | Path(text: String)`), and it can be passed to and returned from any function.

- `==` compares addresses: two handles are equal when they point to the same place.
- A handle hashes by its address, so it can be a dictionary key.
- A handle isn't ordered unless its module conforms its type to [`Ord`](types.md#ordering), as for any declared type; without that, `<` on two is an error.
- A handle prints as its type's name and its address in hexadecimal, as a product with one field would: `File(0x1f4a3c02340)`, or `Some(File(0x1f4a3c02340))` inside an option. `String(f)` and a hole `{f}` give the same text. The address differs from run to run, and between the interpreter and a compiled program, so under `silver test -b both` a test that prints a handle, or a failing `expect` with one on either side, is reported as the backends disagreeing.
- A native type's module can replace its equality, hashing or printing with `opEquals`, `opHash` and `opString`, as for any declared type (see [Equality and hashing](functions.md#equality-and-hashing)), and these are used wherever a handle is compared, hashed or printed. An `opString` gives a printed form that's the same on every run and backend.

A handle is never null. A native that can return a null pointer declares its result as an option, and null arrives as `None`. An option of a native type taken as a parameter is passed as null when it's `None`. Only one level crosses: `File?` is a pointer that may be null, and `File??`, `[File]` or a tuple of handles can't appear in a native signature.

Nothing checks a native declared to return `File` that returns null. The null handle then prints as `File(0x0)`, and passing it on, to `fromCString` or to a native that doesn't expect null, crashes the program with no message.

Silver doesn't manage what a handle refers to. Releasing it is up to the program, through whatever the library provides.

## Structures

```silver
module raylib
native library "raylib"

native type Vector2(x: Float32, y: Float32)
native type Color(r: UInt8, g: UInt8, b: UInt8, a: UInt8)

native("DrawCircleV") def drawCircle(center: Vector2, radius: Float32, color: Color): Unit
native("GetMousePosition") def mousePosition(): Vector2
```

A native type with fields is a C `struct` with those fields in that order, laid out as the platform's C compiler lays it out. A native function takes and returns one by value, as C does.

- Each field's type is one that can cross: an integer, `Float`, `Float32`, `Bool`, a native type, or an option of a native type with no fields. Anything else is an error at the field. A structure inside a structure is held by value, so a native type can't contain itself.
- It is an ordinary product otherwise. It has a constructor, fields, `with`, patterns, `==`, a hash and a printed form, it can be stored anywhere a value can, and any module can write [operator functions](functions.md#operators) for it.
- It can't take type parameters or have an invariant, since C can make any value of it.
- An option of one can't cross: only a pointer can be null.

Silver's own values have no fixed layout, so a structure is put into C's layout as it's passed and read out of it as it comes back. A native that takes a pointer to a structure can't be declared yet.

## Strings

A Silver `String` isn't NUL-terminated, so it is never passed directly. [`std.c`](../stdlib/c.md#strings)'s `CString` is a native type for a C string, with `toCString` and `fromCString` to copy one to and from a `String`:

```silver
import std.c

native def getenv(name: CString): CString?

def home(): String? => fromCString(getenv(toCString("HOME"))?)
```

## Libraries

```silver
module sdl.video
native library "SDL2"

native("SDL_Init") def init(flags: UInt32): CInt
```

`native library` names the library that provides every native function in the module. A module has at most one. Without it, natives are looked up in the C library and Silver's own runtime.

A compiled program is linked against the library. An interpreted one loads it as the program starts, so it must exist as a shared library, `SDL2.dll` on Windows or `libSDL2.so` on Linux, where the system looks for shared libraries. Either way, a library or function that can't be found is an error before `main` runs.

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
- Functions with variable arguments such as `printf`.
- In a structure: a fixed-size array field (`char name[32]`), a union, a bit field, and packing or alignment other than the C compiler's default.
- Where a library is found. `native library` gives a name, and the linker and the system's loader find it by their own search paths, set through the environment. A library whose file has a different name on each platform, or that isn't on those paths, wants a setting in `silver.toml`.
- What a binding for a C library looks like as a package: names (a function or value can't start with a capital, so `InitWindow` is bound as `initWindow`), an `enum` (an alias for `CInt` and a constant per member, since C can return a value outside it), and macros.
- Converting a handle to an integer, or to another native type. A sentinel pointer that isn't null, such as Windows' `INVALID_HANDLE_VALUE` or POSIX's `MAP_FAILED`, arrives as `Some(...)` and can't be told from a real handle, and a `Block` from `malloc` can't become a `CString`. For now such a pointer can be declared as `UInt64`, the integer of its width, which C passes the same way, and compared as a number.
- Reading `errno`.
- A tool that writes native declarations from a C header.

## Current implementation

- `native def`, `native("...")`, `native library`, `native type`, `intrinsic def`, `intrinsic alias` and `intrinsic type` are available.
- `Float32` in a native signature and native types with fields aren't built: a native type takes no field list, and either in a signature is refused.
- The platform being compiled for is always the one the compiler runs on.
- Compiled programs call natives directly. The interpreter can call only the natives it has built in: those that `lang` and the standard library declare, and the C library's `strlen`, `strcmp`, `strchr`, `getenv`, `malloc`, `free`, `abs`, `toupper`, `tolower`, `isdigit` and `ilogb`, each for any declaration C passes the same way as its own signature: a pointer as a native type, an option of one or `UInt64`, an integer parameter as an integer type at least as wide as C's, and an integer result as any integer type or `Bool`. Calling any other native while interpreting, or one of these declared some other way, is an error.
- A module's `native library` is passed to the linker when the program calls one of that module's natives or uses one as a value.
- An intrinsic with an `Any` parameter, such as `print`, can only be called, not used as a value.
