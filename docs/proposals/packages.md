# Proposal: packages

**Status: decided and built, except the package file's fields, a package's root module, and what parts share.** The rules are described in [Modules](../language/modules.md#packages). This document keeps the reasoning and what was rejected. Packages are given on the command line for now (the package file will be TOML, read by a `silver` front end that calls the compiler), and a program is still compiled whole. `lang` is in place: only it may declare intrinsics, and the compiler names no other package. The [conformance proposal](conformance.md) depends on this one for who may declare a conformance and who sees one.

## Summary

A package is a name and a directory. A module's name is the package's name followed by the module's path under that directory, so the folders don't repeat the name:

```
package silver.core at core/source

core/source/lower.ag          module silver.core.lower
core/source/tree/node.ag      module silver.core.tree.node
```

A package lists the packages it uses. One with a `main` is a program, and nothing can depend on it. The compiler knows one package by name, `lang`, and the standard library is an ordinary package.

The lines that describe a package here, as `package silver.core at core/source`, are a notation for this document. A package will be written down in a TOML file whose fields aren't designed.

## Motivation

- **The language now needs the boundary.** [Declared conformance](conformance.md) decides who may conform a type by which package declares it, and a compiler that drew the boundary differently would accept different programs.
- **A sub-package repeats its name in folders.** With `import a.b` loading `<root>/a/b.ag`, a part of `silver` called `core` with its own root has to live at `core/source/silver/core/`.
- **The standard library shouldn't be tied to the compiler.** What the compiler depends on should be small and named, so the rest can change, or be replaced, without it.

## What belongs to the language, and what to the tool

- **The language** says what a package is, which package a module belongs to, what a package may depend on, and which package is the program.
- **The tool** says where a package's source comes from: a manifest, versions, fetching, a lock file and a registry. None of it changes what a program means.
- **Two executables, with the compiler's flags as the contract between them (decided).**
  - `silverc` is the compiler. It's given every package fact on its command line (the name, directory, uses and parts of each package) and never reads a package file or touches the network. Every rule that changes what a program means lives here.
  - `silver` is the front end and package manager. It finds the project, reads its package file, works out where each dependency's source is, and calls `silverc`. `silver run`, `silver build` and `silver test` are its commands.
  - So a package file can change format, or another tool can drive `silverc`, without the language changing. Two programs can later be merged into one more easily than one can be split. A package compiled on its own, which separate compilation needs, is one `silverc` call, as a crate is one `rustc` call under Cargo.
  - Until `silver` exists, today's executable is both. It keeps the name `silver` until the front end takes it.
- **A package file is TOML (decided),** read only by `silver`. Its fields aren't designed. It's TOML because it has comments, it's what package manifests have converged on, and it has few surprises. The compiler doesn't read it, so it needn't be Silver's syntax.

## The proposal

### A package is a name and a directory (decided)

- A package's name is one or more segments, as `std` or `silver.core`.
- A module's name is the package's name and then the module's path under the package's directory. `core/source/tree/node.ag` in `silver.core` is `silver.core.tree.node`.
- A file's `module` line is still its full name, and has to match. A file read on its own says what it is, and imports and errors use one spelling.
- An import is found by the package whose name is the longest prefix of the module's name, and then by the remaining segments as folders. So `silver` and `silver.core` can both be packages, in directories that have nothing to do with each other.
- Nothing changes for whoever imports a module: `import silver.core.lower` is the same line.

### Dependencies

- A package lists the packages it uses, and may import only from those and itself.
- Every package and every script uses the prelude's package without listing it, as every module imports the prelude without naming it (decided). With the standard prelude that's `std`, so `silver hello.ag` can import `std.math`. The compiler doesn't name `std` for this: it's whatever package the build's prelude is in. `lang` is still exempt from lists, and still imports nothing outside itself.
- The list has no cycles.
- The list and each package's directory are given to the compiler as flags, as `--package lib=path/to/lib`. That stays the compiler's interface once a package file exists: `silver` turns the file into these flags.

### Scripts (open)

How a script that needs more than the standard library gets it is the front end's to decide later. It might be `silver run`, a header in the script, or the package of the script's directory. These hold now so that no choice is closed off:

1. A file with no `module` line is a whole program, and runs with no package file anywhere.
2. No package file is needed to run one file. Packages are for work in several files.
3. A script uses the prelude's package without listing it, so most scripts need nothing else.
4. Whatever mechanism comes, it only supplies the facts the compiler's flags carry, so it needs no change to the language.
5. Nothing gives a meaning to a comment at the top of a file, which leaves room for a header there.

### Programs and libraries (decided)

- A package with a `main` is a program. Nothing can depend on one.
- Every other package is a library.
- It's a property of the package, and not of which one is being built. A library built on its own to run its tests is still a library, so it can't declare what only a program may.
- A file with no `module` line, run directly, is a program of its own: one module, named after the file, that nothing can import.

### Parts of one package (decided)

A package can list others as its parts, as `silver` lists `silver.ast`, `silver.core` and `silver.sema`.

```
package silver at source
    parts: silver.ast, silver.core, silver.sema
```

- Only the parent's list makes a package a part. A name that extends another package's, as `std.extra` extends `std`, means nothing by itself.
- Parts are built and laid out separately, and each lists what it uses.
- For ownership they count as one: any part may declare a conformance for a type or an interface that any part owns.
- When the parent is a program, only the part with the `main` is the program. The others are libraries that share ownership with it, and other packages may depend on them.
- A visibility between `private` and public, for what the parts share and nothing outside may use, would be defined here. It isn't designed.

### The package the compiler knows (decided)

The compiler refers to one package by name, `lang`. Everything else, the standard library included, is an ordinary package.

1. `intrinsic def` and `intrinsic alias` are allowed only in `lang`.
2. Every declaration the compiler refers to itself is declared there: `Interval` today, and `Range` once `for` goes through [declared conformance](conformance.md#for-decided).
3. `lang` depends on nothing. `std` depends on it, and never the reverse.
4. `lang` ships with the compiler, at the compiler's version, and can't be replaced. `std` can be versioned on its own.
5. A declaration belongs there only when it's an intrinsic or the compiler names it. Anything that's plain Silver belongs in `std`.

- Built-in types, which no module declares, belong to `lang`: arrays, tuples, options, error unions and function types.
- `lang` and `std` aren't parts of one package. `std` has the rights any library has, so another standard library could stand where it does.
- The functions syntax calls by name, such as `opIndex`, `length` and `next`, are found as any function is. The compiler depends on the name being in scope and not on a package.
- By rule 1, the intrinsics `std` held move: `std.ref`'s `Ref`, `get`, `set` and `update`, `std.c`'s aliases, and `std.time`'s runtime native. `std` forwards them. `std.string` and `std.char` used unchecked conversions privately; `lang` gives them checked ones instead (`decode`, `toChar` and a `slice` that panics unless it falls between characters), so `std` can't build a String that isn't UTF-8 any more than other code can.

### What's in scope without an import (decided)

- `lang` is in scope in every module. It's part of the language.
- The prelude is the standard library's. The build names it, and it defaults to `std.prelude`. The compiler imports the prelude it's given and has no library's name written into it.

So `xs.map(f)` needs no import, the functions behind it are plain Silver in `std`, and the compiler would build a program against another library unchanged.

## Alternatives considered

- **Packages managed entirely outside the language,** by a tool like `dub`. The language would have no boundary to hang ownership or a wider visibility on, and each tool would draw its own.
- **The first segment of a module's name is its package.** Nothing to declare, but `silver.core` couldn't be a package of its own, and the folder problem stays.
- **A manifest written in Silver.** It can compute what it needs, but a tool has to run it to read it. A data file can be read by anything.
- **A package file in a subset of Silver's syntax, read by the compiler.** It would feel familiar and need no second parser in the compiler. But it puts reading the file in the compiler, and with the flags as the contract the compiler needn't read it at all.
- **JSON for the package file.** Everyone knows it and the standard library will parse it anyway, but it has no comments, and a dependency often wants one.
- **YAML for the package file.** Readable and familiar, but it types values implicitly (`no` is false), its indentation is significant, and its parser is large.
- **One executable, with the compiler as a library inside it,** as `go` and `zig` are. One install and nothing to start per package, but the contract would be an internal interface that nothing keeps clean, and one per-package compile is the unit separate compilation wants anyway.
- **A separate package manager with its own idea of a project,** as dub is beside dmd. The compiler and the manager could disagree about which package a file is in. With `silver` calling `silverc` with the facts, only `silverc` decides.
- **Every package stands alone for ownership.** Simpler to state. A project split into parts would meet the restriction on conformances in its own code.
- **A part by its name, or by naming its parent.** Nothing for the parent to write. But being a part gives ownership of the parent's types, and anyone could claim it: a package named `std.extra` could conform built-in types to `std`'s interfaces.
- **Every part of a program is the program.** Each part could conform anything, and nothing outside could depend on any of them, so a program's library parts couldn't be shared.
- **The program is whichever package is being built.** No kind to declare, but a library built alone would count as one and could declare conformances that fail once something depends on it.
- **A package says whether it's a program.** Explicit, and one more thing to write that `main` already says.
- **A script belongs to the package of its directory.** It would see what that package shares among its parts, but a file tried out inside a library couldn't conform anything the library can't.
- **The prelude belongs to the compiler and forwards the standard library.** One fewer setting, and the compiler would then load `std` for every program.
- **The standard library listed like any other package.** One rule with no exception, but nearly every file imports from it, so a script couldn't run without being told so, while the prelude it already sees comes from the same package.
- **Nothing in scope but `lang`.** No prelude to choose, and every module that maps over an array imports the range functions.
- **`intrinsics` or `core` as the compiler's package.** `intrinsics` names the smaller part of what's there once `Interval`, `Range` and the built-in types' conformances are in it. `core` is the usual name for this layer and is also what the compiler calls its own tree.

## Open questions

1. The package file's fields: how a package names what it uses and where each one's source is (a path, git, a registry), and whether a workspace file lists the packages of a project.
2. Where a package's root module lives, so `import cards` can name a package's own module: a fixed name inside its directory (as D's `package.d` and Python's `__init__.py`), or none.
3. The visibility shared by the parts of a package.
4. Whether tests in a library may see more than the library does.
5. Whether a part can list parts of its own.
