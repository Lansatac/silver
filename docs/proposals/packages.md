# Proposal: packages

**Status: decided and built, except a way to describe a package, and what parts share.** The rules are described in [Modules](../language/modules.md#packages). This document keeps the reasoning and what was rejected. Packages are given to `silver` on the command line for now, and a program is still compiled whole. `lang` is in place: only it may declare intrinsics, and the compiler names no other package. The [conformance proposal](conformance.md) depends on this one for who may declare a conformance and who sees one.

## Summary

A package is a name and a directory. A module's name is the package's name followed by the module's path under that directory, so the folders don't repeat the name:

```
package silver.core at core/source

core/source/lower.ag          module silver.core.lower
core/source/tree/node.ag      module silver.core.tree.node
```

A package lists the packages it uses. One with a `main` is a program, and nothing can depend on it. The compiler knows one package by name, `lang`, and the standard library is an ordinary package.

The lines that describe a package here, as `package silver.core at core/source`, are a notation for this document. How a package is written down isn't designed.

## Motivation

- **The language now needs the boundary.** [Declared conformance](conformance.md) decides who may conform a type by which package declares it, and a compiler that drew the boundary differently would accept different programs.
- **A sub-package repeats its name in folders.** With `import a.b` loading `<root>/a/b.ag`, a part of `silver` called `core` with its own root has to live at `core/source/silver/core/`.
- **The standard library shouldn't be tied to the compiler.** What the compiler depends on should be small and named, so the rest can change, or be replaced, without it.

## What belongs to the language, and what to the tool

- **The language** says what a package is, which package a module belongs to, what a package may depend on, and which package is the program.
- **The tool** says where a package's source comes from: a manifest, versions, fetching, a lock file and a registry. None of it changes what a program means.
- **The tool is `silver`.** `silver build` and `silver test` read the package's description. There is no separate package manager with its own idea of a project.

## The proposal

### A package is a name and a directory (decided)

- A package's name is one or more segments, as `std` or `silver.core`.
- A module's name is the package's name and then the module's path under the package's directory. `core/source/tree/node.ag` in `silver.core` is `silver.core.tree.node`.
- A file's `module` line is still its full name, and has to match. A file read on its own says what it is, and imports and errors use one spelling.
- An import is found by the package whose name is the longest prefix of the module's name, and then by the remaining segments as folders. So `silver` and `silver.core` can both be packages, in directories that have nothing to do with each other.
- Nothing changes for whoever imports a module: `import silver.core.lower` is the same line.

### Dependencies

- A package lists the packages it uses, and may import only from those and itself.
- The list has no cycles.
- Until a manifest exists, the list and each package's directory can be given to the compiler directly, as `--package lib=path/to/lib`.

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
- **Every package stands alone for ownership.** Simpler to state. A project split into parts would meet the restriction on conformances in its own code.
- **A part by its name, or by naming its parent.** Nothing for the parent to write. But being a part gives ownership of the parent's types, and anyone could claim it: a package named `std.extra` could conform built-in types to `std`'s interfaces.
- **Every part of a program is the program.** Each part could conform anything, and nothing outside could depend on any of them, so a program's library parts couldn't be shared.
- **The program is whichever package is being built.** No kind to declare, but a library built alone would count as one and could declare conformances that fail once something depends on it.
- **A package says whether it's a program.** Explicit, and one more thing to write that `main` already says.
- **A script belongs to the package of its directory.** It would see what that package shares among its parts, but a file tried out inside a library couldn't conform anything the library can't.
- **The prelude belongs to the compiler and forwards the standard library.** One fewer setting, and the compiler would then load `std` for every program.
- **Nothing in scope but `lang`.** No prelude to choose, and every module that maps over an array imports the range functions.
- **`intrinsics` or `core` as the compiler's package.** `intrinsics` names the smaller part of what's there once `Interval`, `Range` and the built-in types' conformances are in it. `core` is the usual name for this layer and is also what the compiler calls its own tree.

## Open questions

1. How a package is described before a manifest exists, and the manifest's format after.
2. The visibility shared by the parts of a package.
3. Whether tests in a library may see more than the library does.
4. Whether a part can list parts of its own.
