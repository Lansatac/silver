# Ranges

A range is an immutable value that can be stepped: `next` gives its first item and the rest of the range, or `None` at the end. `for` loops over any range, or a collection that says which range steps it, and `std.range`, which the prelude forwards, has lazy adapters such as `map` and `filter`, sources such as `iterate` and `unfold`, and consumers such as `array` that turn a chain back into data.

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

| Function | Gives | Keeps `length` and indexing |
| --- | --- | --- |
| `map(source, transform)` | A `Mapped<R, T, U>` of `transform` applied to each item | Yes |
| `take(source, n)` | A `Taken<R>` of the first `n` items, or all of them when there are fewer | Yes |
| `drop(source, n)` | A `Dropped<R>` of the items after the first `n` | Yes |
| `zip(left, right)` | A `Zipped<A, B>` of pairs, an item from each, until either ends | When both sides have them |
| `enumerate(source)` | An `Enumerated<R>` of each item with its position, as `(Int, T)`, from 0 | Yes |
| `step(source, by)` | A `Stepped<R>` of every `by`th item, starting with the first | Yes |
| `filter(source, keep)` | A `Filtered<R, T>` of the items for which `keep` is true | No |
| `takeWhile(source, keep)` | A `TakenWhile<R, T>` of the items before the first for which `keep` is false | No |
| `dropWhile(source, skip)` | A `DroppedWhile<R, T>` from the first item for which `skip` is false | No |
| `flatMap(source, transform)` | A `FlatMapped<R, T, S>` of the items of each range `transform` gives, one after another | No |
| `append(front, back)` | An `Appended<A, B>` of the items of `front`, then those of `back` | No |

```silver
val xs = [10, 20, 30, 40]

xs.map(x => x + 1)[2]                       // 31, and the function runs for that item only
xs.drop(1).take(2).array()                  // [20, 30]
for (i, x) in xs.enumerate() { ... }        // (0, 10), (1, 20), ...
xs.zip("ab").array()                        // [(10, a), (20, b)]
(0..10).step(3).array()                     // [0, 3, 6, 9]
[[1], [], [2, 3]].flatMap(x => x).array()   // [1, 2, 3]
```

- An adapter's result is its own named type, which a `val` infers. It holds the range its source's `iterate` gave, and is a range since that is, as `conform Mapped<R, T, U>: Range<U> when R: Range<T>` says, and it has a `length` and an `opIndex` when the last column says so, by conformances of the same kind.
- Indexing an adapter outside its own length panics, even where its source has an item there: `xs.take(2)[3]` and `xs.drop(1)[-1]` are both out of range.
- `take` and `drop` with a negative count take or drop nothing. `step` with a step below 1 panics.
- `drop` and `dropWhile` step past the items they skip when they're first stepped, not when they're built.
- Consuming a chain again runs its functions again. `array()` is how a result is kept.
- A function passed to an adapter runs where the chain is consumed, so that's where it panics or has its effect.
- A chain built in one module can be stepped in any other, since its conformance is a fact about its type.

## Length and indexing

Two interfaces in `std.range` say that a range can do more than step:

```silver
interface Sized {
    def length(value: Self): Int
}

interface Indexed<T>: Sized {
    def opIndex(value: Self, index: Int): T
}
```

Arrays and intervals are both. A string isn't, since its `length` counts bytes and it steps by `Char`. A type of your own that conforms to them can be passed to anything that asks for them:

```silver
type Row(cells: [Int])
def length(r: Row): Int => length(r.cells)
def opIndex(r: Row, i: Int): Int => r.cells[i]
conform Row: Sized & Indexed<Int>
```

