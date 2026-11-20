# Functions

## Declarations

```silver
def area(width: Int, height: Int): Int => width * height

def describe(value: Int): String {
    val doubled = value * 2
    "twice {value} is {doubled}"
}
```

`=>` introduces one expression, and a block's last expression is its value. A named function always declares its parameter types and return type. A named function's return type is required even when it's `Unit`. It can be an [interface](interfaces.md#an-interface-name-as-a-result-type), and then the type returned is the body's, which has to satisfy it.

When a `Unit` function's body produces a value of another type, the value is dropped.

A parameter named `_` takes an argument and binds nothing, for a function that has to have a signature but doesn't need every argument: `def onKey(_: Key, mutable state: State): Unit`. Any number of parameters can be `_`, in a `def` or a lambda, and each still has its type, so the function's type is unchanged.

Functions at the top level of a module can be used before they are declared. A function nested in a block has the same form as a top-level one, and is equivalent to binding a lambda to a local.

`return` exits the innermost function or lambda. A bare `return` returns `()`.

`native def` declares a function implemented outside Silver. It has a signature and no body. See [Native functions](native.md).

## Tail calls

`tail f(args)` exits the innermost function or lambda with the result of the call, as `return f(args)` would, except that the call reuses the current call's stack space. The call can be to any function or function value, not only the one it appears in, so self-recursion, mutual recursion and calls through function values all run at any depth through `tail`.

```silver
def sum(n: Int, acc: Int): Int {
    if n == 0 { return acc }
    tail sum(n - 1, acc + n)
}
```

- It can appear wherever `return` can.
- The operand must be a call of a function or a function value. A constructor, a conversion or a native function can't be the operand.
- The call's return type must be exactly the function's. Nothing can be done with the result after the call, so it can't be promoted: in a function returning `Int?`, `tail f(x)` needs `f` to return `Int?` as well.
- A `mutable` argument must be a whole mutable parameter of the current function. A `mutable val` or a field path would have to be written back after the current call has ended.
- A call without `tail` has no such guarantee, even when it's the last thing a function does.

## Lambdas

A lambda is a parameter list, an optional return type, `=>`, and one expression:

```silver
(x: Int): Int => x * 2
(x: Int) => x * 2
(x, y) => x + y
x => x * 2
x => { val y = x * 2; y + 1 }
_ => 0
(_, y) => y
```

So a named function is `def name` followed by a lambda, except that a named block body drops the arrow.

- The return type can always be omitted. It is inferred from the `return`s and the final value.
- Parameter types can be omitted when the context supplies a function type, such as an annotated binding, a call's parameter, or a field. Otherwise leaving them out is an error.
- Parentheses can be omitted only for a single untyped parameter.
- A call checks its non-lambda arguments first, so they can inform a lambda's parameter types.
- `x => y => x + y` nests to the right.
- `return` and postfix `?` exit the lambda. `break` and `continue` can't cross one.

A lambda can capture surrounding values, which are copied when the lambda is created. It can't capture a `mutable val` or a mutable parameter: copy one into a `val` first, or pass it as an argument.

## Function values

Functions are values, of type `(A, B) -> C`.

```silver
def increment(x: Int): Int => x + 1
def applyTo(f: (Int) -> Int, x: Int): Int => f(x)

val f = increment
val two = applyTo(f, 1)
```

