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
while val line = read()! {
    printl(line)
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

A range is half-open. One whose start isn't below its end is empty, and a range ending at a type's maximum doesn't overflow. `for i in a..b` and a `for` over an [`Interval`](arrays.md#ranges) held in a name give the same elements, in a generic function too: a loop over either steps from its start while below its end, and never calls `length`.

### Looping over a value of your own

A type `R` can be looped over when it's a `Range<T>`. That takes a function `next(r: R): (T, R)?`, which returns the next element and the rest, or `None` at the end, and a declaration that says so. Each element is a `T`.

```silver
interface Range<T> { def next(range: Self): (T, Self)? }
```

`Range` is declared in `lang`, the [package the compiler knows](modules.md#the-package-the-compiler-knows).

```silver
type Countdown(from: Int)

def next(c: Countdown): (Int, Countdown)? =>
    if c.from == 0 => None else Some((c.from, Countdown(c.from - 1)))
conform Countdown: Range<Int>

for n in Countdown(3) {
    printl(n)    // 3, 2, 1
}
```

A type with a `length` and an `opIndex` and no `next` isn't looped over: what a `for` takes is what the functions that step a range take.

`for x in r { body }` means:

```silver
mutable val rest = r
while val step = next(rest) {
    val (x, after) = step
    rest = after
    body
}
```

`rest` is a hidden variable. It has moved on before the body runs, so `continue` goes to the next element. `next` is called once per element, and once more for the `None` that ends the loop.

The `next` is the one the type's conformance found where it was declared, so a loop means the same wherever it's written, in a generic function too. A loop never calls `length` or `opIndex`, whatever else the type conforms to. A function that's faster by index asks whether its type is indexed with an [`if type`](interfaces.md#asking-whether-a-type-conforms) and loops with a `while`.

A loop over an array or an interval gives the elements that stepping it gives. It may run without calling `next`, which a program can't observe.

## break and continue

`break` and `continue` work in `while`, `while val` and `for`. Each acts on the innermost loop whose *body* contains it, so one in a `while` condition or `for` iterable belongs to the enclosing loop. Outside a loop body, they are an error. `continue` re-evaluates a `while` condition or steps a `for`.

There are no labels.

## Jumps are expressions

`return`, `break` and `continue` are expressions of type [`Never`](types.md#never), so a jump can stand wherever a value is expected, without a block around it:

```silver
for line in lines {
    val n = parseInt(line) ?? continue
    val kept = if n < 0 => break else n
    total += kept
}

val (first, rest) = items.next() ?? return []
```

`return` takes a value when the next token can begin an expression, and the value takes the rest of the expression, so a jump binds more loosely than any operator:

```silver
return a ?? b               // returns a ?? b
x ?? return y ?? z          // x ?? (return (y ?? z))
f(x ?? return, y)           // in a Unit function: returns ()
if c => return a else b     // `else` ends the value
```

A jump can appear anywhere an expression can, even where it's pointless, as in `f(return 1)`, which returns before `f` is called.

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

- An array and an `Interval` each have a loop of their own, which does what their `next` would. A generic function given one for a type parameter steps it through `next`.
