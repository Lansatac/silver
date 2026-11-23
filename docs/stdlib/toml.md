# std.toml

Reading a [TOML 1.1](https://toml.io/en/v1.1.0) document into tables of values. Every TOML 1.0 document reads the same way under 1.1.

```silver
import std.toml

type Missing(key: String)

def port(text: String): Int ! TomlError | Missing {
    val config = parse(text)?
    printl(config["server"]["name"].asString() ?? "unnamed")
    config["server"]["port"].asInt() ?? fail Missing("server.port")
}
```

## The value

```silver
type Toml = :String | :Int | :Float | :Bool
          | :OffsetDateTime | :DateTime | :Date | :Time
          | :[Toml] | :[String: Toml]
```

- A table is a [dictionary](../language/dictionaries.md), so it keeps its keys in the order the text first names them. That covers tables made by headers, by dotted keys and inline, and an array of tables is an array of them.
- TOML's four kinds of date and time are [std.time](time.md)'s types: an offset date-time is an `OffsetDateTime`, a local date-time a `DateTime`, a local date a `Date` and a local time a `Time`.
- An integer is an `Int` and a float a `Float`, so `1` and `1.0` are different values. `asFloat` takes either.

## Parsing

`parse(text): [String: Toml] ! TomlError` reads a whole document, which is always a table. `TomlError(message, line, column)` says why it stopped and where, with both counted from 1 and the column counted in characters. It prints as `3:7: a is already defined`.

- A key can't be defined twice, and neither can a table. A table that dotted keys made can't be given a header later, and dotted keys can't add to a table that a header made. A header can still add a table below one that dotted keys made, as `[fruit.apple.texture]` can after `apple.color = "red"` under `[fruit]`.
- An inline table is closed where it ends, so nothing can add keys to it later, and `[[name]]` can't add to an array written with brackets.
- An integer too large for an `Int` is an error, as in hex `0x8000000000000000`. A float too large for a `Float` is an error too. `inf`, `-inf` and `nan` are those `Float`s, and a `nan`'s sign isn't kept.
- Fractional seconds past nanoseconds are dropped, as the spec asks. A time with no seconds, as TOML 1.1 allows, has 0. A leap second (`23:59:60`) is an error, since a `Time` can't hold one.
- In a multi-line string, a CRLF line ending is read as `\n`, so a file checked out with Windows line endings gives the same value.
- Arrays and inline tables can be nested 512 deep, and deeper is an error rather than running out of stack.
- A byte-order mark at the start is an error, as it is to [std.json](json.md). TOML doesn't mention one.

## Finding things

- `value[key]` and `value[index]` take a `Toml?` and return one. A missing key, an index out of range, or indexing something that isn't a table or an array is `None`, and so is every lookup after it, so lookups chain: `doc["servers"][0]["port"]`. The document itself is a dictionary, so its own `[key]` is already a `Toml?`.
- `asString`, `asInt`, `asFloat`, `asBool`, `asOffsetDateTime`, `asDateTime`, `asDate`, `asTime`, `asArray` and `asTable` take a `Toml?` and return its value as that type, or `None` when it's something else or missing.

## Open questions

- Writing TOML. Until then, a `Toml` value prints as any union does, as its member prints.
- Decoding into a type of your own, once deriving is designed, as for [std.json](json.md#open-questions).
- A message about something defined twice could say where it first was, as the `silver` tool's own reader does for `silver.toml`.

## Current implementation

- Everything above is built, in plain Silver in `stdlib/std/toml.ag`, and tested in `stdlib/std/toml.test.ag` on both backends.
- `conformance/stdlib/toml_suite.ag` runs the 720 TOML 1.1 cases of [toml-test](https://github.com/toml-lang/toml-test), generated from it by `conformance/tools/toml_suite.d`. Each of its 218 valid cases reads to the value its JSON gives, which the suite reads with `std.json`. Each of its 502 invalid cases is refused, by `parse`, or for the 9 whose bytes aren't UTF-8, by `decode`, since a String is always valid UTF-8.
- The `silver` tool reads `silver.toml` with its own reader in D (`frontend/source/silver/frontend/toml.d`), which keeps where each key and value is for its messages.
