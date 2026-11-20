# Proposal: declared conformance

**Status: decided. [The first version](#the-first-version) is a part of it, and the rest is deferred. The first version is built.** This replaces the conformance rules of the [interfaces proposal](interfaces.md). [Interfaces](../language/interfaces.md) describes the first version. Interfaces, bounds, interface parameters, `Of<T>`, and an interface name as a parameter type are kept. The [ranges proposal](ranges.md) is written against these rules, and [What changes for ranges](#what-changes-for-ranges) lists what changed in it. The deferred parts depend on [packages](../language/modules.md#packages), and the first version doesn't.

## Summary

A type satisfies an interface because a declaration says so. The declaration stands apart from both the type and the interface, names no functions, and is resolved once, where it's written:

```silver
type Countdown(from: Int)

def next(c: Countdown): (Int, Countdown)? =>
    if c.from == 0 => None else (c.from, Countdown(c.from - 1))

conform Countdown: Range<Int>
```

From then on "is a `Countdown` a `Range<Int>`?" is a fact looked up in a table, and not a question answered by choosing a function at each use.

Code that can do something faster for a type with more capabilities asks in its body whether the type has them. Functions never differ only in their bounds, and a function is chosen without looking at its bounds.

## The first version

What's wanted is a range library that costs nothing most of the time in an optimized build, and code that asks what a type can do and adapts, as D's `static if` on a capability does, written with functions and no member blocks. The first version is the least that gives that:

- `conform`, with `when`, and one conformance for a type and an interface in the whole program.
- An interface that requires others.
- Bounds answered from the table, and checked after a function is chosen.
- `if type R: I` in a body, as the one way to ask for more than a bound says.
- `for` over any `Range`, always by stepping.

Decided and deferred, each marked below:

- **Who may declare a conformance, and a program's conformance that only the program sees.** Both need packages. Until then any module may declare one, a duplicate is an error wherever the two are, and every module sees the same answer.
- **`Ord`.** Decided since in full, and described in [Types](../language/types.md#ordering), and built.

Measured, two million elements ten times in an optimized build: a `map` and `filter` chain that only steps takes 20 ms against 18 ms for the loop by hand, and counting an array by stepping compiles to its length. Counting or taking the last element through a `map` stays a walk of every element, about 2 ms per two million, since the transform can panic and has to run. So nothing here is needed for the cost per element. The test is for the shortcuts an optimizer can't find, and for sizing an array before filling it.

## Motivation

Three rules of the current design compound:

- **Conformance is a search at a place.** Whether `T` is a `Sized` has no answer until a module is named, and answering it runs the overloading rule.
- **Overloads that differ only in their bounds make choosing a function depend on conformance.** So the choice runs inside the search that runs inside the choice, together with literals, lambdas and the expected type.
- **Inside a generic function the choice waits for the real type.** That needs questions carried to each caller, answers that may be absent, instances that differ in their answers, and a rule that every function of the group returns the same type. Invariants and promised result types each need their own answer to where the question goes.

Each was reasonable alone. Together, most of what's hard to resolve in the checker traces back to them, and the remaining open items in the range work are all about the third.

## Goals

- "Is this type one of these?" has one answer, found without choosing a function.
- A module can still make a type it didn't declare satisfy an interface.
- A library's code behaves the same whatever a program that uses it declares.
- Fast paths for the types that have them, through generic code, with nothing carried from callers.
- Generic bodies still checked once, and the same behaviour on both backends.

## The proposal

### Declaring a conformance (decided)

```silver
conform Countdown: Range<Int>
conform Point: Json & Named
conform [T]: Range<T> & Sized & Indexed<T>
conform Mapped<R, T, U>: Range<U> when R: Range<T>
conform Mapped<R, T, U>: Indexed<U> when R: Indexed<T>
```

- It's written at module level. The type is a named type, a built-in one, or one of those with type parameters in its arguments, which the declaration introduces.
- A type parameter alone isn't a type to conform: `conform T: Sized when T: Indexed<U>` is an error. It can be allowed later without breaking a program.
- `when` gives the bounds the type's parameters need. This is conditional conformance: a `Mapped<R, T, U>` is indexed when its source is.
- For each function of the interface, with `Self` replaced, the function is the one a call of that name with those argument types would choose where the declaration is written. Its result has to be exactly the interface's, and `mutable` has to agree. This is today's rule for a bound, run once at the declaration instead of at every use.
- A function that isn't found is an error at the declaration, as is one with the wrong result.
- The functions stay ordinary module-level functions. `c.next()` and `next(c)` mean what they do today, and a function can serve several interfaces.
- A conformance is never `private`. It's a fact about the type, seen by every package that can see it. A private type can conform, and its values behave the same in generic code elsewhere. A conformance to a private interface is hidden already, since nothing outside can ask.

### One conformance for a type and an interface (decided; who may declare one is deferred)

Two declarations that could apply to the same type and interface are an error that names both, whether they're the same pattern or overlapping ones such as `conform [T]: Json when T: Json` and `conform [Int]: Json`.

In the first version any module may declare one, and the check for two is made across the whole program. Once packages exist, which [package](../language/modules.md#packages) may declare one:

- **A library** declares a conformance only when it owns the type or the interface.
- **The program**, the package with the `main`, may also declare one for a type and an interface it owns neither of.
- **Built-in types** belong to `lang`, the one package the compiler knows. So a library can conform an array or a tuple to an interface of its own, and not to anyone else's.
- **Parts of one package** count as one for ownership.

So two libraries can never give a third's type two conformances to a fourth's interface, and a duplicate between the program and a library is in code the program's author can change.

### Making a library's type conform (decided, deferred)

```silver
import lib
import std.range

def next(foo: lib.Foo): (Int, lib.Foo)? => ...
conform lib.Foo: Range<Int>

lib.Foo(3).map(x => x * 2).array()      // a Foo is a range here
```

In the first version this works from any module, and every module sees the conformance, the library's included. What follows needs packages.

The program's conformance is seen by the program's own package. The library never sees it: its code was written without it and keeps behaving as it did.

```silver
// lib
def summary(foo: Foo): String => describe(foo)      // describe asks whether its argument is Indexed

// app, which declares conform lib.Foo: Indexed<Int>
describe(foo)          // asked from app: a Foo is Indexed
lib.summary(foo)       // asked inside lib: it isn't, as before app existed
```

- A question about a type is answered where the type becomes a real type in source, with the conformances that package sees: its own and those of the packages it depends on.
- Only the program can see more than a library does, since nothing depends on it. So there are at most two answers for a type and an interface in a program: the libraries' and the program's.
- A library's generic function called from the program with a `lib.Foo` uses the program's answer, as a bound does today. A library's function that isn't generic, or that makes the type concrete itself, uses the library's.
- A generic function at the same types asked from both is two instances.

### An interface that requires another (decided)

```silver
interface Sized { def length(value: Self): Int }

interface Indexed<T>: Sized {
    def opIndex(value: Self, index: Int): T
}

conform [T]: Sized & Indexed<T>
conform Grid: Indexed<Int>         // error: a Grid isn't a Sized

def last<R: Indexed<T>, T>(r: R): T => r[length(r) - 1]
```

- An interface lists what it requires after its name, several joined with `&`.
- A bound on it supplies the required interfaces' functions too, so `R: Indexed<T>` is also `R: Sized`.
- Conforming to it needs a conformance to each one it requires, on the same line or another. It doesn't declare them: every conformance is one somebody wrote.
- Two interfaces no longer cover each other by declaring the same function.

### Bounds (decided)

A bound is checked by looking the type up in the table, and it supplies the conformance's functions for its type parameter, as now. What's written at a use is unchanged:

```silver
def encode<T: Json>(item: T): String => "<" ~ toJson(item) ~ ">"

encode(Point(1, 2))
encode("text")         // error: `String` isn't a `Json`; no conformance is declared
```

- A `when` clause's bounds are looked up the same way, so `Box<Point>` is a `Json` because `Point` is.
- A function in scope with the right name no longer makes a type conform. The error for a failed bound says when such a function exists and the `conform` line is all that's missing.
- A parameter of the interface that's only in a result is fixed by the conformance: `collect([1, 2, 3])` reads `T = Int` from `conform [T]: Range<T>`. A parameter in an argument is part of what the conformance is for, so a `Vec` can be an `Add<Vec>` and an `Add<Float>`.
- A literal still has its default type by the time a bound is looked up.

### Asking whether a type conforms (decided)

Where code needs to know whether a type has a capability it doesn't require, it asks in the body with `if type`:

```silver
def middle<R: Range<Int>>(r: R): Int? =>
    if type R: Indexed<Int> => r[length(r) / 2]
    else r.drop(count(r) / 2).first()

def count<R: Range<T>, T>(r: R): Int =>
    if type R: Sized => length(r)
    else fold(r, 0, (n, item) => n + 1)
```

- What follows `if type` is a bound, written as anywhere else: a type, `:`, and interfaces joined with `&`, as in `if type R: Sized & Indexed<T>`.
- Inside the branch the bound holds, so every value of that type has the interfaces' functions. There's no new name.
- It's decided when the function is compiled for a real type, by the table. Nothing is written in a signature and nothing is passed between functions.
- Both branches are checked, once, like the rest of a generic body, and both give one type. It's an expression, with `=>` and `else` or blocks, as `if` is.
- It asks about a type, so the type needs a name. A parameter written `r: Range<Int>` has a type that isn't written, and a function that asks about it names it: `<R: Range<Int>>(r: R)`.
- It isn't a condition, and can't be joined to one with `&&`.
- It replaces a pair of functions that differ only in their bounds: `count` is one function that asks whether its range is `Sized`.

`if val` keeps one meaning, a one-arm `match` on a value while the program runs. It doesn't ask about interfaces.

### Choosing a function (decided)

- A function is chosen by its arguments. Its bounds are checked afterwards, against the one chosen, and a bound that fails is an error at the call.
- Two functions with the same parameter types are duplicates, whatever their bounds.

```silver
def put<T: Json>(x: T): String => ...
def put<T>(x: T?): String => ...

put(Point(1, 2))     // the first
put(Some("text"))    // the second
put("text")          // error: the first is chosen, and a String isn't a Json
```

Before this, `put("text")` was the second: the first was dropped when its bound failed, and `"text"` became a `String?`. So a missing `conform` line is now an error, where it would have chosen another function without one.

What goes is one function stepping aside for another because its bound failed. A function for a closer shape with a bound, and a general one behind it, become one function that asks in its body:

```silver
def array<R: Range<T>, T, U>(m: Mapped<R, T, U>): [U] =>
    if type R: Indexed<T> => ...                    // by index
    else ...                                        // steps
```

A lambda's result no longer takes part in choosing: the function is chosen by the lambda's shape, the lambda is typed, and then the bound is checked.

### `for` (decided)

`for` loops over a `Range`, and always steps with `next`.

```silver
def total<R: Range<Int>>(r: R): Int {
    mutable val sum = 0
    for x in r { sum = sum + x }
    sum
}

total([1, 2, 3])                  // steps
total([1, 2, 3].map(double))      // steps, though a Mapped over an array is Indexed
total(Countdown(3))               // steps
```

- It's the same rule for every type, and in a generic function it asks nothing about the real type.
- A loop over an array or an interval may run without calling `next`. It gives the elements stepping gives, so a program can't tell.
- The compiler knows `Range` and no other interface. `Range` is declared in `lang`, and `Sized` and `Indexed` in `std.range`.
- An `Interval` is an `Indexed`. Its `length` panics when it holds more integers than an `Int` counts, which a loop over it never asks for.
- A function that's faster by index says so: it asks with `if type R: Indexed<T>` and loops with a `while`.

Measured, two million elements ten times. In an optimized build a `for` over a `map` of a `map` takes 17 ms by index, 17 ms by stepping and 18 ms by hand, and one over a `map`, a `filter` and a `map` takes 17 ms against 20 ms by hand. Without optimization stepping the first takes 2.4 times what the loop by index does, and in the interpreter 1.8 times. A chain with a `filter` in it steps under either rule.

### Ordering (decided)

`Ord` is an ordinary interface under the rules above, with one function, `compare(a: Self, b: Self): Ordering`. [Types](../language/types.md#ordering) describes it, the types that are ordered already, and `derivedCompare`. A type's own package usually declares it, and a program can order a library's type that has no order:

```silver
// app
def compare(a: lib.Tag, b: lib.Tag): Ordering => ...
conform lib.Tag: Ord

val tags: Set<lib.Tag> = ...
```

The library can't have had an order for `Tag`, or this would be a duplicate, so nothing in it depended on one. `==` and printing still belong to the type, so nothing keeps a program's order for a library's type in agreement with the type's `==`.

### An interface name as a type

- As a parameter's type, unchanged.
- As a result type or a binding's annotation (decided), the value keeps its own type and everything that type can do, and the interface is a promise checked where it's written, against the table. See [Interfaces](../language/interfaces.md#an-interface-name-as-a-result-type). So a result can be asked about with `if type` wherever its type has a name, as a type parameter does when it's passed to a generic function.
- A value whose type is only an interface, as in `[Json]`, holds the value and the conformance it was made with. `Seq<T>` is that for `Range<T>`.

### What doesn't change

- Interfaces, `Self`, interface parameters and `&`.
- `Of<T>` for a function that produces a `Self` from nothing of that type.
- `==` and printing belong to the type.
- A generic body is checked once, and each instance is compiled for real types. Core and both backends see neither a bound nor a conformance.

## What this gives up

- **A conformance by writing a function alone.** Each conformance takes a line.
- **Two conformances of one type to one interface in different modules.** The second meaning is a wrapper type or a function passed as an argument.
- **A library conforming another library's type to a third's interface.** Only the program can.
- **A function that steps aside when its bound fails.** It becomes a test in the body.
- **A fast path turned on by a function in the caller's scope.** It's turned on by the conformance.
- **A field that's there only for some types.** D's `static if` can add a member to a type, and `if type` only chooses between two bodies.

## What this removes from the implementation

- The search for a conformance at each use, and its depth limit and cycle rule for anything but `when` clauses.
- Questions carried to callers, answers that may be absent, the pass that works them out, and the functions kept behind a call for each instance to choose from.
- Bounds inside the overload choice, and with them a lambda's result deciding which function is chosen.
- Instances keyed by the functions found. An instance is keyed by its types, and once a program's conformance is its own, by whether it was asked for from the program.
- A `for` by index, and the question a `for` asked about the real type in a generic function.

## Alternatives considered

- **Keep conformance by search, and replace only overloads that differ in their bounds** with default bodies and the test. The functions that differ go, but the test would still need an answer carried from each caller, since the answer would still depend on the place.
- **A program's conformance holds everywhere, inside the library too.** One answer per type, and simpler instances. Rejected: declaring a conformance outside a library would change how the library's own code runs.
- **No conformance for a type and an interface both owned elsewhere**, as in Rust. Simplest, and always one answer. It gives up making two libraries fit each other without a wrapper type, which the interfaces proposal counts among its motives.
- **The functions written inside the declaration,** as `conform Countdown: Range<Int> { def next(c: Countdown) => ... }`. It says which function is meant with no lookup. It would make those functions different from ordinary ones, or have two ways to write one. It could be added as a second form.
- **Conformances named and passed where wanted,** as `encode(foo using pretty)`. It brings back a second conformance for a type, and with it every question about which one a value was built with.
- **Functions that differ only in bounds kept, chosen by the table.** With one answer per type the choice needs nothing carried, but choosing a function would still depend on bounds, and the same-result rule and the duplicates rule stay.
- **A failed bound removes a function from the choice,** as it used to and as C++, D and Swift do. It keeps a general function behind a closer one with a bound. A missing conformance then chooses another function silently, and a bound only a lambda's result decides has to be settled during the choice.
- **A failed bound removes a function only when its type is known from the arguments.** It keeps the pair above and drops the lambda problem, with one more rule to learn and the same silent choice.
- **Requiring an interface also declares it,** so `conform [T]: Indexed<T>` makes an array a `Sized`. Fewer lines, and a conformance nobody wrote that a written one can collide with.
- **No requirements between interfaces,** with `Indexed` keeping a `length` of its own. An `Indexed` then isn't a `Sized` unless both are declared and both bounds are written.
- **A conformance for every type that meets a bound,** as `conform T: Sized when T: Indexed<U>`. It overlaps every other conformance to the interface, and needs a rule for which wins. Left for later.
- **`private conform`.** A conformance that isn't a public promise. But `encode(point)` would work in one module and fail in the next, a second conformance for the same pair could be declared beside it, and instances would differ by module. A private interface gives a library an internal conformance without it.
- **`Ord` declared only by the type's package.** One order per type with nothing to check. A library's type without one couldn't be a set's element or a map's key without a wrapper type.
- **Going back to conformance by search, without functions that differ in their bounds.** Nothing new to build, and the chain already costs what the loop by hand does. Generic code then can't ask what a type can do without the answer being carried from each caller, which is the part that was hard.
- **`for` by index when the type is `Indexed`,** stepping otherwise. This was the earlier decision. It's faster without optimization and in the interpreter, and the same in an optimized build. The compiler then knows three interfaces, a `for` in a generic function asks about each real type, a type's `next` and `opIndex` have to agree with nothing to check it, and an `Interval` can't be an `Indexed`, since a loop by index would panic in `length` on one that a loop by stepping runs.
- **A result type or annotation that restricts the value to the interface,** with a test to ask for more. This was the earlier decision. It lets a function return a private type, and keeps a caller from depending on more than was promised. A result's type then has no name for `if type` to ask about, so it needs a form of its own. A generic function would still see the real type, since `if type` is settled for each one, so the restriction would hold only where the result is used directly. And a function that wraps a chain would lose what the library's own adapters pass on. A function that hides how its range is built returns a `Seq<T>`, and one that wants a stable type writes it out.
- **`if val indexed: Indexed<Int> = r`,** the test as a pattern on a value. This was the earlier decision. It reads as the `name: Type` pattern, which asks about a value while the program runs, and on an option it reads as unwrapping one. It also needs a second name for a narrowed view of the same value.
- **`if R: Indexed<Int>`,** with no marker. It matches a bound exactly. In a body, among ordinary `if`s, nothing but a capital letter and a colon says that this one is settled when the function is compiled.
- **`static if`.** It says when the question is settled. In D the branch not taken isn't compiled and the block can hold declarations, and here both branches are checked and it's an expression. It also reads as a condition on any compile-time value, which is a different feature.
- **Other spellings:** `where` for `when`; bounds in `<>` after `conform`, as on a `def`; `impl Range<Int> for Countdown`. `conform T: I` reads as the bound it satisfies.

### Functions with a default body (considered, not taken)

A function of an interface could have a body, used by a conformance when no function of that name is found for the type. This was decided and then deferred, and is no longer a decision. [`if type`](#asking-whether-a-type-conforms-decided) does the same job from the library, so a fast path has one way to be written. An interface's functions are written in the interface, and `Range` is in `lang`, so every function of the range library with a faster form would have had to be declared in the compiler's package: `count`, `last`, `array`, and the `fold` their bodies call. One thing was never settled: an interface's function called by name fits every type, and can't step aside, so two interfaces in different modules with a function of one name make a call ambiguous for a type that has neither function of its own. It could come back for an interface a library owns. As it was described:

```silver
interface Range<T> {
    def next(range: Self): (T, Self)?
    def count(range: Self): Int => fold(range, 0, (n, item) => n + 1)
}

def count<T>(xs: [T]): Int => length(xs)
conform [T]: Range<T>                // uses the count above

conform Countdown: Range<Int>        // uses the default

def total<R: Range<Int>>(r: R): Int => count(r)

total([1, 2, 3])        // the array's count
total(Countdown(3))     // the default
```

- Each function of an interface is a function of the interface's module, generic over the conforming type, and callable by name: `count(Countdown(3))` reaches the default through the conformance.
- The interface's own function isn't a candidate when a conformance looks for a better one.
- An adapter passes a fast path on by writing it once. `Mapped` has `count(m) => count(m.source)`, and `Filtered` writes nothing and gets the default.
- The functions are expected to differ in speed and not in what they compute. Nothing checks that.

## What changes for ranges

- `Range` is declared in the compiler's package, since `for` uses it, with the built-in types' conformances to it. It has `next` and nothing else. `Sized`, `Indexed` and `Backward` are in `std.range`, which declares the built-in types' conformances to them. `Indexed` requires `Sized` and no longer declares `length` itself.
- A `for` always steps, so a loop over an indexed chain is no longer a loop by index. A consumer that wants one asks.
- Each adapter declares its own conformances, with `when`.
- `count`, `last`, `array` and the others with a second function for an indexed or backward source become one function each that asks in its body.
- A result type that's an interface stays as built: the result keeps its own type. The open question about functions that differ in their bounds goes.
- Answering a question inside an invariant goes with the questions.
- A chain built in one module and consumed in another is the same range in both, so the prelude no longer has to forward every adapter's `next` for that reason.

## Open questions

1. Whether the functions can also be written inside the declaration.
2. Whether a conformance can be seen only inside its own package.
3. Whether a conformance for a bare type parameter is allowed, and what wins where it overlaps.
4. Whether a type can have a field only when a type argument conforms.
5. A form with several arms, as `match type R { ... }`.