A consumer that can do better with a length or with indexing asks with [`if type`](interfaces.md#asking-whether-a-type-conforms), so `count` doesn't step a sized range. The real type decides, so that holds inside a generic function too:

```silver
def busy<R: Range<Int>>(r: R): Int => r.map(x => x * 2).count()

busy([1, 2, 3])         // 3, from the array's length, and the lambda doesn't run
busy(Countdown(5))      // 5, by stepping
```

## Iterable

What a `for` loops over, and what the functions here take, is an `Iterable`: something that says which range steps it.

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

## Sources

| Function | Gives |
| --- | --- |
| `a..b` | An `Interval`, which is sized and indexed |
| `byIndex(value)` | A `ByIndex<R>` over a value with a `length` and an `opIndex`, which is sized and indexed too |
| `unfold(state, produce)` | An `Unfolded<S, T>` of the items `produce` gives from each state, until it gives `None` |
| `repeat(value)` | A `Repeated<T>` of `value`, again and again |

```silver
Row([7, 8, 9]).byIndex().map(x => x + 1).array()                // [8, 9, 10]
unfold(1, n => if n > 100 => None else (n, n * 2)).array()     // [1, 2, 4, 8, 16, 32, 64]
repeat("a").take(3).array()                                     // [a, a, a]
```

- `byIndex` is how a type that's `Indexed` but isn't a `Range` is looped over or passed to an adapter: `for cell in row.byIndex()`. To have `for cell in row` and `row.map(...)` work on it directly, the type says so:

  ```silver
  def iterate(row: Row): ByIndex<Row> => byIndex(row)
  conform Row: Iterable<ByIndex<Row>>
  ```
- `repeat`, and an `unfold` whose `produce` never gives `None`, never end. `array()` or `count()` on one never finishes, and nothing in its type says so, so it's used with something that stops, such as `take` or `takeWhile`.

## The erased form

`Seq<T>` is a range whose type says only what its items are, and `seq()` makes one from any range:

```silver
val picked = if wantEven => xs.filter(isEven).seq() else xs.map(double).seq()

type Game(deck: Seq<Card>)

mutable val built = Countdown(0).seq()
for i in 1..4 { built = built.append([i]).seq() }
```

It's for where one type has to stand for many: two branches that build different chains, a field, an element of an array, a chain built up in a loop, and a recursive function whose result would otherwise contain its own type. It also hides how a range is built. It steps by calling a closure, which costs a call and an allocation for each item, and it has no `length` or indexing. Each `seq()` over a `Seq` adds a layer that every later step goes through, so a chain built up by a loop of `n` rounds costs `n` calls for each item.

## Consumers

| Function | Gives |
| --- | --- |
| `array(range)` | Its items, as an array |
| `first(range)` | Its first item, or `None` when it's empty |
| `last(range)` | Its last item, or `None` when it's empty |
| `rest(range)` | The range after its first item, or the range itself when it's empty |
| `fold(range, initial, combine)` | `combine` applied to the result so far and each item in turn, from `initial` |
| `count(range)` | How many items it has |
| `isEmpty(range)` | Whether it has no items |
| `any(range, test)` | Whether `test` is true for some item |
| `all(range, test)` | Whether `test` is true for every item |
| `find(range, test)` | The first item for which `test` is true, or `None` |
| `contains(range, value)` | Whether some item is `==` to `value` |
| `splitAt(range, n)` | Its first `n` items as an array, and the range after them |

```silver
[1, 2, 3, 4].fold(0, (a, b) => a + b)     // 10
"héllo".count()                           // 5
[1, 2, 3].rest()                          // [2, 3]
[1, 2, 3].find(x => x > 1)                // Some(2)
Countdown(5).splitAt(2)                   // ([5, 4], Countdown(3))
```

- `count` and `isEmpty` take a `Sized` range's length, and `last` indexes an `Indexed` one. Any other range is stepped.
- `first`, `rest`, `isEmpty`, `any`, `all`, `find`, `contains` and `splitAt` stop as soon as they know the answer. The others step to the end.
- `splitAt` gives back the range after the items it took, so a range that keeps its state, such as a deck, can be consumed in parts.

## Ordering

Over a range of an [`Ord`](interfaces.md) type:

| Function | Gives |
| --- | --- |
| `min(range)` | Its smallest item, or `None` when it's empty |
| `max(range)` | Its largest item, or `None` when it's empty |
| `sorted(range)` | Its items in order, as an array |
| `sortedBy(range, key)` | Its items in the order of what `key` gives for each, as an array; the key is the `Ord` one |

```silver
type Person(name: String, age: Int)
val people = [Person("Ann", 30), Person("Bob", 25), Person("Cy", 30)]

[5, 3, 9].min()                                     // Some(3)
[5, 3, 9].sorted()                                  // [3, 5, 9]
people.sortedBy(p => p.age)                         // Bob, Ann, Cy
people.sortedBy(p => (Descending(p.age), p.name))   // Ann, Cy, Bob
[5, 3, 9].sortedBy(x => Descending(x))              // [9, 5, 3]
```

- The sort is stable: items that compare equal, or whose keys do, keep the order they had. `min` and `max` give the first of several equal items.
- `sortedBy` calls `key` once for each item, not at each comparison.
- `Descending<T>` holds a value and orders the other way round. It's an `Ord` when `T` is, so it can be a whole key or part of a tuple key.
- Sorting needs every item first, so it gives an array, as `array()` does.

## What the prelude brings

The prelude forwards `std.range`'s functions and the types a program writes: `Sized`, `Indexed`, `Seq`, `Descending` and `ByIndex`. The adapter types such as `Mapped` and `Taken` are inferred, so they come only with `import std.range`, and a module of your own is free to use those names. A library that declares its own `Seq` or `Sized` is ambiguous beside the prelude's, as between any two imports that bring every name, and [listing the name or qualifying it](modules.md#which-declaration-a-name-means) settles it.

## Open questions

These are listed in the [ranges proposal](../proposals/ranges.md#open-questions), with what printing a chain shows and collecting a chain over a `String` back into a `String`.

## Current implementation

- Everything above is built, in plain Silver in `stdlib/std/range.ag`, with `Iterable` in `lang`.
- A type that's `Indexed` isn't an `Iterable` for that: it declares one, as above, or is stepped with `byIndex`.
- `array` steps every range. Sizing its result first needs a way to make an array with room for a known number of items, which there isn't yet.
- Not built yet, as designed in the proposal: `sum`, `Backward` and `reversed`. `sorted` and `sortedBy` are a merge sort written in Silver.
- An adapter's type can be built with its constructor by a module that imports it, which skips what `take` and `step` check: `Stepped(xs, 0)` divides by zero when asked for its length.
- A panic in an adapter, such as indexing a `Taken` past its length, is reported at the line in `std.range` that panics, not at the caller's index.
- Passing a type that isn't a range to an adapter says so, but doesn't yet suggest `byIndex()` for a type with a `length` and an `opIndex`. `byIndex()` on a type that isn't `Indexed` reports the missing `Sized` as well.
- Assigning a chain where an array is expected is a type mismatch that doesn't yet suggest `array()`.
