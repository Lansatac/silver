# Interfaces

An interface describes a shape: a set of function signatures. A type satisfies an interface when a `conform` declaration says so, and the functions that make it conform are ordinary functions.

```silver
interface Json {
    def toJson(value: Self): String
}

type Point(x: Int, y: Int)

def toJson(value: Int): String => "{value}"
def toJson(p: Point): String => "[{toJson(p.x)}, {toJson(p.y)}]"

conform Int: Json
conform Point: Json

def encode<T: Json>(item: T): String => "<" ~ toJson(item) ~ ">"

encode(1)              // <1>
encode(Point(1, 2))    // <[1, 2]>
encode("text")         // error: `String` isn't a `Json`; no conformance is declared
```

The declaration stands apart from both the type and the interface, so a module can make a type it didn't declare satisfy an interface. Whether a type conforms is a fact looked up in a table. It doesn't depend on where the question is asked.

## Declaring an interface

```silver
interface Sized {
    def length(value: Self): Int
}

interface Indexed<T>: Sized {
    def opIndex(value: Self, index: Int): T
}
```

- `Self` is the type that conforms. It's a type only inside an interface, and nothing else can be named `Self`.
- A function has a signature and no body, and no type parameters of its own. The interface's type parameters are in scope.
- Every function takes a `Self` somewhere in its parameters, because a function is found by what it's given. See [A type only in the result](#a-type-only-in-the-result).
- Two functions can share a name when their parameter types differ.
- An interface is declared at module level, can be `private`, and shares its module's names with types.

### An interface that requires another

An interface lists the interfaces it requires after its name, several joined with `&`. `Indexed<T>` above requires `Sized`.

```silver
conform [T]: Sized & Indexed<T>
conform Grid: Indexed<Int>         // error: a `Grid` isn't a `Sized`

def last<R: Indexed<T>, T>(r: R): T => r[length(r) - 1]
```

- A bound on it supplies the required interfaces' functions too, so `R: Indexed<T>` is also `R: Sized`.
- Conforming to it needs a conformance to each interface it requires, on the same line or another. Requiring doesn't declare one: every conformance is one somebody wrote.
- Two interfaces don't cover each other by declaring the same function.

## Conformance

```silver
conform Countdown: Range<Int>
conform Point: Json & Named
conform [T]: Range<T> & Sized & Indexed<T>
conform Mapped<R, T, U>: Range<U> when R: Range<T>
conform Mapped<R, T, U>: Indexed<U> when R: Indexed<T>
```

A conformance is written at module level, in any module. It names a type, then the interfaces it satisfies, joined with `&`.

