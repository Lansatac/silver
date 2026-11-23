# std.char

`std.char` has `toChar`, the questions `isDigit` (the ten ASCII digits), `isAsciiLetter` and `isWhitespace` (Unicode white space), and `toAsciiUpper` and `toAsciiLower`, which change only the 26 unaccented letters.

```silver
import std.char

isDigit('7')            // true
toAsciiUpper('q')       // Q
toChar(0x1F600)         // Some(😀)
toChar(0xD800)          // None: a surrogate isn't a Char
```

`toChar(n: Int)` is the `Char` whose value is `n`, or `None` when `n` isn't a Unicode scalar value.

## Open questions

- Case mapping beyond ASCII, which needs Unicode's tables.

## Current implementation

- Everything above is built, in plain Silver in `stdlib/std/char.ag`. `toChar` is declared in `lang.char`, which `std.char` forwards.
