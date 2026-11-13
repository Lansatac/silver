# Proposal: checked operations with `try`

**Status: proposed.** Nothing here is implemented or decided beyond the direction. It builds on [errors](../language/errors.md).

## Summary

The built-in operations panic when they can't produce a value: arithmetic on overflow, indexing out of range, a conversion that doesn't fit, a construction that breaks its invariant. `try` gives the same operations a form that yields an option:

```silver
val item = try xs[i] ?? fallback
val total = try price * count + shipping      // Int?
val small = try Int8(reading)                 // Int8?
val volume = try Percent(number)              // Percent?
val part = try xs[from..to]                   // [T]?
```

## Motivation

The same operation is a bug at one call and bad input at another. `xs[i]` with `i` from a loop over `xs` can only fail through a mistake, and `xs[i]` with `i` typed by a user fails because users type things. Only the caller knows which, and today the caller has no choice: the operation panics.

- A panic can't be recovered from, so a program has to repeat the check by hand before the operation, and get it exactly right.
- A library that wants to report overflow as an [error](../language/errors.md) has to derive the bound itself. `factorial` returning `Int ! Negative | Overflow` needs to know that 20 is the last argument that fits.
- A type with an invariant needs a second, hand-written function for a construction that can fail, as [user types](../language/user-types.md) shows with `percent(value): Percent?`.

## The design

`try e` evaluates `e`. If an operation written in `e` would have panicked, the result is `None`. Otherwise it's `Some` of the value.

The operations covered:

- `+`, `-`, `*`, `/`, `%`, negation and shifts on integers
- indexing and slicing an array
- a numeric conversion
- constructing a value of a type that has an invariant, and `with` on one

Rules:

- **It covers what's written, not what's called.** `try xs[f(i)]` checks the index, and a panic inside `f` is still a panic. `x[i]` on a type of your own calls `opIndex`, which is a function, so it isn't covered.
- **A `try` with nothing to check is an error.** `try factorial(n)` doesn't compile, and the message says what `try` covers.
- **The result is an option, not an error union.** Each operation has one reason to fail, and the expression already shows what it is. A caller that wants a reason supplies it: `try Percent(n) ?? { return Error(OutOfRange("volume", n)) }`.
- **Precedence.** `try` binds tighter than `??` and looser than the arithmetic and bit operators, so `try a * b + c ?? 0` is `(try a * b + c) ?? 0`. A block is an expression, so `try { ... }` covers several statements.

With it, a library reports overflow without knowing the bound:

```silver
def factorial(n: Int): Int ! Negative | Overflow {
    if n < 0 { return Error(Negative) }
    mutable val result = 1
    for i in 2..n + 1 {
        result = try result * i ?? { return Error(Overflow) }
    }
    result
}
```

## What it answers

- The open question in [user types](../language/user-types.md): a built-in checked construction is `try Percent(n)`, with no second constructor per type.
- A form of indexing that returns an option is `try xs[i]`.

## Alternatives considered

- **A named twin for each operation**: `get(xs, i)`, `checkedAdd`, `toInt8`, a `percent` per type. Each is unsurprising alone. Together they're a second name for everything, and arithmetic needs a numeric bound or an overload per integer type.
- **The operation changing meaning with its surroundings**, so that `xs[i] ?? 0` handles a bad index and a bare `xs[i]` panics. It needs no keyword. It was rejected because the same expression then means different things in different places, and moving it into a helper function changes what it does.
- **`try` returning an error union** with a prelude sum saying which operation failed. The reason is already on the page where `try` is written, and every error list would need that sum.
- **`try` reaching into the functions it calls.** That is [recovering from a panic](recover.md), and belongs at a boundary, not around an expression.

## Open questions

- Whether `try` is the right word. In most languages it means something dynamic, and `try xs[f(i)]` looks as though it protects `f`.
- Whether assigning a field of a value with an invariant gets a checked form. It's a statement, so it has no value to make optional; `with` builds the new value instead.
- Whether `try` on a constant expression is evaluated at compile time, which waits on compile-time evaluation.
