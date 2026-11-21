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

## Current implementation

- `silver` and `silverc` are two programs, and `silver` runs a file, builds one and tests a path by calling `silverc` with the same command and options. It finds `silverc` beside itself, or where the environment variable `SILVERC` says.
- `silver` reads no `silver.toml` and finds no project. Packages are given on the command line, which it passes on: see [Modules](language/modules.md#current-implementation).
- `run`, `build` and `test` need a file or a path.
- A program can't read arguments, so anything after the file is an error.
