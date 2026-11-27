# Arrays

An array, of type `[T]`, is an immutable value. Slicing and sharing are constant-time, and nothing can observe a write to an array another value holds.

## Literals

```silver
val values = [1, 2, 3]
val bytes: [UInt8] = [1, 2]
val maybe = [Some(1), None]        // [Int?]
val empty: [Int] = []
```

Against an expected `[T]`, each element is checked against `T`, so literals adapt and elements promote. Unannotated, the elements must have [a type they share](types.md#a-shared-type). Literals [take one together](numbers.md#literals), so `[1, 2.0]` is a `[Float]`, while `[n, 2.0]` with `n: Int` is an error. And `val x = []` needs an annotation, as does `val x = Some([])`.

A literal may have a trailing comma, and can span lines.

## Indexing and slicing

`xs[i]` takes an `Int` index and yields an element. It panics on an out-of-range index, including a negative one. An index of another integer type is converted first, as `xs[Int(b)]`.

Indexing is a call: `x[i]` means `opIndex(x, i)`, `x[i] = v` means `x = opIndexAssign(x, i, v)`, and `x[a..b]` means `opIndex(x, a..b)`, indexing by an [`Interval`](#ranges). So a value of any type with those functions can be indexed, assigned and sliced, and the results are whatever they return. See [operator functions](functions.md#operator-functions). An array's `opIndex` returns the element and panics out of range, while a type where a missing entry is ordinary can return an option.

`xs[a..b]` is the half-open slice from `a` to `b`, whose bounds are `Int`s. It panics when `a > b`, `a < 0`, or `b > length(xs)`.

Either bound can be left out: `xs[a..]` runs to the end, as `xs[a..length(xs)]` would with `xs` evaluated once, and `xs[..b]` starts at 0. `xs[..]` isn't allowed, since it would just be `xs`.

`length(xs)` is the number of elements, as an `Int`, and `at(xs, i)` is `xs[i]`, for where a function is wanted. Both are `lang` functions, so they can be called as methods (`xs.at(i)`). So are `opIndex` and `opIndexAssign` for arrays, and the `opIndex` that slices one by an `Interval<Int>`.

## Assigning elements

`xs[i] = v` replaces one element of an array held by a `mutable val` or a mutable parameter. A `val` can't assign its elements. The index follows the same rules as reading one, so it's an `Int` and an out-of-range index panics. `v` is checked against the element type, so literals adapt and options promote.

```silver
mutable val xs = [1, 2, 3]
val before = xs
xs[0] = 9
printl(xs)        // [9, 2, 3]
printl(before)    // [1, 2, 3]
```

An array remains a value: the assignment changes what `xs` holds, and nothing else that held the old array can see it.

The index is evaluated first, then `v`, and then the element is replaced in whatever `xs` holds at that point. Compound assignment works on an element and evaluates the index once, so `xs[next()] += 1` calls `next` once.

An element can be assigned through a path of elements and fields rooted at a `mutable val` or a mutable parameter, as `grid[y][x] = v`, `ps[i].name = n` and `game.board[i] = v`. Each step is written back into the one that holds it, as in [operator functions](functions.md#operator-functions).

Two elements can be swapped with a [tuple of targets](tuples.md#assigning-parts): `(xs[i], xs[j]) = (xs[j], xs[i])`.

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

`==` and `!=` compare elementwise. Arrays have no ordering. An array prints as `[1, 2, 3]`.

## Ranges

`a..b` is the half-open range of integers from `a` up to but not including `b`, as a value of `lang`'s `Interval`:

```silver
type Interval<T>(from: T, to: T)

val r = 2..6                // Interval<Int>
length(r)                   // 4
r[1]                        // 3
r[1..3]                     // Interval(3, 5)
r.contains(5)               // true
r == 2..6                   // true
next(r)                     // Some((2, Interval(3, 6)))
nextBack(r)                 // Some((5, Interval(2, 5)))
for i in r { print(i) }     // 2345
[10, 20, 30, 40, 50][r]     // [30, 40, 50]
```

- The bounds are of any one integer type, and a literal adapts to the other bound, as in a `for`. So with `low: UInt8`, `low..255` is an `Interval<UInt8>`. Against an expected `Interval<T>`, also inside an option or an error union, both bounds are checked against `T`, so `val small: Interval<UInt16> = 0..3` works, and so does `r == 0..3` with `r` an `Interval<UInt16>`. A `Char` or a `Float` isn't a bound.
- Its elements are its bounds' type, and its length is an `Int`. `length` panics on an interval holding more integers than an `Int` can count, such as `Int.min..Int.max`. `r[i]` panics when `i` is out of range, as an array's does.
- Bounds the wrong way round are empty: `5..0` has length 0, contains nothing, and loops no times. It isn't a panic.
- Two intervals are equal when they hold the same integers, so `3..3 == 6..0`.
- `for i in r` steps from `r.from` while below `r.to`, as `for i in a..b` does, so it gives the same elements however many there are, and never calls `length`. An interval is a `Range`, a `Sized` and an `Indexed`, so a range built on one, as `(10..20).map(f)`, is indexed too.
- Slicing is indexing by an interval: `x[a..b]` is `opIndex(x, a..b)`, `x[a..]` is `opIndex(x, a..length(x))`, and `x[..b]` is `opIndex(x, 0..b)`. `x[a..b] = v` is `x = opIndexAssign(x, a..b, v)`, in each form. See [operator functions](functions.md#operator-functions). On an array, `xs[a..b]` written out is built in, and `xs[r]` slices the same way, panicking as that slice would, and a slice can't be assigned to, since it shares the array's elements: assign them one at a time. An interval's own slice counts from its start, so `(10..20)[2..5]` is `12..15`, and panics as an array's slice does.
- `0..10.f()` calls `f` on `10`, since a method call binds tighter than `..`. Calling one on the range needs parentheses: `(0..10).contains(9)`.
- An `Interval` prints as any product does, as `Interval(2, 6)`.
- Two intervals are equal when their bounds are, as for any product. So `0..0 == 5..5` is false though both are empty, since where an empty interval is can matter, as in `x[5..5] = v`. `isEmpty(r)` asks whether one is empty.

A range with a bound left out exists only inside brackets.

## Dictionaries

Dictionaries share the bracket syntax, with `:` between key and value, as in `["a": 1]`. See [Dictionaries](dictionaries.md).

## Open questions

- A form of indexing that returns `T?`, as a second prelude function beside `at`.
- Whether `mutable` arguments work on an element.
- `a..` and `..b` as values, an inclusive interval, and a step written in the syntax. `enumerate()` numbers items, and `step(n)` and `reversed()` are library adapters.
- An interval over a type that isn't an integer, as a range query on a sorted map would need. It would be a value type of its own that isn't a range.
- Pre-sizing an array before appending, and making one of `n` copies of a value. Leaning towards the range form (a repeating range collected into an array) once ranges exist, rather than an array function now.

## Current implementation

- `xs[i] = v` copies the whole array every time, even when nothing else holds it.
- An `Interval`'s `length`, `opIndex`, `next`, `nextBack` and `contains` are written once per integer type, since a bound can't ask for an integer yet. So an error about one of those calls lists every integer type's, and each name is overloaded, so using one as a value needs a function type, as in `val f: ([Int]) -> Int = length`.
- A panic in an `Interval`'s `opIndex`, or in slicing an array with one, is reported inside `lang` rather than at the call.
