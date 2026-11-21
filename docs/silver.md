# The `silver` tool

`silver` is what a programmer runs. It finds the project a file belongs to, reads the project's package file, and calls the compiler, `silverc`, with what it found. What a [package](language/modules.md#packages) is, and every rule about one, belongs to the language and to `silverc`. Where a package's source is, and how that's written down, belongs to `silver`.

## Commands

```
silver hello.ag            run a file
silver run hello.ag        the same
silver build hello.ag      compile it to an executable
silver test sema           run the tests in a file or a directory
silver run                 run the program of the project here
silver build               compile it
silver test                run the tests of the project here
```

- The first word is a command only when it's one of `silver`'s. Anything else is a file, so a file named `build` is run as `silver ./build`.
- What follows the file is for the program, not for `silver`.
- A file can start with `#!/usr/bin/env silver` and be run as `./hello.ag`.
- With no file, `run` and `build` take the program of the package `silver` was started in. A library is reported as one. In a package with several parts that are programs, `silver` lists them, and one is chosen by its directory, as `silver run compiler`.
- With no path, `test` runs the tests of the package `silver` was started in, and of its parts.
- `test` over a directory leaves out any directory under it with a `silver.toml` that the project doesn't use: that's another project, tested from its own directory. One the project uses is tested with it.
- `--show-command`, given before the file like any option, prints the command line `silver` runs the compiler with, then runs it. It's for when `silver` and `silverc` seem to disagree.

## Projects

A directory is a package when it holds a file named `silver.toml`. Nothing else makes one: a folder's name means nothing by itself.

```toml
# geometry/silver.toml
name = "geometry"
```

```
geometry/silver.toml
geometry/package.ag           module geometry
geometry/area.ag              module geometry.area
geometry/shapes/circle.ag     module geometry.shapes.circle
```

- `name` is the package's name, and has to be given.
- The package's modules are in the file's own directory, unless `source` names a directory under it, as `source = "source"`.
- `uses` lists the packages this one uses, by name. The standard library isn't listed: every package uses it.
- `[paths]` says where a used package is, as a directory. That directory's `silver.toml` has to declare a package of that name, and what the used package uses in turn is read there and not repeated.
- A field `silver` doesn't know is an error.

```toml
# cards/silver.toml
name = "cards"
uses = ["geometry"]

[paths]
geometry = "../geometry"
```

### A project of several packages

