# std.random

Pseudo-random numbers from a generator that a program holds and passes on, so that a seed gives the same numbers every time.

```silver
import std.random

mutable val rng = seeded(42)
val roll = nextInt(mutable rng, 6)! + 1      // 1 to 6
val word = next(mutable rng)                 // any UInt64

mutable val shuffler = fromClock()           // different every run
```

- An `Rng` is a value, so copying one copies its state: two copies give the same numbers. A function that draws numbers takes it as a `mutable` parameter.
- `seeded(seed: UInt64)` starts a generator at a seed, and `fromClock()` at the wall clock's nanoseconds.
- `next(mutable rng): UInt64` is the next number, all 64 bits of it.
- `nextInt(mutable rng, bound: Int): Int ! EmptyRange` is uniform in `0..bound`, each value equally likely. It's `EmptyRange` when `bound` isn't positive, and then leaves the generator where it was.
- `split(mutable rng): Rng` makes a generator of its own for a callee that only consumes randomness, advancing `rng` once.
- The generator is SplitMix64, so a seed gives the numbers SplitMix64's published output gives. It's fast and good enough for games and simulations, and not for anything secret: its numbers can be predicted from a few of them.

## Open questions

- Floats, shuffling and choosing from an array.
- A generator for secrets, from the system.

## Current implementation

- Everything above is built, in plain Silver in `stdlib/std/random.ag`.
