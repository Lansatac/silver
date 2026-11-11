# Strings

A `String` is an immutable sequence of UTF-8 bytes. It's a distinct type, not an array, so `"a" == [97]` doesn't type-check. A string may contain a NUL byte.

## Literals

String literals are written `"..."` on one line. The escapes are `\n`, `\r`, `\t`, `\0`, `\"`, `\\`, `\{` and `\}`, and `\u{...}` with one to six hex digits naming a Unicode scalar value, which is written as its UTF-8 bytes: `"\u{1b}[31m"` starts with the escape character, and `"caf\u{e9}"` is `"café"`. A surrogate (`D800` to `DFFF`) or anything above `10FFFF` is an error, as is any other escape.

## Interpolation

Every string interpolates. `{expr}` holds one expression, of any type `print` accepts.

```silver
val message = "{count} of {total} done"
```

`{}` is an error. A literal brace is `\{`. A lone `}` outside a hole is literal text. A hole may contain a nested string.

There's no format-specifier syntax. Formatting is done by functions: `"{round(x, 2)}"`.

## Operators

`~` concatenates two strings and `~=` appends to a `mutable val`, with the same behaviour and complexity as [arrays](arrays.md).

`<`, `<=`, `>` and `>=` compare by bytes, which is code point order for valid UTF-8. Locale-aware collation is left to libraries.

## Measuring and viewing

A string has no `length` and no indexing. No single unit is privileged, and no linear-time operation hides behind constant-time syntax. Views say what they measure:

- `bytes(s): [UInt8]` is constant-time.
- `chars(s)` is a sequence of code points, of a distinct `Char` type written `'a'`.

Grapheme clusters are out of scope for the language.

## Conversions

`String(x)` formats any printable value, as `print` would.

Operations that can fail return an option under their own names, and aren't spelled as conversions. Decoding bytes returns `String?`, and `parseInt(s)` returns `Int?`.

## Input

`read()` returns the next line of input, including its newline, or `None` at the end of input.

## Planned forms

- Raw strings with a prefix, which turn off both backslashes and braces
- `"""` multi-line strings with indentation stripped

## Current implementation

- `bytes`, decoding, `chars`, `Char` and `parseInt` aren't available.
- The planned forms above aren't available.
