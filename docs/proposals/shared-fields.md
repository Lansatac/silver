# Proposal: shared fields on a sum

**Status: decided in outline, and nothing is built.** A sum can state fields that every member provides. A marker provides them as constants written at the sum, which makes a sum of markers an enum whose members carry data. A product member provides them by having fields of those names and types. Silver gets no separate `enum`.

## Summary

```silver
type Planet(mass: Float, radius: Float) =
    Mercury(3.3e23, 2.44e6) | Earth(5.97e24, 6.37e6)

val p: Planet = Earth
p.mass                 // 5.97e24
Mercury.radius         // 2.44e6

match p {
    Mercury => ...
    Earth => ...
}
```

The field list after the sum's name is its **shared fields**. Each member answers for every one of them, and a shared field is read from a value of the sum with `.`, whichever member the value is.

A sum with no shared fields is as it is today: its values have no field access.

## Markers

A marker of a sum with shared fields is written with a value for each, in the fields' order:

```silver
type Suit(letter: String)    = Clubs("C") | Diamonds("D") | Hearts("H") | Spades("S")
type KeyboardKey(code: CInt) = KeyRight(262) | KeyLeft(263) | KeyDown(264)

KeyRight.code          // 262
```

- Each value is a constant of its field's type, checked as a [top-level constant](../language/bindings.md#top-level-constants)'s initializer is, so it can name constants and use operators, and a literal adapts to the field.
- Every marker gives every shared field. There are no defaults, and values are given by position.
- The member is still a marker. It's constructed and matched by its bare name, and two values of it are equal. The values belong to the member, not to a value of it, so nothing assigns them and `with` doesn't apply.
- Two markers can give the same values. Nothing here promises a way back from a value to a member.

A member's parentheses hold values in this form and `name: Type` declarations in a product member, so the two are told apart by what's written.

## Product members

A product member provides the shared fields by having them:

```silver
type Asteroid(mass: Float, radius: Float, composition: String)

type Planet(mass: Float, radius: Float) =
    Earth(5.97e24, 6.37e6) | Mars(6.42e23, 3.39e6) | :Asteroid

def density(p: Planet): Float => p.mass / volume(p.radius)

density(Earth)                               // the member's constants
density(Asteroid(9.4e20, 4.7e5, "rock"))     // the value's own fields
```

- A member that's a product, declared inline or referenced with `:`, must have a field of each shared field's name and type. One that doesn't is an error where the sum is declared.
- An inline product member declares the shared fields itself, as `Comet(mass: Float, radius: Float, tail: Float)`. The sum's field list never adds a field to a member: it only checks them.
- A member's other fields are reached by matching it, as in any sum.
- A shared field can't be assigned through a value of the sum.

A marker's value can come from a constant of another type, as `Ceres(ceres.mass, ceres.radius)` with `val ceres: Asteroid = ...`, which needs constants of constructed types (below). Only what the shared fields name is carried.

## Constants of constructed types

A marker's values are constants, so a shared field can have any type a constant can. Today that's `Bool`, the integers, `Float`, `Float32`, `String` and `Unit`. Constants of constructed types are their own piece of work, and also let a binding write `val rayWhite: Color = Color(245, 245, 245, 255)`:

```silver
type Point(x: Int, y: Int)
type Suit = Clubs | Hearts

val origin: Point = Point(0, 0)
val trump: Suit = Hearts
val corner: (Int, Point) = (1, Point(origin.x, 5))
val start: Point? = origin
val none: Point? = None
```

- A constant's type can be a product, a marker, a sum, a tuple or an option, when every type inside it can be a constant's too. A [native type with fields](../language/native.md) is a product here. An instance of a generic type is allowed.
- It can't be or contain an array, a dictionary, a function, an error union, a `Ref` or a native type with no fields.
- The initializer can also be a constructor called with constants, a tuple of them, `None` or `Some(...)`, and a field of a constant, as `origin.x`. A value is promoted into an option or a sum as anywhere. No function is called, and there's no `with`, `if` or `match`.
- A constant is a value like any other: each use is that value, and it's compared and printed structurally. It still isn't a pattern.

## Details

- A sum with shared fields has at least one, and their names differ. It can't be generic yet.
- Every member of it is a marker written with its values, or a product with the fields. A bare marker, a marker type referenced with `:`, and a member that isn't a product, as `:Int?` or another sum, are errors.
- A shared field's type and a product member's field's type are the same type, with no promotion between them.
- A shared field is also read from a value of a marker's own type, as `val e: Earth = Earth` then `e.mass`.
- A shared field of a marker, as `Mercury.radius`, can be used in a constant.
- Equality and printing are a sum's as they are today: by member, and `Earth` prints as `Earth`.

## Open questions

- What an enum has beyond data, for a sum whose members are all markers: ordering by declaration order, a list of the members, and a member's position. These are for [deriving](attributes.md), not new syntax here.
- The way back from a shared field's value to a member, as `262` to `KeyRight`. It would be asked for on a field, need that field's values to be distinct, and give an option.
- Crossing to C as a shared field's value, so a native takes a `KeyboardKey` where C takes an `int`, and what a native that returns one gives when C returns a value no member has.
- Flags, where values combine: a product over an integer with constants and operator functions (`type ConfigFlags(bits: CUInt)`, `val flagVsyncHint: ConfigFlags = ConfigFlags(64)`, `opOr`) is the expected shape, and needs only constants of constructed types.
- A member backed by a whole value of another type, as `Ceres = Asteroid(9.4e20, 4.7e5, "rock")`, with the shared fields taken from it. It makes the member an `Asteroid` as well as a `Planet`, which is where extension types and inheritance begin, so it's left out.
- A named constant as a pattern, as `match p { origin => ... }`, which [User types](../language/user-types.md#open-questions) already lists.
- Whether an interface should be able to ask for a field, for the open form of "anything with a mass and a radius". Shared fields are closed and about one sum's members.
- Shared fields on a generic sum.

## Order of work

1. Constants of constructed types.
2. Shared fields on a sum whose members are all markers.
3. Product members that provide the shared fields.

The second is specified with the field list as a requirement on every member from the start, so the third adds a kind of member and changes nothing.
