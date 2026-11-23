# Ranges

A range is an immutable value that can be stepped: `next` gives its first item and the rest of the range, or `None` at the end. `for` loops over any range, or a collection that says which range steps it. [`std.range`](../stdlib/range.md), which the prelude forwards, has lazy adapters such as `map` and `filter`, sources such as `unfold`, and consumers such as `array` that turn a chain back into data.

```silver
val big = [1, 2, 3].map(x => x * 2).filter(x => x > 2).array()    // [4, 6]
```

What the library has, and what it's designed to have and doesn't yet, is in [`std.range`](../stdlib/range.md).

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

## Iterable

What a `for` loops over, and what [`std.range`](../stdlib/range.md)'s functions take, is an `Iterable`: something that says which range steps it.

```silver
interface Iterable<R> {
    def iterate(value: Self): R
}

conform R: Iterable<R> when R: Range<T>                 // in `lang`: every range is its own
conform Dictionary<K, V>: Iterable<Entries<K, V>>       // a collection declares the range that steps it
```

- Every range is an `Iterable` of itself, so anything that takes an `Iterable` takes a range, and `iterate(r)` on a range is `r`.
- A collection that isn't a range conforms by giving an `iterate` that returns one. Then `for x in c` loops over it, and `c.map(...)`, `c.filter(...)`, `c.count()` and the rest take it as they take a range:

  ```silver
  for (name, age) in ages { ... }
  ages.filter(((_, age)) => age >= 18).array()
  ```

- A range can't declare another `Iterable`: it has the one every range has, and a type has one conformance to an interface.
- `iterate` is called once, where the loop starts or the chain is built. What an adapter holds is the range it gave.
- The `iterate` is the one the conformance found, as a loop's `next` is, so a loop means the same wherever it's written. A function named `iterate` without the conformance doesn't make a type loop.
- A function of your own that should take a collection as well as a range asks for both, and steps what `iterate` gives:

  ```silver
  def total<C: Iterable<R>, R: Range<Int>>(items: C): Int {
      mutable val sum = 0
      for item in items { sum += item }
      sum
  }
  ```

  One that asks only for `R: Range<Int>` takes a range and not a dictionary.
- `Iterable` is declared in `lang`, beside `Range`.

## Open questions

- Whether the item type as a parameter of the interface (`Range<T>`) reads well in practice.
- Whether a single-pass source, such as a range over input, should be told apart in its type.
- Whether a range over input that fails part way has ended.
- The library's own are in [`std.range`](../stdlib/range.md#open-questions).

## Current implementation

- Everything above is built: `Range` and `Iterable` are declared in `lang`, and the conformances of arrays, strings and intervals are there too.
