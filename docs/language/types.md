# Types

Silver is statically typed. Types trail what they describe (`name: Type`), and type names are capitalized.

| Type | Values |
| --- | --- |
| `Bool` | `true`, `false` |
| `Int8` to `Int64`, `UInt8` to `UInt64`, `Float32`, `Float` | see [Numbers](numbers.md) |
| `String`, `Char` | see [Strings](strings.md) |
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

`return`, `break`, `continue` and `panic(...)` have type `Never`. `Never` is assignable to every type, so a branch that ends in one needs no common type with the others. Each is an expression, so it can stand wherever a value is expected:

```silver
val size = if isValid => compute() else return None
val (first, rest) = items.next() ?? return []
```

## Promotion

Values do not convert implicitly, with a small number of exceptions called *promotions*. Each happens where a known type is expected, and a value promotes through every option and error-union layer the expected type has, so `val a: (Int?)? = 1` is `Some(Some(1))` and `val b: Int? ! Oops = 1` is `Ok(Some(1))`:

- `T` promotes to `T?`.
- `T` promotes to `T ! E`, and an error union widens to one whose errors include its own.
- A member of a sum type promotes to the sum.

Expected types flow through assignments, arguments, returns, `if` arms, block values, constructor fields and collection elements. A number literal adapts to its expected type in the same way (see [Numbers](numbers.md)).

### Steps

Each promotion is a *step*, and a value fits where a type is expected in some number of them. `S` fits `S` in none. Wrapping in an option, wrapping in an error union, widening an error union and making a member its sum are one step each, and so is a literal taking a type other than its default. Steps add up through layers, outermost last:

```silver
type Box(value: Int)
type Held = :Box | :String

val n = 3
val a: Int? = n            // 1 step
val b: (Int?)? = 1         // 2: two layers
val c: Held? = Box(7)      // 2: into the sum, then the option
val d: UInt8? = 1          // 2: the literal takes UInt8, then the option
```

