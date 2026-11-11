# Types

Silver is statically typed. Types trail what they describe (`name: Type`), and type names are capitalized.

| Type | Values |
| --- | --- |
| `Bool` | `true`, `false` |
| `Int8` to `Int64`, `UInt8` to `UInt64`, `Float` | see [Numbers](numbers.md) |
| `String` | see [Strings](strings.md) |
| `Unit` | `()`, the only value |
| `Never` | none; the type of an expression that doesn't finish |
| `T?` | see [Options](options.md) |
| `[T]` | see [Arrays](arrays.md) |
| `(A, B)` | see [Tuples](tuples.md) |
| `(A, B) -> C` | see [Functions](functions.md) |
| declared types | see [User types](user-types.md) |

`()` as a type is another spelling of `Unit`.

## Never

`return`, `break`, `continue` and `panic(...)` have type `Never`. `Never` is assignable to every type, so a branch that ends in one needs no common type with the others. `return`, `break` and `continue` are statements, so inside an expression they go in a block:

```silver
val size = if isValid => compute() else { return None }
```

## Promotion

Values do not convert implicitly, with a small number of exceptions called *promotions*. Each is one step, happens where a known type is expected, and is never chained:

- `T` promotes to `T?`.
- A member of a sum type promotes to the sum.

Expected types flow through assignments, arguments, returns, `if` arms, block values, constructor fields and collection elements. A number literal adapts to its expected type in the same way (see [Numbers](numbers.md)).

Containers do not promote their contents once they are values. A *literal* checks each element against the expected element type, so `val xs: [Int?] = [1, None]` works, but a value of type `[Int]` is not a `[Int?]`. An empty `[]` and `None` have no type of their own that a binding can take, so they need an expected type.

A conversion is implicit only if it works for every value, keeps the value's meaning, and can't fail at runtime. Anything else is written out, as in `UInt8(x)`. There are no user-defined implicit conversions.

## Equality and ordering

`==` and `!=` work on any two values of one *comparable* type. Primitives are comparable. Options, arrays, tuples and declared types are compared structurally, and are comparable when everything they contain is. Function values are not comparable.

Ordering with `<`, `<=`, `>` and `>=` is defined only for numbers and strings.

## Printing

`print` and `printl` (which adds a newline) accept any printable value, and `String(x)` and string holes format it in the same way.

| Value | Printed form |
| --- | --- |
| `()` | `()` |
| `"text"` | `text` |
| `Some(1)`, `None` | `Some(1)`, `None` |
| `[1, 2]`, `["a"]` | `[1, 2]`, `[a]` |
| `(1, "a")` | `(1, a)` |
| a product or member `Point(1, 2)` | `Point(1, 2)` |
| a marker | its name |

## Open questions

- Whether integers widen implicitly where a type is expected, as `Int8` to `Int` or `UInt8` to `Int16`. These would pass the rule for implicit conversions. `Int` and `UInt` wouldn't convert in either direction, and neither would `Int` to `Float`, which is inexact for large values.

## Current implementation

- `Any` is a placeholder type visible in prelude signatures such as `print(value: Any)`, standing in for a design based on generics. It can't be an element of an array, tuple or option, a field, or a member of a sum.
- Printing a function value works when interpreted, showing its name, and is a compile error when compiled.
