# std.file

Reading and writing a file whole.

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

The errors are members of `lang`'s [`IoError`](../language/errors.md#ioerror), so `?` widens each into it. Each names the path as the program gave it, and prints as a message:

- `NotFound(path)` is a file that isn't there. It's a member of its own because it's the failure a program most often answers itself, as by using its defaults.
- `ReadFailed(path, reason)` and `WriteFailed(path, reason)` are every other failure, with the system's words for it, in the system's language. A reason is for showing to a person, not for comparing: it differs between systems, so a program that needs to tell two failures apart needs a member of `IoError` for it.

```silver
def main(): Unit ! IoError {
    writeFile("out/report.txt", readFile("in.txt")?)?
}
```

With `in.txt` there and no directory `out`, on Linux:

```
error: couldn't write out/report.txt: No such file or directory
```

On Windows the reason reads `The system cannot find the path specified.` instead.

## Open questions

- Files that are held open: reading one a piece at a time, a file as a range of lines, and writing as the program goes. A range that holds an open file needs a way to say when it's closed, which nothing in the language does yet.
- Directories: listing, creating and removing them, and removing or renaming a file.
- A type for paths, and joining and splitting them.
- `exists` doesn't say whether it found a file or a directory, and is `false` for a directory it isn't allowed to look in. Functions that ask which, such as `isFile` and `isDirectory`, belong with the directory functions, rather than a second meaning for `exists`.

## Current implementation

- Everything above is built, on both backends. On Windows a path is opened through the system's UTF-16 functions, so a name that isn't ASCII works, and one longer than 260 characters reaches its file. A file another program has open can still be read, replaced and added to, unless that program forbade it.
- `NotFound` is a file that isn't there, a path through a directory that isn't or through a file, and the empty path. On Windows a name the system can't take, such as one holding `?`, is `NotFound` when read.
- Some reasons are Silver's own words, the same on every system: a directory given as a file is `Is a directory` (where Windows would say `Access is denied.`), a path ending in a separator is `A path ending in a separator names a directory, not a file`, writing to the empty path is `The path is empty`, and a path holding the character `\u{0}`, which no system can take, is `The path contains a NUL character`, with `exists` `false` for it.
- Every other reason is the system's: on Windows in the language it's set to.
