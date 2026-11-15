# Interfaces

An interface describes a shape: a set of function signatures. A type satisfies an interface by having those functions, and nothing declares that it does.

```silver
interface Json {
    def toJson(value: Self): String
}

type Point(x: Int, y: Int)

def toJson(value: Int): String => "{value}"
def toJson(p: Point): String => "[{toJson(p.x)}, {toJson(p.y)}]"

def encode<T: Json>(item: T): String => "<" ~ toJson(item) ~ ">"

encode(1)              // <1>
encode(Point(1, 2))    // <[1, 2]>
encode("text")         // error: `String` isn't a `Json`
```

The functions are looked for where the type is supplied, at the call, and not inside the generic function. So a module can make a type it didn't declare satisfy an interface by writing an ordinary function.

## Declaring an interface

```silver
interface Indexed<T> {
    def length(value: Self): Int
    def opIndex(value: Self, index: Int): T
}
```

- `Self` is the type that conforms. It's a type only inside an interface, and nothing else can be named `Self`.
- A function has a signature and no body, and no type parameters of its own. The interface's type parameters are in scope.
- Every function takes a `Self` somewhere in its parameters, because a function is found by what it's given. See [A type only in the result](#a-type-only-in-the-result).
- Two functions can share a name when their parameter types differ.
- An interface is declared at module level, can be `private`, and shares its module's names with types.
- An interface can't require another. It doesn't need to for one to cover another: a type that's an `Indexed<T>` is a `Sized` too, when `Sized` declares the same `length`.

## Bounds

A bound says a type parameter satisfies an interface. It's written after the parameter, and several are joined with `&`:

```silver
def encode<T: Json>(item: T): String => toJson(item)
def describe<T: Json & Named>(item: T): String => name(item) ~ " " ~ toJson(item)
```

A bound goes on a type parameter of a `def` at module level. A type's parameter can't have one, and neither can an interface's.

Two functions with the same parameter types can differ in their bounds when one asks for everything the other does and more. Where both fit a call, the one that asks for more is chosen:

```silver
def count<R: Range<T>, T>(range: R): Int { ... }                    // steps to the end
def count<R: Range<T> & Indexed<T>, T>(range: R): Int => length(range)

count([1, 2, 3])        // the second
count(Countdown(3))     // the first: a Countdown isn't Indexed
```

- A bound asks for its interface's functions, so `R: Indexed<T>` asks for more than `R: Sized` when `Sized` declares only `length`. A function with no bound asks for nothing.
- Several can form a chain, each asking for more than the one before, and the one chosen is the one that asks for most of those that fit.
- When neither asks for everything the other does, as `R: Range<T>` and `R: Indexed<T>`, the two are duplicates. So are two that differ only in their result.
- A bound with a type written for its interface's parameter doesn't ask for the same function as one with a type parameter there, so `R: Range<Int> & Indexed<Int>` against `R: Range<T>` is a duplicate too.
- A literal argument is taken as the type the call would give it, from the type the call is expected to have first and its default otherwise. With `twice<T: A>(x: T): T` and `twice<T: A & B>(x: T): T`, `twice(1)` is the first when an `Int` is an `A` and not a `B`, and `val f: Float = twice(1)` is the second when a `Float` is both.
- What the expected type gives a type parameter has to suit the arguments as well as the bounds. With `conv<T: A>(x: T): [T]` and `conv<T: A & B>(x: T): T`, `val xs: [Int] = conv(1)` is the first even when an `[Int]` is both, since the second would need `1` to be an `[Int]`. When that leaves no function fitting and each fails only on an argument, the choice is made without the expected type, and the argument is then an error against the one chosen, as it would be with no overloads. When the expected type also breaks a function's bounds, the choice isn't made again, since that would bring the function back: `val q: [String] = conv(1)`, where a `[String]` isn't an `A`, is an error listing why each function doesn't fit.
- The choice follows the real type, wherever the call is written. Inside `def total<R: Range<T>, T>(range: R)`, `count(range)` is the second function when `total` is called with an array and the first when it's called with a `Countdown`. See [capability queries](../proposals/interfaces.md#capability-queries). When the two return different types, the choice is made from what's known where the call is written.

### Inside the function

