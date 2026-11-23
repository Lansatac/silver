# std.json

Reading JSON text into a value, finding things in it, and writing it back. It follows RFC 8259 strictly.

```silver
import std.json

type Missing(path: String)

def port(text: String): Int ! JsonError | Missing {
    val config = parse(text)?
    printl(config["server"]["name"].asString() ?? "unnamed")
    config["server"]["port"].asInt() ?? fail Missing("server.port")
}

val doc: [String: Json] = ["name": "x", "sizes": [1, 2.5]]
printl(write(doc)!)          // {"name":"x","sizes":[1,2.5]}
printl(pretty(doc)!)
```

## The value

```silver
type Null
type Json = :String | :Int | :Float | :Bool | :Null | :[Json] | :[String: Json]
```

- A JSON object is a [dictionary](../language/dictionaries.md), so it keeps its members in the order they were written, and is matched, iterated and updated like any other. An array is a Silver array.
- `Null` is JSON's `null`. A missing member is `None` when it's looked up, so the two stay apart.
- A number with a fraction or an exponent is a `Float`, and one without is an `Int`, so `1` and `1.0` are different values. `asFloat` takes either.

## Parsing

`parse(text): Json ! JsonError` reads one value, with white space around it. `JsonError(message, line, column)` says why it stopped and where, with both counted from 1 and the column counted in characters.

- Only what RFC 8259 allows is read. There are no comments, no trailing commas, and no white space but space, tab, `\n` and `\r`.
- An object that names a key twice is an error at the second key.
- An integer too large for an `Int` is an error, since a `Float` would silently lose digits. A number with a fraction or an exponent is the nearest `Float`, and one too large for a `Float` is an error.
- Arrays and objects can be nested 512 deep, and deeper is an error rather than running out of stack.
- Escapes are decoded, a `\u` pair making one character outside the Basic Multilingual Plane. An escape for half of a pair alone is an error, since a String holds only whole characters.

## Finding things

- `value[key]` and `value[index]` take a `Json?` and return one. A missing member, an index out of range, or indexing something that isn't an object or an array is `None`, and so is every lookup after it, so lookups chain: `doc["a"]["b"][0]`.
- `asString`, `asInt`, `asFloat`, `asBool`, `asArray` and `asObject` take a `Json?` and return its value as that type, or `None` when it's something else or missing. `isNull` is whether it's `Null`.

## Writing

- `write(value): String ! NotFinite` is compact text, with no spaces.
- `pretty(value): String ! NotFinite` indents by two spaces, one member or item to a line, except that an array holding no arrays or objects stays on one line.
- Strings are escaped where JSON requires it: `"`, `\` and the control characters below U+0020. Everything else is written as it is, in UTF-8.
- A `Float` is written as Silver [prints it](../language/numbers.md#printing-floats), the shortest text that reads back as the same `Float`, so it keeps its `.0` and reads back as a `Float`.
- NaN and the infinities aren't JSON. Writing one fails with `NotFinite(value, path)`, where `path` is a JSON Pointer (RFC 6901) to it, as `/scores/2`.
- Printing a `Json` value, or putting it in a string hole, shows its compact text, and a NaN or an infinity shows as Silver prints it.

## Open questions

- Decoding into a type of your own, and encoding from one, once deriving is designed. A decoding error should say where in the document it happened.
- A lenient mode (comments, trailing commas) and streaming. Neither is planned.
- Integers too large for an `Int`, should the standard library get a big integer type.

## Current implementation

- Everything above is built, in plain Silver in `stdlib/std/json.ag`, and tested in `stdlib/std/json.test.ag` on both backends.
- `conformance/stdlib/json_suite.ag` runs the 318 parsing cases of [JSONTestSuite](https://github.com/nst/JSONTestSuite), generated from it by `conformance/tools/json_suite.py`. Every case it says must be read is, except the two with a key named twice, and every case it says must be refused is: by `parse`, or for the 12 whose bytes aren't UTF-8, by `decode`, since a String is always valid UTF-8. Of the 35 cases left to the parser, 13 aren't UTF-8; of the rest, two numbers that become zero and 500 levels of nesting are read, and the other numbers, the halves of surrogate pairs and a leading byte-order mark are refused.
