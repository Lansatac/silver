# std.process

Ending the program with a status of its own, and reading the environment. What a status means, and the statuses Silver gives itself, are in [Programs](../language/programs.md#exit-status).

## exit

`exit` is for a program whose status means something more, as a search that found nothing:

```silver
import std.process

def main(args: [String]): Unit ! IoError {
    val found = search(args)?
    if isEmpty(found) { exit(1) }
    for line in found { printl(line) }
}
```

- `exit(status: UInt8): Never` ends the program at once with that status, after writing out what it has printed. A status is 0 to 255 everywhere Silver runs, which is why it's a `UInt8`.
- It prints nothing itself. A program that wants a message writes one first.
- In a test, `exit` fails the test and the run goes on.

## environment

```silver
import std.process

val home = environment("HOME") ?? "."
```

`environment(name: String): String?` is the value of an environment variable, or `None` when it isn't set or its value isn't UTF-8.

## Open questions

- Starting another program.
- Testing a function that calls `exit`. A test that reaches `exit` fails, even for `exit(0)`, so a function that exits on `--help` can't be tested, and `panics` doesn't catch it, since an exit isn't a panic. Whether `panics` should catch it, or there should be a separate `exits(work): UInt8?` beside it that hands back the status, is open.

## Current implementation

- Everything above is built, on both backends. `exit` is an intrinsic: the compiled program's runtime writes out what it has printed (C's `stdout`) and calls C's `exit`, and the interpreter ends with the status after flushing its own output. In a test, on either backend, it fails the test with `file(line,column): exit(3) called in a test`, ends that test and the run goes on, also when the call is inside a `panics`, which doesn't catch it.
- `environment` reads the system's environment each time it's called. On Windows it asks for the name as UTF-16, so a name that isn't ASCII works, a name's case doesn't matter (`path` finds `Path`), and a value with an unpaired surrogate is `None`, as a value that isn't UTF-8 is elsewhere. Elsewhere a name's case matters. An empty name, and one with a `=` or a NUL, is `None` on every system. A variable set to the empty string is `Some("")`, not `None`.
