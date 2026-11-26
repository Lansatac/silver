# Strings

A `String` is an immutable sequence of UTF-8 bytes. It's a distinct type, not an array, so `"a" == [97]` doesn't type-check. A string may contain a NUL byte.

## Literals

String literals are written `"..."` on one line. The escapes are `\n`, `\r`, `\t`, `\0`, `\"`, `\\`, `\{` and `\}`, and `\u{...}` with one to six hex digits naming a Unicode scalar value, which is written as its UTF-8 bytes: `"\u{1b}[31m"` starts with the escape character, and `"caf\u{e9}"` is `"café"`. A surrogate (`D800` to `DFFF`) or anything above `10FFFF` is an error, as is any other escape.

## Interpolation

Every string interpolates. `{expr}` holds one expression, of any type.

```silver
val message = "{count} of {total} done"
```

`{}` is an error. A literal brace is `\{`. A lone `}` outside a hole is literal text. A hole may contain a nested string.

There's no format-specifier syntax. Formatting is done by functions: `"{round(x, 2)}"`.

## Operators

`~` concatenates two strings and `~=` appends to a `mutable val`, with the same behaviour and complexity as [arrays](arrays.md).

`<`, `<=`, `>` and `>=` compare by bytes, which is code point order for valid UTF-8. Locale-aware collation is left to libraries.

## Characters

A `Char` is one Unicode scalar value: any code point except a surrogate. It's a fixed size, whatever the character, while the same character takes one to four bytes inside a string.

```silver
val letter = 'é'
val smile = '\u{1f600}'
```

A character literal is written `'...'` and holds exactly one character, or one of the escapes `\n`, `\r`, `\t`, `\0`, `\'`, `\\` and `\u{...}`. A brace or a `"` needs no escape.

- `==`, `!=` and the ordering operators compare the values, and a literal can be a `match` pattern.
- A `Char` prints as its character, in `print`, in a hole and through `String(c)`.
- `Int(c)` and `UInt32(c)` give its value. A narrower integer type converts too, and panics when the value doesn't fit, as it does for a number. `toChar(n)` in `std.char` goes the other way and returns `Char?`, since not every number is a scalar value.
- There's no arithmetic on a `Char`, and `~` doesn't take one: write `s ~ String(c)` or use a hole.

A `Char` isn't always what a reader sees as one character. `"é"` can be one `Char` or two (a letter and a combining accent), and many emoji are several. Those units are grapheme clusters, which are left to libraries.

## Stepping through a string

A string is a forward range of `Char`.

```silver
next("café")          // Some(('c', "afé"))
next("")              // None

for c in "café" {
    printl(c)
}
```

`next` returns the first character and the rest of the string, which shares the original's bytes.

A string has no `length` and no indexing. No single unit is privileged for measuring, and no linear-time operation hides behind constant-time syntax. `bytes(s): [UInt8]` is the other view, in constant time, and it has both.

## Cutting a string

A string is taken apart by value, never by position: no function takes or returns an offset into one, so a piece always begins and ends between characters. [`std.string`](../stdlib/string.md) has the functions that ask about a string, cut it and parse it, and [`std.char`](../stdlib/char.md) the questions about a character.

## Validity

Every `String` is valid UTF-8. A literal can't be anything else, and bytes that arrive from outside are checked where they enter:

- `decode(bytes)` returns `String?`, `None` when the bytes aren't UTF-8.
- `read()` reports input that isn't UTF-8 as an error.

## Conversions

`String(x)` formats a value of any type, as `print` would.

Operations that can fail return an option under their own names, and aren't spelled as conversions: `decode(bytes)` returns `String?`, `parseInt(s)` returns `Int?`, `parseFloat(s)` returns `Float?`, `parseBool(s)` returns `Bool?` (all three in [`std.string`](../stdlib/string.md)) and `toChar(n)` returns `Char?`.

## Input

`read()` returns the next line of input without its `\n` or `\r\n`, or `None` at the end of input. Its type is `String? ! NotUtf8 | InputFailed`, with the errors of [`IoError`](errors.md#ioerror).

```silver
def main(): Unit ! IoError {
    while val line = read()? {
        printl("[{line}]")
    }
}
```

- A final line needs no ending, and an empty line is `Some("")`.
- A line that isn't UTF-8 is `NotUtf8`. It's consumed, so the next `read()` goes on after it.

## Planned forms

- Raw strings with a prefix, which turn off both backslashes and braces
- `"""` multi-line strings with indentation stripped

## Open questions

None for strings themselves: see [`std.string`](../stdlib/string.md#open-questions) and [`std.char`](../stdlib/char.md#open-questions).

## Current implementation

- Everything above is available on both backends, except as listed here.
- The planned forms above aren't available.
