# Ranges

A range is an immutable value that can be stepped: `next` gives its first item and the rest of the range, or `None` at the end. `for` loops over any range, and `std.range`, which the prelude forwards, has lazy adapters such as `map` and `filter` and consumers such as `array` that turn a chain back into data.

```silver
val big = [1, 2, 3].map(x => x * 2).filter(x => x > 2).array()    // [4, 6]
```

The whole design, including the parts not built yet, is in the [ranges proposal](../proposals/ranges.md).

## The protocol

```silver
interface Range<T> {
    def next(range: Self): (T, Self)?
}
```

A type is a range when a [conformance](interfaces.md#conformance) says so. Arrays, strings (by `Char`) and intervals are. A source of your own gives a `next` and declares it:

```silver
type Countdown(from: Int)

def next(c: Countdown): (Int, Countdown)? =>
    if c.from == 0 => None else (c.from, Countdown(c.from - 1))

conform Countdown: Range<Int>

for n in Countdown(3) { printl(n) }     // 3 2 1
```

- Stepping never changes a range value. A range that keeps its state in a field gives the same item when the same value is stepped again. One whose state is outside it, as a range over input is, gives a new item each time, and can be consumed once.
- `for` always steps with the `next` of the conformance. See [Control flow](control-flow.md#for).
- The item type is part of the conformance, so a type is a range of one item type.

## Adapters

An adapter holds its source and does nothing until it's stepped. Each item goes through the whole chain before the next one starts, and no array is made between the steps.

```silver
def noisy(x: Int): Int {
    print("<{x}>")
    x * 10
}

val chain = [1, 2, 3, 4, 5].map(noisy).filter(x => x > 20)    // prints nothing
chain.first()     // prints <1><2><3>, gives Some(30)
chain.array()     // prints <1> to <5> again, gives [30, 40, 50]
```

| Function | Gives |
| --- | --- |
| `map(source, transform)` | A `Mapped<R, T, U>` of `transform` applied to each item |
| `filter(source, keep)` | A `Filtered<R, T>` of the items for which `keep` is true |

- An adapter's result is its own named type, which a `val` infers. It's a range exactly when its source is, as `conform Mapped<R, T, U>: Range<U> when R: Range<T>` says.
- Consuming a chain again runs its functions again. `array()` is how a result is kept.
- A function passed to an adapter runs where the chain is consumed, so that's where it panics or has its effect.
- A chain built in one module can be stepped in any other, since its conformance is a fact about its type.

## Consumers

| Function | Gives |
| --- | --- |
| `array(range)` | Its items, as an array |
| `first(range)` | Its first item, or `None` when it's empty |
| `rest(range)` | The range after its first item, or the range itself when it's empty |
| `fold(range, initial, combine)` | `combine` applied to the result so far and each item in turn, from `initial` |
| `count(range)` | How many items it has |

```silver
[1, 2, 3, 4].fold(0, (a, b) => a + b)     // 10
"héllo".count()                           // 5
[1, 2, 3].rest()                          // [2, 3]
```

Each consumer steps its range to the end, except `first` and `rest`, which take one step.

## Open questions

These are listed in the [ranges proposal](../proposals/ranges.md#open-questions), with what printing a chain shows and collecting a chain over a `String` back into a `String`.

## Current implementation

- Not built yet, as designed in the proposal: `Sized` and `Indexed`, and `count`, `last` and `array` taking a length or indexing when the range has one; `take`, `drop`, `zip`, `enumerate`, `step`, `takeWhile`, `dropWhile`, `flatMap` and `append`; `iterate`, `unfold` and `repeat`; `any`, `all`, `find`, `last`, `contains`, `isEmpty` and `splitAt`; and the erased form `Seq<T>`. `sum`, `min`, `max`, `sorted`, `sortedBy`, `Backward` and `reversed` come after those.
- Passing a type that isn't a range to an adapter says so, but doesn't yet suggest `iterate()` for a type with a `length` and an `opIndex`.
- Assigning a chain where an array is expected is a type mismatch that doesn't yet suggest `array()`.
