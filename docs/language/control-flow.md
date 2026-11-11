# Control flow

## Blocks

A block `{ ... }` is an expression. Its value is its last expression statement, or `()` if it has none.

Where a block's value lands somewhere `Unit` is expected, any type is accepted and the value is dropped. Those places are a `Unit` function body, a `while` or `for` body, and an `if` without `else`. This reaches through nested blocks and `if` arms, which then need no common type. It doesn't apply to an ordinary expected type, so `val x: Unit = { 1 }` is an error.

## if

`=>` introduces one expression and `{}` a block, and the forms can be mixed:

```silver
val sign = if n < 0 => -1 else 1

if isReady {
    start()
} else {
    wait()
}
```

`if` is an expression. Its arms must have a common type unless the value is dropped. An `if` without `else` has value `()`.

`if val` unwraps an option. The name is immutable and is in scope only in the then-branch:

```silver
val size = if val found = lookup(key) => found.size else 0
```

`if val` also takes a constructor pattern, as a one-arm [`match`](user-types.md#match).

## while

`while` takes a block, has value `()`, and drops the body's value.

```silver
while count < limit {
    count += 1
}
```

`while val` evaluates its initializer before each iteration, and ends on `None`. The name is in scope only in the body.

```silver
while val line = read() {
    print(line)
}
```

## for

```silver
for value in values {
    printl(value)
}

for i in 0..10 {
    printl(i)
}
```

`for` takes a block, has value `()`, and drops the body's value. The iterable is an array, a range `a..b` with integer bounds of one type, with literals adapting to the other bound, or a value of another type that functions named `length` and `at`, or `next`, loop over.

The iterable is evaluated once, before the loop. The loop variable is immutable, fresh on each iteration, and in scope only in the body. `for _ in` works when the value isn't needed.

A range is half-open. One whose start isn't below its end is empty, and a range ending at a type's maximum doesn't overflow.

### Looping over a value of your own

A value of any other type `R` is looped over by index when there are functions `length(r: R): Int` and `at(r: R, index: Int): T`, and otherwise by stepping it with `next(r: R): (T, R)?`, which returns the next element and the rest, or `None` at the end. Each element is a `T`.

```silver
type Squares(count: Int)

def length(s: Squares): Int => s.count
def at(s: Squares, index: Int): Int => index * index

type Countdown(from: Int)

def next(c: Countdown): (Int, Countdown)? =>
    if c.from == 0 => None else Some((c.from, Countdown(c.from - 1)))

for n in Squares(3) {
    printl(n)    // 0, 1, 4
}
for n in Countdown(3) {
    printl(n)    // 3, 2, 1
}
```

By index, `for x in r { body }` calls `length(r)` once, before the loop, then `at(r, i)` for each `i` from `0` up to the length, in order, even when the loop variable is `_`. By stepping, it means:

```silver
mutable val rest = r
while val step = next(rest) {
    val (x, after) = step
    rest = after
    body
}
```

`rest` is a hidden variable. It has moved on before the body runs, so `continue` goes to the next element. `next` is called once per element, and once more for the `None` that ends the loop.

Each function used is the one a call at the loop would choose, as in `length(r)`, `at(r, 0)` or `next(r)`. Indexing is used when both a `length` and an `at` take an `R`, whether or not there's a `next`, and `next` only when one of them is missing. Each must take exactly `R`, not an option of it or a `mutable` one; `at`'s index must be exactly `Int`; `length` must return `Int`; and `next` must return `(T, R)?`, with the rest of the same type. No declaration says that a type can be looped over, so a module can make a type it didn't write loopable by writing these functions for it.

An array has a `length` and an `at` in the prelude, and is looped over by index, which never calls a `length` or `at` of your own.

## break and continue

`break` and `continue` are statements of type `Never`, and work in `while`, `while val` and `for`. Each acts on the innermost loop whose *body* contains it, so one in a `while` condition or `for` iterable belongs to the enclosing loop. Outside a loop body, they are an error. `continue` re-evaluates a `while` condition or steps a `for`.

There are no labels.

## Panics

A panic stops the program with a message. Integer overflow, an out-of-range index, a failed conversion and recursion too deep for the stack all panic, and `panic(message: String): Never` panics explicitly:

```silver
val result = if isValid => compute() else panic("invalid state")
```

How deep a program can recurse isn't specified, and differs between the interpreter and compiled programs.

## Open questions

- A tuple pattern as the loop variable, as in `for (i, x) in pairs`.
- Whether `for` will require a `Range` interface by name once interfaces exist. A type that works with `for` now would still satisfy it.
