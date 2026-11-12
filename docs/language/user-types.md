# User types

`type` declares a nominal type in one of three shapes. `alias` gives an existing type a second name.

```silver
type Unknown                                      // marker
type Point(x: Int, y: Int)                        // product
type Shape = Circle(radius: Float) | Square(side: Float) | Nothing   // sum
alias Meters = Float
```

`type` always introduces a new type. `alias` never does. A `type` may refer to itself, as in `type Tree(value: Int, children: [Tree])` or `type List(head: Int, rest: List?)`, as long as a value can be built: `type A(a: A)` is an error, because nothing could end it. An `alias` can't refer to itself.

An alias can name any type and is interchangeable with it everywhere, including in `match` patterns and the members of a sum. An alias of a product or marker constructs it, and an alias of a numeric type or `String` converts to it, so `Meters(1)` means `Float(1)`. An alias of any other type isn't a value. Aliases are declared at the top level, and can be `private`.

## Products

A product is constructed by calling its name, and its fields are read with `.`:

```silver
val p = Point(1, 2)
val x = p.x
```

A declaration with an empty field list, `type T()`, is an error: write `type T`.

A constructor can be used as a function value, and its return type is the product itself even when a sum owns it. Products are compared and printed structurally: `Point(1, 2)`.

### Copying with changes

`value with (field = new)` is a copy with fields replaced. It means `{ mutable val t = value; t.field = new; t }`.

```silver
val moved = point with (x = 3)
val adjusted = line with (start.x = 9, end.y = 1)
val chained = point with (x = 1) with (y = 2)
```

The result has the original's type. Each value is checked against its field, so literals adapt and options promote. There must be at least one update, and two updates can't overlap. `with` can't be used on tuples or on a sum value.

### Invariants

A product can state a condition that every value of it meets:

```silver
type Percent(value: Int) invariant 0 <= value && value <= 100
type Span(low: Int, high: Int) invariant low <= high
type NonEmpty<T>(items: [T]) invariant length(items) > 0
```

The invariant is a `Bool` expression over the fields. A name in it refers to a field first, and otherwise resolves as it would in a function of the module, so it can call functions and use constants, private ones included. A marker has no fields and can't have one.

A value that would break its invariant is never produced: the program panics instead, with a message naming the type and showing the invariant. So a function that receives a `Span` never checks it again. The invariant is checked wherever a value of the type comes about, in the type's own module as much as anywhere else:

- **Construction**, including through an alias and through the constructor used as a function value. When every argument is a literal and the invariant uses only what a constant's initializer may, a violation is a compile error, as `UInt8(256)` is.
- **`with`**, once, after every update is applied. `span with (low = 5, high = 9)` is fine even where `low = 5` alone would cross `high`, which makes `with` the way to change several fields together.
- **Assigning a field** of a `mutable val` or a mutable parameter, after the write. Assigning through a path such as `line.start.x = 2` checks each type along the path, innermost first.
- **A `mutable` argument written back**, for the types around the place it's written to. After `advance(mutable line.start)`, `Line` is checked; `advance` has already kept `Point`'s.

Reading a field, matching and destructuring check nothing. Equality and printing are unchanged.

An invariant should have no effects. How many times it's evaluated isn't specified, so a check that can't fail, such as one after assigning a field the invariant doesn't mention, may be skipped.

A construction that can fail without stopping the program is an ordinary function that returns an option, sharing the condition with the invariant by name:

```silver
def isPercent(value: Int): Bool => 0 <= value && value <= 100

type Percent(value: Int) invariant isPercent(value)

def percent(value: Int): Percent? => if isPercent(value) => Percent(value) else None
```

In a generic type the invariant is checked once, where it's written, like a generic function's body. So it can't order a value whose type mentions a type parameter.

A member that a sum declares inline can have an invariant, written in parentheses, since `|` would otherwise read as the operator:

```silver
type Shape = Circle(radius: Float) invariant (radius > 0.0) | Square(side: Float) | Nothing
```

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

A sum value has no field access or field assignment. A `mutable val` holding one can be rebound. Sums compare and print structurally.

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
- A built-in checked construction that returns `T?` where the invariant doesn't hold.
- Whether the panic for a broken invariant shows the value's fields.
- An invariant that's costly to check, or that a module maintains step by step, such as a sorted array. Checking it at every construction is too slow. This is what `opaque type` is for; see [Modules](modules.md).

## Current implementation

- Invariants aren't available, and `invariant` isn't reserved yet.
- Everything else above is implemented.
