# Arrays

An array, of type `[T]`, is an immutable value. Slicing and sharing are constant-time, and nothing can observe a write to an array another value holds.

## Literals

```silver
val values = [1, 2, 3]
val bytes: [UInt8] = [1, 2]
val maybe = [Some(1), None]        // [Int?]
val empty: [Int] = []
```

Against an expected `[T]`, each element is checked against `T`, so literals adapt and elements promote. Unannotated, the elements must have a common type. `[1, 2.0]` is an error, and `val x = []` needs an annotation.

A literal may have a trailing comma, and can span lines.

## Indexing and slicing

`xs[i]` takes an index of any integer type and yields an element. It panics on an out-of-range index, including a negative one.

`xs[a..b]` is the half-open slice from `a` to `b`, whose bounds are of one integer type. It panics when `a > b`, `a < 0`, or `b > length(xs)`.

`length(xs)` is the number of elements, as an `Int`, and `at(xs, i)` is `xs[i]` with an `Int` index. Both are prelude functions, so they can be called as methods (`xs.at(i)`), and they're what lets an array be looped over like any value with a `length` and an `at` (see [`for`](control-flow.md#for)).

## Assigning elements

`xs[i] = v` replaces one element of an array held by a `mutable val` or a mutable parameter. A `val` can't assign its elements. The index follows the same rules as reading one, so it can be any integer type and an out-of-range index panics. `v` is checked against the element type, so literals adapt and options promote.

```silver
mutable val xs = [1, 2, 3]
val before = xs
xs[0] = 9
printl(xs)        // [9, 2, 3]
printl(before)    // [1, 2, 3]
```

An array remains a value: the assignment changes what `xs` holds, and nothing else that held the old array can see it.

Assigning to an array that nothing else holds is meant to take constant time. If the array has been shared, the next assignment may copy it once, after which assignments are constant time again. Exactly when a copy happens isn't part of the language.

## Concatenation

`~` joins two arrays of one type, with literals adapting on both sides. It doesn't accept a bare element, so an element is written `xs ~ [x]`. A chain `a ~ b ~ c` performs one allocation.

`xs ~= ys` appends to a `mutable val`. It means `xs = xs ~ ys`, and the right side is again an array, not a bare element.

```silver
mutable val squares: [Int] = []
for i in 0..10 {
    squares ~= [i * i]
}
```

Appending in a loop is amortized constant time per element. No other array value can observe the append.

A slice keeps its whole underlying storage alive.

## Comparison and printing

`==` and `!=` compare elementwise when `T` is comparable. Arrays have no ordering. An array prints as `[1, 2, 3]`.

## Ranges

`a..b` is a half-open numeric range. It is accepted as a slice index and as the iterable of a `for`. It has no meaning elsewhere until ranges are designed as values.

## Maps

Maps share the bracket syntax, with `:` between key and value:

```silver
["a": 1, "b": 2]
[:]               // empty
```

## Open questions

- A form of indexing that returns `T?`.
- Which paths can be assigned beyond a plain variable, such as `game.board[i] = v` and `grid[y][x] = v`, and whether compound assignment and `mutable` arguments work on an element.
- Pre-sizing an array before appending.
- The semantics of maps.

## Current implementation

- Map literals parse, but are rejected.
- `xs[i] = v` isn't available yet.
- `length` is built into the compiler, so it can only be called, as `length(xs)` or `xs.length()`, and not used as a function value.
