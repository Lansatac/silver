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

A `for` takes each element apart the same way: `for (name, count) in pairs { ... }` (see [`for`](control-flow.md#for)).

## Assigning parts

A tuple of targets assigns each one its part of a value:

```silver
(a, b) = (b, a)                    // swaps
(xs[i], xs[j]) = (xs[j], xs[i])
(p.x, _) = f()
((low, high), count) = g()
```

A target is anything `=` can assign to, `_`, or a tuple of those. Only `=` works this way; `(a, b) += v` is an error.

The indices of element targets are evaluated first, left to right, then the whole value, and then the targets are written left to right. Nothing is written until every part of the value is known, which is what makes a swap work.

Against a tuple literal of the same count, each part is checked as its own assignment, so literals adapt: `(count, maybe) = (0, None)`. Any other value has to have the targets' shape, and each part must be exactly its target's type, since a value doesn't convert.

Two targets can't be the same place, or one inside the other: `(a, a)`, `(p, p.x)` and `(xs, xs[0])` are errors. Two elements of one array are allowed, since their indices aren't known until the program runs; if they turn out to be the same, the later write wins.

## Open questions

- Named elements, as in `(first: A, rest: B)`, which wouldn't be part of the type.

## Current implementation

The implementation matches this description.
