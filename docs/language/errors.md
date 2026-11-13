# Errors

A function that can't do its job has three ways to say so, and each has one use.

| | Means | Written | What it does |
| --- | --- | --- | --- |
| Absence | There's no value, for the one obvious reason | `T?` | A value. See [Options](options.md). |
| Error | The operation failed, and the caller may want to know why | `T ! E` | A value that carries the reason. It can't be used as a `T` or dropped without saying so. |
| Panic | The program is wrong | `panic`, `assert`, overflow, a bad index | Stops the program. See [Control flow](control-flow.md#panics). |

## Error unions

`T ! E` is an *error union*: either a `T`, or an error of type `E`.

```silver
type ParseError = Empty | BadDigit(at: Int) | TooLarge

def parseInt(text: String): Int ! ParseError
def save(config: Config): Unit ! IoError
val handler: (String) -> Int ! ParseError = parseInt
```

`E` is any type. `!` binds looser than `?` and tighter than `->`, so `String? ! IoError` is an optional string or an error, and `(String) -> Int ! ParseError` is a function that returns an error union. A type carries at most one `!`, and a nested one takes parentheses, as in `(Int ! A) ! B`. Nothing collapses.

### A list of errors

The error side can list several types, separated by `|`:

```silver
type Negative
type Overflow

def factorial(n: Int): Int ! Negative | Overflow
```

- Each name is a type that's already declared. A list never declares one, so a misspelt name is an error.
- A type can't be listed twice, and the order doesn't matter: `Int ! Negative | Overflow` and `Int ! Overflow | Negative` are the same type.
- A list is written only after `!`.

### Widening

An error fits where another error type is expected when each of its types is there. Taking a single type as a list of one, every type on the left must be

- one of the types on the right, or
- a member of a declared sum that is one of the types on the right.

```silver
type Missing(key: String)
type ConfigError = Missing | ParseError

Int ! Negative                      // fits Int ! Negative | Overflow
Int ! Negative | Overflow           // fits Int ! Negative | Overflow | Missing
Int ! ParseError                    // fits Int ! ConfigError, as a member of the sum
Int ! Empty                         // fits Int ! ParseError | Missing, as a member of ParseError
```

A declared sum is one type, so it doesn't fit a list of its own members: `Int ! ParseError` doesn't fit `Int ! Empty | BadDigit | TooLarge`.

This is what lets one function report the failures of everything it calls. It happens wherever an error union is checked against another, most often at [`?`](#passing-it-on-).

## Values

```silver
val good: Int ! ParseError = 42
val alsoGood: Int ! ParseError = Ok(42)
val bad: Int ! ParseError = Error(BadDigit(2))
```

- `T` promotes to `T ! E`, as it does to `T?`: one step, where a type is expected, with a literal adapting to `T` first.
- `Ok(x)` and `Error(e)` are reserved names, like `Some` and `None`. Each needs a type from context, so `val x = Error(Empty)` is an error.
- `Error(e)` checks `e` against the error side, so a type in a list, or a member of a sum, is accepted.
- An error is always written with `Error`. An `E` doesn't promote into `T ! E`, so every place a function fails is visible.
- An error union prints as `Ok(42)` or `Error(BadDigit(2))`, and compares structurally with `==`. When one side of `==` is an error union, the other is checked against it, so `parseInt("7") == 7` and `parseInt("x") == Error(BadDigit(0))` both work.

## Using an error union

An error union can't be used where a `T` is wanted, and can't be left unused. Every use says what happens to the error, and `_ = save(config)` says it's dropped on purpose.

### Passing it on: `?`

`x?` is the value of `x`. If `x` is an error, the enclosing function or lambda returns it. The enclosing function must return an error union that the error [fits](#widening).

```silver
def port(path: String): Int ! IoError | ParseError {
    val text = readFile(path)?          // String ! IoError
    val number = parseInt(text)?        // Int ! ParseError
    number
}
```

`?` never crosses between options and error unions, since a reason would be invented or lost. Each direction is written out with `??`:

```silver
val raw = lookup(key) ?? { return Error(Missing(key)) }     // an option, in a function returning an error union
val number = parseInt(raw) ?? { return None }               // an error union, in a function returning an option
```

A lambda's return type is inferred from its `?`s and its value, so `line => parseInt(line)? * 2` is a `(String) -> Int ! ParseError`. Two `?`s on different error types need a written return type, since a list is never invented.

### Asserting it worked: `!`

`x!` is the value of `x`. If `x` is an error, the program panics at that line, showing the expression and the error.

```silver
val port = parseInt("8080")!
```

```
panic: server.ag(12,16): `parseInt(setting)` failed: BadDigit(2)
```

It's how a caller says that a failure here would be a bug in their own code. So a function can return an error without burdening the callers who know it can't happen, and they're stopped at their own line when they're wrong.

`!` also works on an option, where it's the payload or a panic. It follows its operand on the same line.

### The option operators

These work on an error union as they do on an option, and drop the error:

- `a ?? b` is the value, or else `b`, with the result types `??` has on an option. So `parseInt(text) ?? None` is an `Int?`.
- `if val n = parseInt(text)` binds the value. `if val Error(reason) = parseInt(text)` binds the error.
- `a?.b` with `a: T ! E` is a `U ! E`, flat as with options.

`while val` doesn't take an error union, since the loop would end on an error without a word. Unwrap the error first: `while val line = read()? { ... }`.

### match

`match` takes `Ok(p)` and `Error(p)`, and is exhaustive over both sides:

```silver
match factorial(n) {
    Ok(value) => printl(value)
    Error(Negative) => printl("not defined below zero")
    Error(Overflow) => printl("too large for an Int")
}
```

A type added to a function's errors is a compile error at every `match` that has to handle it.

A pattern inside `Error(...)` can name a member of a declared sum that the list names, as widening does. With `Int ! ParseError | Missing`, `Error(Empty)` matches, and the arms cover `ParseError` once they cover each of its members, or take it whole with `Error(e: ParseError)`:

```silver
match port(path) {
    Ok(number) => listen(number)
    Error(Empty) => printl("the setting is empty")
    Error(BadDigit(at)) => printl("not a digit at {at}")
    Error(TooLarge) => printl("too large")
    Error(Missing(key)) => printl("no {key}")
}
```

### In a test

`?` in a test's body stops the test and reports the error, as it reports `None`. An error is a value, so a test checks one with `expect(parseInt("12a") == Error(BadDigit(2)))`.

## Which to use

- **An error** is for a failure the caller couldn't have ruled out first: a file that isn't there, text that isn't a number, input that's out of range.
- **An option** is for absence with one obvious reason, such as a missing key or the end of input.
- **A panic** is for a bug. The built-in operations panic: arithmetic, indexing and slicing, and conversions. They're written constantly, almost always where they can't fail, and an error from each would bury the code.

Building a value of a type with an [invariant](user-types.md#invariants) isn't one of them. It's where unchecked data is checked, so it yields an error.

A function that changes a `mutable` parameter and then returns an error has still returned, so the change is written back.

### The standard library doesn't panic

A function in the standard library that can't do its job returns an option or an error. The caller chooses, with `!`, whether a failure is a bug.

```silver
import std.math

val a = factorial(5)!                    // the caller knows
val b = factorial(count - used)?         // the caller doesn't, and passes it on
val c = factorial(count - used) ?? 1     // or chooses a value
```

The exceptions are the operations the language itself defines as panicking. An arithmetic operator inside a library function behaves as it does anywhere, and so do the functions that are those operations by another name: `at`, `opIndex`, `opIndexAssign` and `opSlice` in the prelude, and `powInt` in `std.math`, which is exponentiation without a symbol. Using a `Ref` from inside its own `update` is a misuse of the cell, and panics too. `panic` and `assert` are there to panic.

## main

`main` returns `Unit`, or `Unit ! E` for any `E`.

```silver
def main(): Unit ! IoError | ParseError {
    val number = port("app.conf")?
    listen(number)
}
```

An error returned from `main` is printed to standard error as `error: ` and the value, and the program exits with status 1. A panic exits with status 101, so a script can tell a program that reported a failure from one that's broken.

```
error: Missing(port)
```

## Open questions

- How a function names a list of errors it receives, as a helper that describes a `Negative | Overflow` would. A list is written only after `!` today, so the helper takes a declared sum.
- The exit statuses, 1 and 101, which are placeholders until program arguments and exit codes are designed.
- What `IoError` is, and `read()` returning `String? ! IoError` so that the end of input and a failure to read are told apart. Input that isn't UTF-8 is one of those failures.
- Whether other maths written for speed counts as arithmetic under the standard library's rule, as `powInt` does.
- A record of where an error was passed on by `?`, printed when it reaches `main` or a `!`.

Two proposals build on this: [checked operations](../proposals/checked-operations.md), a form of the built-in operations that yields an option where they'd panic, and [recovering from a panic](../proposals/recover.md).

## Current implementation

The implementation matches this description, except:

- `read()` returns `String?`, since `IoError` isn't designed.
- `Ok` and `Error` can't be passed as function values, as `Some` can't.
