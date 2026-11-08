# Tuples

`(a, b)` is a value of the structural type `(A, B)`. The element types in order are the whole identity of a tuple type.

There are no one-element tuples: `(x)` is grouping, and `()` is `Unit`.

## Typing

A literal checked against an expected tuple type checks each element, so literals adapt and elements promote:

```silver
val pair: (UInt8, Int?) = (1, 2)
```

Unannotated, each element is typed on its own, so `(1, None)` needs an annotation. A tuple *value* never converts: `(Int, Int)` isn't assignable to `(Int, Int?)`.

Tuples are compared elementwise with `==` and `!=` when every element is comparable, and have no ordering. A tuple prints as `(1, a)`.

A tuple passed to a function is one argument. `f((1, 2))` passes one tuple, and `f(1, 2)` passes two arguments.

## Destructuring

Elements are reached by destructuring. There's no positional access.

```silver
val (a, b) = pair
mutable val (x, y) = origin()
val ((p, q), n) = nested()
val (first, _) = pair
val (c: UInt8, d) = (1, 2)
```

The element count must match exactly. Patterns here can't fail: they are names, `_`, and tuples of those.

Against a tuple literal of the same count, the pattern goes element by element, so each part is checked like its own `val`, and `val (_, x) = (None, 1)` needs no type. Otherwise the whole value is typed first, and an annotation on one part must match that value exactly, since a value doesn't convert.

## Open questions

- Named elements, as in `(first: A, rest: B)`, which wouldn't be part of the type.
- Destructuring assignment, `(a, b) = f()`.
- `for (i, x)` over arrays.

## Current implementation

The implementation matches this description.
