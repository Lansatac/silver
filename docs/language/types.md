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
| `T ! E` | see [Errors](errors.md) |
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
- `T` promotes to `T ! E`, and an error union widens to one whose errors include its own.
- A member of a sum type promotes to the sum.

Expected types flow through assignments, arguments, returns, `if` arms, block values, constructor fields and collection elements. A number literal adapts to its expected type in the same way (see [Numbers](numbers.md)).

Containers do not promote their contents once they are values. A *literal* checks each element against the expected element type, so `val xs: [Int?] = [1, None]` works, but a value of type `[Int]` is not a `[Int?]`. An empty `[]` and `None` have no type of their own that a binding can take, so they need an expected type.

A conversion is implicit only if it works for every value, keeps the value's meaning, and can't fail at runtime. Anything else is written out, as in `UInt8(x)`. There are no user-defined implicit conversions.

## Equality and ordering

`==` and `!=` work on any two values of one type. Options, arrays, tuples and declared types are compared structurally. Two `Ref`s are equal when they're the same cell (see [Shared references](refs.md)), and function values are compared as described below.

A type's equality belongs to the type. Its own module can replace the structural one by writing an `opEquals`, and the printed form by writing an `opString` (see [operator functions](functions.md#operator-functions)). A function in another module can't change what `==` means for it, and generic code comparing a value uses the same equality as everyone else. A comparison with another meaning, such as "equal ignoring case", is an ordinary function, passed where it's needed.

### Function values

Function values are comparable. Two are equal when they come from the same place in the source and hold equal values:

- A `def`, a constructor or a native function used as a value is equal to itself. A generic one is equal to itself with the same type arguments.
- A value made by a lambda or a nested `def` is equal to another made by that same lambda, when everything the two captured is equal.

```silver
def increment(x: Int): Int => x + 1
def adder(n: Int): (Int) -> Int => x => x + n

val f = adder(1)
f == f                              // true
adder(1) == adder(1)                // true: the same lambda, equal captures
adder(1) == adder(2)                // false
increment == increment              // true
increment == (x => increment(x))    // false
```

Two lambdas with the same text are different functions, and a lambda that calls a function isn't that function. So a lambda written in a comparison can't be equal to the other side, and it's an error there: as an operand of `==` or `!=`, or as part of a value an operand builds with a constructor, a tuple, an array or `Some`.

```silver
button == Button("OK", () => save())     // error: this lambda is equal to nothing else
```

### Ordering

Ordering with `<`, `<=`, `>` and `>=` is defined only for numbers and strings.

## Printing

`print` and `printl` (which adds a newline) accept any printable value, and `String(x)` and string holes format it in the same way.

| Value | Printed form |
| --- | --- |
| `()` | `()` |
| `"text"` | `text` |
| `Some(1)`, `None` | `Some(1)`, `None` |
| `Ok(1)`, `Error(Empty)` | `Ok(1)`, `Error(Empty)` |
| `[1, 2]`, `["a"]` | `[1, 2]`, `[a]` |
| `(1, "a")` | `(1, a)` |
| a product or member `Point(1, 2)` | `Point(1, 2)` |
| a marker | its name |
| a function value | its name: `increment`, `Point` |

A function value prints as the function it comes from, without anything it captured, so `adder(1)` and `adder(2)` print alike:

- A `def`, a constructor or a native function prints its name. An overloaded one prints the same name for each overload.
- A generic instance adds its type arguments, written as they would be in source: `identity<Int>`, `wrap<[String]>`.
- A nested `def` prints its name, and a lambda prints `lambda`.
- A function from another module prints without the module's name, as its types' values do.

## Open questions

- Whether integers widen implicitly where a type is expected, as `Int8` to `Int` or `UInt8` to `Int16`. These would pass the rule for implicit conversions. `Int` and `UInt` wouldn't convert in either direction, and neither would `Int` to `Float`, which is inexact for large values.


## Current implementation

- Function values and `Ref`s aren't comparable yet. Comparing two, or two values of a type that contains one, is an error.
- `Any` is a placeholder type visible in prelude signatures such as `print(value: Any)`, standing in for a design based on generics. It can't be an element of an array, tuple or option, a field, or a member of a sum.
