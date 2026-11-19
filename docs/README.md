# The Silver language

Silver is a statically typed language with a functional feel: values are immutable by default, absence is explicit, and blocks and `if` are expressions.

These documents describe the language as designed. Where the implementation doesn't match the design yet, the end of each file has a **Current implementation** section. Silver can be run by an interpreter or compiled to a native program, and both are meant to behave identically.

## Running and building

- `silver <file>` runs a program with the interpreter, and `silver -b llvm <file>` compiles it and runs the result.
- `silver build <file>` compiles it to an executable, which `-o` names. With `--emit-llvm` it writes the LLVM IR instead.
- `silver test <path>` runs tests: see [Testing](language/testing.md#running-tests).
- `-I <path>` adds a directory to search for imported modules.

Silver is designed to be compiled a package at a time. A package compiles to its signatures, the bodies of its generic and inlinable functions, and object code. A package that uses it instantiates those generics itself and is rebuilt when the package changes. There is no stable binary interface: a compiled package can't be swapped without rebuilding what uses it. Today every program is still compiled whole.

`-O`, or `--optimize`, optimizes a compiled program: with `silver build`, and with `-b llvm` when running, and with `-b llvm` or `-b both` when testing. It is meant to change how fast the program runs and how deep it can recurse, and nothing else. Every check stays: overflow, bounds, invariants, and the rest of what [panics](language/control-flow.md#panics). So a program that doesn't run out of stack either way prints, panics and fails as it does without `-O`. One known gap: optimized code can hold a pointer somewhere the memory manager's conservative collector doesn't look, so a program may rarely misbehave with `-O` and not without it. That is a defect, not a feature of `-O`. How deep a program can recurse isn't specified, and optimizing can turn a recursion into a loop, which needs no stack: a program that panics with `Stack overflow` may then finish, never stop, or reach a different panic first, as [Panics](language/control-flow.md#panics) shows. `-O2` is another spelling of `-O`, and `-O0` is the default, no optimization; there are no other levels. With `--emit-llvm`, `-O` writes the IR as optimized. The interpreter has nothing to optimize, so `-O` without `build` or `-b llvm` is an error. Options are case-sensitive: `-o` names the output and `-O` optimizes.

## Contents

| Document | Covers | Status |
| --- | --- | --- |
| [Syntax](language/syntax.md) | Comments, names, literals, newlines, operator precedence | Implemented |
| [Types](language/types.md) | Built-in types, promotion, equality, printing | Mostly implemented |
| [Numbers](language/numbers.md) | Numeric types, literals, operators, overflow, conversions | Implemented |
| [Bindings](language/bindings.md) | `val`, `mutable val`, discards, shadowing, constants | Implemented |
| [Functions](language/functions.md) | Declarations, lambdas, mutable parameters, method-call syntax, overloading, operator functions | Partial: no tail calls, `opEquals`, `opCompare` or `opString` |
| [Control flow](language/control-flow.md) | Blocks, `if`, `while`, `for`, jumps, panics | Implemented |
| [Options](language/options.md) | `T?`, `Some`, `None` and their operators | Implemented |
| [Errors](language/errors.md) | `T ! E`, `?` and `!` on errors, what panics, `main` | Implemented, except `read()` returning an error |
| [Arrays](language/arrays.md) | Arrays, slices, concatenation, `a..b` as an `Interval` | Implemented, except that element assignment always copies |
| [Ranges](language/ranges.md) | `Range`, sources of your own, `std.range` adapters and consumers | Partial: `map`, `filter`, `first`, `rest`, `array`, `fold` and `count`; `std.range` needs an import |
| [Maps](language/maps.md) | `[K: V]`, lookup and update, insertion order, keys | Designed, not implemented |
| [Strings](language/strings.md) | Text, interpolation, characters, cutting, `std.string` | Partial: `read()` doesn't check for UTF-8; no raw or multi-line strings |
| [Tuples](language/tuples.md) | Tuple values and destructuring | Implemented |
| [User types](language/user-types.md) | Markers, products, sums, aliases, `with`, `match` | Implemented, with `invariant` still to be removed |
| [Generics](language/generics.md) | Type parameters on functions and types, inference | Implemented |
| [Interfaces](language/interfaces.md) | Interfaces, declared conformance, bounds, `if type`, interface names as parameter and result types | Partial: every module sees every conformance; no interface types as values |
| [Shared references](language/refs.md) | `Ref<T>`, the one value that's shared when copied | Implemented |
| [Modules](language/modules.md) | Files, imports, forwarding, visibility, packages | Partial: no packages or renamed imports, and the prelude doesn't forward `std` modules yet |
| [Native functions](language/native.md) | Calling C functions, native types, `std.c`, intrinsics | Partial: no `native type` or `CString`; the interpreter calls only the standard library's natives |
| [Testing](language/testing.md) | `test`, `assert`, `expect`, `panics`, the test runner | Partial: no companion files, `--filter` or `--format json` |

## Not designed yet

These areas are expected but have no settled design, so the documents mention them only where they affect another feature:

- Compile-time evaluation
- Program arguments and exit codes
