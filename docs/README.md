# The Silver language

Silver is a statically typed language with a functional feel: values are immutable by default, absence is explicit, and blocks and `if` are expressions.

These documents describe the language as designed. Where the implementation doesn't match the design yet, the end of each file has a **Current implementation** section. Silver can be run by an interpreter or compiled to a native program, and both are meant to behave identically.

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
| [Arrays](language/arrays.md) | Arrays, slices, concatenation, maps | Implemented, except maps; element assignment always copies |
| [Strings](language/strings.md) | Text, interpolation, views | Partial: no byte or character views |
| [Tuples](language/tuples.md) | Tuple values and destructuring | Implemented |
| [User types](language/user-types.md) | Markers, products, sums, aliases, `with`, invariants, `match` | Implemented |
| [Generics](language/generics.md) | Type parameters on functions and types, inference | Implemented |
| [Interfaces](language/interfaces.md) | Interfaces, bounds, conformance, interface names as parameter types | Partial: no interface types as results or values, no `Ord`, no bounds on a type's parameters |
| [Shared references](language/refs.md) | `Ref<T>`, the one value that's shared when copied | Implemented |
| [Modules](language/modules.md) | Files, imports, visibility | Partial: no `forward import` or renamed imports |
| [Native functions](language/native.md) | Calling C functions, native types, `std.c`, intrinsics | Partial: no `native type` or `CString`; the interpreter calls only the standard library's natives |
| [Testing](language/testing.md) | `test`, `assert`, `expect`, `panics`, the test runner | Partial: no companion files, `--filter` or `--format json` |

## Not designed yet

These areas are expected but have no settled design, so the documents mention them only where they affect another feature:

- Compile-time evaluation
- Ranges as values
- Program arguments and exit codes
