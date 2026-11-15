# User types

`type` declares a nominal type in one of three shapes. `alias` gives an existing type a second name.

```silver
type Unknown                                      // marker
type Point(x: Int, y: Int)                        // product
type Shape = Circle(radius: Float) | Square(side: Float) | Nothing   // sum
alias Meters = Float
```

`type` always introduces a new type. `alias` never does. A `type` may refer to itself, as in `type Tree(value: Int, children: [Tree])` or `type List(head: Int, rest: List?)`, as long as a value can be built: `type A(a: A)` is an error, because nothing could end it. An `alias` can't refer to itself.

An alias can name any type and is interchangeable with it everywhere, including in `match` patterns and the members of a sum. An alias of a product or marker constructs it, so `IntBox(1)` after `alias IntBox = Box<Int>` builds a `Box<Int>`, and an alias of a numeric type or `String` converts to it, so `Meters(1)` means `Float(1)`. An alias of any other type isn't a value. Aliases are declared at the top level, and can be `private`.

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

A product can state a condition that every value of it meets, and the error that building one gives when the condition doesn't hold:

```silver
type OutOfRange(value: Int)
type Reversed(low: Int, high: Int)
type Empty

type Percent(value: Int) invariant 0 <= value && value <= 100 else OutOfRange(value)
type Span(low: Int, high: Int) invariant low <= high else Reversed(low, high)
type NonEmpty<T>(items: [T]) invariant length(items) > 0 else Empty
```

The invariant is a `Bool` expression over the fields. A name in it refers to a field first, and otherwise resolves as it would in a function of the module, so it can call functions and use constants, private ones included. The `else` is required. Its expression is written over the fields in the same way, is evaluated only when the condition is false, and can be of any type. A marker has no fields and can't have an invariant.

A value that would break its invariant is never produced, so a function that receives a `Span` never checks it again. Building one yields an [error union](errors.md), and the caller says what a failure means:

```silver
val volume = Percent(number)?                    // Percent ! OutOfRange: pass the error on
val capped = Percent(number) ?? Percent(100)     // or choose a value
val half = Percent(50)!                          // or say it can't fail
```

A value of the type comes about in two ways, in the type's own module as much as anywhere else:

- **Construction** of a `T` whose invariant gives an `E` is a `T ! E`. That includes construction through an alias, and the constructor used as a function value, which is a `(Int) -> Percent ! OutOfRange`.
- **`with`** that updates a field the invariant mentions is a `T ! E` too. The invariant is checked once, after every update is applied, so `span with (low = 5, high = 9)` is fine even where `low = 5` alone would cross `high`. A `with` that updates only other fields is a plain `T`.

A field the invariant mentions changes only through `with`. Assigning to it is a compile error, since a statement has nowhere to put an error, and so is assigning through it, as in `line.start.x = 2` where `Line`'s invariant mentions `start`, or passing it as a `mutable` argument. A field the invariant doesn't mention is assigned as usual.

```silver
type TooEarly
type Meeting(time: Span, title: String) invariant time.low >= 0 else TooEarly

meeting.title = "Review"                              // fine
meeting.time = later                                  // error: `time` is in the invariant of `Meeting`
meeting = (meeting with (time = later))?
```

When `!` follows a construction whose arguments are all literals, and the invariant uses only what a constant's initializer may, the check is made at compile time, and a violation is a compile error, as `UInt8(256)` is.

Reading a field, matching and destructuring check nothing. Equality and printing are unchanged.

An invariant and its `else` should have no effects. How many times the condition is evaluated isn't specified.

In a generic type the invariant is checked once, where it's written, like a generic function's body. So it can't order a value whose type mentions a type parameter.

A member that a sum declares inline can have an invariant, with the condition and the error each written in parentheses, since `|` would otherwise read as the operator. Its constructor then yields the sum or the error, so `Circle(r)` is a `Shape ! NotPositive`:

```silver
type Shape = Circle(radius: Float) invariant (radius > 0.0) else (NotPositive(radius)) | Square(side: Float) | Nothing
```

## Sums

Every member of a sum is a type.

- `Name(fields)` declares a product right there.
- A bare `Name` declares a marker.
- `:Type` refers to a type that already exists: one declared elsewhere in this module, an imported one such as `:geometry.Point`, or any other type, such as `:Int?` or `:[String]`.

```silver
type Color = Red | Green | Blue
type Point = :Point2D | :Point3D                 // over existing types
type Reading = :Int | :geometry.Point | Missing  // Missing is declared here
```

So a sum's declaration says on its own which members it owns. Declaring or removing a type elsewhere in the module, or adding one to an imported module, never changes what a member means.

A bare name declares, so it's an error if the module already declares that name, and a member that isn't a plain name, such as `Int` or `geometry.Point` without the `:`, is an error too. A marker a sum declares is the module's own, so like any declaration it takes precedence over an import of the same name.

