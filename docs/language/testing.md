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

A test can sit inline next to the code it documents, or in a companion file. The companion of `name.ag` is the file `name.test.ag` beside it; a directory of that name isn't one. It is a module of its own that has the privileges of `name.ag`, and it's loaded only when testing.

Code under test is the code that ships. There's no conditional compilation for tests. So the module's own code means the same thing whether it's tested or built, and nothing the companion adds can change that.

- The companion sees the module's declarations as the module does, private ones included, unqualified or qualified.
- A declaration in the companion with the name of one of the module's is a duplicate, as is a test with the name of one of the module's tests. This covers functions too, whatever their parameters, so a test calling one of the module's functions calls what the module's code would.
- The companion has its own imports and helpers, and doesn't see the module's imports.
- Neither the module's code nor its importers see what the companion declares or imports. No import can name a companion, and `silver build` and running a program never read it.
- A conformance is seen by every module, so neither the companion nor a module that's in the program only because the companion imports it can declare one.

```silver
// shape.ag
private def double(x: Int): Int => x * 2
def area(side: Int): Int => side * side

// shape.test.ag
import geometry.fixtures             // the companion's own import: shape.ag doesn't see it

def square(): Int => fixtureSide()   // a helper only the companion sees
def area(side: Float): Float => side * side   // error: `area` is shape.ag's

test "double is private, and still reachable here" => expect(double(square()) == 8)
```

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

## panics

`panics(work)` runs `work`, a function taking nothing, and gives a `String?`: the message of the panic that ended it, or `None` if it returned. Whatever `work` returns is dropped. Like `expect`, it's available only in test code.

```silver
test "powInt panics as arithmetic does" {
    expect(panics(() => powInt(2, 63)) == "Integer overflow")
    expect(panics(() => powInt(2, 10)) == None)
}
```

The message is the panic's own, without `panic: ` or where it happened, so a test doesn't depend on a line number. A failed `assert` gives every line it would print: `Assertion failed: ...`, then the condition and values.

It's an ordinary value, so `expect` reports a wrong or missing panic as it reports anything else:

```
powers.ag(2,5): Expectation failed: panics(() => powInt(2, 3)) == "Integer overflow"
    left: None
    right: Some(Integer overflow)
```

- Every panic is caught, including recursion too deep for the stack. A crash is still a crash.
- The test carries on afterwards, and a later panic outside `panics` ends it as usual.
- A `panics` inside `work` catches only its own panic.
- `work` is a lambda like any other: it can't capture a `mutable val`, `?` in it returns from it, and `expect` in it records a failure.
- A `Ref` that was in the middle of an `update` when the panic happened stays that way, so using it afterwards panics with `Ref is being updated`.

## Running tests

`silver test <path>` runs the tests under that path, and not those of imported modules. `main` is neither required nor run, so a library tests the same way as a program. `silver build` type-checks inline tests without including them.

Each test is isolated, so a panic ends only that test. A crash that can't be caught is reported as one. `read()` returns `Ok(None)` in a test.

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

The interpreter is the default: `-b llvm` compiles the tests, and `-b both` runs them both ways and fails a test the two backends disagree on.

### Choosing tests

`--filter text` runs only the tests whose name contains `text`, matched case-sensitively. Given more than once, it runs the tests that match any of them:

```
silver test --filter "area of" shapes/              # "area of one", "area of two", not "Area of three"
silver test --filter one --filter companion shape.ag
```

- It matches the test's name alone, not its file. With a directory, it applies to every file under it, and with a file, to that file's tests and its companion's together.
- Every file is still loaded and checked, so a file with errors is reported whether or not any of its tests would have been chosen. A file none of whose tests is chosen isn't compiled.
- The summary counts the tests left out: `1 passed, 1 failed, 2 filtered out`.
- A filter that chooses no test at all is a failure, `No tests match the filter` with exit status 1, so a misspelt name can't pass unnoticed.
- An empty filter is a mistake rather than a way to choose every test.

### Reporting for tools

`--format json` writes one JSON document to standard output and nothing else, for editors and CI. `--format text` is the default. The exit status is the same either way. A mistake on the command line is still reported on standard error, with nothing on standard output.