A bound supplies its interface's functions for its type parameter, and that's all that's known about the parameter. Each is an ordinary function of the current module, with `Self` replaced, so it's called by name or as a method, used as a value, and takes part in [overloading](functions.md#overloading):

```silver
def toJson<T: Json>(x: T?): String => match x {
    None => "null"
    Some(v) => toJson(v)        // the bound's toJson(T), which fits a T exactly, and not this function
}
```

- It isn't generic, so it beats a generic function that fits as well, and `toJson(1)` in the same body still reaches the other functions named `toJson`.
- Two bounds that declare the same function supply one function.
- `for` over a value of the type parameter uses the bound's `next`, or its `length` and `opIndex`.

## Conformance

`T` satisfies an interface at a call when, for every function of the interface with `Self` replaced by `T`, a call of that name with those argument types would resolve there. The function that call would choose is the one used.

- The search is the overloading rule, with nothing of its own: the current module's functions first, then one imported module's. Only module-level functions are candidates. `toJson(foo)` and `encode(foo)` always choose the same function, and one resolves exactly when the other does.
- Nothing outside the caller's module and its imports is searched. Using a type with a bound needs the module holding its function imported, as calling the function does. When that's all that's missing, the error says so.
- The function is chosen by its arguments alone. Its result then has to be exactly the interface's, with no conversion, or the bound fails and the error names the function.
- An argument is promoted as in any call, so a function taking a sum makes each member conform:

  ```silver
  type Shape = :Circle | :Square
  def area(s: Shape): Int => ...

  def measure<T: HasArea>(shape: T): Int => area(shape)
  measure(Circle(2))        // a Circle is a HasArea, through area(Shape)
  ```

- `mutable` has to agree: a function that takes its parameter as `mutable` fits only an interface function that does.
- Two imported modules that fit equally well are an error. A bound has nothing to qualify, so the fix is a function in the current module that calls the one that's meant.
- A built-in type conforms through functions in scope, like any other.

### A function's own bounds

A function found for a bound can have bounds itself, and they're searched from the same call. That is how a type conforms when what it holds does:

```silver
def toJson<T: Json>(b: Box<T>): String => "box({toJson(b.value)})"

encode(Box(Point(1, 2)))      // Box<Point> is a Json because Point is
encode(Box("text"))           // error: that toJson needs `String` to be a `Json`
```

- A bound that needs itself fails. With only `toJson<T: Json>(x: T?)` in scope, an `Int` isn't a `Json`, since that function would need it to be one already.
- A search that keeps needing the same interface of a larger type is given up after 32 steps, with an error of its own.

### A failed bound doesn't fit

A function whose bound isn't satisfied doesn't fit a call, and the choice goes on among the others:

```silver
def show<T: Json>(item: T): String => "json " ~ toJson(item)
def show<T>(item: [T]): String => "{length(item)} values"

show(20)              // show<T: Json>
show([1.5, 2.5])      // show<T>([T]): a [Float] isn't a Json here
```

When nothing fits, the error says which bound failed and why.

### Inside a generic function

A bound on the function's own type parameter is passed along. A bound on a type built from it is searched where the function is written, with the bound's functions as the ones for the parameter:

```silver
def twice<T: Json>(item: T): String => encode(item) ~ encode(Box(item))
```

`encode(item)` uses whatever `twice` was given for `T`. `Box<T>` is a `Json` through the `toJson` for `Box` that this module sees, not one in the module that calls `twice`.

### Conformance belongs to the place, not the type

Two modules can give one type different conformances, each with its own function. A generic function is compiled once for each, and uses the one from where it was called:

```silver
// app.ag
def toJson(f: Foo): String => "foo#{f.id}"
encode(foo)            // json:foo#7

// pretty.ag, another module with its own toJson(f: Foo)
encode(foo)            // json:Foo { id: 7 }
```

## Interface parameters

A type that depends on the conforming type, such as what a range yields, is a type parameter of the interface.

```silver
interface Range<T> {
    def next(range: Self): (T, Self)?
}

def collect<R: Range<T>, T>(range: R): [T] { ... }

collect([1, 2, 3])        // T = Int, read off the next that takes an array
collect(Countdown(3))     // T = Int, from next(c: Countdown)
```

A bound is solved as a call, with what's known at that point:

- **A parameter that's only in a result is whatever the function found returns.** Functions aren't overloaded on their result, so a type is a range of one element type in a given place. A `[String]` is a `Range<String>`, and passing one where a `Range<Int>` is wanted is an error that shows both results.
- **A parameter in an argument takes part in choosing.** With `interface Add<Rhs> { def add(a: Self, b: Rhs): Self }`, a `Vec` with `add(Vec, Vec)` and `add(Vec, Float)` is both an `Add<Vec>` and an `Add<Float>`.
- **A parameter in an argument that isn't known yet** is bound by the one function that fits the arguments that are. When more than one fits, something else has to say what it is.

In [inference](generics.md#inference), a bound is solved as soon as its type is known: after the arguments that have a type of their own, and before the expected type, literals and lambdas. So a lambda's parameter can come from a bound:

```silver
def map<R: Range<T>, T, U>(source: R, transform: (T) -> U): Mapped<R, T, U> => ...

[1, 2, 3].map(x => x * 2)      // x is an Int, from the array's next
```

A literal doesn't adapt through a bound. With only `toJson(x: UInt8)` in scope, `toJson(1)` works, since the literal takes the parameter's type. `encode(1)` doesn't: the literal has its default type by the time the bound is looked into, and `Int` isn't a `Json`. `encode<UInt8>(1)` says which is meant.

## A type only in the result

A function that produces a `Self` from nothing of that type has no argument to be found by. It takes a parameter whose only job is to carry the type, the prelude's `Of<T>`:

```silver
interface FromText { def fromText(of: Of<Self>, text: String): Self? }

def fromText(of: Of<Point>, text: String): Point? => ...
def fromText(of: Of<Int>, text: String): Int? => ...

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
- Each such parameter has a type of its own. To say two parameters have the same type, name it with a type parameter.
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
- The interface is what the author promises. A body whose type doesn't satisfy it is an error in that function, found as a [bound](#conformance) is, from where the function is written.
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

  def countdown(from: Int): Range<Int> => Steps(from)             // error: `Steps` is private
  def doubled(from: Int): Range<Int> => Steps(from).map(x => x * 2)   // error: a Mapped<Steps, Int, Int> holds one
  ```
- A function of an interface can't return an interface type, since each function that conforms would return a different one. A parameter of the interface says it.
- A function that needs its own result, by calling itself or a function that calls it, writes the type out. Another function of the same name isn't the function itself.
- Only a function with a body has a type to take: a `native def` writes its result type out.
- A lambda's and a nested `def`'s result type can be written this way too.
- Every other result type is still written in full.

### On a binding

A `val`'s annotation works the same way: the binding has the value's type, checked against the interface.

```silver
val xs: Range<Int> = [1, 2, 3]
xs[0]                                             // 1: xs is an [Int]

val ys: Range<Int> & Indexed<Int> = squares(xs)
val strings: Range<String> = [1, 2]               // error: an [Int] is a Range<Int>

mutable val current: Range<Int> = [1]
current = [2, 3]
current = current.filter(x => x > 2)              // error: current is an [Int]
```

- A `mutable val` still has one type, the first value's.
- It nests as in a result type: `val pair: (String, Range<Int>)? = ...`, and `val loaded: Range<String> ! IoError = lines(path)`.
- The value has to say what the type is. `val xs: Range<Int> = []` and `mutable val xs: Range<Int>?` with no value are errors.
- Only a `val` with a name inside a function takes one. A binding in a pattern, as in `val (a: Range<Int>, b) = ...`, a top-level constant, a field, an element and an alias don't: each of those has one type, which has to be written. Mixed values go in a sum type.

## Open questions

- A value whose type is only an interface, as in `[Json]`, which needs a runtime representation.
- Asking whether a type satisfies an interface inside a generic function, as in `static if R: Sized`.
- A bound on a type's own parameter, as in `type Set<T: Ord>`, which makes the conformance part of the type.
- A way to name which function conforms, for a type two imports conform differently.
- `Ord`, and what `opCompare` returns.
- An interface requiring another, default bodies, and generic functions in an interface.
- A shorter way to write a function for a type only in the result, such as `def Point.fromText(text: String): Point?`.
- Whether `Of` is the right name.

See the [interfaces proposal](../proposals/interfaces.md) for the reasoning behind these rules and the alternatives considered, and the [ranges proposal](../proposals/ranges.md#an-interface-name-as-a-type-decided) for an interface name as a result type.

## Current implementation

- Inside a type's invariant and its `else`, a call of a function that others differ from only in their bounds is chosen from what's known where it's written, and so is how a `for` there loops: the question isn't carried to where the type is built.
- An answer that two imported modules give equally well is an error where the type becomes concrete, and it names the function that asked first, which can be one the call reaches rather than the one called.
- A program that gives one type different answers in two places compiles a generic function once for each. An answer that isn't there shows as `none` in such an instance's name.
- When several functions of a name could take a call, a bound whose type parameter only a lambda argument's result would decide isn't looked into until one is chosen, so it's an error then rather than a reason to choose another. Of two functions that differ in their bounds, the one that asks for more is then chosen even where only the other's bounds hold: with `ap<T>(x: Int, g: (Int) -> T)` and `ap<T: A>(x: Int, g: (Int) -> T)`, `ap(1, n => "s")` is an error when a `String` isn't an `A`. Annotating the lambda's result doesn't help; a named function in its place does.
- A program that gives one type two conformances compiles a generic function once for each. Such an instance's name, as a function value prints it, doesn't show which it is.
- Beside an interface name in a result type or an annotation, a literal has its default type, since nothing but the interface is there to say otherwise. `def f(xs: [Int]): (Float, Range<Int>) => (1, xs)` is a mismatch and `val a: Range<Float> = [1, 2]` is an `[Int]` that isn't a `Range<Float>`; `(1.0, xs)` and `[1.0, 2.0]` are how to write them, and the error says so. The errors of an error union aren't beside it in this sense: they're written out, and a literal in an `Error` adapts to them.
- `Ok(None)` and `Ok([])` under an interface name are errors even where another branch says what the type is, since the `Ok` has to have a type of its own.
- A private alias for a public type doesn't count as private in what a public function returns through an interface name, since the result's type is the type the alias names.
- When two functions need each other's result, the error is at the result type of the one reached first, and doesn't name the other.
- Everything else above is implemented.
