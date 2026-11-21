# Proposal: packages

**Status: decided, and built except the `silver` front end, its package file, a package's root module, and what parts share.** The rules are described in [Modules](../language/modules.md#packages), and the front end and its file in [The `silver` tool](../silver.md). This document keeps the reasoning and what was rejected. Packages are given on the command line until the front end is built, and a program is still compiled whole. `lang` is in place: only it may declare intrinsics, and the compiler names no other package. The [conformance proposal](conformance.md) depends on this one for who may declare a conformance and who sees one.

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
  - Both exist. Until `silver` reads a package file it passes its command line on, so the package flags can be given to either.
- **A package file is TOML (decided),** read only by `silver`, named `silver.toml` and kept in the package's directory. Its fields are in [The `silver` tool](../silver.md#projects). It's TOML because it has comments, it's what package manifests have converged on, and it has few surprises. The compiler doesn't read it, so it needn't be Silver's syntax.

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

### A package file makes a package (decided)

- A directory is a package only when it holds a `silver.toml`, which gives the name. `silver` finds it by looking in the directory of the file it was given and then upward.
- So a module is always named by its package, as `geometry.area`, and never by its bare file name, however small the project.
- A package's own name is a module's when its directory has a `package.ag`. Only the package's directory has one: a module deeper in already has a place, as a file beside the folder of its name.

### Scripts (decided inside a project, open outside one)

- A script under a package's directory uses what that package uses, and the package too when it's a library. It's still a program of its own and not part of the package, so it gains none of the package's rights over its types.
- That's how several runnable files share modules: the package holds what's shared and is a library, and each runnable file is a script beside it.
- Under a program, a script can't use the program, since nothing can. It sees what the program uses. A test harness with the programs it runs kept under it is the case.
- A script in no project, or under none of a project's packages, uses the standard library only. How one would say it needs more is open, and a header in the script is the likely form.

These hold so that no choice is closed off:

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
- A part with a `main` is a program, and a parent can have several, as a compiler, its front end and its test harness. The others are libraries that share ownership with them, and other packages may depend on them.
- A parent needn't have modules of its own. One that exists only to hold its parts together is the usual shape of a project in several packages, and a tool that wants a root package with code in it pushes the code somewhere it doesn't belong.
- The parent's package file describes each part: its name, its path and what it uses. The parts have no file of their own. That follows from the rule above it: a package is a part only because its parent says so, so the parent is where it's written down, and the whole project's packages and what each uses read in one place.
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
- **A script imports the modules beside it by their bare names,** as `import hands` for `hands.ag` in its folder, with no package file. Nothing to write, and it's what a program's directory as a root used to give. But a helper then has a name that says nothing of the project it's part of, and there'd be a second way to name a module beside the package's.
- **A folder is a package named after itself,** with no package file. Nothing to write either, but the name comes from the path, so renaming the folder or cloning it under another name breaks every `module` line in it.
- **Several `main`s in one package,** with the one being run as the program. It would undo a program being a property of the package, and nothing could then use the shared modules as a library.
- **One program per folder,** with every other runnable file moved to a package of its own. Explicit, and a folder of fifty experiments would be fifty packages.
- **A root module named after the package,** as `cards/cards.ag` for `module cards`. The file's name says what it is, but `cards.cards` could then never be a module, and which file is the root would depend on the package's name.
- **No root module.** The smallest rule, and a library of one file would always be imported as `name.something`.
- **A package file in every part,** each giving the path of every package it uses. Each directory then says what it is by itself, as a Cargo crate does. But a project of nine parts writes `../ast` and its like some twenty-five times, and no one file shows what uses what.
- **A used package written as a name and a table,** as `geometry = { path = "../geometry" }`. It's what Cargo does, and keeps a name beside its source. But a part names its siblings with no path at all, so what's used is a list of names, and where a package outside the file is kept is a separate table.
- **A workspace file beside the package files,** listing a project's packages without making them parts. It would be a second way to group packages. A parent with no modules of its own does it with the one there is, and a list of packages that share nothing can be added if it's wanted.
- **A script belongs to the package of its directory.** It would see what that package shares among its parts, but a file tried out inside a library couldn't conform anything the library can't.
- **The prelude belongs to the compiler and forwards the standard library.** One fewer setting, and the compiler would then load `std` for every program.
- **The standard library listed like any other package.** One rule with no exception, but nearly every file imports from it, so a script couldn't run without being told so, while the prelude it already sees comes from the same package.
- **Nothing in scope but `lang`.** No prelude to choose, and every module that maps over an array imports the range functions.
- **`intrinsics` or `core` as the compiler's package.** `intrinsics` names the smaller part of what's there once `Interval`, `Range` and the built-in types' conformances are in it. `core` is the usual name for this layer and is also what the compiler calls its own tree.

## Open questions

1. Where a used package's source may come from besides a path (git, a registry), versions and a lock file.
2. How a script in no project says it needs a package.
3. The visibility shared by the parts of a package.
4. Whether tests in a library may see more than the library does.
5. Whether a part can list parts of its own.