A constructor can also be used as a function value. Two function values are equal when they come from the same place in the source and captured equal values; see [Types](types.md#function-values).

## Mutable parameters

A parameter marked `mutable` can be assigned by the function, and the final value is written back to the caller. `mutable` is required at the call as well, so a write is visible where it happens.

```silver
def advance(mutable c: Counter, by: Int): Int {
    c.value += by
    c.value
}

mutable val counter = Counter(0)
val now = advance(mutable counter, 2)
```

- The argument must be a place: a `mutable val`, a mutable parameter, or a field path rooted at one (`mutable state.counter`). An array element or a `?.` path isn't a place.
- Its type must be exactly the parameter's type.
- A place is read when the call starts, after all arguments are evaluated, and is written when the call returns, including through `return` and `?`. So in `f(mutable c, g(mutable c))`, `f` sees `g`'s write. A plain argument naming the same variable is a snapshot.
- Two `mutable` arguments of one call can't overlap, which means neither path may be a prefix of the other. Disjoint fields are fine.
- Mutability is part of a function type: `(mutable Counter) -> Int`. A lambda can take a mutable parameter: `(mutable c) => ...`.
- A native function can't take one.

## Method-call syntax

`x.f(args)` means `f(x, args)` when `x` is a value with no field named `f`. A field always wins, even one that can't be called.

```silver
def scaled(p: Point, factor: Int): Point => Point(p.x * factor, p.y * factor)

val bigger = point.scaled(2)
```

`f` is looked up as a plain name would be, but only module-level functions are candidates. Constructors, conversions and constants aren't.

The receiver behaves as any first argument does. It takes part in overload selection, and it adapts and promotes like any argument. A value is promoted after the field lookup, which uses its own type. So with `f(x: Int?)`, `value.f()` works on an `Int`. Promotion only wraps, so `optional.f()` with `f(x: Int)` is an error, for which `?.` is the appropriate form.

## Overloading

Functions can be overloaded on all of their parameters, and `f(x)` and `x.f()` choose in the same way.

```silver
def describe(x: Int): String => "Int {x}"
def describe(x: String): String => "String {x}"
def describe<T>(xs: [T]): String => "{length(xs)} values"

describe(1)        // describe(Int)
describe("a")      // describe(String)
describe([true])   // describe<T>([T])
```

- Two `def`s of one name in a scope are allowed when their parameter types differ. A different return type doesn't make them differ, and neither does `mutable` alone, an alias of the same type, or other names for the type parameters.
- A local or parameter holding a function wins outright and isn't overloaded.
- The type a call is expected to have never makes one function better than another, since functions aren't overloaded on their return type. What it gives a type parameter has to suit the arguments, though, so it can rule a function out.
- A [bound](interfaces.md#bounds) takes no part. Two functions with the same parameter types are duplicates whatever their bounds, and the bounds of the function chosen are checked afterwards, so one that fails is an error at the call and never passes the call to another function; see [Interfaces](interfaces.md#choosing-a-function).
- Inside a function with a bound, the functions the bound supplies are among the current module's.

A call chooses among the functions of its name like this:

1. Only those taking as many arguments are candidates, and as many type arguments when some are written. If that leaves one, it's called as a function with no overloads would be.
2. Each argument that has a type of its own is typed, once. Some arguments' types depend on where they go, and those are compared with each candidate's parameter by their shape instead: literals, `None`, `[]`, lambdas without their result type written, names of generic or overloaded functions, [arithmetic on literals](numbers.md#literals), arrays, tuples and `Some`s made only of these, and `if`s, `match`es and blocks whose values are all of these. An arm that can't finish, because it ends in `return`, `break`, `continue` or `tail`, has no value to count, and a block's earlier statements don't count. Such an `if` fits a parameter as well as its worst-fitting value does. They're checked against the chosen function's parameters afterwards. A lambda fits a function parameter that takes as many parameters as it does, with the types it annotates.
3. Each generic candidate's type parameters are bound as a call of it alone would bind them, by [inference](generics.md#inference), in a trial that records nothing, so the choice and the call can't disagree. An argument compared by its shape binds what it would be given on its own, so `[Some(1), None]` binds as an `[Int?]`, and a lambda binds what its annotations say. A bound that holds binds what its interface's parameters say, as in inference, and one that fails doesn't rule the candidate out. The expected type binds too, and the arguments have to suit what it binds, but it never makes one candidate better than another.
4. A candidate fits when every argument [fits](types.md#steps) its parameter, and costs the number of steps that takes, per argument. A candidate that fits every argument beats another if it costs no more for each argument and less for one, so with `type Held = :Box<Int> | :Box<String>`, `g(Box(1))` calls `g(b: Box<Int>?)`, one step, rather than `g(h: Held?)`, two. When two fit every argument equally well, a function that isn't generic beats a generic one, and a generic function beats another that takes everything it takes, as `f<T>(x: [T])` beats `f<T>(x: T)`.
5. If no candidate fits, or more than one fits better than all the others, the call is an error. When nothing fits only because of what the expected type bound, the choice is made again without it, and the argument is then an error against the one chosen, as it would be with no overloads.
6. The bounds of the function chosen are checked. A lambda is typed before that, so a bound on its result is checked like any other.

The current module's functions come first. Imported functions are only tried when none of the current module's fits, and then every imported function of the name is ranked together, by step 4, whichever import brings it. If two fit equally well, the call is ambiguous, and qualifying it resolves that. A function is the same function however it's reached, so one that arrives through two imports counts once.

```silver
import shapes    // def encode(s: Square): String
import encoding  // def encode<T>(x: T?): String

encode(Square(2))  // shapes.encode, which fits exactly
encode(Circle(1))  // encoding.encode, the only one that fits
```

So an import, or a new overload in a library, never changes which of the current module's own functions a call means. Among imported functions, a new overload that fits a call better than the one it reached takes the call, as it would if one module declared both, and one that fits equally well makes the call ambiguous. It also means a module can declare its own `printl(p: Point)` and still call `lang`'s `printl` with anything else.

An overloaded function used as a value is the one whose type is exactly the expected type, so it needs one:

```silver
val show: (String) -> String = describe
```

## Operator functions

Syntax that isn't a call means a call to a function whose name starts with `op`. Writing that function for a type gives the type the syntax.

| Syntax | Means |
| --- | --- |
| `x[i]` | `opIndex(x, i)` |
| `x[i] = v` | `x = opIndexAssign(x, i, v)` |
| `x[a..b]` | `opIndex(x, a..b)` |
| `x[a..b] = v` | `x = opIndexAssign(x, a..b, v)` |
| `a == b`, `a != b` | `opEquals(a, b)` |
| `a < b`, `<=`, `>`, `>=` | `compare(a, b)`, through the type's conformance to [`Ord`](types.md#ordering) |
| printing, `String(x)`, a string hole | `opString(x)` |

```silver
type Window<T>(items: [T], from: Int, to: Int)

def length<T>(w: Window<T>): Int => w.to - w.from
def opIndex<T>(w: Window<T>, index: Int): T => w.items[w.from + index]
def opIndexAssign<T>(w: Window<T>, index: Int, value: T): Window<T> {
    mutable val items = w.items
    items[w.from + index] = value
    w with (items = items)
}
def opIndex<T>(w: Window<T>, part: Interval<Int>): Window<T> =>
    Window(w.items, w.from + part.from, w.from + part.to)
```

- The result of `x[i]` and of `x[a..b]` is whatever the function returns.
- `opIndexAssign` returns the changed value, which is assigned back, so it takes and returns the type of `x`. An assignment through several steps is built from the inside out: `grid[y][x] = v` means `grid = opIndexAssign(grid, y, opIndexAssign(grid[y], x, v))`. A field can be a step too, so `game.board[i] = v` gives `game` a new `board`.
- Each index on the way is evaluated once, from the root out, then `v`, and only then is the place read and written.
- `x[i] += 1` reads with `opIndex` and writes with `opIndexAssign`, so both have to take `i` as one type. Each step on the way is read once, so `grid[y][x] += 1` calls `opIndex(grid, y)` once.
- Slicing is indexing by an [`Interval`](arrays.md#ranges), so a type is sliced by writing an `opIndex` that takes one, and a slice is assigned to through an `opIndexAssign` that takes one, in every form: `x[a..b] = v` and a held `x[r] = v` mean the same. A type without one can't be sliced, and `x[a..b]` on it is an error that says so. Two literal bounds take the interval type the function asks for, as a literal argument does, so `x[0..2]` passes an `Interval<UInt8>` to an `opIndex` that takes one; otherwise `a..b` is typed as it is anywhere.
- A slice with a bound left out uses `length`: `x[a..]` is `opIndex(x, a..length(x))`, with `x` evaluated once, and `x[..b]` is `opIndex(x, 0..b)`. The `opIndex` has to take that interval's type exactly. `length` returns an `Int`, so in `x[a..]` the start is an `Int` too.
- An `opIndex` whose index is a type parameter takes an interval as any other key: for a `Table<K, V>` with `K` an `Interval<Int>`, `t[9..11]` looks up the key `9..11`.
- For an array the syntax is built in, and an integer index is an `Int`. `lang`'s `opIndex` and `opIndexAssign` for arrays do the same where a function is wanted, and its `opIndex` that takes an `Interval<Int>` slices. `x[i]` on an array with an integer index, and `x[a..b]` written out, never call a module's own. With an index of another type, `x[i]` calls `opIndex(x, i)`, as for any type.

### How syntax finds its function

Syntax finds its function in one of three ways, by what the syntax is for:

- **Indexing is a call.** `x[i]`, `x[i] = v` and slices mean the calls in the table, chosen where they're written as any call is, just as `x.f()` means `f(x)`. So indexing a type needs its `opIndex` in scope, as calling `x.length()` needs `length`, and a module can write one for a type it didn't declare. No [conformance](interfaces.md#conformance) is involved.
- **Looping and ordering go through a conformance.** `for` steps with the `next` of the type's conformance to [`Range`](control-flow.md#for), and `<` compares with the `compare` of its conformance to [`Ord`](types.md#ordering). A conformance is one answer for the whole program, so a loop or a comparison means the same wherever it's written, in a generic function too, where a bound asks for it.
- **Equality, hashing and printing belong to the type.** Every type has an `opEquals`, an `opHash` and an `opString` already, so generic code needs no bound to use them, and only the type's own module can write one to replace it.

```silver
import grid : Grid, make       // the type and `make`, but not grid's `opIndex`

val g = make()
g == make()                    // fine: equality belongs to the type
for cell in g { ... }          // fine: grid declares `conform Grid: Range<Int>`
g[1]                           // error: `x[i]` calls `opIndex`, and no `opIndex` here takes a `Grid`
```

### Equality and hashing

`opHash(x): UInt64` is the hash a [map](maps.md) uses for its keys. Values that are equal have to hash alike, so a type that replaces `opEquals` replaces `opHash` too, and writing one without the other is an error.

```silver
def opEquals<K, V>(a: Map<K, V>, b: Map<K, V>): Bool {
    if length(a) != length(b) { return false }
    for (k, v) in a {
        if b[k] != Some(v) { return false }
    }
    true
}
def opHash<K, V>(m: Map<K, V>): UInt64 => ...      // combines the entries in any order
```

Structural equality is right for nearly every type. These functions are for a type whose fields can differ for values that mean the same thing, such as a collection whose layout depends on the order it was built in. A comparison that ignores part of a value, such as positions in source or the case of a name, is an ordinary function, passed where it's needed, and not a replacement for `==`.

A function that's useful to call by name keeps a plain name, even where syntax uses it: `length`; `next`, which `for` calls through the type's conformance to [`Range`](control-flow.md#for); and `compare`, which `<` calls through its conformance to [`Ord`](types.md#ordering).

## Open questions

- Whether `x.f()` can drop its parentheses.
- Whether a method call can have a `mutable` receiver.
- Method calls through `?.`, as in `a?.f()`.

## Current implementation

- A nested function can call itself and those declared before it, but not one declared after it.
- Of the operator functions, `opIndex` and `opIndexAssign` are available. `opEquals`, `opHash` and `opString` aren't, so `==` and printing are always the structural ones. [`Ord`](types.md#ordering), `Ordering` and `derivedCompare` aren't built, so `<` works only on numbers, strings and characters. A `for` still finds `next` by name, as [Control flow](control-flow.md#current-implementation) describes.
- Only module-level functions can be overloaded. Two nested `def`s of one name in a block are an error.
- When more than one candidate is left, an `if`, `match` or block is typed before any is chosen, even when its values are all literals, so it doesn't adapt to the chosen parameter: `f(if c => 1 else 2)` gives an `Int` even if the only `f` it could fit takes a `UInt8`. A literal written directly as the argument does adapt.
- Of the arguments compared by their shape, `None` and `[]` count one step wherever they go.
- Arithmetic on literals isn't compared by its shape yet: it's an `Int`, as [Numbers](numbers.md#current-implementation) describes, so `f(1 + 2)` doesn't fit an `f(x: UInt8)`.
- A method call's receiver needs a type of its own, so `None.f()` and `[].f()` are errors. An integer literal receiver adapts, as in `(200).f()` with `f(x: UInt8)`.
- Two native functions of one name in a module have to bind different C symbols, and two intrinsics can't share a name.
- A `mutable` first parameter is rejected for a method call. A later `mutable` argument is fine.
- `tail` isn't available.
