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

`xs[i]` takes an `Int` and yields an element. It panics on an out-of-range index, including a negative one.

`xs[a..b]` is the half-open slice from `a` to `b`. It panics when `a > b`, `a < 0`, or `b > length(xs)`.

`length(xs)` is the number of elements.

## Elements can't be assigned

`xs[i] = v` is an error, even on a `mutable val`, because it would hide a full copy behind syntax that looks constant-time. Rebinding the whole array is fine.

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
- Random-access construction of an array, which would need a design for in-place mutation.
- Pre-sizing an array before appending.
- The semantics of maps.

## Current implementation

- Map literals parse, but are rejected.
- `length` is available only as `length(xs)`, and can't be used as a function value.