A sum is nominal. Two sums with the same members are different types.

A member can't be `Never` or the sum itself, and can't be listed twice. Different instances of one generic are different members: `type Held = :Box<Int> | :Box<String>` is allowed. A bare name can only declare a marker in one sum of a module. To share a marker between sums, declare it on its own with `type Name` and write `:Name` in each.

A sum's name isn't a value, so only its members can be constructed.

### Owned and referenced members

A member is *owned* if the sum declares it (inline fields or a bare marker name), and *referenced* if it is written with `:`.

A constructor of an owned member has the sum's type, and a constructor of a referenced member has its own type:

```silver
val s = Circle(1.0)       // Shape
val cs = [Red, Green]     // [Color]
val p = Point2D(1, 2)     // Point2D
```

Where a type is expected, a constructor checked against its member type produces the member, and checked against the sum it promotes. Under `!` or `?`, the constructor is checked against what's expected of the value they unwrap:

```silver
val c: Circle = Circle(1.0)
val d: Circle = Circle(2.0)!    // with an invariant on Circle
```

Common types: a member and its sum join to the sum. Otherwise a sum is never invented, so `if c => Point2D(1, 2) else Point3D(1, 2, 3)` needs an annotation.

### Promotion into a sum

Promotion into a sum takes a member to the sum, and then on through any option or error-union layers around it, as other promotions do. A literal adapts when exactly one member can take it. A `1` against `Int8 | String` adapts to `Int8`. Against `Int8 | Int` it's an error, and against `Int? | String` it's also an error that says to write `Some(1)`.

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
| `Ok(p)`, `Error(p)` | error unions; see [Errors](errors.md#match) |
| `(p, q)` | a tuple, with nested patterns |

A match must be exhaustive, and the error names what's missing, including through nested patterns and tuples. `Bool` is exhausted by `true` and `false`, while integer and string literals need a `_`. An unreachable arm is an error.

Bindings are immutable and in scope only in their arm.

A member pattern of a [generic](generics.md) type can write its type arguments, as construction does, and then matches only that instance. Without them it takes the instance from the value, as `Box(v)` on a `Box<Int>` binds an `Int`. Written ones are how a sum over two instances of one type is taken apart:

```silver
type Held = :Box<Int> | :Box<String>

val text = match held {
    Box<Int>(n) => String(n)
    Box<String>(s) => s
}
```

An instance the value can't be is an error, as `Box<String>(s)` on a `Box<Int>` is. So is a pattern without type arguments on a value that can be more than one instance, as `Box(n)` on a `Held` is, nested or not: write which, as in `Box<Int>(n)`, or use an alias of it. An alias of an instance is used without type arguments, as `IntBox(n)`, and `Some`, `None`, `Ok` and `Error` take none either: the value's type gives them.

A pattern compares by structure: a member pattern looks at the value's fields, and never calls the type's `opEquals`. So for a type whose `opEquals` treats `Fraction(1, 2)` and `Fraction(2, 4)` as equal, `f == Fraction(1, 2)` can be true where the pattern `Fraction(1, 2)` doesn't match `f`. To branch on the type's own equality, compare with `==`.

`if val` is the one-arm form. It takes a constructor pattern, including `Some(p)`, `None`, `Ok(p)` and `Error(p)`, and doesn't need to be exhaustive:

```silver
val r = if val Circle(radius) = shape => radius else 0.0
```

## Open questions

- Guards on match arms
- Named constants as patterns, as in `match p { origin => ... }`, and whether one compares with `==`, since it's a whole value rather than a structure
- Named patterns, alongside named arguments
- A one-member sum over an existing type, such as `type Id = :Int`, is a nominal wrapper with implicit injection. It may be rejected if it proves a footgun.
- A `with` through a path that reaches two types with invariants, such as `line with (start.x = 2)`, where the two errors differ. A list of errors is never invented, so for now the inner value is built first.
- Whether an invariant can name a field whose type contains a `Ref`, whose cell changes without going through the type.
- An invariant that's costly to check, or that a module maintains step by step, such as a sorted array. Checking it at every construction is too slow. This is what `opaque type` is for; see [Modules](modules.md).

## Current implementation

- An invariant may name a field whose type contains a `Ref`, although the cell can change without going through the type.
- An invariant's `else` can't lead back to building a value of its own type, directly or through a function it calls whose result type is an [interface](interfaces.md#an-interface-name-as-a-result-type). Through such a function, the error names the type, the function and what to do: write that function's result type out, and its body is no longer part of the `else`.
- A member's injection into a sum doesn't yet combine with option and error-union layers: `val h: Held? = Box(7)` and `val e: Held ! Oops = Box("s")` are rejected (`T0001`), while a value of the sum type itself promotes through them. Write the sum first, as in `Some(h)` with `val h: Held = Box(7)`.
- Everything else above is implemented.
