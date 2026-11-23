# std.string

Asking about a `String`'s contents, cutting one apart and parsing one. A string is cut by value, never by position, as [Strings](../language/strings.md#cutting-a-string) says: every piece handed back begins and ends between characters.

```silver
import std.string

"key=value".splitOnce("=")       // Some(("key", "value"))
"v1.2".stripPrefix("v")          // Some("1.2")
"  hi ".trim()                   // "hi"
"42abc".splitWhile(isDigit)      // ("42", "abc")
```

| | |
| --- | --- |
| Asking | `contains`, `startsWith`, `endsWith`, `isEmpty` |
| Cutting | `stripPrefix`, `stripSuffix`, `splitOnce`, `splitWhile`, `trim`, `trimStart`, `trimEnd` |
| Many pieces | `split(text, separator)` and `lines(text)`, each an array of strings |
| Converting | `decode`, `parseInt`, `parseFloat`, `parseBool` |

- The questions compare bytes, which for UTF-8 gives the same answer as comparing characters, and the empty string is found in every string, at both ends.
- `stripPrefix`, `stripSuffix` and `splitOnce` return `None` when what they look for isn't there. `splitOnce` cuts at the first separator.
- `splitWhile(text, keep)` returns the characters at the beginning that `keep` accepts, and everything after them.
- The `trim` functions remove Unicode white space.
- `split` returns one more piece than there are separators, so some may be empty: `split(",a,", ",")` is `["", "a", ""]`. An empty separator gives each character as its own piece.
- `lines` drops the `\n` or `\r\n` that ends each line. A final line needs no ending, and nothing follows the last ending: `lines("a\n")` is `["a"]`.
- `parseInt` reads decimal digits with an optional `-` before them. Anything else is `None`: an empty string, a `+`, spaces, `_`, and a number that doesn't fit an `Int`.
- `parseFloat` reads a decimal number: digits with an optional `.` among them, before them or after them, then optionally `e` or `E` with an optional `+` or `-` and digits, and an optional `-` before it all. So `"3"`, `"-0.5"`, `".5"`, `"5."` and `"1.5e-3"` are numbers, which is more than a [literal](../language/numbers.md) allows, and `"."`, `"+1"`, `"inf"` and `"1_000.0"` are `None`. The result is the `Float` nearest the number written, however many digits it has, a tie going to the one whose last bit is zero. A number too large for a `Float` is `None`, and one too small to tell from zero is zero.
- `parseBool` is `true` for `"true"` and `false` for `"false"`, with any of the letters in capitals, so `"True"` and `"FALSE"` are read too. Anything else is `None`: `"yes"`, `"1"`, `"t"`, and either word with a space beside it.

## Open questions

- Whether `split` and `lines` become lazy once [ranges](../proposals/ranges.md) are decided.
- Whether `parseInt`, `parseFloat` and `parseBool` return an error rather than an option.

## Current implementation

- Everything above is built, in plain Silver in `stdlib/std/string.ag`.
- `decode` is declared in `lang`, which `std.string` forwards. `lang.string` also has `slice(text, from, to)`, which cuts a String at two byte offsets and panics unless both fall between characters. It exists so that `std.string` can cut a String without an unchecked conversion, and isn't part of the language's surface: the rule above, that no function takes an offset into a String, is still the one to follow.
