# The Silver language

Silver is a statically typed language with a functional feel: values are immutable by default, absence is explicit, and blocks and `if` are expressions.

These documents describe the language as designed. Where the implementation doesn't match the design yet, the end of each file has a **Current implementation** section. Silver can be run by an interpreter or compiled to a native program, and both are meant to behave identically.

## Contents

| Document | Covers | Status |
| --- | --- | --- |
| [Syntax](language/syntax.md) | Comments, names, literals, newlines, operator precedence | Implemented |
| [Types](language/types.md) | Built-in types, promotion, equality, printing | Mostly implemented |
| [Numbers](language/numbers.md) | Numeric types, literals, operators, overflow, conversions | Implemented, except shift amounts of any integer type |
| [Bindings](language/bindings.md) | `val`, `mutable val`, discards, shadowing, constants | Implemented |
| [Functions](language/functions.md) | Declarations, lambdas, mutable parameters, method-call syntax, overloading | Partial: no lambdas or overloading |
| [Control flow](language/control-flow.md) | Blocks, `if`, `while`, `for`, jumps, panics | Implemented |
| [Options](language/options.md) | `T?`, `Some`, `None` and their operators | Implemented |
| [Arrays](language/arrays.md) | Arrays, slices, concatenation, maps | Implemented, except maps and indexes of any integer type |
| [Strings](language/strings.md) | Text, interpolation, views | Partial: no byte or character views |
| [Tuples](language/tuples.md) | Tuple values and destructuring | Implemented |
| [User types](language/user-types.md) | Markers, products, sums, aliases, `with`, `match` | Implemented, except `alias` |
| [Modules](language/modules.md) | Files, imports, visibility | Partial: no visibility or import forms beyond `import a.b` |
| [Testing](language/testing.md) | `test`, `assert`, `expect`, the test runner | Not implemented |

## Not designed yet

These areas are expected but have no settled design, so the documents mention them only where they affect another feature:

- Generics and interfaces
- Compile-time evaluation
- Ranges as values
- Shared mutable references
- Program arguments and exit codes