```
{
  "version": 1,
  "backend": "interpreter",
  "files": [
    { "file": "lookup.ag", "problem": null, "diagnostics": [] }
  ],
  "tests": [
    {
      "name": "first element",
      "file": "lookup.ag",
      "line": 12,
      "column": 6,
      "status": "panicked",
      "failures": [
        {
          "kind": "expectation",
          "file": "lookup.ag",
          "line": 14,
          "column": 5,
          "text": "Expectation failed: value.size > 0\n    left: 0\n    right: 0",
          "message": null,
          "source": "value.size > 0",
          "left": "0",
          "right": "0"
        },
        {
          "kind": "panic",
          "file": "lookup.ag",
          "line": 15,
          "column": 5,
          "text": "Index is out of range",
          "message": null,
          "source": null,
          "left": null,
          "right": null
        }
      ],
      "output": "looking up a\n"
    }
  ],
  "summary": {
    "tests": 4, "passed": 3, "failed": 0, "panicked": 1,
    "filteredOut": 0, "filesNotRun": 0, "succeeded": false
  }
}
```

(Written here with some objects on one line; the real document puts each member on a line of its own.)

- `version` is 1. It changes when the shape changes in a way a tool would have to know about; a new member can be added without changing it.
- `backend` is `interpreter`, `llvm` or `both`.
- `files` has every file the run looked at. `problem` says why its tests didn't run, or is null, and `diagnostics` holds what loading and checking it reported, as text.
- `tests` has every test that ran, passing ones included, in the order they ran. `status` is `passed`, `failed`, or `panicked` when a panic or a crash ended the test. `output` is what it printed, even when it passed.
- Each failure has the same members, null where they don't apply. `kind` is `expectation`, `stopped` (`?` found `None` or an error), `panic`, `crash` or `disagreement`. `file`, `line` and `column` say where it happened; a panic in the runtime itself has none. `text` is what the text report shows after the location. `message` is the message given to `expect` or `assert`, `source` the condition as written (for `stopped`, the operand of `?`), and `left` and `right` the two sides of a failed comparison, formatted as `print` would show them. A failed `assert` is a `panic` with `source`, `left` and `right` filled in.
- With `-b both`, a test the backends agree on is reported once, as either would report it. A test they disagree on is `failed` with a single failure of kind `disagreement`, which has `interpreter` and `llvm` members, each holding that backend's `status`, `failures` and `output`; the test's own `output` is then null.
- `summary` counts the tests by status, the tests no filter chose, and the files whose tests didn't run. `succeeded` is true exactly when the exit status is 0.

## Library hooks

- `silver test --runner some.library.run` hands the tests to a library runner
- A caller's location, available as a default argument
- `report(Failure(...))` records a failure from any function and continues

Matchers, fixtures, property testing, snapshots and reporters belong in libraries.

## Open questions

- `test group "name" { ... }` and a `name.test/` directory, for larger suites
- Which conformances the companion, and the modules only it imports, may declare. One for a type declared there, as a fake `Range` would need, can't change what the module's code means, but every module sees a conformance, so one for any other type could.
- Whether a companion of a module of `lang` may import outside `lang`, as to use `std.random` in its tests
- The syntax of the caller-location default argument
- The cap on failures recorded per test

## Current implementation

- `assert`, `test`, `expect` and `silver test` are available on both backends. `silver test -b llvm` compiles the tests, and `-b both` runs them both ways and fails a test the two backends disagree on. `-O` with either optimizes the compiled tests.
- A directory's tests are those of every `.ag` file under it, each loaded as a program of its own. `silver test` takes the [package options](modules.md#current-implementation) `silver` does: a file with a `module` line is loaded as a module of its package, and one without uses what `--uses a,b` lists besides `std`, the prelude's package, which every file uses.
- `panics` is available on both backends. Its work can't be a function that returns `Never`, such as `() => panic("x")`, because a type parameter doesn't take `Never` yet; `(): Unit => panic("x")` works.
- Companion files are available on both backends. `silver test` loads only the companion of the file it runs, beside it, and its tests run after the file's own. A directory's companions run with their modules, and naming a companion runs its module.
- A companion can't have a `module` line, a `native library` (it has its module's), a `forward import`, a `def main` or a `conform` declaration (`L0007`), and a module in the program only because a companion imports it can't declare a conformance (`L0008`). A companion's function named like one of its module's is `S0033`. Running or building a companion, or testing one with no module beside it, is `L0006`, and a companion that can't be read as text is `L0009`.
- A companion of a module of `lang` is in `lang` too: it imports nothing outside `lang` (`L0005`) and doesn't see the prelude.
- `--filter` and `--format json` are available on every backend, `-b both` included.
- The JSON report's `message`, `source`, `left` and `right` are read back from the text of the failure, so a formatted value containing a line that starts with four spaces and `right: ` or `left: ` can be split in the wrong place. `text` is always exact.
- The library hooks aren't available yet.
