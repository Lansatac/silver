# Proposal: ranges

**Status: designed, mostly not built.** The protocol, sources with state, `for`, `a..b` as a value, laziness, interface names as types and the library's shape are decided. `for` and interface names as parameter types are implemented. What's left open is listed at the end and marked where it comes up. It builds on [generics](../language/generics.md) and on the [interfaces proposal](interfaces.md), and it changes parts of that proposal; see "What this changes in the interfaces proposal".

Each point below is marked:

- **Leaning**: the direction preferred in discussion so far.
- **Proposed**: suggested, not yet confirmed.
- **Open**: no direction yet.

## Summary

A range is an immutable value that can be stepped: `next` returns the next element and the rest of the range, or `None` at the end. Anything with a `next` of that shape is a range, and `for` loops over any of them. Adapters such as `map` and `filter` are lazy and are ordinary library code.

```silver
val big = [1, 2, 3].map(x => x * 2).filter(x => x > 2).array()    // [4, 6]

for n in Countdown(3) { printl(n) }
```

## The protocol (decided)

```silver
interface Range<T> {
    def next(range: Self): (T, Self)?
}
```

- Stepping never changes a range value. What stepping the same value again gives depends on where its state is; see "Sources with state".
- The element type `T` is not chosen by the caller. It's read off the `next` that conformance finds. A type can only be a range of one element type in a given place, because functions aren't overloaded on their return type.

### Arrays

One generic function in the prelude makes every array a range:

```silver
def next<T>(xs: [T]): (T, [T])? =>
    if length(xs) == 0 => None else (xs[0], xs[1..])
```

```silver
next([10, 20, 30])   // Some((10, [20, 30]))
next([30])           // Some((30, []))
next([])             // None
```

Each step returns a shorter slice of the same buffer, so nothing is copied.

### A source of your own

```silver
type Countdown(from: Int)

def next(c: Countdown): (Int, Countdown)? =>
    if c.from == 0 => None else (c.from, Countdown(c.from - 1))
```

### Anything indexed (proposed)

A library type gives a `next` to any value with a `length` and an `opIndex`, by pairing it with a position:

```silver
type Iterator<R, T>(range: R, position: Int)

def iterate<R: Indexed<T>, T>(range: R): Iterator<R, T> => Iterator(range, 0)

def next<R: Indexed<T>, T>(it: Iterator<R, T>): (T, Iterator<R, T>)? =>
    if it.position == length(it.range) => None
    else (it.range[it.position], it with (position = it.position + 1))
```

It's how a type with only a `length` and an `opIndex` is looped over or passed to an adapter: `for cell in row.iterate()`, `row.iterate().map(f)`. An `Iterator` has a `length` and an `opIndex` of its own, counted from its position, so a `for` over one is still a loop by index.

### Sources with state (decided)

A range value is immutable, and where its state is kept decides what stepping it again does. There is no rule that stepping one value twice gives the same element.

- **State in the range.** A generator, a deck or a position in a parse keeps its state in a field, and the rest that `next` returns carries the new state. Stepping the same value again gives the same element. The state comes back to the caller as that rest, so a consumer that stops early returns it, as `splitAt` returns the elements taken and the range that continues. A range of random draws takes a generator of its own from `std.random.split`, which leaves the caller's usable.
- **State outside the range.** A range over input, or one holding a `Ref`, gets a new element each time it's stepped:

  ```silver
  type Input

  def next(input: Input): (String, Input)? {
      val line = read()?
      (line, Input)
  }

  val input = Input
  next(input)     // the first line
  next(input)     // the second line, from the same value
  ```

  Such a range is single-pass: a step can't be taken again, and looking at the first element to see whether there is one uses it up. Nothing in the type says so. The library's documentation says which of its sources are single-pass.

- **Considered**: a protocol that changes the range, `next(mutable range: Self): T?`. Input fits it with nothing to explain, state comes back through the `mutable` argument, and adapters are shorter. Rejected because a range is to be an immutable value.
- **Considered**: a source that remembers each step in a `Ref`, so that stepping a value again gives the same element without reading again. Rejected as what a source does by default, since it costs a cell for every element. It can be a library adapter for input that has to be stepped more than once.

