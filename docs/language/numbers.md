# Numbers

## Types

The integer types are `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32` and `UInt64`. `Int` and `UInt` are the same types as `Int64` and `UInt64`. `Float` is a 64-bit floating-point number.

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

An integer literal takes the type expected of it, or the type of the number beside it, and is checked at compile time to fit. With neither, it is an `Int`. An arm of an `if` or `match` that's a literal takes the type of the other arms in the same way, so with `small: UInt8`, `if c => 1 else small` is a `UInt8`. A sign is an operator applied to a literal, but a negated literal still adapts, so `-128` is a valid `Int8`.

```silver
val byte: UInt8 = 255
val tooBig: UInt8 = 256    // error
val next = byte + 1        // UInt8
```

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

## Integer behaviour

An integer operation produces the right answer or stops the program. This is the same for every type and in every build. These panic:

- overflow in `+`, `-`, `*` or negation
- division or remainder by zero
- the most negative value `/` or `%` `-1`
- a shift amount that is negative, or at least the type's width

`<<` does not panic when bits fall off the end. `>>` is logical on unsigned types and arithmetic on signed types. `+%`, `-%` and `*%` wrap instead of panicking.

## Conversions

A conversion is written as a call to the target type: `UInt8(x)`, `Float(n)`, `Int(f)`.

A conversion panics when the value doesn't fit, or is NaN. A `Float` is truncated toward zero first. A literal argument is range-checked at compile time. A conversion never reinterprets bits, so `UInt64(-1)` panics.

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

Apart from the infinities and NaN, the text is a Float literal in Silver and a number in JSON. `String(x)` and string holes give the same text. Showing a fixed number of places, as for money, is a job for a formatting function.

## Open questions

- If a `Float32` is added, float literals would adapt the way integer literals do.
- A function for formatting a Float with a given number of places or significant digits.

## Current implementation

- Adaptation doesn't go through arithmetic yet. Only a literal by itself adapts, also in parentheses or negated, so `val x: UInt8 = 1 + 2` and `1 + 2 + small` are errors while `small + 1 + 2` works; `UInt8(1 + 2)` is the way to write it.
- A literal arm of an `if` or `match` doesn't take the type of the other arms yet, so `if c => 1 else small` is an error unless a `UInt8` is expected of it.
