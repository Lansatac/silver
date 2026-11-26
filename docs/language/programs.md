# Programs

A program starts at `main` and reaches the world outside it through its arguments, its exit status, standard input, output and error, the environment and files.

## main

A program's entry module defines `main`. It takes no parameters or the program's arguments, and returns `Unit`, or `Unit ! E` for any `E`:

```silver
def main(): Unit
def main(args: [String]): Unit
def main(args: [String]): Unit ! IoError | UsageError
```

`main` is an ordinary function otherwise, so the parameter can have any name. A module defines one `main`, and `private def main` is an error.

## Arguments

```silver
type UsageError(message: String)

def main(args: [String]): Unit ! UsageError | IoError {
    val path = first(args) ?? fail UsageError("expected a file")
    printl(readFile(path)?)
}
```

```
silver count.ag notes.txt --lines
```

- `args` is what follows the file on the command line, in order: here `["notes.txt", "--lines"]`. A compiled program gets what follows its own name.
- The program's own name isn't among them. It would be the script's path when interpreted and the executable's when compiled.
- Nothing else reads the arguments. A function that needs them is passed them, so it can be called with any array, in a test as well.
- Silver doesn't interpret them. What's an option and what's a file is the program's to say, so an option written after the file is the program's too: `silver run prog.ag -b llvm` gives it `["-b", "llvm"]`, and runs it interpreted.
- The first `--` after the file is dropped, as it is after a package's directory or where the file would be, so `silver run tool.ag -- x`, `silver run tool -- x` and `silver run -- x` all give `["x"]`. Only that first one is: `silver run tool.ag -- -- x` gives `["--", "x"]`, and `silver run tool.ag a -- b` gives `["a", "--", "b"]`. See [The `silver` tool](../silver.md#commands).
- Every `String` is UTF-8, so an argument that isn't stops the program before `main`, as an error returned from `main` would. The message shows it, with each byte that isn't part of UTF-8 written `\xHH`:

```
error: argument 2 isn't UTF-8: caf\xE9.txt
```

A program whose `main` takes no parameters can still be given arguments, and ignores them, without a word.

## Exit status

| The program | Status |
| --- | --- |
| Returns from `main` | 0 |
| Returns an error from `main`, or can't write its output | 1 |
| [Panics](control-flow.md#panics) | 101 |
| Calls `exit(n)` | `n` |

So a script can tell a program that reported a failure from one that's broken.

An error returned from `main` is printed to standard error as `error: ` and the value:

```
error: Missing(port)
```

[`exit(status)`](../stdlib/process.md), in `std.process`, is for a program whose status means something more, as a search that found nothing.

## Standard output and error

`print` and `printl` write to standard output. `eprint` and `eprintl` take the same values and write to standard error, for what's meant for the person running the program and not for whatever reads its output:

```silver
eprintl("warning: {path} is empty")
```

All four return `Unit`. When standard output can't be written, there is nothing left for the program to do, so it ends:

- A closed pipe, as in `silver run words | head -2`, ends it with status 1 and no message. The reader has what it asked for.
- Any other failure, such as a full disk, ends it with `error: couldn't write output: ` and the system's message, and status 1.

A failure to write to standard error is ignored.

[`read()`](strings.md#input) reads a line of standard input.

## The environment

`environment(name)`, in [`std.process`](../stdlib/process.md), reads an environment variable. The environment is read where it's needed, unlike the arguments, which are a parameter of `main`: a program reads a variable rarely and by its name, where it reads its arguments as a whole.

## Open questions

- Whether an error type can choose the status its program exits with, in place of `exit`.
- A status wider than a byte on Windows, where it's 32 bits and a program may want to exit with an `HRESULT`. `exit` stays the form that means the same everywhere, and a Windows module would have its own, taking a `UInt32`.
- Arguments and environment values that aren't UTF-8, for a program that must handle any file name.
- A way to get the program's own name, for a usage message or a tool that does different things under different names.
- A pattern such as `*.txt` arrives unexpanded on Windows, where nothing expands it, and as the files it names elsewhere, where the shell does. To settle when directories are designed.
- Standard input as bytes, and reading all of it at once.
- Whether each test starts in an empty directory of its own. A `test` that writes a file today writes it into the directory `silver test` was run from, and two tests using one name see each other's file.

## Current implementation

[main](#main), [Arguments](#arguments), `eprint` and `eprintl` and [a failed write to standard output](#standard-output-and-error) are built, on both backends:

- `main` takes no parameters or one of type `[String]`, written directly or through an alias. Two parameters, a `mutable` one, or one of another type is `S0009`.
- `silver` and `silverc` give the program what follows the file, options included, with the first `--` dropped by the rule above.
- An argument that isn't UTF-8 ends the program whether `main` takes the arguments or not. On Windows the arguments are read as UTF-16, so only an unpaired surrogate does, and the message shows it as `\u{D800}`. `silverc` and a compiled program check once the program is compiled. On Windows, where such an argument can't be passed on, `silver run` checks before it calls the compiler, so there that message comes before any about the program's source.
- A word starting `--DRT-`, which a D program's runtime would take as its own option, is the program's like any other, for `silver`, `silverc` and a compiled program.
- `eprint` and `eprintl` are in `lang.io` beside `print` and `printl`, generic over what they write, and a failed write is ignored. A compiled program writes to C's standard error, which C leaves unbuffered, so it appears at once, without waiting for what standard output holds. Where the two go to one place, as a pipe both are redirected to, the order is therefore not defined: standard output, buffered, may come out after later standard error. When interpreted, standard output is flushed after each write, so the two come out in the order they were written.

[Exit status](#exit-status)'s `exit` and [The environment](#the-environment) are built, as [`std.process`](../stdlib/process.md#current-implementation) says.

A failed write to standard output ends the program as described above, on both backends:

- A compiled program ignores SIGPIPE, so a write to a closed pipe fails with EPIPE rather than the system killing it with a signal. On Windows the C library reports it as EPIPE or EINVAL, and both count as closed. Elsewhere the failure's `strerror` is the message, so its words are the system's.
- Output is buffered, so a failure can come at a later `print`, at the end of `main`, or in `exit`, which each end the program the same way. A panic's report and an error from `main` write out what's buffered too, but ignore a failure of that: they end the program with their own status and message. A `test` run compiled has its output carried to `silver test` as records, and a failure writing those is ignored; interpreted, a test's output is kept, not written.
- `silverc` ignores SIGPIPE too, and what it writes itself (a test report) to a closed pipe ends it with status 1 and no message. Ending this way skips C's exit flush, since the buffer holds what couldn't be written.

The exit statuses, and an error from `main`, are as described.
