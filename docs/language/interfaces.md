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

Two functions that differ only in their bounds are duplicates, as two that differ only in their result are.

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
  type Shape = Circle | Square
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
def map<R: Range<T>, T, U>(source: R, transform: (T) -> U): Map<R, T, U> => ...

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
def toArray<T>(range: Range<T>): [T] { ... }      // <S: Range<T>, T>(range: S)
def total(range: Range<Int>): Int { ... }

toArray(Countdown(3))
toArray<Int>([4, 5])       // only T is a type argument
total(["a", "b"])          // error: a [String] is a Range<String>
```

- The hidden parameter is never written at a call and doesn't count toward "all type arguments or none".
- Each such parameter has a type of its own. To say two parameters have the same type, name it with a type parameter.
- The argument needs a type of its own, so `total([])` is an error.
- Anywhere else an interface name isn't a type: inside another type (`[Json]`, `Json?`), as a field, a result, a binding's annotation, or the parameter of a lambda or nested `def`, neither of which can be generic. Mixed values go in a sum type.

## Open questions

- Returning an interface type, as in `def evens(xs: [Int]): Range<Int>`, and annotating a binding with one. See the [ranges proposal](../proposals/ranges.md#an-interface-name-as-a-type-decided).
- A value whose type is only an interface, as in `[Json]`, which needs a runtime representation.
- Asking whether a type satisfies an interface inside a generic function, as in `static if R: Sized`.
- A bound on a type's own parameter, as in `type Set<T: Ord>`, which makes the conformance part of the type.
- A way to name which function conforms, for a type two imports conform differently.
- `Ord`, and what `opCompare` returns.
- An interface requiring another, default bodies, and generic functions in an interface.
- A shorter way to write a function for a type only in the result, such as `def Point.fromText(text: String): Point?`.
- Whether `Of` is the right name.

See the [interfaces proposal](../proposals/interfaces.md) for the reasoning behind these rules and the alternatives considered.

## Current implementation

- When several functions of a name could take a call, a bound whose type parameter only the call's expected type would decide isn't looked into until one is chosen, so it's an error then rather than a reason to choose another.
- A program that gives one type two conformances compiles a generic function once for each. Such an instance's name, as a function value prints it, doesn't show which it is.
- Everything else above is implemented.
