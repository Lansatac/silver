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

`test` declarations appear only at the top level. Names are strings.

## Where tests live

A test can sit inline next to the code it documents, or in a companion file. `name.test.ag` is part of the module `name.ag`: it sees its private members, has its own imports and helpers, and is loaded only when testing.

Code under test is the code that ships. There's no conditional compilation for tests.

## assert and expect

| Form | On failure | Available |
| --- | --- | --- |
| `assert(c)`, `assert(c, "message")` | panics | everywhere, never stripped |
| `expect(c)`, `expect(c, "message")` | records the failure and continues | test code only |

Each word has one meaning wherever it appears. A later panic in a test just ends that test, and the report shows both.

Both take apart a comparison at the top of the expression and report the source text, location, and left and right values. Each operand is evaluated once and formatted as `print` would. A library can't do this, since it would receive only a `false`.

Postfix `?` in a test stops the test and reports that the value was `None`.

```silver
test "first element" {
    val value = lookup(key)?
    expect(value.size > 0)
}
```

`panics { ... }`, valid only in test code, tests a panic and its message.

## Running tests

`silver test <path>` runs the tests under that path, and not those of imported modules. `main` is neither required nor run, so a library tests the same way as a program. `silver build` type-checks inline tests without including them.

Each test is isolated, so a panic ends only that test. A crash that can't be caught, such as a stack overflow, is reported as one. `read` returns `None` in a test.

Output shows every failure of the run with its values in one pass. Passing tests are quiet, captured output appears only for failures, a summary comes last, and the exit code is meaningful. `--format json` serves tools.

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

None of this is available yet, including `assert` and `silver test`.