This one relation is what checking, [inference](generics.md#inference) and [overload choice](functions.md#overloading) all ask. Checking only needs to know that a value fits; overload choice prefers the function an argument reaches in fewer steps.

A value whose type could reach the expected type by two different routes doesn't fit, and is an error. The one case is a value that's one of an error union's errors and could also become its success, as an `Oops` against `H2 ! Oops` with `type H2 = :Oops | :Int`; it's written `Ok(...)` or `Error(...)` (see [Errors](errors.md#values)).

Containers do not promote their contents once they are values. A *literal* checks each element against the expected element type, so `val xs: [Int?] = [1, None]` works, but a value of type `[Int]` is not a `[Int?]`. An empty `[]` and `None` have [no type of their own](#a-type-of-its-own) that a binding can take, so they need an expected type.

A conversion is implicit only if it works for every value, keeps the value's meaning, and can't fail at runtime. Anything else is written out, as in `UInt8(x)`. There are no user-defined implicit conversions.

## A type of its own

Most expressions have a type of their own: `n + 1`, `"a"`, `point.x` and `Point(1, 2)` are what they are wherever they're written. Some have none, and take their type from where they go:

- `None`, `[]`, `[:]`, a bare `Error(e)`, a marker that a generic sum owns, a lambda without its parameter types, and the name of a generic or overloaded function.
- A number literal, which takes the type expected of it, and is an `Int` or a `Float` only when nothing is expected.
- Parentheses, a block, an `if` or `match`, an array, dictionary or tuple literal, a range literal `a..b` and arithmetic, when the part that decides their type has none of its own. `[1, 2]` has none, and `[1, n]` with `n: UInt8` is a `[UInt8]`, since `n` decides it. A tuple has none when any of its parts has none. An arm that can't finish, because it ends in `return`, `break`, `continue` or `tail`, has no value to count, and a block's earlier statements don't count.
- A call of a generic function or constructor, `Some(...)` and `Ok(...)` among them, when a type parameter in its result is reached by no argument that has a type of its own. That can be read off the signature:

  ```silver
  def id<T>(x: T): T
  def opt<T>(x: T, y: T?): T?
  def none<T>(): T?
  val n = 2

  id(n)           // an Int: n reaches T
  id(None)        // none of its own: only None reaches T
  none()          // none of its own: nothing reaches T
  opt(n, None)    // an Int?: n reaches T, and the None is checked against it
  opt(1, None)    // none of its own: only the literals reach T
  Box([])         // none of its own
  ```

  A type parameter that a [bound](interfaces.md#bounds) gives from one an argument reaches is reached too: in `conv<R: Range<T>, T>(r: R): [T]`, `r` reaches `R`, and `R`'s conformance says what `T` is.

  A lambda has no type of its own, so a call whose result only a lambda decides has none either, as `map(xs, x => x + 1)` with `map<T, U>(xs: [T], f: (T) -> U): [U]`: nothing but the lambda reaches `U`.

An expression is one or the other whatever surrounds it, and one with a type of its own is typed once, by itself. So a call of an overloaded function is chosen by its own arguments, never by the call it's an argument of.

An expression with no type of its own is never given one first and fitted afterwards. The type its place expects is passed into it, and its parts are checked against that type's parts. A generic call takes what the expected type says of the type parameters its arguments left open, and its arguments are then checked against their parameters, so the expected type reaches as far in as it's needed:

```silver
val v: UInt8 = id(id(1))                               // each id is an id<UInt8>, and the 1 a UInt8
val t: Table<String, Int> = Table(Branch(0, []), 0)    // the [] is a [Node<String, Int>]
val r: Int ! String = id(Error("x"))
```

That makes wrapping harmless: where `val v: X = e` works, so does `val v: X = id(e)`, and so do `(e)` and `{ e }`.

A result that is only a type parameter takes the expected type whole, so in `val v: Int? = id(None)` the `T` is `Int?`. A literal is therefore promoted on its way in, while a value with a type of its own decides `T` first and is promoted on its way out:

```silver
def describe<T>(x: T): T {
    printl("saw {x}")
    x
}

val n = 5
val a: Int? = describe(5)    // saw Some(5)
val b: Int? = describe(n)    // saw 5
```

Where the result's own shape can't be the option or error union that's expected, the layer is the promotion's: against `Box<Int>?`, a result of `Box<T>` gives `T = Int`.

With nothing expected, such an expression is what its parts make it, by the rules each form has anyway. A number literal is its default type, and literals that have to share a type [take one together](numbers.md#literals). A `None` beside a value [makes an option of it](options.md), so `[1, None]` is an `[Int?]` and `if c => 1 else None` an `Int?`. A generic call binds its type parameters from what its arguments are with nothing expected, so `id(1)` is an `Int` and `opt(1, None)` an `Int?`, and a lambda's body gives its result once its parameter types are known, so `map(xs, x => x + 1)` is an `[Int]`. Only an expression with nothing to make it anything is an error, which asks for the type to be written: `None`, `[]`, `[None]`, `(1, None)`, `Box([])` and `none()` are, as in `val x = None`.

How such an expression takes its turn among a generic function's arguments is under [Inference](generics.md#inference), how it's compared with each of several functions under [Overloading](functions.md#overloading), and what it does before a `.` under [Method-call syntax](functions.md#method-call-syntax).

## Equality and ordering

`==` and `!=` work on any two values of one type. Options, arrays, tuples and declared types are compared structurally. Two `Ref`s are equal when they're the same cell (see [Shared references](refs.md)), two handles of a [native type](native.md#native-types) when they're the same address, and function values are compared as described below.

A type's equality belongs to the type. Its own module can replace the structural one by writing an `opEquals`, with an `opHash` to match, and the printed form by writing an `opString` (see [operator functions](functions.md#operator-functions)). A function in another module can't change what `==` means for it, and generic code comparing a value uses the same equality as everyone else. A comparison with another meaning, such as "equal ignoring case", is an ordinary function, passed where it's needed.

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

Two lambdas with the same text are different functions, and a lambda that calls a function isn't that function. So a lambda written in a comparison can't be equal to the other side, and it's an error there: as an operand of `==` or `!=`, or as part of a value an operand builds with a constructor, a tuple, an array, `Some`, `Ok` or `Error`.

```silver
button == Button("OK", () => save())     // error: this lambda is equal to nothing else
```

### Ordering

A type is ordered when it conforms to `Ord`, which asks for one function:

```silver
type Ordering = Less | Equal | Greater

interface Ord {
    def compare(a: Self, b: Self): Ordering
}
```

`<`, `<=`, `>` and `>=` work on two values of one ordered type, and mean what `compare` says: `a < b` is `compare(a, b) == Less`, and `a <= b` is `compare(a, b) != Greater`. `compare` is an ordinary function, called by name wherever the three-way answer is wanted.

```silver
type Card(rank: Int, suit: Suit)

def compare(a: Card, b: Card): Ordering => compare((a.rank, a.suit), (b.rank, b.suit))
conform Card: Ord

Card(3, Club) < Card(5, Club)        // true
compare(Card(3, Club), Card(3, Club)) // Equal

def smaller<T: Ord>(a: T, b: T): T => if a < b => a else b
```

These types are ordered already:

| Type | Order |
| --- | --- |
| The integer types | By value |
| `Float`, `Float32` | By value, with `-0.0` and `0.0` equal and NaN after every other value |
| `Char`, `String` | By code point, a string being compared a character at a time, with a prefix before what it's a prefix of |
| `Bool` | `false` before `true` |
| A tuple, when each element is ordered | Element by element, the first difference deciding |
| `[T]`, when `T` is ordered | Element by element, with a prefix before what it's a prefix of |
| `T?`, when `T` is ordered | `None` before every `Some` |

- Function values, `Ref`s, [native types](native.md#native-types), maps and error unions aren't ordered.
- Both sides are one type, as for `==`: an `Int8` isn't compared with an `Int`. A literal written as `Some(...)`, a tuple or an array takes its type from the other side, so with `x: UInt8?`, `x < Some(2)` compares two `UInt8?`s.
- A value isn't wrapped to meet an option, as it is for `==`. With `age: Int?`, `age < 18` is an error: `None` is before every `Some`, so it would be true for a missing age without saying so. `age < Some(18)` says it, and `age ?? 0 < 18` chooses what a missing one counts as.
- `<` on two `Float`s or two `Float32`s written outside generic code is the machine's comparison, which is false whenever either is NaN. `compare` on them, and `<` on a type parameter that turns out to be a `Float` or a `Float32`, use the total order above, so the two differ only when a NaN is involved.
- `Ord` is an [interface](interfaces.md) like any other, so a module can order a type it didn't declare, and there is one order for a type in the whole program.

### An order from the type's shape

Nothing is ordered without a conformance. A type whose order is the order it's written in asks for it with `derivedCompare`:

```silver
type Rank = Two | Three | Four | Jack | Queen | King | Ace

def compare(a: Rank, b: Rank): Ordering => derivedCompare(a, b)
conform Rank: Ord

Jack < Ace        // true
```

- A sum's members are ordered as they're declared, and two values of one member by its fields. A product is ordered by its fields, the first difference deciding.
- Every field, and every member that's a type of its own, has to be ordered, or the call is an error that names the one that isn't.
- It takes two values of a declared type. A tuple, an array or an option is ordered already, and anything else has no members or fields to go by.
- It's called like a function, so a `compare` can use it for part of its answer and decide the rest itself.

### Ordering and equality

`==` never calls `compare`: [equality belongs to the type](#equality-and-ordering), and ordering is a conformance. The two should agree, so that `compare(a, b) == Equal` exactly when `a == b`, and nothing checks that they do. `derivedCompare` agrees with structural equality. The one built-in exception is NaN, which `compare` puts equal to itself and `==` doesn't.

## Printing

`print` and `printl` (which adds a newline) take a value of any type, as `print<T>(value: T)`, and `String(x)` and string holes format it in the same way. Every type prints, so generic code prints a value of a type parameter with no bound, and `print` and `printl` are function values like any other generic function: `val log: (String) -> Unit = printl` makes `log` print a line, where the function type it is expected to be chooses the overload.

| Value | Printed form |
| --- | --- |
| `()` | `()` |
| `"text"` | `text` |
| `1.0`, `0.1 + 0.2`, `1e300` | `1.0`, `0.30000000000000004`, `1e300`: see [Numbers](numbers.md#printing-floats) |
| `Some(1)`, `None` | `Some(1)`, `None` |
| `Ok(1)`, `Error(Empty)` | `Ok(1)`, `Error(Empty)` |
| `[1, 2]`, `["a"]` | `[1, 2]`, `[a]` |
| `(1, "a")` | `(1, a)` |
| a product or member `Point(1, 2)` | `Point(1, 2)` |
| a marker | its name |
| a function value | its name: `increment`, `Point` |
| a handle of a [native type](native.md#native-types) | its type and address: `File(0x1f4a3c02340)` |

A function value prints as the function it comes from, without anything it captured, so `adder(1)` and `adder(2)` print alike:

- A `def`, a constructor or a native function prints its name. An overloaded one prints the same name for each overload.
- A generic instance adds its type arguments, written as they would be in source: `identity<Int>`, `wrap<[String]>`.
- A nested `def` prints its name, and a lambda prints `lambda`.
- A function from another module prints without the module's name, as its types' values do.

## Open questions

- Whether integers widen implicitly where a type is expected, as `Int8` to `Int` or `UInt8` to `Int16`. These would pass the rule for implicit conversions. `Int` and `UInt` wouldn't convert in either direction, and neither would `Int` to `Float`, which is inexact for large values.

## Current implementation

- [A type of its own](#a-type-of-its-own) is built in part, by separate lists of forms:
  - A generic call always counts as having a type of its own, so nothing expected reaches into one that's an argument of another generic call or of an overloaded function: `id(id(1))` where a `UInt8` is expected, `Wrap(Box([]))`, `id(none())` and `ov(id(1))` are errors, while each works one level up, as `val v: UInt8 = id(1)` does.
  - As an argument of a generic function, an array, tuple, dictionary or `Some` of literals, an `if`, a block and arithmetic are typed alone first, so `same([1, 2], t)` with `t: [UInt8]` is an error where `same(1, small)` works.
  - A bare `Error(e)` binds a type parameter to a type that only it has, so `same(Error("x"), t)` with `t: Int ! String` is an error, and `id(Error("x"))` compiled is `I0002`.
  - A result that is only a type parameter takes an expected option's or error union's value type, not the whole of it, so `val v: Int? = id(None)` is an error and `describe(5)` above prints `saw 5`.
- A tuple is ordered up to eight elements. `lang` writes the conformance once for each length, since no one declaration covers them all.
- `compare` on an integer is written once for each integer type, since a bound can't ask for an integer yet, so an error about a call of it lists them all.
- `derivedCompare` can only be called. It isn't a function value, so `val f = derivedCompare` is an error.
- `Ord`, `Ordering` and its members, `compare` and `derivedCompare` are declared in `lang.ord`, which `lang` forwards, and the compiler finds them there by name.
