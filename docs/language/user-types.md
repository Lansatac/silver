# User types

`type` declares a nominal type in one of three shapes. `alias` gives an existing type a second name.

```silver
type Unknown                                      // marker
type Point(x: Int, y: Int)                        // product
type Shape = Circle(radius: Float) | Square(side: Float) | Nothing   // sum
alias Meters = Float
```

`type` always introduces a new type. `alias` never does. A `type` may refer to itself, as in `type Tree(value: Int, children: [Tree])` or `type List(head: Int, tail: List?)`. An `alias` can't.

## Products

A product is constructed by calling its name, and its fields are read with `.`:

```silver
val p = Point(1, 2)
val x = p.x
```

A declaration with an empty field list, `type T()`, is an error: write `type T`.

A constructor can be used as a function value, and its return type is the product itself even when a sum owns it. Products are compared and printed structurally: `Point(1, 2)`. A type is comparable when all of its fields are.

### Copying with changes

`value with (field = new)` is a copy with fields replaced. It means `{ mutable val t = value; t.field = new; t }`.

```silver
val moved = point with (x = 3)
val adjusted = line with (start.x = 9, end.y = 1)
val chained = point with (x = 1) with (y = 2)
```

The result has the original's type. Each value is checked against its field, so literals adapt and options promote. There must be at least one update, and two updates can't overlap. `with` can't be used on tuples or on a sum value.

## Sums

Every member of a sum is a type.

- `Name(fields)` declares a product right there.
- A bare name refers to the type of that name in this module, or declares a marker if the module has none.
- An imported type is written qualified, as in `geometry.Point`. A bare name that an import also provides is an error.

```silver
type Color = Red | Green | Blue
type Point = Point2D | Point3D      // over existing types
```

A sum is nominal. Two sums with the same members are different types.

A member can't be `Never` or the sum itself, and can't be listed twice. A bare name can only declare a marker in one sum of a module. To share a marker between sums, declare it on its own with `type Name`.

A sum's name isn't a value, so only its members can be constructed.

### Owned and referenced members

A member is *owned* if the sum declares it (inline fields or an auto-declared marker), and *referenced* if it already existed.

A constructor of an owned member has the sum's type, and a constructor of a referenced member has its own type:

```silver
val s = Circle(1.0)       // Shape
val cs = [Red, Green]     // [Color]
val p = Point2D(1, 2)     // Point2D
```

Where a type is expected, a constructor checked against its member type produces the member, and checked against the sum it promotes:

```silver
val c: Circle = Circle(1.0)
```

Common types: a member and its sum join to the sum. Otherwise a sum is never invented, so `if c => Point2D(1, 2) else Point3D(1, 2, 3)` needs an annotation.

### Promotion into a sum

Promotion into a sum is one step and is never chained through an option. A literal adapts when exactly one member can take it. A `1` against `Int8 | String` adapts to `Int8`. Against `Int8 | Int` it's an error, and against `Int? | String` it's also an error that says to write `Some(1)`.

### Using sum values

A sum value has no field access or field assignment. A `mutable val` holding one can be rebound. Sums compare and print structurally, and a sum is comparable when all of its members are.

## match

`match` is an expression. Each arm is `Pattern => Expression`, with arms separated by newlines, and the first arm whose pattern matches runs. `return`, `break` and `continue` are statements, so an arm using one needs a block: `_ => { return None }`.

```silver
val area = match shape {
    Circle(radius) => 3.14 * radius * radius
    Square(side) => side * side
    Nothing => 0.0
}
```

The patterns are:

| Pattern | Matches |
| --- | --- |
| `Member(p, q)` | a member, with nested positional patterns |
| `name: Type` | a member by type, bound to `name` |
| `name` | anything, bound to `name` |
| `_` | anything |
| a literal | that value |
| `Some(p)`, `None` | options |
| `(p, q)` | a tuple, with nested patterns |

A match must be exhaustive, and the error names what's missing, including through nested patterns and tuples. `Bool` is exhausted by `true` and `false`, while integer and string literals need a `_`. An unreachable arm is an error.

Bindings are immutable and in scope only in their arm.

`if val` is the one-arm form. It takes a constructor pattern, including `Some(p)` and `None`, and doesn't need to be exhaustive:

```silver
val r = if val Circle(radius) = shape => radius else 0.0
```

## Open questions

- Guards on match arms
- Named patterns, alongside named arguments
- A one-member sum over an existing type, such as `type Id = Int`, is a nominal wrapper with implicit injection. It may be rejected if it proves a footgun.

## Current implementation

- `alias` isn't available, though it's a reserved word.