- The type is a named type, a built-in one, or one of those with type parameters in its arguments, which the declaration introduces: a name in it that isn't a type where the declaration is written is a type parameter, so `T` in `conform [T]: Range<T>` is one and `Int` in `conform Box<Int>: Json` isn't. A type parameter alone conforms every type that meets its `when` bounds, which only the module that declares the interface can write: see [Every type that meets a bound](#every-type-that-meets-a-bound).
- For each function of the interface, with `Self` replaced, the function used is the one a call of that name with those argument types would choose where the declaration is written. So the functions have to be in scope there, as they would for the call.
- The function is chosen by its arguments alone. Its result then has to be exactly the interface's, with no conversion, and `mutable` has to agree: a function that takes its parameter as `mutable` fits only an interface function that does.
- A function that isn't found, or has the wrong result, is an error at the declaration, which names it.
- The functions stay ordinary module-level functions. `c.next()` and `next(c)` mean what they always did, and one function can serve several interfaces.
- An argument is promoted as in any call, so one function that takes a sum serves each member's conformance:

  ```silver
  type Shape = :Circle | :Square
  def area(s: Shape): Int => ...

  conform Circle: HasArea       // through area(Shape)
  ```

- A built-in type conforms by a declaration, like any other.
- `conform` is reserved only at the top level, and `when` only in a conformance. Anywhere else each is an ordinary name.

### Conditional conformance

`when` gives the bounds the type's parameters need. A `Mapped<R, T, U>` is indexed when its source is, and a `Box<T>` is a `Json` when what it holds is:

```silver
def toJson<T: Json>(b: Box<T>): String => "box({toJson(b.value)})"
conform Box<T>: Json when T: Json

encode(Box(Point(1, 2)))      // Box<Point> is a Json because Point is
encode(Box("text"))           // error: `Box<String>` is a `Json` only when `String` is
```

- A `when` bound is on one of the declaration's type parameters, and is written as any bound is.
- A `when` bound can introduce a type parameter the conforming type doesn't mention, when it's in an argument of the bound's interface that only the interface's results mention, alone or inside another type: `S: Range<(T, Int)>` takes a source that gives pairs whose second part is an `Int`, and decides `T` from the first. In `conform Skipped<S>: Range<T> when S: Range<T>`, `T` is whatever `S`'s conformance says its items are, so an adapter needs no type parameter for them. A name that nothing decides, as in `conform Box<S>: Json when S: Add<T>`, is an error, since `Add`'s `T` is in an argument.
- The function found for the conformance can have bounds of its own. They have to follow from the `when` clause, which is checked at the declaration.

### Every type that meets a bound

The module that declares an interface can conform every type that meets a bound to it, by conforming a type parameter alone:

```silver
interface Iterable<R> {
    def iterate(value: Self): R
}

private def iterate<R: Range<T>, T>(range: R): R => range
conform R: Iterable<R> when R: Range<T>          // every range is an `Iterable` of itself
```

- Only the interface's own module can write one, so every other conformance to the interface is checked against a declaration that's known, and no module can make everyone's types conform to an interface it didn't declare. Anywhere else it's an error.
- A type that meets the bounds can't declare a conformance of its own to the interface: it has this one, and a type has one. A type that doesn't meet them declares its own as usual.
- The function is found as for any conformance: the one a call with the type parameter as its argument would choose where the declaration is written.

### One conformance for a type and an interface

Two declarations that could apply to the same type and interface are an error that names both, wherever in the program they are. That covers the same pattern written twice, and overlapping ones such as `conform [T]: Json when T: Json` beside `conform [Int]: Json`.

- A parameter of the interface that's only in a result is part of the conformance, so an array is a `Range` of one element type: `conform [T]: Range<T>` and `conform [Int]: Range<String>` are two for one type and interface.
- A parameter in an argument is part of what the conformance is for. With `interface Add<Rhs> { def add(a: Self, b: Rhs): Self }`, a `Vec` can be an `Add<Vec>` and an `Add<Float>`, each declared.

### Who sees a conformance

A conformance isn't a name. It isn't imported, forwarded or qualified, and every module of the program sees it.

- It's never `private`. A private type can conform, and its values behave the same in generic code elsewhere. A conformance to a private interface is hidden already, since nothing outside can ask about it.
- The functions it uses don't have to be visible where the type is used. A generic function is given the functions the conformance found.

## Bounds

A bound says a type parameter satisfies an interface. It's written after the parameter, and several are joined with `&`:

```silver
def encode<T: Json>(item: T): String => toJson(item)
def describe<T: Json & Named>(item: T): String => name(item) ~ " " ~ toJson(item)
```

A bound goes on a type parameter of a `def` at module level. A type's parameter can't have one, and neither can an interface's.

Two bounds on one parameter to the same interface that differ only in arguments the interface's results alone mention can't both hold, since a type has one conformance to the interface: `R: Range<Int> & Range<String>` is an error where it's written. `T: Add<Int> & Add<Float>` is fine, since `Add`'s argument is in a parameter.

A bound is checked by looking the type up among the conformances. A function in scope with the right name doesn't make a type conform, and the error for a failed bound says when such a function exists and the `conform` line is all that's missing.

### Inside the function

A bound supplies its interface's functions for its type parameter, and those of the interfaces it requires. That's all that's known about the parameter. Each is an ordinary function of the current module, with `Self` replaced, so it's called by name or as a method, used as a value, and takes part in [overloading](functions.md#overloading):

```silver
def toJson<T: Json>(x: T?): String => match x {
    None => "null"
    Some(v) => toJson(v)        // the bound's toJson(T), which fits a T exactly, and not this function
}
conform T?: Json when T: Json
```

- It isn't generic, so it beats a generic function that fits as well, and `toJson(1)` in the same body still reaches the other functions named `toJson`.
- Two bounds that supply the same function supply one function.
- `for` over a value of the type parameter needs a bound of `Range`, and [loops](control-flow.md#for) as it does for any type.
- A bound on a type built from the parameter is looked up with the function's own bounds as what's known. In `def twice<T: Json>(item: T): String => encode(item) ~ encode(Box(item))`, a `Box<T>` is a `Json` because `T` is.

### Choosing a function

A function is chosen by its arguments. Its bounds are checked afterwards, against the one chosen, and a bound that fails is an error at the call. Two functions with the same parameter types are duplicates, whatever their bounds.

```silver
def put<T: Json>(x: T): String => ...
def put<T>(x: T?): String => ...

put(Point(1, 2))     // the first
put(Some("text"))    // the second
put("text")          // error: the first is chosen, and a `String` isn't a `Json`
```

So a missing `conform` line is an error, and never quietly chooses another function. A function for the types that can do more is one function that [asks](#asking-whether-a-type-conforms). See [Overloading](functions.md#overloading).

## Asking whether a type conforms

Where code needs to know whether a type has a capability it doesn't require, it asks in the body with `if type`:

```silver
def count<R: Range<T>, T>(r: R): Int =>
    if type R: Sized => length(r)
    else fold(r, 0, (n, item) => n + 1)

def middle<R: Range<Int>>(r: R): Int? =>
    if type R: Indexed<Int> => r[length(r) / 2]
    else r.drop(count(r) / 2).first()
```

- What follows `if type` is a bound, written as anywhere else: a type, `:`, and interfaces joined with `&`, as in `if type R: Sized & Indexed<T>`.
- Inside the branch the bound holds, so every value of that type has the interfaces' functions. There's no new name.
- It's decided when the function is compiled for a real type, by looking the type up. Nothing is written in the signature, and a caller passes nothing.
- Both branches are checked, once, like the rest of a generic body. It's an expression, with `=>` and `else` or with blocks, as `if` is, and its branches give one type.
- It asks about a type, so the type needs a name: one of the type parameters of the function it's in. A parameter written `r: Range<Int>` has a type that isn't written, and a function that asks about it names it: `<R: Range<Int>>(r: R)`.
- Every name in it is one already in scope. A type parameter that only a test mentions has to be given by each caller, so `def f<R, T>(r: R): Int => if type R: Range<T> => 1 else 0` can't be called as `f([1])`: nothing there says what `T` is.
- A test asks with the arguments the type's bounds already give. Where `R` is a `Range<T>`, `if type R: Range<Int>` is an error, as [those two bounds](#bounds) are: a type has one conformance to `Range`, and the bound already says which, so a test can't narrow `T` to `Int`.
- It isn't a condition, and can't be joined to one with `&&`.
- Its branches can compute different things: it chooses by type, for a faster way to do the same thing or for something else.
- Where two bounds supply a function with the same name and type, as two interfaces that both declare `size(value: Self): Int` do, a call finds the one of the bound written first, and in an `if type` the one supplied outside it.

[`if val`](control-flow.md#if) asks about a value while the program runs, and doesn't ask about interfaces.

## Interface parameters

A type that depends on the conforming type, such as what a range yields, is a type parameter of the interface.

```silver
interface Range<T> {
    def next(range: Self): (T, Self)?
}

def collect<R: Range<T>, T>(range: R): [T] { ... }

collect([1, 2, 3])        // T = Int, from conform [T]: Range<T>
collect(Countdown(3))     // T = Int, from conform Countdown: Range<Int>
```

A bound is looked up with what's known at that point:

- **A parameter that's only in a result is what the conformance says.** A `[String]` is a `Range<String>`, and passing one where a `Range<Int>` is wanted is an error that shows both.
- **A parameter in an argument is part of which conformance is meant.** A `Vec` that's an `Add<Vec>` and an `Add<Float>` satisfies `T: Add<Float>` by the second.
- **A parameter in an argument that isn't known yet** is given by the type's one conformance to the interface. When it has several, something else has to say which is meant.

In [inference](generics.md#inference), a bound is looked up as soon as its type is known: after the arguments that have a type of their own, and before the expected type, literals and lambdas. So a lambda's parameter can come from a bound:

```silver
def map<R: Range<T>, T, U>(source: R, transform: (T) -> U): Mapped<R, T, U> => ...

[1, 2, 3].map(x => x * 2)      // x is an Int, from the array's conformance
```

A literal doesn't adapt through a bound. With `toJson(x: UInt8)` and `conform UInt8: Json`, `toJson(1)` works, since the literal takes the parameter's type. `encode(1)` doesn't: the literal has its default type by the time the bound is looked up, and `Int` isn't a `Json`. `encode<UInt8>(1)` says which is meant.

## A type only in the result

A function that produces a `Self` from nothing of that type has no argument to be found by. It takes a parameter whose only job is to carry the type, `Of<T>`, from `std.of`, which the prelude forwards:

```silver
interface FromText { def fromText(of: Of<Self>, text: String): Self? }

def fromText(of: Of<Point>, text: String): Point? => ...
def fromText(of: Of<Int>, text: String): Int? => ...
conform Point: FromText
conform Int: FromText

// One generic function in front, which is what callers use.
def fromText<T: FromText>(text: String): T? => fromText(Of<T>, text)

val p = fromText<Point>("origin")
val n: Int? = fromText("one")
```

`Of<T>` is an ordinary type with one value, written `Of<Point>`. Nothing about lookup or conformance is special to these functions.

## An interface name as a parameter type

A parameter of a module-level `def` can have an interface as its whole type. It stands for some type that satisfies the interface, which is a type parameter that isn't written:

```silver
def array<T>(range: Range<T>): [T] { ... }      // <S: Range<T>, T>(range: S)
def total(range: Range<Int>): Int { ... }

array(Countdown(3))
array<Int>([4, 5])       // only T is a type argument
total(["a", "b"])          // error: a [String] is a Range<String>
```

- The hidden parameter is never written at a call and doesn't count toward "all type arguments or none".
- Each such parameter has a type of its own. To say two parameters have the same type, or to [ask](#asking-whether-a-type-conforms) about one, name it with a type parameter.
- The argument needs a type of its own, so `total([])` is an error.
- Several interfaces are joined with `&`, as in a bound, and the hidden parameter has every one: `def middle(items: Range<Int> & Indexed<Int>): Int` is `<S: Range<Int> & Indexed<Int>>(items: S)`.
- Inside a parameter's type an interface name or `A & B` isn't a type, as in `items: [Json]` or `item: Json?`, and neither is the parameter of a lambda or nested `def`, which can't be generic. A type parameter with a bound says it.
- A `native def`'s parameter and a parameter of an interface's function name their types too.

## An interface name as a result type

A function's result type can be an interface. The result's type is then the body's, the compiler checks that it satisfies the interface, and callers get that type with everything it can do:

```silver
def squares<R: Range<Int>>(r: R): Range<Int> => r.map(x => x * x)

squares([1, 2, 3])[1]           // 4: the result is a Mapped<[Int], Int, Int>
squares(Countdown(3)).array()   // [9, 4, 1]
squares(Countdown(3))[1]        // error: nothing indexes a Mapped<Countdown, Int, Int>

def bad(xs: [Int]): Range<Int> => length(xs)    // error in bad: an Int isn't a Range<Int>
```

- The result's type is worked out from the body, once, in terms of the function's type parameters. Here it's `Mapped<R, Int, Int>`. It's the type callers see: they can name it, index it when it's indexed, and use the function as a value of that type.
- The interface is what the author promises. A body whose type doesn't satisfy it is an error in that function, looked up as a [bound](#bounds) is.
- Several are joined with `&`, as in a bound: `def squares(xs: [Int]): Range<Int> & Indexed<Int>`. Adding a `filter` to that body is then an error there, and not in a caller that indexed the result. `?` binds tighter than `&`, so an option of the two is `(Range<Int> & Indexed<Int>)?`.
- A caller can use more than was promised. If it does, a change to the body can break it, and the error is at the caller.
- Everything the body returns has one type, as in any function. `if c => xs else xs.filter(f)` is a mismatch.
- An interface name can sit inside a tuple, an option, an array or a type argument of the result, each checked in its place:

  ```silver
  def split(xs: [Int]): (Int, Range<Int>) => (xs[0], xs[1..])
  def nonEmpty(xs: [Int]): Range<Int>? => if length(xs) == 0 => None else xs
  def rows(xs: [Int]): Range<Range<Int>> => [xs, xs]
  ```

  The type around it is the body's too, after the promotion any result gets: a body that gives an `[Int]` fits `Range<Int>?`, and one that gives an `[Int]` doesn't fit `(Int, Range<Int>)`.
- It can be the success side of an error union that's the whole result type, with `&` binding tighter than `!`. The errors are written as usual, and the body is any function's that returns an error union: `?` passes on an error the list includes, `Error(e)` returns one, `Ok(x)` returns a value, and branches can give different errors of the list. What goes to the errors is checked against them as written, so a literal adapts: `Error(1)` is a `Float` in a function returning `Range<Int> ! Float`.

  ```silver
  def lines(path: String): Range<String> ! IoError {
      val text = read(path)?
      text.split("\n")
  }

  def checked(xs: [Int]): Range<Int> & Indexed<Int> ! Empty | TooLong => ...
  ```

  Something the body returns has to be a value, since that's what says what the type is: a body that only returns `Error(e)` writes its result type out.

  An interface name can't be one of the errors, or sit in an error union inside the result, as in `(Int, Range<Int> ! E)`.
- It can't sit inside a function type. A function returning a function names the type: `<R: Range<Int>>(make: () -> R)`.
- A public function can't return a [private type](modules.md#visibility) this way, any more than it can name one in its signature. The error is at the result type, and says what the body returns:

  ```silver
  private type Steps(from: Int)
  private def next(s: Steps): (Int, Steps)? => ...
  conform Steps: Range<Int>

  def countdown(from: Int): Range<Int> => Steps(from)             // error: `Steps` is private
  def doubled(from: Int): Range<Int> => Steps(from).map(x => x * 2)   // error: a Mapped<Steps, Int, Int> holds one
  ```
- A function of an interface can't return an interface type, since each function that conforms would return a different one. A parameter of the interface says it.
- A function that needs its own result, by calling itself or a function that calls it, writes the type out. Another function of the same name isn't the function itself.
- Only a function with a body has a type to take: a `native def` writes its result type out.
- A lambda's and a nested `def`'s result type can be written this way too.
- Every other result type is still written in full.

### Only in a signature

An interface name is a type only in a function's signature: a parameter of a module-level `def`, and the result of a `def`, a nested `def` or a lambda. Everywhere else a type is written in full, and an interface name is an error: a `val`'s annotation, a binding in a pattern, a top-level constant, a field, an element and an alias. Mixed values go in a sum type.

```silver
val xs: Range<Int> = [1, 2, 3]      // error: an interface isn't a type for a binding
val xs = [1, 2, 3]                  // [Int]
val ys = squares(xs)                // Mapped<[Int], Int, Int>, the type `squares` returns
```

A binding needs no such annotation: the value already has a type, and the binding takes it.

## Open questions

- A value whose type is only an interface, as in `[Json]`, which needs a runtime representation.
- A bound on a type's own parameter, as in `type Set<T: Ord>`.
- A field a type has only when a type argument conforms.
- A form of `if type` with several arms, as `match type R { ... }`.
- An `if type` that narrows an argument its bounds leave open, as `if type R: Range<Int>` where `R` is a `Range<T>`, making `T` an `Int` in the branch; one that names a type of its own, as `if type R: Range<E>`; and one that asks about a type that isn't a bare type parameter, as `if type Box<T>: Sized`.
- Generic functions in an interface.
- Whether the functions can also be written inside the `conform` declaration.
- A shorter way to write a function for a type only in the result, such as `def Point.fromText(text: String): Point?`.
- Whether `Of` is the right name.

Decided, and not part of the first version, each described in the [conformance proposal](../proposals/conformance.md): which [package](modules.md#packages) may declare a conformance, and a program's conformance for a library's type that only the program sees. `Ord` is an ordinary interface, described in [Types](types.md#ordering). The proposal also has the reasoning behind these rules and what was rejected. The [ranges proposal](../proposals/ranges.md#an-interface-name-as-a-type-decided) covers an interface name as a result type.

## Current implementation

Declared conformance is built as described above, except what needs packages:

- In the first version every module sees every conformance, and any module can declare one.
- A conformance's functions are found as a call where it's declared would find them. Where that chooses among functions of one name, one whose own bounds fail is passed over, unlike at a call, and so is one for an overloaded function used as a value.
- The error for two conformances that overlap names the earlier one by its type and module, not where it's written.
- A `val`'s annotation can still name an interface, as in `val xs: Range<Int> = [1, 2, 3]`: the binding has the value's type, checked against the interface, and a `mutable val` keeps the first value's type.
- Beside an interface name in a result type or an annotation, a literal has its default type, since nothing but the interface is there to say otherwise. `def f(xs: [Int]): (Float, Range<Int>) => (1, xs)` is a mismatch and `val a: Range<Float> = [1, 2]` is an `[Int]` that isn't a `Range<Float>`; `(1.0, xs)` and `[1.0, 2.0]` are how to write them, and the error says so. The errors of an error union aren't beside it in this sense: they're written out, and a literal in an `Error` adapts to them.
- `Ok(None)` and `Ok([])` under an interface name are errors even where another branch says what the type is, since the `Ok` has to have a type of its own.
- A private alias for a public type doesn't count as private in what a public function returns through an interface name, since the result's type is the type the alias names.
- When two functions need each other's result, the error is at the result type of the one reached first, and doesn't name the other.
