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

## Current implementation

- Not built: there is no `std.process`, so no `exit` or `environment`.
