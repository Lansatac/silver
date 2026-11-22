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
- Silver doesn't interpret them. What's an option and what's a file is the program's to say.
- Every `String` is UTF-8, so an argument that isn't stops the program before `main`, as an error returned from `main` would:

```
error: argument 2 isn't UTF-8
```

A program whose `main` takes no parameters can still be given arguments, and ignores them.

With no file, or with a package's directory, `silver run` takes the program's arguments after `--`: see [The `silver` tool](../silver.md#commands).

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

```silver
import std.process

val home = environment("HOME") ?? "."
```

`environment(name: String): String?` is the value of an environment variable, or `None` when it isn't set or its value isn't UTF-8.

## Files

`std.file` reads and writes a file whole:

```silver
import std.file

def readFile(path: String): String ! NotFound | NotUtf8 | ReadFailed
def readBytes(path: String): [UInt8] ! NotFound | ReadFailed
def writeFile(path: String, text: String): Unit ! WriteFailed
def writeBytes(path: String, data: [UInt8]): Unit ! WriteFailed
def appendFile(path: String, text: String): Unit ! WriteFailed
def exists(path: String): Bool
```

```silver
def main(args: [String]): Unit ! IoError {
    val text = readFile("notes.txt")?
    writeFile("notes.bak", text)?
}
```

- A path is a `String`, relative to the directory the program was started in unless it's absolute, with `/` between its parts on every system.
- `readFile` returns the file's bytes as text when they're UTF-8, and nothing is translated: a `\r\n` stays one. `readBytes` is for everything else.
- `writeFile` and `writeBytes` replace the file, creating it when it isn't there. `appendFile` adds to its end, creating it too. None creates a directory.
- `exists` is `true` for a file or a directory. It's a question about one moment, so a `readFile` after it can still be `NotFound`.

The errors are members of `lang`'s [`IoError`](errors.md#ioerror), so `?` widens each into it:

- `NotFound(path)` is a file that isn't there. It's a member of its own because it's the failure a program most often answers itself, as by using its defaults.
- `ReadFailed(reason)` and `WriteFailed(reason)` carry the system's message, such as `Permission denied` or `Is a directory`.

## Open questions

- Files that are held open: reading one a piece at a time, a file as a range of lines, and writing as the program goes. A range that holds an open file needs a way to say when it's closed, which nothing in the language does yet.
- Directories: listing, creating and removing them, and removing or renaming a file.
- A type for paths, and joining and splitting them.
- Whether an error type can choose the status its program exits with, in place of `exit`.
- A status wider than a byte on Windows, where it's 32 bits and a program may want to exit with an `HRESULT`. `exit` stays the form that means the same everywhere, and a Windows module would have its own, taking a `UInt32`.
- Arguments and environment values that aren't UTF-8, for a program that must handle any file name.
- Standard input as bytes, and reading all of it at once.
- Starting another program.

## Current implementation

[main](#main) and [Arguments](#arguments) are built, on both backends:

- `main` takes no parameters or one of type `[String]`, written directly or through an alias. Two parameters, a `mutable` one, or one of another type is `S0009`.
- `silver` and `silverc` pass what follows the file to the program untouched, options included. With no file or with a package's directory, `silver run` takes them after `--`.
- An argument that isn't UTF-8 ends the program whether `main` takes the arguments or not. On Windows the arguments are read as UTF-16, so only an unpaired surrogate does. `silverc` and a compiled program check once the program is compiled, but `silver` checks before it calls the compiler, so through `silver` that message comes before any about the program's source.

The rest of this document's additions aren't built:

- There is no `exit`, `eprint`, `eprintl` or `environment`, and no `std.process` or `std.file`. `IoError` has only `NotUtf8` and `ReadFailed`.
- `print` panics when the write fails, and when interpreted a closed pipe ends the program with the interpreter's own error.

The exit statuses, and an error from `main`, are as described.
