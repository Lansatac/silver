# std.math

Functions of `Float`s, whole powers, `factorial`, and counting bits.

```silver
import std.math

sqrt(2.0)               // 1.41421
atan2(1.0, -1.0)        // 2.35619, three quarters of pi
round(-2.5)             // -3
powInt(3, 4)            // 81
factorial(5)!           // 120
countOnes(0b1011)       // 3
```

| | |
| --- | --- |
| Constants | `pi` |
| Powers and logarithms | `sqrt`, `exp`, `log` (natural), `pow(base, exponent)` |
| Angles, in radians | `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2(y, x)` |
| Whole numbers of a `Float` | `floor`, `ceil`, `round` |
| Integers | `powInt(base, exponent)`, `factorial(n)`, `countOnes(value)` |

- The `Float` functions follow IEEE 754 and C's library: `sqrt(-1.0)` is NaN, `log(0.0)` is negative infinity, and a NaN argument gives NaN.
- `atan2(y, x)` is the angle from the positive x axis to the point `(x, y)`, from -pi to pi.
- `floor`, `ceil` and `round` give a `Float`, which `Int(...)` converts. `round` takes a value halfway between two whole numbers away from zero. Each keeps the sign of a zero, so `ceil(-0.5)` is `-0.0`.
- `powInt` is arithmetic, so it panics as `*` and `/` do: on overflow, and for 0 to a negative power. A negative exponent truncates as division does, so only 1 and -1 give anything but 0.
- `factorial(n): Int ! Negative | Overflow` is `Negative` below 0 and `Overflow` above 20, the largest whose factorial fits an `Int`.
- `countOnes(value: UInt): Int` is how many bits of `value` are 1. A value of another integer type is converted first, as in `countOnes(UInt(byte))`.

## Open questions

- The functions take and give a `Float`. A `Float32` goes through `Float(x)` and back with `Float32(...)`; versions for `Float32` can come later, under the same names, so a call picks one by its argument.
- Whether other maths written for speed counts as arithmetic, and panics, as `powInt` does: see [Errors](../language/errors.md#open-questions).

## Current implementation

- Everything above is built. `sqrt`, `exp`, `log`, `sin`, `cos`, `atan` and `pow` are C's own functions, called directly when compiled and through the same library when interpreted. The rest is plain Silver in `stdlib/std/math.ag`, and `countOnes` is an intrinsic in `lang.bits`, which `std.math` forwards.
