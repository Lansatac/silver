# Functions

## Declarations

```silver
def area(width: Int, height: Int): Int => width * height

def describe(value: Int): String {
    val doubled = value * 2
    "twice {value} is {doubled}"
}
```

`=>` introduces one expression, and a block's last expression is its value. A named function always declares its parameter types and return type. A named function's return type is required even when it's `Unit`.

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

The receiver behaves as any first argument does. It takes part in overload selection, and it adapts and promotes one step. A value is promoted after the field lookup, which uses its own type. So with `f(x: Int?)`, `value.f()` works on an `Int`. Promotion isn't chained, and `optional.f()` with `f(x: Int)` is an error, for which `?.` is the appropriate form.

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
- The type a call is expected to have never chooses, since functions aren't overloaded on their return type.

A call chooses among the functions of its name like this:

1. Only those taking as many arguments are candidates, and as many type arguments when some are written. If that leaves one, it's called as a function with no overloads would be.
2. Each argument that has a type of its own is typed, once. Some arguments' types depend on where they go, and those are compared with each candidate's parameter by their shape instead: literals, `None`, `[]`, lambdas, names of generic or overloaded functions, and arrays, tuples and `Some`s made only of these. They're checked against the chosen function's parameters afterwards. A lambda fits a function parameter that takes as many parameters as it does, with the types it annotates.
3. An argument fits its parameter exactly, or by a conversion: promotion to an option, becoming a member of a sum, or a literal taking a type other than its default. A candidate that fits every argument beats another if it fits each argument at least as well and one of them better. When two fit every argument equally well, a function that isn't generic beats a generic one, and a generic function beats another that takes everything it takes, as `f<T>(x: [T])` beats `f<T>(x: T)`.
4. If no candidate fits, or more than one fits better than all the others, the call is an error.

The current module's functions come first. Imported functions are only tried when none of the current module's fits, and then the choice is made within one imported module. A module with a function that fits every argument exactly and isn't generic beats the other modules, whose functions would need a conversion or are generic. Otherwise only one imported module's functions may fit: if functions from two modules fit equally well, the call is ambiguous, and qualifying it resolves that.

```silver
import shapes    // def encode(s: Square): String
import encoding  // def encode<T>(x: T?): String

encode(Square(2))  // shapes.encode, which fits exactly
encode(Circle(1))  // encoding.encode, the only one that fits
```

So a new overload in a library can silently change a call only by fitting it exactly, without being generic, where another import's function needed a conversion or was generic. Anything else it adds can at worst cause an ambiguity error. It also means a module can declare its own `printl(p: Point)` and still call the prelude's `printl` with anything else.

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
| `x[a..b]` | `opSlice(x, a, b)` |
| `a == b`, `a != b` | `opEquals(a, b)` |
| `a < b`, `<=`, `>`, `>=` | `opCompare(a, b)` |
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
def opSlice<T>(w: Window<T>, from: Int, to: Int): Window<T> =>
    Window(w.items, w.from + from, w.from + to)
```

- The result of `x[i]` and of `x[a..b]` is whatever the function returns.
- `opIndexAssign` returns the changed value, which is assigned back, so it takes and returns the type of `x`. An assignment through several steps is built from the inside out: `grid[y][x] = v` means `grid = opIndexAssign(grid, y, opIndexAssign(grid[y], x, v))`. A field can be a step too, so `game.board[i] = v` gives `game` a new `board`.
- Each index on the way is evaluated once, from the root out, then `v`, and only then is the place read and written.
- `x[i] += 1` reads with `opIndex` and writes with `opIndexAssign`, so both have to take `i` as one type. Each step on the way is read once, so `grid[y][x] += 1` calls `opIndex(grid, y)` once.
- A slice with a bound left out uses `length`: `x[a..]` is `opSlice(x, a, length(x))`, with `x` evaluated once, and `x[..b]` is `opSlice(x, 0, b)`. The 0 is an `Int`.
- For an array the syntax is built in, and an index is an `Int`. The prelude's `opIndex`, `opIndexAssign` and `opSlice` for arrays do the same where a function is wanted. `x[i]` on an array never calls a module's own.

`opIndex`, `opIndexAssign` and `opSlice` are ordinary functions, chosen as any call is, so a module can write them for a type it didn't declare. `opEquals`, `opCompare` and `opString` belong to the type: every type has an `opEquals` and an `opString` already, and only the type's own module can write one to replace it, or write an `opCompare`.

A function that's useful to call by name keeps a plain name, even where syntax uses it: `length` and `next`, which `for` calls.

## Open questions

- What `opCompare` returns, whether a type gets one without writing it, and how `opEquals` and `opCompare` are kept in agreement.
- Whether `x.f()` can drop its parentheses.
- Whether a method call can have a `mutable` receiver.
- Method calls through `?.`, as in `a?.f()`.

## Current implementation

- A nested function can call itself and those declared before it, but not one declared after it.
- Function values aren't comparable yet.
- Of the operator functions, `opIndex`, `opIndexAssign` and `opSlice` are available. `opEquals`, `opCompare` and `opString` aren't, so `==` and printing are always the structural ones, and `<` works only on numbers and strings.
- Only module-level functions can be overloaded. Two nested `def`s of one name in a block are an error.
- When more than one candidate is left, an argument with a type of its own is typed before any is chosen, so it doesn't adapt to the chosen parameter: `f(if c => 1 else 2)` gives an `Int` even if the only `f` it could fit takes a `UInt8`. A literal written directly as the argument does adapt.
- A method call's receiver needs a type of its own, so `None.f()` and `[].f()` are errors. An integer literal receiver adapts, as in `(200).f()` with `f(x: UInt8)`.
- Two native functions of one name in a module have to bind different C symbols, and two intrinsics can't share a name.
- A `mutable` first parameter is rejected for a method call. A later `mutable` argument is fine.
- A native function can't be used as a function value in compiled programs.
- `tail` isn't available.
