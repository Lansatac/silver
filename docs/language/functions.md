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

Functions at the top level of a module can be used before they are declared. A function nested in a block has the same form as a top-level one, and is equivalent to binding a lambda to a local.

`return` exits the innermost function or lambda. A bare `return` returns `()`.

`native def` declares a function implemented outside Silver. It has a signature and no body.

## Tail calls

`tail f(args)` exits the innermost function or lambda with the result of the call, as `return f(args)` would, except that the call reuses the current call's stack space. Recursion through `tail` therefore runs at any depth.

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

A constructor can also be used as a function value. Function values aren't comparable.

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

Functions can be overloaded on all of their parameters, and `f(x)` and `x.f()` select in the same way.

- A local or parameter holding a function wins outright and isn't overloaded.
- Candidates in the current module are tried before imports, so a new overload in a library can at worst cause an ambiguity error and can never silently change a call.
- Two `def`s of one name in a scope are allowed when their parameter types differ.

## Open questions

- Details of overload selection, as currently proposed: no overloading on the return type or on `mutable` alone; each argument is typed at most once; arguments with a type select first, and a lambda is then checked against the one remaining candidate; exact matches beat adaptation and promotion, and a literal prefers its default type; two equally good matches are an error; a function used as a value needs an expected type when overloaded.
- Whether `x.f()` can drop its parentheses.
- Whether a method call can have a `mutable` receiver.
- Method calls through `?.`, as in `a?.f()`.
- Whether `tail` can call any function, or only the function it appears in.

## Current implementation

- A nested function can call itself and those declared before it, but not one declared after it.
- Overloading isn't available, so every call is resolved by name alone.
- In a method call, the receiver must be exactly the first parameter's type, with no adaptation or promotion, and its type doesn't choose between functions.
- A `mutable` first parameter is rejected for a method call. A later `mutable` argument is fine.
- A native function can't be used as a function value in compiled programs.
- `tail` isn't available.
