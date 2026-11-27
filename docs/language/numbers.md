# Numbers

## Types

The integer types are `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32` and `UInt64`. `Int` and `UInt` are the same types as `Int64` and `UInt64`. `Float` is a 64-bit floating-point number, and `Float32` a 32-bit one. `Float64` is the same type as `Float`, as `Int64` is as `Int`.

## Literals

```silver
42       // decimal
0xff     // hexadecimal
0b1010   // binary; digits after the first may be separated by _
1.5      // float
1.5e-2   // float with an exponent
1e3
```

There are no type suffixes. Write `1.0` or `Float(1)`.

A float literal is a `Float` unless the type expected of it is `Float32`, and wherever an integer literal adapts to `Float` it adapts to `Float32` in the same way:

```silver
val x: Float32 = 1.5     // a Float32
val y = 1.5              // a Float
val z: Float32 = 3       // 3.0, a Float32
x + 0.25                 // the literal is a Float32, beside one
val big: Float32 = 1e40  // error: doesn't fit
```

A float literal is rounded once, from its text, to the nearest value of its type, and one that rounds to infinity is a compile error, for a `Float` as for a `Float32`: `1e400` is an error wherever it's a `Float`, and `1e40` is one where a `Float32` is expected. A literal too small for its type rounds to zero. Only a literal is checked: a conversion or arithmetic that leaves the range is infinity, so `Float32(1e40)` and `1e300 * 1e300` are `inf`.

