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

The environment is read where it's needed, unlike the arguments, which are a parameter of `main`: a program reads a variable rarely and by its name, where it reads its arguments as a whole.

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
- A path ending in a separator names a directory, so it's never a file: `readFile("notes.txt/")` is `ReadFailed`, and `writeFile("new/", text)` is `WriteFailed` rather than creating a file `new`. `exists("logs/")` is `true` only when `logs` is a directory.
- Nothing else about a path is Silver's: the system decides the rest. On Windows `\` separates parts too, so a path ending in one is refused there as well, a name's case doesn't matter, and `NUL` is a device. Elsewhere `\` is an ordinary character in a name, at the end as anywhere, and `NUL` an ordinary name.
- `readFile` returns the file's bytes as text when they're UTF-8, and nothing is translated: a `\r\n` stays one, and a byte-order mark at the start stays a `\u{feff}`. `readBytes` is for everything else.
- `writeFile` and `writeBytes` replace the file, creating it when it isn't there. `appendFile` adds to its end, creating it too, and two programs appending to one file don't overwrite each other. None creates a directory.
- A write isn't all or nothing: one that fails part way, as on a full disk, can leave part of the file.
- A file too large to hold in memory ends the program as running out of memory does anywhere, with a panic.
- `exists` is `true` for a file or a directory. It's a question about one moment, so a `readFile` after it can still be `NotFound`.

The errors are members of `lang`'s [`IoError`](errors.md#ioerror), so `?` widens each into it. Each names the path as the program gave it:

- `NotFound(path)` is a file that isn't there. It's a member of its own because it's the failure a program most often answers itself, as by using its defaults.
- `ReadFailed(path, reason)` and `WriteFailed(path, reason)` are every other failure, with the system's words for it, in the system's language. A reason is for showing to a person, not for comparing: it differs between systems, so a program that needs to tell two failures apart needs a member of `IoError` for it.

```silver
def main(): Unit ! IoError {
    writeFile("out/report.txt", readFile("in.txt")?)?
}
```

With `in.txt` there and no directory `out`, on Linux:

```
error: WriteFailed(out/report.txt, No such file or directory)
```

On Windows the reason reads `The system cannot find the path specified.` instead.

## Open questions

- Files that are held open: reading one a piece at a time, a file as a range of lines, and writing as the program goes. A range that holds an open file needs a way to say when it's closed, which nothing in the language does yet.
- Directories: listing, creating and removing them, and removing or renaming a file.
- A type for paths, and joining and splitting them.
- Whether an error type can choose the status its program exits with, in place of `exit`.
- A status wider than a byte on Windows, where it's 32 bits and a program may want to exit with an `HRESULT`. `exit` stays the form that means the same everywhere, and a Windows module would have its own, taking a `UInt32`.
- Arguments and environment values that aren't UTF-8, for a program that must handle any file name.
- A way to get the program's own name, for a usage message or a tool that does different things under different names.
- A pattern such as `*.txt` arrives unexpanded on Windows, where nothing expands it, and as the files it names elsewhere, where the shell does. To settle when directories are designed.
- Standard input as bytes, and reading all of it at once.
- Starting another program.
- An error whose fields are both Strings prints them side by side without quotes, so `WriteFailed(notes, final.txt, Access is denied.)` doesn't show where the path ends. Whether Strings inside a printed value, or only in the `error:` line, should be quoted.
- Whether each test starts in an empty directory of its own. A `test` that writes a file today writes it into the directory `silver test` was run from, and two tests using one name see each other's file.
- `exists` doesn't say whether it found a file or a directory, and is `false` for a directory it isn't allowed to look in. Functions that ask which, such as `isFile` and `isDirectory`, belong with the directory functions, rather than a second meaning for `exists`.

## Current implementation

[main](#main), [Arguments](#arguments) and [Files](#files) are built, on both backends:

- `main` takes no parameters or one of type `[String]`, written directly or through an alias. Two parameters, a `mutable` one, or one of another type is `S0009`.
- `silver` and `silverc` give the program what follows the file, options included, with the first `--` dropped by the rule above.
- An argument that isn't UTF-8 ends the program whether `main` takes the arguments or not. On Windows the arguments are read as UTF-16, so only an unpaired surrogate does, and the message shows it as `\u{D800}`. `silverc` and a compiled program check once the program is compiled. On Windows, where such an argument can't be passed on, `silver run` checks before it calls the compiler, so there that message comes before any about the program's source.
- A word starting `--DRT-`, which a D program's runtime would take as its own option, is the program's like any other, for `silver`, `silverc` and a compiled program.
- `std.file` is as described. On Windows a path is opened through the system's UTF-16 functions, so a name that isn't ASCII works, and one longer than 260 characters reaches its file. A file another program has open can still be read, replaced and added to, unless that program forbade it.
- `NotFound` is a file that isn't there, a path through a directory that isn't or through a file, and the empty path. On Windows a name the system can't take, such as one holding `?`, is `NotFound` when read.
- Some reasons are Silver's own words, the same on every system: a directory given as a file is `Is a directory` (where Windows would say `Access is denied.`), a path ending in a separator is `A path ending in a separator names a directory, not a file`, writing to the empty path is `The path is empty`, and a path holding the character `\u{0}`, which no system can take, is `The path contains a NUL character`, with `exists` `false` for it.
- Every other reason is the system's: on Windows in the language it's set to.

The rest of this document's additions aren't built:

- There is no `exit`, `eprint`, `eprintl` or `environment`, and no `std.process`.
- `print` panics when the write fails, and when interpreted a closed pipe ends the program with the interpreter's own error.

The exit statuses, and an error from `main`, are as described.
