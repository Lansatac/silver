# Proposal: ranges

**Status: exploring.** Only `for` over a value of your own is decided and implemented; the rest is undecided. It builds on [generics](../language/generics.md) and on the [interfaces proposal](interfaces.md), and it changes parts of that proposal; see "What this changes in the interfaces proposal".

Each point below is marked:

- **Leaning**: the direction preferred in discussion so far.
- **Proposed**: suggested, not yet confirmed.
- **Open**: no direction yet.

## Summary

A range is an immutable value that can be stepped: `next` returns the next element and the rest of the range, or `None` at the end. Anything with a `next` of that shape is a range, and `for` loops over any of them. Adapters such as `map` and `filter` are lazy and are ordinary library code.

```silver
val big = [1, 2, 3].map(x => x * 2).filter(x => x > 2).toArray()    // [4, 6]

for n in Countdown(3) { printl(n) }
```

## The protocol (proposed; the element type as an interface parameter is decided)

```silver
interface Range<T> {
    def next(range: Self): (T, Self)?
}
```

- Stepping never changes a range, so any range value can be used again. Holding an old one is always safe.
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

## `for` (decided and implemented)

`for` is structural for now: it uses the functions a call at the loop would choose, with no interface. The rules are in [control flow](../language/control-flow.md#for). In short, a value is looped over by index when a `length(r): Int` and an `opIndex(r, i: Int): T` take it, and otherwise stepped with `next(r): (T, R)?`, expanded in lowering to:

```silver
mutable val rest = e
while val step = next(rest) {
    val (x, after) = step
    rest = after
    ...
}
```

Indexing is preferred when both fit, so a random-access range gets an index loop rather than a chain of steps. Arrays keep their built-in index loop, and `a..b` keeps its own.

Because interface conformance in [interfaces.md](interfaces.md) is found by the same call-site lookup, any type that works with `for` today would satisfy a `Range` interface, so `for` can be made to require one later without breaking code.

- **Open**: whether `for` should require `Range` by name once interfaces exist. The two differ mostly in the error for something that isn't a range.
- **Left out on purpose**: a second interface for things that can be turned into a range (Rust's `IntoIterator`). Addable later.
- **Decided and implemented**: a tuple pattern in `for`, as in `for (i, x) in xs.enumerate()`. See [control flow](../language/control-flow.md#for).
- `a..b` as a value would be a product with `length` and `opIndex`, and the constructor that `a..b` builds would be known by name, the way `Some` is.

## Adapters

An adapter is a value holding its source. Building a chain does no work; work happens when something pulls.

```silver
type Map<R, T, U>(source: R, transform: (T) -> U)

def map<R: Range<T>, T, U>(source: R, transform: (T) -> U): Map<R, T, U> =>
    Map(source, transform)

def next<R: Range<T>, T, U>(m: Map<R, T, U>): (U, Map<R, T, U>)? {
    val (item, rest) = next(m.source)?
    (m.transform(item), Map(rest, m.transform))
}

def length<R: Sized, T, U>(m: Map<R, T, U>): Int => length(m.source)
def opIndex<R: Indexed<T>, T, U>(m: Map<R, T, U>, index: Int): U => m.transform(m.source[index])
```

`Sized` and `Indexed<T>` are the capabilities `for` uses to loop by index:

```silver
interface Sized { def length(value: Self): Int }

interface Indexed<T> {
    def length(value: Self): Int
    def opIndex(value: Self, index: Int): T
}
```

`Map` is a range exactly when its source is, which its `next` says through its own bound. `filter` is the same shape, looping until an element passes.

The library's adapters return their own named types, not an opaque `Range<U>` (decided). An opaque result has only what its signature promises, so `[1, 2, 3].map(double)` would lose the array's length and indexing. Named, a `Map` has a `length` and an `opIndex` exactly when its source does, through functions like the two above, and `for` over it loops by index. The cost is that `Map` is public and appears in error messages. Nobody has to write it, since `val` infers it.

- **Considered**: an overload of `map` per capability, returning `Indexed<U>` for an indexed source. It needs a rule for which bound is more specific, and an overload for each combination.
- **Considered**: keeping the result opaque and letting capability queries (`static if R: Sized`) see the real type. That recovers the fast path inside generic code, but `doubled[1]` still can't be written.

So a result keeps what its source can do, as D's ranges do, wherever its type is known: where the chain is written, where it's passed to a function that asks for the capability (`binarySearch<R: Indexed<T>, T>` takes `xs.map(f)`), and where a generic function returns the named type. Two things D has are missing:

- **A generic consumer sees only its bounds.** `toArray` below steps even over an indexed chain, and can't size its result first. An overload can't fix it, since two functions differing only in their bounds are duplicates, and an overload is chosen where the call is written. This waits for [capability queries](interfaces.md#capability-queries-a-direction-not-in-the-first-version).
- **An opaque return hides capabilities** (open). `def evens(xs: [Int]): Range<Int>` promises only stepping, so a function wrapping a pipeline loses its source's indexing unless it writes out `Filter<Map<[Int], Int, Int>, Int>`. D's `auto` keeps it. Candidates: inferring such a function's result type, or letting capabilities show through an opaque type.

One pull on `[1, 2, 3].map(double).filter(big)`: the filter asks the map, the map asks the array and gets `1`, returns `2`, the filter rejects it and asks again, gets `4`, and returns `4` with a new filter over the rest.

A consumer turns a chain back into data:

```silver
def toArray<T>(range: Range<T>): [T] {
    mutable val result: [T] = []
    for item in range { result ~= [item] }
    result
}
```

- **Proposed**: chains are lazy, and `val ys: [Int] = xs.map(f)` is an error that points at `.toArray()`. The alternative, eager array functions beside a lazy family, splits the vocabulary.

## An interface name as a type (decided)

An interface name in a type position means "some type that satisfies it", decided when the program is compiled.

- **In a parameter** (implemented; see [Interfaces](../language/interfaces.md#an-interface-name-as-a-parameter-type)) it's shorthand for a bounded type parameter. `source: Range<T>` means `<S: Range<T>>(source: S)`. To say two parameters have the same type, name it. The hidden parameter is never written at a call and doesn't count as one, so `toArray<Int>(xs)` gives only `T`. A lambda or a nested `def` can't have such a parameter, since neither can be generic, and the error says to name the type.
- **In a return** it's opaque: the function returns one specific type, which the compiler knows and callers can't name. `def evens(xs: [Int]): Range<Int>`.
- **On a binding** it's a view of the one type the value has (decided). After `val thing: Range<Int> = [1, 2, 3]`, `thing` is an array underneath and only what `Range<Int>` provides can be used, so `thing[0]` is an error. It's the only annotation a binding can have when the value came from an opaque return. A `mutable val` annotated this way still has one type, so it can't be given a range of another type.

What this gives:

- Signatures stay short, and a function can hide how it builds its result. This is for code that uses ranges, such as `def evens(xs: [Int]): Range<Int>`. The library's own adapters return named types; see "Adapters".
- The opaque type carries the conformance it was built with, so a chain built in one module steps correctly in another.

Proposed, not yet confirmed:

- Two opaque types are the same only when they come from the same function with the same type arguments and the same witnesses. `evens(a) == evens(b)` is fine, and `evens(a) == odds(a)` is a mismatch even when both hide the same type, or callers would depend on the implementation.
- In a result, an interface name can sit inside a tuple, an option, an array or a type argument, each occurrence with its own hidden type, as `splitAt` returning `([T], Range<T>)` needs. It can't sit inside a function type, so `flatMap` names the type: `f: (T) -> R` with `R: Range<U>`.
- A function of an interface can't return an interface type. Each conforming function would hide a different type, which is an associated type without a name.
- An opaque value can be passed to the interface's functions, looped over, compared with `==` and printed. Printing shows the real structure.

What it can't do:

- An opaque type can't be a field or an element: `type Game(deck: Range<Card>)` has no single hidden type. That needs a type parameter on `Game`, or the erased form.
- A function has one hidden type, so `if c => xs.map(f) else xs.filter(g)` is a mismatch unless erased. So is a function whose result would contain its own hidden type, such as a recursive `countdown` built from `cons`.
- The same holds for named adapters: `r = r.map(g)` in a loop is a mismatch, since a `Map` of a `Map` is a new type.

### The erased form

A range whose type is only its element type, holding a closure. It needs nothing beyond stage 1 generics:

```silver
type Seq<T>(step: () -> (T, Seq<T>)?)
```

It costs an indirect call and an allocation per step, and it's a real type that can be stored anywhere. It was first described as a later addition; fields and mixed branches need it as soon as opaque returns exist, so it belongs in the first version. Decided: it's the library type `Seq<T>`, written in plain Silver. There is no general form such as `any Range<T>` in the first version, so an interface name can't be the type of a field or an element.

## Other shapes considered for `Map`

- **Hide `T` in a closure**: `type Map<R, U>(source: R, step: (R) -> (U, R)?)`, where `map` builds the closure from `transform` and the source's `next`. Needs no bound on `Map`'s `next`. One more indirect call per element.
- **The function type as the parameter**: `type Map<R, F>`, as Rust does. No shorter when written, and Silver's function values share one type per signature, so it buys nothing.
- **A bound that introduces `T`**: `type Map<R: Range<val T>, U>`. Tidy to read, but it needs bounds on a type's parameters, a way for a bound to bring a name into scope, implied bounds for functions over the type, and the witness as part of the type's identity. With `T` as a parameter of `Map`, ranges don't need this. It returns for public types whose invariant depends on a conformance, such as `Set<T: Ord>`.

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
2. Overloading (implemented): `next` for arrays, `Countdown`, `Map` and `Filter` are all named `next`.
3. Interfaces: structural conformance, parameters that conformance determines, witnesses (implemented).
4. Interface names as types (implemented for parameters), with opaque returns and the erased form.
5. The range library.
6. Small products by value, for chains to be fast when compiled.

Not needed for ranges: capability queries (`static if R: Sized`), an explicit adapter form, interfaces where `Self` is only in the return, operators mapped to interfaces, bounds on a type's own parameters.

## What this changes in the interfaces proposal

- Open question 1 (associated types) gets an answer, since decided there: a parameter on the interface, determined by the conformance.
- Interface names become usable as types, statically. Open question 7 (interface values) becomes the erased form.
- "Stored structure" is no longer needed by ranges, only by types like `Set<T: Ord>`.
- Overloading moves from "lands with generics" to a prerequisite of interfaces.

## Risks

1. **Stateful sources are untested.** Dealing cards with an `rng`, or reading lines, doesn't fit "a range is an immutable value" neatly: the final `rng` is wanted back after the range is consumed, and stepping a range over input twice gives different answers. `unfold(state, step)` covers generating, not recovering the state. No example has been worked.
2. **Ranges are the hardest test of interfaces, not the most needed.** After stage 1 the first things missed will be printing and comparing a `T`. `Show` and `Eq` raise questions ranges don't: whether `==` means `equals`, whether derived equality is a conformance, whether a local function can change either. Interfaces should be designed against all three together. (Decided since: `==` and printing aren't interfaces and need no bound, so `Show` and `Eq` drop out. See the [interfaces proposal](interfaces.md).)
3. **A long chain of unbuilt features**, each designed on paper on top of the one before.
4. **The combination is new.** Structural conformance, lookup at the call site and bodies checked once aren't found together elsewhere. D has structural ranges but checks per instantiation and can't see a caller's functions; Nim and C++ concepts are structural with caller-side lookup but don't check bodies at the definition; Go is structural but only within the type's package; Scala passes witnesses but declares them. Known hazards: accidental matches, two modules disagreeing about a conformance, and interfaces such as `Default` that can't be expressed.
5. **Chains are slow when compiled** until products go by value.

## Open questions

- Whether `for` requires `Range` by name once interfaces exist.
- Whether the element type as an interface parameter reads well in practice.
- `a..b` over integer types other than `Int`, which needs a numeric bound.
- Strings: not ranges by default, with `.bytes` and `.chars`.
- Capabilities beyond stepping forward and indexing (which `for` now uses), such as stepping from the end. An adapter keeps its source's indexing by being a named type with a conditional `opIndex`.
- How a stateful source hands its state back.
- How a function that returns a pipeline keeps its source's capabilities without naming the adapter types; see "Adapters".

## Before deciding

Stage 1 generics are implemented, so this can start now: write `Seq<T>` and a few adapters in plain Silver and port a program from `exploration/` (cards or poker) to them. That tests the functional protocol, stateful sources and lazy chains against real code, with no new language features. Then design interfaces with `Show`, `Eq` and `Range` side by side.