An integer literal takes the type expected of it, or the type of the number beside it, and is checked at compile time to fit. With neither, it is an `Int`. A literal has [no type of its own](types.md#a-type-of-its-own), so wherever several values have to share a type, the ones that have a type decide it and the literals take it: with `small: UInt8`, `if c => 1 else small` is a `UInt8` and `[1, small]` a `[UInt8]`. A sign is an operator applied to a literal, but a negated literal still adapts, so `-128` is a valid `Int8`.

```silver
val byte: UInt8 = 255
val tooBig: UInt8 = 256    // error
val next = byte + 1        // UInt8
```

Where an integer literal could become more than one type, as an argument of overloaded functions or a value of a sum, it's an integer first: an `Int` if an `Int` fits, otherwise another integer type, and only where no integer type fits is it read as the float literal of the same value, `1` as `1.0`, which is a `Float` before a `Float32`. A negated literal is read the same way.

```silver
def f(x: Int): String     def f(x: Float): String
f(1)                      // f(Int)

def h(x: Int8): String    def h(x: Float): String
h(1)                      // h(Int8): both take it in one step, and an integer is read first

def k(x: Float32): String def k(x: Float): String
k(1)                      // k(Float), as k(1.0) is

def g(x: Int8): String    def g(x: Int16): String
g(1)                      // error: two integer types, and neither is the default
```

Overload choice [counts steps](functions.md#overloading) first, so how a literal is read is the last tie-break, deciding only between functions that fit a call equally well otherwise: with `m(x: Int8?)` and `m(x: Float)`, `m(1)` calls `m(Float)`, a step fewer than the option, and `m(Int8(1))` says the other.

A type fits a literal by its value, since a literal is checked to fit wherever it goes: `300` isn't an `Int8`, so a function that takes one isn't a candidate for it.

```silver
h(300)                    // h(Float): 300 doesn't fit in an Int8
g(300)                    // g(Int16)

def u(x: UInt8): String   def u(x: Float): String
u(200)                    // u(UInt8)
u(-1)                     // u(Float)
```

Only a literal and a negated literal are read by their value. Arithmetic on literals fits by its type, as below, so `u(200 + 100)` calls `u(UInt8)` and overflows when it runs.

A sum takes a literal as one of its number members, the one that overloaded functions taking each would be chosen by:

```silver
type S = :Int8 | :Int
val s: S = 1              // the Int, as w(1) calls w(Int) of w(Int8) and w(Int)

type N = :Float32 | :Float
val t: N = 1              // a Float, as 1.0 is

type M = :Int8 | :Float
val a: M = 1              // the Int8
val b: M = 300            // the Float

type P = :Int8 | :Int16
val p: P = 1              // error: two integer members, and neither is the default
```

An integer literal too large for every integer type is the float literal of its value where only a float fits it, so `val x: Float = 99999999999999999999` is `1e20`. Where an integer type fits, it's an integer, and too large.

Adaptation goes through arithmetic. An arithmetic or bitwise operator passes the type expected of it to its operands, and an operand made only of literals takes the type of the operand beside it, on either side:

```silver
val small: UInt8 = 3

val sum: UInt8 = 1 + 2        // both literals are UInt8s
val mask: UInt8 = 1 << 3      // 8
val total = 1 + 2 + small     // UInt8, as small + 1 + 2 is
small & (1 << 3)              // the mask is a UInt8
small == 1 + 2                // true
val half: Float = 1 / 2       // 0.5: both literals are Floats
```

- The operators are `+ - * / %`, the wrapping forms, `& | ^`, prefix `-` and `~`, and the value side of a shift. A shift amount keeps its own type.
- An expected option or error union passes its value's type, so `val x: UInt8? = 1 + 2` works. Any expected type that isn't a number passes nothing.
- Only literals adapt. A value has its type already, so with `n: Int`, `val z: UInt8 = n + 1` is an error at `n`.
- Each literal is checked at compile time to fit, and the arithmetic then behaves as it does anywhere: `val y: UInt8 = 200 + 100` panics with `Integer overflow` when it runs. In a [constant](bindings.md#top-level-constants), which is evaluated at compile time, it's a compile error.
- With nothing expected and no number beside it, arithmetic on integer literals is an `Int`.

Literals that have to [share one type](types.md#a-shared-type), with nothing that has a type to decide it and nothing expected, take it together: a `Float` if any of them is a float literal, and an `Int` otherwise, since a `Float` is the one type both kinds can be. That's so wherever values share a type: an array's elements, a dictionary's keys and its values, the arms of an `if` or `match`, the two sides of `??`, and the arguments that reach one type parameter of a generic function.

```silver
def id<T>(x: T): T => x
def pair<T>(a: T, b: T): T => b

val xs = [1, 2.5]                // a [Float]
val y = if c => 1 else 2.5       // a Float
val zs = [[1], [2.5]]            // a [[Float]]
val g = pair(1, 1.5)             // a Float
val p = (1, 2.5)                 // an (Int, Float): a tuple's parts don't share a type

val n = 3
val bad = [n, 2.5]               // error: n is an Int, and decides
```

A literal argument doesn't fix the type parameter of a generic function by itself. The arguments that have a type or the type expected of the call do, and only when nothing else does, the literals take their type as above:

```silver
val d: Float32 = id(1.5)         // a Float32
val e = id(1.5)                  // a Float
val h = pair(Float32(1.0), 2.5)  // a Float32: the other argument fixes it
```

A float literal never becomes an integer type this way.

## Operators

| Operators | Meaning |
| --- | --- |
| `+ - * / %` | arithmetic |
| `+% -% *%` | wrapping integer arithmetic |
| `& \| ^` | bitwise and, or, xor |
| `~` (prefix) | bitwise not |
| `<< >>` | shifts |

`^` is xor. Silver has no power operator. [`std.math`](../stdlib/math.md) provides `pow` and `powInt`.

Each has a compound assignment form (`+=`, `+%=`, `<<=` and so on), except `%`.

All operands must be of one numeric type, and values never convert implicitly. The exception is a shift amount, which can be any integer type, since the result has the type of the value being shifted.

`+ - * / %` and prefix `-` on anything but two built-in numbers call an [operator function](functions.md#operator-functions), so a type of your own can have them, and so do `& | ^ << >>` and prefix `~` on anything but two built-in numbers.

## Integer behaviour

An integer operation produces the right answer or stops the program. This is the same for every type and in every build. These panic:

- overflow in `+`, `-`, `*` or negation
- division or remainder by zero
- the most negative value `/` or `%` `-1`
- a shift amount that is negative, or at least the type's width

`<<` does not panic when bits fall off the end. `>>` is logical on unsigned types and arithmetic on signed types. `+%`, `-%` and `*%` wrap instead of panicking.

## Conversions

A conversion is written as a call to the target type: `UInt8(x)`, `Float(n)`, `Int(f)`.

A conversion to an integer type panics when the value doesn't fit, or is NaN. A `Float` or `Float32` is truncated toward zero first. A literal argument is range-checked at compile time. A conversion never reinterprets bits, so `UInt64(-1)` panics.

A conversion to a float type never panics, since float arithmetic doesn't:

```silver
Float(x)         // x: Float32. Exact
Float32(d)       // d: Float. The nearest Float32, inf or -inf when out of range, nan for NaN
Float32(n)       // n: an integer. The nearest Float32
Float(n)         // the nearest Float
Float32(1e300)   // inf
```

`Float32(d)` rounds a `Float`, so with a literal written inside it the text is rounded twice, first to a `Float` and then to a `Float32`. For text that lies just past the midpoint between two `Float32`s, closer to it than a `Float` can tell, that can differ by one step from `val x: Float32 = text`, which rounds the text once.

`Float32` and `Float` never convert implicitly, so `x + d` with a `Float32` and a `Float` is an error: write `Float(x) + d` to compute in double precision, or `x + Float32(d)` to compute in single.

## Printing floats

A `Float` prints as the shortest text that reads back as the same value, and of those the nearest to it. So printing never loses anything, and a Float never prints like an integer:

```silver
printl(1.0)           // 1.0
printl(0.1 + 0.2)     // 0.30000000000000004
printl(1234567.0)     // 1234567.0
printl(0.0001)        // 0.0001
printl(0.00001)       // 1e-5
printl(1e16)          // 1e16
printl(-0.0)          // -0.0
printl(1e300 * 1e300) // inf
```

- Values from `1e-4` up to below `1e16` are written out with a `.`, ending in `.0` when there's no fraction.
- Others are written with an exponent, as `1.5e-7` or `1e16`, with no `+` and no leading zeros in the exponent.
- Infinities print as `inf` and `-inf`, and every NaN as `nan`, whatever its sign bit.

A `Float32` prints the same way, as the shortest text that reads back as the same `Float32`. It has fewer digits to show than a `Float` has, so the text can differ from a `Float`'s for the same number:

```silver
printl(Float32(0.1))           // 0.1
printl(Float(Float32(0.1)))    // 0.10000000149011612
printl(Float32(16777216.0) + Float32(1.0) == Float32(16777216.0))   // true: arithmetic is single precision
```

Apart from the infinities and NaN, the text is a Float literal in Silver and a number in JSON. `String(x)` and string holes give the same text. Showing a fixed number of places, as for money, is a job for a formatting function.

## Open questions

- Numeric interfaces. Generic code over the integer types, or over both float types, has no bound to ask for: `Ord` is the only interface they share, and `compare` is declared once for each type. A bound such as `T: Floating` over `Float` and `Float32` isn't designed. The two float types have the same operators, conversion spelling and function names, and no width in a function's name, so that one could describe them both.
- A function for formatting a Float with a given number of places or significant digits.

## Current implementation

- A float literal's range is checked once checking is done, since its type isn't final before, so Core and the backends never see an infinite literal.
- `std.math` is `Float`-only: a `Float32` goes through `Float(x)` and back. `parseFloat` returns a `Float`.
- A `Float32` is a 32-bit `float` in compiled code. The interpreter holds it as the `double` it widens to, rounded to a `float` after every operation, so both compute in single precision.
- Adaptation doesn't go through arithmetic yet. Only a literal by itself adapts, also in parentheses or negated, so `val x: UInt8 = 1 + 2` and `1 + 2 + small` are errors while `small + 1 + 2` works; `UInt8(1 + 2)` is the way to write it.
- A literal fits a type by the type alone, not its value, in overload choice and in a sum: with `u(x: UInt8)` and `u(x: Float)`, `u(-1)` and `u(300)` choose `u(UInt8)` and are then errors, and `h(300)` with `h(x: Int8)` and `h(x: Int16)` is ambiguous.
- A sum takes an integer literal as its one integer member, or with none as its `Float` member, then its `Float32`. With more than one integer member it's an error even when `Int` is among them, so `val s: S = 1` with `type S = :Int8 | :Int` is.
- Literals take a type together only as arguments reaching one type parameter of a generic function. Beside a part that has a type of its own a literal takes that type, as in `[1, small]` and `if c => 1 else small`, but `[1, 2.5]`, `if c => 1 else 2.5`, `["a": 1, "b": 2.5]`, `[[1], [2.5]]`, `same([1], [2.5])` and `Some(1) ?? 2.5` are errors that say the types differ.