## `for` (decided)

`for` loops over a `Range<T>`: a value that a `next(r): (T, R)?` takes. It uses the functions a call at the loop would choose, which is how conformance is found, so naming the interface changes nothing about what's accepted. The rules are in [control flow](../language/control-flow.md#for). A range that also has a `length(r): Int` and an `opIndex(r, i: Int): T` is looped over by index. Otherwise it's stepped, expanded in lowering to:

```silver
mutable val rest = e
while val step = next(rest) {
    val (x, after) = step
    rest = after
    ...
}
```

Indexing is preferred when both fit, so a random-access range gets an index loop rather than a chain of steps. Arrays keep their built-in index loop, and `a..b` keeps its own.

A type with a `length` and an `opIndex` but no `next` isn't looped over (decided; the implementation still accepts it). So whatever a `for` takes, `map`, `filter` and `array()` take too. Such a type gets a `next`, or is wrapped with `iterate()`; see "Anything indexed". The error for it says so, as does the error for passing it to an adapter.

- **Considered**: `for` taking a value that is indexed and not a range, as first built. A type could then work in a `for` and be rejected by the first adapter it met.
- **Left out on purpose**: a second interface for things that can be turned into a range (Rust's `IntoIterator`). Addable later.
- **Decided and implemented**: a tuple pattern in `for`, as in `for (i, x) in xs.enumerate()`. See [control flow](../language/control-flow.md#for).
- `a..b` as a value is an `Interval`; see the next section.

## `a..b` as a value (decided)

Outside a slice and a `for`, `a..b` builds an `Interval`, a product in the prelude that the compiler knows by name, the way it knows `Some`:

```silver
type Interval<T>(from: T, to: T)

val r = 2..6                          // Interval<Int>
length(r)                             // 4
r[1]                                  // 3
r.contains(5)                         // true
r == 2..6                             // true
for i in r { ... }                    // 2 3 4 5

val squares = (2..6).map(x => x * x)  // lazy, and still indexed
squares[3]                            // 25
squares.array()                       // [4, 9, 16, 25]
```

- **The name** is `Interval`, since `Range<T>` is the interface.
- **The bounds** are of any one integer type, with a literal adapting to the other bound, as in a `for`. So `low..255` with a `UInt8` is an `Interval<UInt8>`, and whatever a `for` can loop over can be bound to a name first. A `Char` isn't a bound.
- **It has** a `length` and an `opIndex`, so it's indexed and a `for` over it loops by index, a `next`, and `contains`. Its length is an `Int`.
- **Bounds the wrong way round are empty.** `5..0` has length 0 and loops no times, as `for i in 5..0` does. It isn't a panic.
- **Slicing with one works.** `xs[r]` is `opIndex(xs, r)`, and arrays have an `opIndex` that takes an `Interval<Int>` and panics as the slice would. `xs[a..b]` written out is still `opSlice(xs, a, b)`, which builds no value.
- **A method call needs parentheses**, since `0..10.map(f)` is `0..(10.map(f))`.
- `for i in a..b` keeps its own loop, which behaves the same.
- **Considered**: `x[a..b]` as `opIndex(x, a..b)`, with no `opSlice`. It's one rule, but `xs[a..]` would then need a second type for an interval with no end.
- **Left out of the first version**: `a..` and `..b` as values, an inclusive form, and a step in the syntax. `enumerate()` covers numbering elements, and `step(n)` and `reversed()` can be library adapters.
- **Open**: what an `Interval` prints as. Today a product prints as `Interval(2, 6)`.

## Adapters

An adapter is a value holding its source. Building a chain does no work; work happens when something pulls.

```silver
type Mapped<R, T, U>(source: R, transform: (T) -> U)

def map<R: Range<T>, T, U>(source: R, transform: (T) -> U): Mapped<R, T, U> =>
    Mapped(source, transform)

def next<R: Range<T>, T, U>(m: Mapped<R, T, U>): (U, Mapped<R, T, U>)? {
    val (item, rest) = next(m.source)?
    (m.transform(item), Mapped(rest, m.transform))
}

def length<R: Sized, T, U>(m: Mapped<R, T, U>): Int => length(m.source)
def opIndex<R: Indexed<T>, T, U>(m: Mapped<R, T, U>, index: Int): U => m.transform(m.source[index])
```

`Sized` and `Indexed<T>` are the capabilities `for` uses to loop by index:

```silver
interface Sized { def length(value: Self): Int }

interface Indexed<T> {
    def length(value: Self): Int
    def opIndex(value: Self, index: Int): T
}
```

`Mapped` is a range exactly when its source is, which its `next` says through its own bound. `filter` is the same shape, looping until an element passes.

The library's adapters return their own named types, not an opaque `Range<U>` (decided). An opaque result has only what its signature promises, so `[1, 2, 3].map(double)` would lose the array's length and indexing. Named, a `Mapped` has a `length` and an `opIndex` exactly when its source does, through functions like the two above, and `for` over it loops by index. The cost is that `Mapped` is public and appears in error messages. Nobody has to write it, since `val` infers it.

- **Considered**: an overload of `map` per capability, returning `Indexed<U>` for an indexed source. It needs an overload for each combination.
- **Considered**: keeping the result opaque and letting capability queries (`static if R: Sized`) see the real type. That recovers the fast path inside generic code, but `doubled[1]` still can't be written.

So a result keeps what its source can do, as D's ranges do, wherever its type is known: where the chain is written, where it's passed to a function that asks for the capability (`binarySearch<R: Indexed<T>, T>` takes `xs.map(f)`), and where a function returns it. One thing D has is missing:

- **A generic consumer sees only its bounds.** `array` below steps even over an indexed chain, and can't size its result first. An overload that also asks for `Indexed<T>` fixes it where the chain's type is known at the call (decided: of two functions differing only in their bounds, the one asking for more wins). It doesn't inside another generic function, since an overload is chosen where the call is written. That waits for [capability queries](interfaces.md#capability-queries-a-direction-not-in-the-first-version).
One pull on `[1, 2, 3].map(double).filter(big)`: the filter asks the map, the map asks the array and gets `1`, returns `2`, the filter rejects it and asks again, gets `4`, and returns `4` with a new filter over the rest.

A consumer turns a chain back into data:

```silver
def array<T>(range: Range<T>): [T] {
    mutable val result: [T] = []
    for item in range { result ~= [item] }
    result
}
```

### Laziness (decided)

Every adapter is lazy, over arrays as over anything else, and `array()` is how a chain becomes an array.

```silver
val doubled = xs.map(x => x * 2)        // a Mapped<[Int], Int, Int>; nothing has run
val kept = doubled.array()              // [2, 4, 6, 8]
val ys: [Int] = xs.map(x => x * 2)      // error, which says to add .array()
```

- Building a chain runs nothing. Each element goes through the whole chain before the next one starts, and no array is made between the steps.
- Consuming a chain again runs its functions again. `array()` is how a result is kept.
- A function passed to an adapter runs where the chain is consumed, so that's where it panics or has its effect. Over a single-pass source, consuming a chain twice gives different elements.
- An adapter is never turned into an array because one is expected: it's a type error, and the message names `array()`.
- Work that needs every element first, such as sorting or grouping, returns an array, as `array()` does.
- **Considered**: eager functions on arrays with a lazy family asked for by name, as Swift's `.lazy` and Kotlin's `.asSequence()` do. The short spelling would then be the one that builds an array at every step, and each adapter would exist twice.
- **Considered**: building the array wherever one is expected. It hides an allocation and a run of the whole chain behind an annotation, and values don't convert implicitly anywhere else.
- **Open**: what printing a chain shows. Today it's the adapter, as in `Mapped([1, 2, 3, 4], lambda)`. Printing the elements would use up a single-pass source.

## An interface name as a type (decided)

An interface name in a type position means "some type that satisfies it", decided when the program is compiled.

- **In a parameter** (implemented; see [Interfaces](../language/interfaces.md#an-interface-name-as-a-parameter-type)) it's shorthand for a bounded type parameter. `source: Range<T>` means `<S: Range<T>>(source: S)`. To say two parameters have the same type, name it. The hidden parameter is never written at a call and doesn't count as one, so `array<Int>(xs)` gives only `T`. A lambda or a nested `def` can't have such a parameter, since neither can be generic, and the error says to name the type.
- **In a return** it's a floor (decided): the result's type is the body's, the compiler checks that it satisfies the interface, and callers get the real type. See "An interface name as a return type".
- **On a binding** it's a floor too (decided). `val thing: Range<Int> = [1, 2, 3]` checks that the value is a `Range<Int>`, and `thing` is an array, so `thing[0]` works. A `mutable val` annotated this way still has one type, so it can't be given a range of another type.
  - **Considered**: a view that narrows the binding to what the interface provides. This was the earlier decision, made so that a binding could annotate an opaque result. The same annotation would then keep the real type on a return and hide it on a binding.

### An interface name as a return type (decided)

```silver
def squares<R: Range<Int>>(r: R): Range<Int> => r.map(x => x * x)

squares([1, 2, 3])[1]           // 4: the result is a Mapped<[Int], Int, Int>
squares(Countdown(3)).array()   // [9, 4, 1]
squares(Countdown(3))[1]        // error: Countdown isn't Indexed

def bad(xs: [Int]): Range<Int> => length(xs)    // error in bad: Int isn't a Range<Int>
```

- The result's type is worked out from the body, once, in terms of the function's type parameters. Here it's `Mapped<R, Int, Int>`, and it's the type callers see: they can name it, index it when it's indexed, and compare two results of the same type.
- The interface is what the author promises. A body whose type doesn't satisfy it is an error in that function.
- Several are joined with `&`, as in a bound: `def squares(xs: [Int]): Range<Int> & Indexed<Int>`. Adding a `filter` to that body is then an error there, and not in a caller that indexed the result.
- A caller can use more than was promised. If it does, a change to the body can break it, and the error is at the caller.
- An interface name can sit inside a tuple, an option, an array or a type argument of the result, each checked in its place, as `splitAt` returning `([T], Range<T>)` needs. It can't sit inside a function type, so `flatMap` names the type: `f: (T) -> R` with `R: Range<U>`.
- A function of an interface can't return an interface type. Each conforming function would return a different type, which is an associated type without a name.
- A function whose result type would depend on its own, as a recursive one's does, writes the type out.
- Every other result type is still written in full. This isn't inference for results in general.

What it can't do:

- An interface name can't be the type of a field or an element: `type Game(deck: Range<Card>)` has no single type. That needs a type parameter on `Game`, or the erased form.
- A function has one result type, so `if c => xs.map(f) else xs.filter(g)` is a mismatch unless erased.
- `r = r.map(g)` in a loop is a mismatch, since a `Mapped` of a `Mapped` is a new type.
- The result doesn't carry the conformance it was built with; it's searched again where it's used, as for any named type. The erased form carries it.

Considered:

- **An opaque result**, as Rust's `impl Trait` and Swift's `some`: callers see only the interface. This was the earlier decision. It hides how a result is built, but a function wrapping a pipeline loses its source's length and indexing, and `&` can't promise them when they depend on a type parameter. Hiding is what the erased form is for.
- **No result type at all**, as D's `auto`. Capabilities flow the same way, but the signature says nothing, and nothing holds the author to what they meant to return.

### The erased form

A range whose type is only its element type, holding a closure. It needs nothing beyond stage 1 generics:

```silver
type Seq<T>(step: () -> (T, Seq<T>)?)
```

It costs an indirect call and an allocation per step, and it's a real type that can be stored anywhere. It was first described as a later addition; fields and mixed branches need it, and it's the way to hide how a range is built, so it belongs in the first version. Decided: it's the library type `Seq<T>`, written in plain Silver. There is no general form such as `any Range<T>` in the first version, so an interface name can't be the type of a field or an element.

## The library (decided)

**Where it lives.** The interfaces, adapters and consumers are in `std.range`, and the prelude forwards all of it, so `xs.map(f).filter(g).array()` needs no import in any module. It has to be that way: conformance is looked up where a value is used, so a module that only loops over a chain another module built still needs the adapter's `next` in scope. Sources tied to a domain stay in their own modules, as random draws do in `std.random`.

- What one import brings is ranked as one module (decided; see [modules](../language/modules.md#forms-of-import)), so an array's own `first` in `std.array` beats the general one in `std.range` when both come through the prelude.

**Interfaces.** Three, and no more in the first version:

```silver
interface Range<T> {
    def next(range: Self): (T, Self)?
}

interface Sized {
    def length(value: Self): Int
}

interface Indexed<T> {
    def length(value: Self): Int
    def opIndex(value: Self, index: Int): T
}
```

Stepping from the end waits, so `reversed()` asks for `Indexed<T>`.

**Adapter types** are named for what they hold: `Mapped`, `Filtered`, `Taken`, `Dropped`, `Zipped`, `Enumerated`, `Reversed`. The functions are `map`, `filter`, `take` and so on. `Map` is left for a dictionary.

**The first set:**

| Kind | Functions | Keeps `length` and indexing |
| --- | --- | --- |
| Lazy | `map`, `enumerate`, `take`, `drop`, `zip`, `reversed`, `step` | When the source has them |
| Lazy | `filter`, `takeWhile`, `dropWhile`, `flatMap`, `append` | No |
| Sources | `a..b`, `iterate`, `unfold`, `repeat` | `a..b` and `iterate` |
| Consumers | `array`, `fold`, `sum`, `count`, `any`, `all`, `find`, `first`, `last`, `min`, `max`, `contains`, `isEmpty`, `splitAt` | |
| Return arrays | `sorted`, `sortedBy` | |

- `first`, `last`, `find`, `min` and `max` return an option, `None` for an empty range.
- `count`, `last` and `array` each have a second function that also asks for `Indexed<T>`, chosen where the type is known to be indexed.
- **Left out of the first version**: grouping, chunks, windows, `cycle`, and an adapter that remembers steps.

**The erased form** is `Seq<T>`, made with `seq()`:

```silver
val picked = if wantEven => xs.filter(isEven).seq() else xs.map(double).seq()

type Game(deck: Seq<Card>)

def walk(tree: Tree): Seq<Int> => match tree {
    Leaf => empty<Int>()
    Node(left, value, right) => walk(left).append([value]).append(walk(right)).seq()
}
```

It's for where one type has to stand for many: a field, an element of an array, two branches that build different chains, a chain built up in a loop, and a recursive function whose result would otherwise contain its own type. It also hides how a range is built. The error for mismatched branches suggests it.

- **Open**: collecting a chain over a `String` back into a `String`.

## Other shapes considered for `Mapped`

- **Hide `T` in a closure**: `type Mapped<R, U>(source: R, step: (R) -> (U, R)?)`, where `map` builds the closure from `transform` and the source's `next`. Needs no bound on `Mapped`'s `next`. One more indirect call per element.
- **The function type as the parameter**: `type Mapped<R, F>`, as Rust does. No shorter when written, and Silver's function values share one type per signature, so it buys nothing.
- **A bound that introduces `T`**: `type Mapped<R: Range<val T>, U>`. Tidy to read, but it needs bounds on a type's parameters, a way for a bound to bring a name into scope, implied bounds for functions over the type, and the witness as part of the type's identity. With `T` as a parameter of `Mapped`, ranges don't need this. It returns for public types whose invariant depends on a conformance, such as `Set<T: Ord>`.

## Cost

### When the program runs

Conformance is settled by the checker, and every call to `next` in a chain is a direct call to a specific instance. Nothing is looked up.

The cost is allocation. Products are heap values today, so each step of an adapter builds a new adapter value, per layer, per element. Plain loops over arrays and `a..b` avoid it through the index-loop lowering. For chains:

- **Small products by value** is the direct fix. An adapter becomes a few values LLVM can see through, the allocation goes, and a closure pointer that doesn't change in a loop can be called directly and inlined. It doesn't depend on the memory strategy.
- **Perceus-style reuse** removes the allocation when the range is unshared, by writing the new adapter into the old one's cell. It needs `next` to own its argument, so it comes with the late stage (borrow inference, cell reuse, the mid-level IR). It doesn't make an indirect call direct.
- Today the toolchain compiles without optimization by default and declares `silver_alloc` with no allocator attributes, so LLVM removes none of this.

### When the program is compiled

The search is cheap: one lookup per bound, proportional to the functions of that name in scope, adding per layer of a chain and never multiplying, and it caches per module. The real costs are the number of instances (each distinct chain compiles each adapter again), conformances that never terminate (a bound that needs itself fails, and the search has a depth limit: see [interfaces](interfaces.md#conformance)), and making the error say which layer of a chain failed to conform.

## Prerequisites, in order

1. Stage 1 generics (implemented).
2. Overloading (implemented): `next` for arrays, `Countdown`, `Mapped` and `Filtered` are all named `next`.
3. Interfaces: structural conformance, parameters that conformance determines, witnesses (implemented).
4. Interface names as types (implemented for parameters), with interface return types and the erased form.
5. The range library.
6. Small products by value, for chains to be fast when compiled.

Not needed for ranges: capability queries (`static if R: Sized`), an explicit adapter form, interfaces where `Self` is only in the return, operators mapped to interfaces, bounds on a type's own parameters.

## What this changes in the interfaces proposal

- Open question 1 (associated types) gets an answer, since decided there: a parameter on the interface, determined by the conformance.
- Interface names become usable as types, statically. Open question 7 (interface values) becomes the erased form.
- "Stored structure" is no longer needed by ranges, only by types like `Set<T: Ord>`.
- Overloading moves from "lands with generics" to a prerequisite of interfaces.

## Risks

1. **Stateful sources are untested.** Dealing cards with an `rng`, or reading lines, doesn't fit "a range is an immutable value" neatly: the final `rng` is wanted back after the range is consumed, and stepping a range over input twice gives different answers. `unfold(state, step)` covers generating, not recovering the state. No example has been worked. (Decided since: see "Sources with state".)
2. **Ranges are the hardest test of interfaces, not the most needed.** After stage 1 the first things missed will be printing and comparing a `T`. `Show` and `Eq` raise questions ranges don't: whether `==` means `equals`, whether derived equality is a conformance, whether a local function can change either. Interfaces should be designed against all three together. (Decided since: `==` and printing aren't interfaces and need no bound, so `Show` and `Eq` drop out. See the [interfaces proposal](interfaces.md).)
3. **A long chain of unbuilt features**, each designed on paper on top of the one before.
4. **The combination is new.** Structural conformance, lookup at the call site and bodies checked once aren't found together elsewhere. D has structural ranges but checks per instantiation and can't see a caller's functions; Nim and C++ concepts are structural with caller-side lookup but don't check bodies at the definition; Go is structural but only within the type's package; Scala passes witnesses but declares them. Known hazards: accidental matches, two modules disagreeing about a conformance, and interfaces such as `Default` that can't be expressed.
5. **Chains are slow when compiled** until products go by value.

## Open questions

- Whether the element type as an interface parameter reads well in practice.
- `a..` and `..b` as values, and whether an interval can be inclusive.
- Strings (decided): a string is a forward range of `Char`, with `bytes(s)` as the other view. See [Strings](../language/strings.md).
- Capabilities beyond stepping forward and indexing (which `for` now uses), such as stepping from the end. An adapter keeps its source's indexing by being a named type with a conditional `opIndex`.
- Whether a single-pass source should be told apart in its type, and whether the library has an adapter that remembers steps.
- Whether a range over input that fails part way has ended.

## Before deciding

Stage 1 generics are implemented, so this can start now: write `Seq<T>` and a few adapters in plain Silver and port a program from `exploration/` (cards or poker) to them. That tests the functional protocol, stateful sources and lazy chains against real code, with no new language features. Then design interfaces with `Show`, `Eq` and `Range` side by side.
