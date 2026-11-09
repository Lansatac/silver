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

`for` takes a block, has value `()`, and drops the body's value. The iterable is either an array or a range `a..b` with integer bounds of one type, with literals adapting to the other bound.

The iterable is evaluated once, before the loop. The loop variable is immutable, fresh on each iteration, and in scope only in the body. `for _ in` works when the value isn't needed.

A range is half-open. One whose start isn't below its end is empty, and a range ending at a type's maximum doesn't overflow.

## break and continue

`break` and `continue` are statements of type `Never`, and work in `while`, `while val` and `for`. Each acts on the innermost loop whose *body* contains it, so one in a `while` condition or `for` iterable belongs to the enclosing loop. Outside a loop body, they are an error. `continue` re-evaluates a `while` condition or steps a `for`.

There are no labels.

## Panics

A panic stops the program with a message. Integer overflow, an out-of-range index, a failed conversion and recursion too deep for the stack all panic, and `panic(message: String): Never` panics explicitly:

```silver
val result = if isValid => compute() else panic("invalid state")
```

How deep a program can recurse isn't specified, and differs between the interpreter and compiled programs.
