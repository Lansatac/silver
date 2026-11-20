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

### Checking a condition

A type's fields are all public, so a product by itself promises nothing about them. A condition on the fields is checked by an ordinary function that builds the value and returns an [error](errors.md) when it doesn't hold:

```silver
type OutOfRange(value: Int)
type Percent(value: Int)

def percent(value: Int): Percent ! OutOfRange =>
    if 0 <= value && value <= 100 => Percent(value) else Error(OutOfRange(value))

val volume = percent(number)?                    // pass the error on
val capped = percent(number) ?? Percent(100)     // or choose a value
val half = percent(50)!                          // or say it can't fail
```

Nothing yet stops other code from writing `Percent(150)` or assigning `p.value`. Keeping construction to the type's own module, with the fields still readable, is an [open question](#open-questions).

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

Where a type is expected, a constructor checked against its member type produces the member, and checked against the sum it promotes:

```silver
val c: Circle = Circle(1.0)
```

Common types: a member and its sum join to the sum. Otherwise a sum is never invented, so `if c => Point2D(1, 2) else Point3D(1, 2, 3)` needs an annotation.

### Promotion into a sum

Promotion into a sum takes a member to the sum, and then on through any option or error-union layers around it, as other promotions do. Under an error union that lists the member as an error, it isn't promoted, and has to be written as `Ok(...)` or `Error(...)` (see [Errors](errors.md#values)). A literal adapts when exactly one member can take it. A `1` against `Int8 | String` adapts to `Int8`. Against `Int8 | Int` it's an error, and against `Int? | String` it's also an error that says to write `Some(1)`.

### Using sum values

A sum value has no field access or field assignment. A `mutable val` holding one can be rebound. Sums compare and print structurally.

## match

`match` is an expression. Each arm is `Pattern => Expression`, with arms separated by newlines, and the first arm whose pattern matches runs. An arm can be a jump: `_ => return None`.

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
- Construction that's private to a type's module, with its fields still readable and matchable everywhere, so a function such as `percent` above is the only way to a value. `with` and assignment would be the module's too. See [Modules](modules.md#open-questions) for hiding the fields as well.

## Current implementation

- `invariant` is still available, and is to be removed. `type Percent(value: Int) invariant 0 <= value && value <= 100 else OutOfRange(value)` states a condition over the fields and the error given when it fails:
  - Construction is then a `Percent ! OutOfRange`, also through an alias or as a function value, and so is a `with` that updates a field the condition names.
  - A field the condition names can't be assigned, assigned through, or passed as a `mutable` argument.
  - `!` on a construction whose arguments are all literals is checked at compile time.
  - An inline member of a sum takes one with the condition and the error each in parentheses, and its constructor gives the sum or the error.
  - The `else` can't lead back to building its own type, and a `with` through two invariants with different errors is an error.
  - A condition can name a field whose type contains a `Ref`, whose cell then changes without being checked.
- Everything else above is implemented.
