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

`for` takes a block, has value `()`, and drops the body's value. The iterable is a range `a..b` with integer bounds of one type, with literals adapting to the other bound, or a value of any type that's a `Range`: one with a [conformance](interfaces.md#conformance) to it. Arrays are, and so is a `String`, which steps a `Char` at a time (see [Strings](strings.md)).

The iterable is evaluated once, before the loop. The loop variable is immutable, fresh on each iteration, and in scope only in the body. `for _ in` works when the value isn't needed.

The loop variable can be a tuple pattern, which takes each element apart as `val` would: `for (name, count) in [("a", 1), ("b", 2)] { ... }`. The pattern is names, `_`, and tuples of those, and it binds only in the body. An element of the wrong shape is an error, as it would be for `val (name, count) = element`.

A range is half-open. One whose start isn't below its end is empty, and a range ending at a type's maximum doesn't overflow. `for i in a..b` and a `for` over an [`Interval`](arrays.md#ranges) held in a name give the same elements, in a generic function too: an interval is a `Range` and not an `Indexed`, so a loop over one always steps from its start while below its end, and never calls `length`.

### Looping over a value of your own

A type `R` can be looped over when it's a `Range<T>`. That takes a function `next(r: R): (T, R)?`, which returns the next element and the rest, or `None` at the end, and a declaration that says so. Each element is a `T`. When the type is an `Indexed<T>` as well, with `length(r: R): Int` and `opIndex(r: R, index: Int): T`, the function that `r[i]` calls, the loop goes by index and `next` isn't called.

```silver
interface Range<T> { def next(range: Self): (T, Self)? }
interface Sized { def length(value: Self): Int }
interface Indexed<T>: Sized { def opIndex(value: Self, index: Int): T }
```

The three are declared in `lang`, the [package the compiler knows](modules.md#the-package-the-compiler-knows).

```silver
type Countdown(from: Int)

def next(c: Countdown): (Int, Countdown)? =>
    if c.from == 0 => None else Some((c.from, Countdown(c.from - 1)))
conform Countdown: Range<Int>

type Squares(from: Int, count: Int)

def next(s: Squares): (Int, Squares)? =>
    if s.count == 0 => None else Some((s.from * s.from, Squares(s.from + 1, s.count - 1)))
def length(s: Squares): Int => s.count
def opIndex(s: Squares, index: Int): Int => (s.from + index) * (s.from + index)
conform Squares: Range<Int> & Sized & Indexed<Int>

for n in Countdown(3) {
    printl(n)    // 3, 2, 1, by stepping
}
for n in Squares(0, 3) {
    printl(n)    // 0, 1, 4, by index
}
```

A type that's an `Indexed` and not a `Range` isn't looped over: what a `for` takes is what the functions that step a range take.

By index, `for x in r { body }` calls `length(r)` once, before the loop, then `opIndex(r, i)` for each `i` from `0` up to the length, in order, even when the loop variable is `_`. By stepping, it means:

```silver
mutable val rest = r
while val step = next(rest) {
    val (x, after) = step
    rest = after
    body
}
```

`rest` is a hidden variable. It has moved on before the body runs, so `continue` goes to the next element. `next` is called once per element, and once more for the `None` that ends the loop.

The functions are the ones the type's conformances found where they were declared, so a loop means the same wherever it's written. In a generic function, over a value whose type has a `Range` bound, which way it loops is decided for each real type, as an [`if type`](interfaces.md#asking-whether-a-type-conforms) is. A type's `next` and its `opIndex` are expected to give the same elements in the same order, and nothing checks that.

An array has no loop of its own. It's a `Range` and an `Indexed` through `lang`'s conformances, so it's looped by index.

## break and continue

`break` and `continue` are statements of type `Never`, and work in `while`, `while val` and `for`. Each acts on the innermost loop whose *body* contains it, so one in a `while` condition or `for` iterable belongs to the enclosing loop. Outside a loop body, they are an error. `continue` re-evaluates a `while` condition or steps a `for`.

There are no labels.

## Panics

A panic stops the program with a message. Integer overflow, an out-of-range index, a failed conversion and recursion too deep for the stack, and running out of memory (`panic: Out of memory`) all panic, and `panic(message: String): Never` panics explicitly:

```silver
val result = if isValid => compute() else panic("invalid state")
```

A panic prints `panic: `, where it happened and the message to standard error, and the program exits with status 101:

```
panic: main.ag(12,5): invalid state
```

A panic is for a bug. A failure a correct program can meet, such as a missing file or text that isn't a number, is an option or an error: see [Errors](errors.md).

How deep a program can recurse isn't specified. It differs between the interpreter and compiled programs, and between a compiled program and the same one optimized (`-O`), where a recursion can become a loop that uses no stack at all. So a recursion too deep for one of them can finish on another, run for ever, or reach a different panic first:

```silver
def count(n: Int, total: Int): Int => if n == 0 => total else count(n - 1, total + 1)
def f(n: Int): Int => 1 +% f(n + 1)

count(100000000, 0)     // compiled: panics with Stack overflow; with -O: 100000000
f(0)                    // compiled: panics with Stack overflow; with -O: Integer overflow, from n + 1
```

Otherwise `-O` is meant to change only speed: a program that stays within the stack either way does the same thing. The one known exception is a gap in how an optimized program's memory is collected, which is a defect to be fixed, not behaviour to rely on.

## Open questions

None.

## Current implementation

- A `for` needs no conformance: it finds `next`, `length` and `opIndex` by name, as a call where the loop is written would, and goes by index when all three take the type. Inside a generic function it uses the bound's functions.
- An array and an `Interval` each have a loop of their own, which calls none of those functions. A generic function given an interval loops it by index, through its `length`.
- The error for a type with a `length` and an `opIndex` but no `next` suggests `iterate()`, which isn't built yet.
