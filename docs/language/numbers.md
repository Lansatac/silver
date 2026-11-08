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

An integer literal takes the type expected of it, or the type of the number beside it, and is checked at compile time to fit. With neither, it is an `Int`. A sign is an operator applied to a literal, but a negated literal still adapts, so `-128` is a valid `Int8`.

```silver
val byte: UInt8 = 255
val tooBig: UInt8 = 256    // error
val next = byte + 1        // UInt8
```

Adaptation applies to a literal, not to arithmetic on literals. `val x: UInt8 = 1 + 2` is an error, because `1 + 2` is an `Int`.

## Operators

| Operators | Meaning |
| --- | --- |
| `+ - * / %` | arithmetic |
| `&+ &- &*` | wrapping integer arithmetic |
| `& \| ^` | bitwise and, or, xor |
| `~` (prefix) | bitwise not |
| `<< >>` | shifts |

`^` is xor. Silver has no power operator. `std.math` provides `pow` and `powInt`.

Each has a compound assignment form (`+=`, `&+=`, `<<=` and so on), except `%`.

All operands must be of one numeric type, and values never convert implicitly. The exception is a shift amount, which can be any integer type, since the result has the type of the value being shifted.

## Integer behaviour

An integer operation produces the right answer or stops the program. This is the same for every type and in every build. These panic:

- overflow in `+`, `-`, `*` or negation
- division or remainder by zero
- the most negative value `/` or `%` `-1`
- a shift amount that is negative, or at least the type's width

`<<` does not panic when bits fall off the end. `>>` is logical on unsigned types and arithmetic on signed types. `&+`, `&-` and `&*` wrap instead of panicking.

## Conversions

A conversion is written as a call to the target type: `UInt8(x)`, `Float(n)`, `Int(f)`.

A conversion panics when the value doesn't fit, or is NaN. A `Float` is truncated toward zero first. A literal argument is range-checked at compile time. A conversion never reinterprets bits, so `UInt64(-1)` panics.

## Open questions

- Whether the wrapping operators should be respelled `+%`, `-%` and `*%`. With `&-`, spacing changes the meaning: `a & -1` is bitwise and, while `a &-1` wraps.
- If a `Float32` is added, float literals would adapt the way integer literals do.

## Current implementation

- A shift amount must have the same type as the value being shifted.
