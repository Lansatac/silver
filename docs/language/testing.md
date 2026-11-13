# Testing

The language provides only what a library can't: finding tests, reaching private code, leaving tests out of normal builds, showing an expression with its values, and surviving a panic.

## Tests

```silver
test "adding one increases the value" {
    val before = 1
    expect(increment(before) == 2)
}

test "doubling zero is zero" => expect(double(0) == 0)
```

`test` declarations appear only at the top level. A test's name is a string with no holes, and no two tests in a module share one. Its body is checked as the body of a function returning `Unit`, and nothing can call it.

## Where tests live

A test can sit inline next to the code it documents, or in a companion file. `name.test.ag` is part of the module `name.ag`: it sees its private members, has its own imports and helpers, and is loaded only when testing.

Code under test is the code that ships. There's no conditional compilation for tests.

## assert and expect

| Form | On failure | Available |
| --- | --- | --- |
| `assert(c)`, `assert(c, "message")` | panics | everywhere, never stripped |
| `expect(c)`, `expect(c, "message")` | records the failure and continues | test code only: a test's body, and the lambdas and nested `def`s in it |

Each word has one meaning wherever it appears. A later panic in a test just ends that test, and the report shows both.

Both take apart a comparison at the top of the expression and report the source text, location, and left and right values. Each operand is evaluated once and formatted as `print` would. A library can't do this, since it would receive only a `false`.

```silver
val scores = [3, 4]
assert(scores[0] == scores[1], "scores differ")
```

```
panic: main.ag(2,1): Assertion failed: scores differ
    condition: scores[0] == scores[1]
    left: 3
    right: 4
```

Without a message, the condition takes its place on the first line. A comparison is `==`, `!=`, `<`, `<=`, `>` or `>=`; any other condition, such as `a && b`, is shown without values. The message is evaluated only when the condition is false. `assert` can't be used as a function value, since it has to see the condition it's given.

Postfix `?` in a test stops the test and reports that the value was `None`, or the error it found, as in `` `parse("1x")` failed with BadDigit(1), so the test stopped ``. In a lambda or nested `def` inside a test, `?` returns from that function as it does anywhere else.

```silver
test "first element" {
    val value = lookup(key)?
    expect(value.size > 0)
}
```

`panics { ... }`, valid only in test code, tests a panic and its message.

## Running tests

`silver test <path>` runs the tests under that path, and not those of imported modules. `main` is neither required nor run, so a library tests the same way as a program. `silver build` type-checks inline tests without including them.

Each test is isolated, so a panic ends only that test. A crash that can't be caught is reported as one. `read` returns `None` in a test.

Output shows every failure of the run with its values in one pass. Passing tests are quiet, captured output appears only for failures, a summary comes last, and the exit code is meaningful. `--format json` serves tools.

```
FAIL "first element" at lookup.ag(12,6)
    lookup.ag(14,5): Expectation failed: value.size > 0
        left: 0
        right: 0
    panic: lookup.ag(15,5): Index is out of range
    Output:
        looking up a
3 passed, 1 failed
```

Each failed test lists its failures in the order they happened, so a panic, or `?` finding `None` or an error, comes last. The exit status is 0 only when every test ran and passed.

`--filter` selects tests by name. The interpreter is the default, with a flag to compile or to use both.

## Library hooks

- `silver test --runner some.library.run` hands the tests to a library runner
- A caller's location, available as a default argument
- `report(Failure(...))` records a failure from any function and continues

Matchers, fixtures, property testing, snapshots and reporters belong in libraries.

## Open questions

- `test group "name" { ... }` and a `name.test/` directory, for larger suites
- The syntax of the caller-location default argument
- The cap on failures recorded per test

## Current implementation

- `assert`, `test`, `expect` and `silver test` are available on both backends. `silver test -b llvm` compiles the tests, and `-b both` runs them both ways and fails a test the two backends disagree on.
- A directory's tests are those of every `.ag` file under it, each loaded as a program of its own.
- `panics`, companion files, `--filter`, `--format json` and the library hooks aren't available yet.