A package describes its [parts](language/modules.md#parts) in its own file, each with a name, a path and what it uses. Here is the compiler:

```toml
# silver.toml
name = "silver"

[[part]]
name = "silver.ast"
path = "ast"

[[part]]
name = "silver.syntax"
path = "syntax"
uses = ["silver.ast"]

[[part]]
name = "silver.sema"
path = "sema"
uses = ["silver.ast", "silver.loader"]

[[part]]
name = "silver.compiler"
path = "compiler"
uses = ["silver.sema", "silver.core", "silver.interpreter", "silver.codegen"]

[[part]]
name = "silver.frontend"
path = "frontend"
```

```
silver.toml
ast/node.ag                   module silver.ast.node
sema/package.ag               module silver.sema
sema/check.ag                 module silver.sema.check
compiler/main.ag              module silver.compiler.main
```

- A part's directory has no `silver.toml`. Its file is the parent's.
- A part names another part of the same file with no path. A package outside the file is found through `[paths]`, which every part of the file shares.
- A part's `source` works as a package's does.
- A package with parts has modules of its own only when it gives `source`. Without it, as above, the package only holds its parts together.
- Any number of parts can be programs. Each part with a `main` is one.
- A package elsewhere uses a part by the part's directory, as `"silver.core" = "../silver/core"` under `[paths]`. `silver` finds the parent's file above it.
- A name of more than one segment is quoted where it's a key, since TOML reads an unquoted dot as nesting.

### Finding the project

- When a file is named, `silver` looks for `silver.toml` in the file's directory and then in each directory above it, and takes the first it finds. Where `silver` was started from doesn't matter, so a script run by its path behaves the same from anywhere.
- When no file is named, it looks the same way from the directory it was started in.
- A file belongs to the package, or the part, whose directory of modules it's under.
- A file with a `module` line has to be named by its package's name followed by its path there.

## Scripts

A file with no `module` line is a script: a whole program in one file, which nothing can import.

- With no `silver.toml` at or above it, a script uses the standard library and nothing else. No package file is ever needed to run one file.
- A script under a package's directory uses what that package uses. When the package is a library, the script uses the package too.
- A package's directory here is the one its `silver.toml` is in, and a part's is its `path`, even when `source` puts the modules below it, so a script beside a `silver.toml` is under that package. When several hold a script, the deepest does, so a script in a part's directory is under the part.
- A script is never part of the package. It's a program of its own beside it.

So a library can keep runnable files beside its modules, each a program that uses it:

```
geometry/silver.toml
geometry/area.ag              module geometry.area
geometry/demo.ag              a script
geometry/benchmark.ag         another
```

```silver
// geometry/demo.ag, with no module line
import geometry.area

def main(): Unit { printl(area(Circle(2.0))) }
```

And a program can keep scripts under it that never import it, as a test harness keeps the programs it runs. Those see the packages the harness uses and not the harness.

## Open questions

- Where a used package's source may come from besides a path: a git repository, a registry, versions, and a lock file.
- A script that needs a package and sits in no project, or in a project but under none of its packages. A header in the script could say so.
- What an executable built from a part is called when the part's name isn't wanted, as `silverc` for `silver.compiler`.
- A package used only by tests.
- Naming a prelude other than the standard one.
- Whether only what a run reaches should be read. Today every package and part of a file is read and followed once any of them is reached, so a part's broken `[paths]` entry stops runs that never use that part.

## Current implementation

- `silver` and `silverc` are two programs, and `silver` runs a file, builds one and tests a path by calling `silverc` with the same command and options. It finds `silverc` beside itself, or where the environment variable `SILVERC` says.
- `silver` finds the project of the file or directory named and reads its `silver.toml`, and the files of the packages it uses, as above. It gives `silverc` each package's directory, uses and parts as `--package`, `--uses` and `--parts`, and the file that describes it as `--package-file`, so that what `silverc` reports about a package names that file and its `uses` rather than an option, and a starting file whose `module` line names no package is told the name its package and path give it. The directories are given relative to where `silver` was started when they're inside it. `std` isn't given: `silverc` adds it.
- With no `silver.toml` at or above the file, the command line is passed on as it is, and packages can still be given on it: see [Modules](language/modules.md#current-implementation). Options given by hand inside a project follow the ones `silver` gives, and a package declared both ways is the compiler's error.
- A package file is read whole and checked before anything is run, and a mistake in it is one message located in the file, with a code from `F0001`: a field `silver` doesn't know or of the wrong type, a missing `name`, a part with no `name` or `path`, a name that isn't a package's, an empty directory, a directory that isn't one, a used package `silver` can't find, a directory under `[paths]` whose file doesn't describe a package of that name there, or one package name at two directories.
- Where the design leaves it open, `silver` refuses: a `source` or a part's `path` outside the directory it's taken from, a part, or a package's or part's `source`, in or under a directory with a `silver.toml` of its own below the file, since that file's package would hold its files, a part at the file's own directory, a part with its package's name or another part's, two parts at one path, a name listed twice in `uses`, `std` in `uses` or under `[paths]`, a name under `[paths]` that's the file's own package or one of its parts, and `uses` on a package with parts and no `source`. When any package of a file is reached, every package and part in that file is read and followed and given to `silverc`, so a mistake in one part's `[paths]` entry, such as a directory that isn't there, stops every run that reaches the file, including one from a package elsewhere that uses a different part. An entry under `[paths]` is followed only when something uses it.
- `run`, `build` and `test` need a file or a path. `-` as the file is passed on with no search for a project.
- A directory named `silver.toml` isn't a package file, and the search carries on above it.
- For a file or directory in a project, `silver` tells `silverc` which packages' directories hold it with `--scripts-in`: the deepest package or part whose directory holds the file, and for a directory, also each one whose directory is inside it. A package that only holds its parts gets none. Whether the file is a script, and whether its package is a program, `silverc` decides, so `silver` never reads a `.ag` file. `silver test` over a directory gives each script there the package it's under, or none.
- A script under a package's directory that imports what the package doesn't use is told to list it in that package's `uses`. One under a program that imports the program is told a program can't be used, even by a file beside it. One under none of the project's packages is told it uses only the standard library, and that a script that needs a package belongs under that package's directory or under the directory of one that uses it. `--uses a,b` given by hand still adds to what a script uses.
- `silver test` over a directory gives `silverc` each directory under it with a `silver.toml` that no package `silver` read for the run is described in, as `--skip`, and doesn't look inside it for more. A project left out this way isn't mentioned in the report.
- A program can't read arguments, so anything after the file is an error.
