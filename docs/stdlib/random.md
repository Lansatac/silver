# std.random

Pseudo-random numbers from a generator that a program holds and passes on, so that a seed gives the same numbers every time. Every generator satisfies one interface, `Rng`, and everything that draws numbers is written against it, so a program can choose a generator or bring its own.

```silver
import std.random

mutable val rng = seeded(42)
val roll = nextInt(mutable rng, 6)! + 1         // 1 to 6
val deck = shuffle(cards, mutable rng)
val word = next(mutable rng)                    // any UInt64

mutable val pinned = SplitMix64.seeded(42)      // a generator chosen by name
mutable val shuffler = fromClock()              // different every run
```

## Generators

```silver
interface Rng {
    def next(mutable rng: Self): UInt64
}

interface Seedable {
    def Self.seeded(seed: UInt64): Self
}
```

- `next` is the next number, all 64 bits of it. A generator is a type with a `next` and a `conform` line, and that's all the rest of the module needs.
- A generator is a value, so copying one copies its state: two copies give the same numbers. A function that draws numbers takes it as a `mutable` parameter, usually written with the interface as its type, as in `def deal(deck: [Card], mutable rng: Rng)`, which takes any generator.
- `Seedable` is for a generator that can start from a seed. It's what [`split`](#drawing) needs.
- `SplitMix64` and `Xoshiro256` are both, and a seed gives the numbers their published reference code gives:
  - `SplitMix64` is the smallest and fastest, with 64 bits of state.
  - `Xoshiro256` is xoshiro256++, with 256 bits of state, started from four numbers of a `SplitMix64` with the same seed, as its authors recommend.
- `seeded(seed: UInt64)` starts the default generator at a seed, and `fromClock()` at the wall clock's nanoseconds. The default is `Xoshiro256` today. Which algorithm it is may change in a later version, so a program that needs the same numbers from a seed forever names its generator, as in `Xoshiro256.seeded(seed)`.
- None of them is for anything secret: their numbers can be predicted from a few of them.

A generator of your own, here one that replays numbers for a test:

```silver
type Replay(numbers: [UInt64], at: Int)

def next(mutable rng: Replay): UInt64 {
    val n = rng.numbers[rng.at % length(rng.numbers)]
    rng.at += 1
    n
}
conform Replay: Rng

mutable val fixed = Replay([0, 5, 3], 0)
val order = shuffle(cards, mutable fixed)
```

## Drawing

Each of these takes any `Rng`:

- `nextInt(mutable rng: Rng, bound: Int): Int ! EmptyRange` is uniform in `0..bound`, each value equally likely. It's `EmptyRange` when `bound` isn't positive, and then leaves the generator where it was.
- `nextFloat(mutable rng: Rng): Float` is uniform in `[0, 1)`, from the top 53 bits of one number, so it's a multiple of 2^-53.
- `shuffle<T>(items: [T], mutable rng: Rng): [T]` is the items in a random order, each order equally likely.
- `choose<T>(items: [T], mutable rng: Rng): T?` is one of the items, each equally likely, or `None` for no items, which leaves the generator where it was.
- `split<R: Rng & Seedable>(mutable rng: R): R` makes a generator of the same kind for a callee that only consumes randomness, seeded from one number of `rng`.

## Open questions

- A generator for secrets, from the system.
- A range of draws, such as `draws(rng)`, now that a generator's `next` and a range's can share a name.
- Drawing from an interval, as `nextInt(mutable rng, 1..7)`.
- Splitting by a generator's own jump function where it has one.

## Current implementation

- Only the old module is built, in plain Silver in `stdlib/std/random.ag`: one generator type, `Rng`, which is SplitMix64, with `seeded`, `fromClock`, `next`, `nextInt` and `split` taking it directly. There's no interface, no `Xoshiro256`, and no `nextFloat`, `shuffle` or `choose`.
