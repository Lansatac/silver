# Generics

A function or a type can take type parameters, written in `<>` after its name. A type parameter is a type name, so it's capitalized.

```silver
def first<T>(values: [T]): T? => if length(values) == 0 => None else values[0]

type Box<T>(value: T)
type Pair<A, B>(left: A, right: B)
type Result<T, E> = Ok(value: T) | Error(error: E)
type List<T> = Cons(head: T, rest: List<T>) | Nil
```

Each use with different type arguments is a separate instance, compiled for exactly those types. Nothing is decided by looking at a type while the program runs.

## Type parameters

- A `def` at module level and a `type` can declare type parameters. So can an `intrinsic def`. A lambda, a nested `def`, a `native def`, an `alias` and `main` can't. A nested `def` or lambda can use the type parameters of the function it's written in.
- A type parameter of a module-level `def` can have bounds, as in `<T: Json>`, which say what its values can do. See [Interfaces](interfaces.md#bounds).
- A type parameter is in scope in the whole declaration: parameter and return types, the body, field types and sum members.
- Two type parameters of one declaration can't share a name, and a type parameter can't be named like a built-in type or like a type or alias declared in its own module. It hides an imported type of the same name, so a library that adds a type can't break a module that already uses the name as a parameter.
- A type parameter doesn't have to appear in the parameters. `def empty<T>(): [T] => []` is fine, and so is a type that never stores its parameter.

## Inside a generic declaration

A body is checked once, where it's written, with each type parameter standing for a type about which nothing is known. Whatever passes there works for every type argument, so an error never appears inside an instance.

A value whose type is `T` can be bound, passed, returned, stored and captured. Any type can be built from `T`: `T?`, `[T]`, `(T, Int)`, `(T) -> T`, `Box<T>`. Promotion works as usual, so a `T` is accepted where a `T?` is expected.

Nothing else is known about `T`, unless it has a [bound](interfaces.md#bounds), which supplies its interface's functions. So:

- `T` is assignable only to itself. A literal can't be a `T`.
- A `T` isn't ordered, so `<` on one is an error, unless its bound is [`Ord`](types.md#ordering).
- A pattern on a `T` can only bind it.

Comparing with `==` and printing do work on a `T`, because every type has both. Each instance uses its type's own:

```silver
def contains<T>(values: [T], wanted: T): Bool {
    for value in values {
        if value == wanted { return true }
    }
    false
}
```

A function that needs an order asks for it with a bound, as in `def smaller<T: Ord>(a: T, b: T): T => if a < b => a else b`, or takes a comparison as a parameter, as `larger` does below.

## Generic types

A generic type is named with its arguments, as in `Box<Int>` or `Result<Int, String>`. `Box<Int>` and `Box<String>` are different types.

- The number of arguments has to match. `Box` alone isn't a type, and arguments on a type that takes none are an error.
- A generic type may refer to itself with its own parameters, as `List<T>` does above. The rule that a value must be buildable is checked at the declaration, assuming every type parameter can be built.

In a sum, a member declared inline takes the sum's parameters that it mentions, in the sum's order. In `Result<T, E>` the members are `Ok<T>` and `Error<E>`, and in `List<T>` they are `Cons<T>` and plain `Nil`. So the members of `Result<Int, String>` are `Ok<Int>` and `Error<String>`.

Fields, `with`, `match` and promotion into a sum work on an instance as they do on any declared type, with the arguments filled in.

## Using a generic

Type arguments are usually inferred:

```silver
val b = Box(1)                          // Box<Int>
val n = first([1, 2, 3])                // Int?
val r: Result<Int, String> = Ok(1)
```

They can also be written out, after the name. It's all of them or none, not counting the one that stands behind a parameter whose type is an [interface name](interfaces.md#an-interface-name-as-a-parameter-type):

```silver
val e = empty<Int>()
val b = Box<UInt8>(1)
```

Type arguments on a constructor are those of the type it names, so `Ok<Int>(1)` names the member `Ok<Int>`.

A constructor pattern can write them too, and then matches only that instance. Without them it takes the instance from the value it matches, which has to be able to be only one instance. Writing them tells apart members of one generic type, as in a sum like `type Held = :Box<Int> | :Box<String>`, and an instance the value can't be is an error. See [match](user-types.md#match).

An alias of an instance gives its type arguments wherever its name is used: in a call, as a function value and in a pattern. The alias isn't generic itself, so no type arguments can be written after it.

```silver
alias IntBox = Box<Int>
val b = IntBox(1)                       // Box<Int>
val wrap = IntBox                       // (Int) -> Box<Int>
```

### Inference

A type parameter is bound by matching an argument's type against its parameter's type structurally: `[Int]` against `[T]` gives `T = Int`, and `(Int, String)` against `(A, B)` gives both. The one allowance is that an option or error-union layer on the parameter may be peeled off, since a value promotes into it:

- `A` against `T?` gives `T = A`, unless `A` is an option.
- `A` against `T ! E` gives `T = A`.
- A promotion into a sum never binds. With `type W<T> = :Box<T> | Empty`, a `Box<Int>` against `W<T>` binds nothing, so `g(Box(1))` for `g<T>(w: W<T>)` is an error. `g<Int>(Box(1))` works, and so does a binding with a type first, as in `val w: W<Int> = Box(1)`.

When type arguments aren't written, each type parameter is found from the call alone, in this order:

1. The arguments that have [a type of their own](types.md#a-type-of-its-own), left to right.
2. The bounds whose type is known by now. The type's conformance says what its interface's own type arguments are, as with `R: Range<T>`; see [Interface parameters](interfaces.md#interface-parameters).
3. The expected type, where there is one, for any parameter still unknown. It's matched against the return type. A return type that is only a type parameter takes it whole, so `val v: Int? = id(None)` gives `T = Int?`. Any other return type that isn't itself an option or error union is matched inside the one expected, since its value promotes into it: against `Box<Int>?`, a return type of `Box<T>` gives `T = Int`. The layer `!` or `?` removes is part of what's expected (see [Errors](errors.md#whats-expected-of-the-operand)).
4. The remaining arguments, those with no type of their own, left to right in the order they're written, each when its turn comes. One whose parameter type is known by now is checked against it, which passes that type into it. One whose parameter type is still open takes what it would be with nothing expected, a literal its default type, and binds that. One that can't be typed yet, as a lambda whose parameter types aren't known or a `Box([])` whose parameter is still open, is tried again after the arguments that follow it. A lambda takes its parameter types from a parameter type that's known that far, as `(Int) -> U` is with `U` still open, and its body gives its return type. Nothing else reads part of a type: a generic or overloaded function's name needs the whole function type, so `map(xs, dbl)` with an overloaded `dbl` is an error, written `map(xs, x => dbl(x))`. When the parameter returns an option, as in `(S) -> (T, S)?`, that return type is an option too, so a body ending in `(a, b)` returns `Some((a, b))`, just as it would if the type were written out.

Literals that reach the same type parameter [take one type together](numbers.md#literals), so `pair(1, 2.0)` is a pair of `Float`s and `pick(1.5, [2])` with `pick<T>(x: T, xs: [T])` is a `[Float]`.

The first thing that determines a parameter decides it, and an argument with a type of its own always comes before one without. So with `n: Int`, `two(opt(1, None), n)` for `two<T>(a: T, b: T)` is an error: `n` makes `T` an `Int`, and `opt(1, None)` can only be an option. `two(opt(1, None), Some(n))` and `two(opt(1, None), 2)` are `[Int?]`s. There is no search for a common type, so `pair("a", 2.0)` with `pair<T>(a: T, b: T)` is a type mismatch at the second argument.

[Overload choice](functions.md#overloading) binds each candidate in this same order, as a trial that records nothing, so the function chosen is bound as the call then binds it.

Once the parameters are known, every argument is checked against its parameter type with the ordinary [fit](types.md#steps), so literals adapt and values promote there, and only there:

```silver
def larger<T>(a: T, b: T, less: (T, T) -> Bool): T => if less(a, b) => b else a

val small: UInt8 = 3
val m = larger(1, small, (a, b) => a < b)     // T = UInt8, and the 1 adapts
```

A parameter that nothing determines is an error asking for it to be written out, as with `val xs = empty()`.

A constructor of a member that a sum owns produces the sum, so every parameter of the sum has to be found. `Ok(1)` alone leaves `E` unknown and needs an expected type. `Nil` alone is the same error as a bare `None`.

### Function values

A function value always has one type. A generic function or constructor used as a value needs its type arguments written, or an expected function type to take them from:

```silver
val unwrap: (Box<Int>) -> Int = valueOf
val wrap = Box<Int>
```

### Method-call syntax

`x.f(args)` works with a generic `f`. The receiver is the first argument for inference.

## Limits

Each instance is compiled for its own types, so a generic function can need itself again, directly or through other functions, only at type arguments that don't grow: its type parameters passed along or swapped, types that don't mention them, or an error list that adds fixed errors to a type parameter's, as in `E | Oops`, since a list holds each error once. One that needs itself at a larger type would need endlessly many instances, so it's an error at the call that makes the type grow, which shows the instances it would lead to. It's an error whether or not anything calls the function.

```silver
def same<T>(x: T, n: Int): Int => if n == 0 => 0 else same(x, n - 1)            // fine
def swap<A, B>(a: A, b: B, n: Int): Int => if n == 0 => 0 else swap(b, a, n - 1)  // fine
def grow<T>(x: T): Unit => grow([x])        // error: `grow<T>`, then `grow<[T]>`, then `grow<[[T]]>`, ...

// fine: at `E = Other`, `E | Oops` is `Other | Oops`, and at that, `Other | Oops` again
def tries<E>(r: Int ! E, n: Int): Int ! E | Oops {
    if n == 0 { return r? }
    val widened: Int ! E | Oops = r
    tries(widened, n - 1)
}
```

The same goes for everything else an instance needs at types that come from it: the functions of the conformances that meet its bounds, and the `next`, `length` and `opIndex` a `for` loops with.

Both branches of an [`if type`](interfaces.md#asking-whether-a-type-conforms) count, whichever an instance takes, so the rule is read from declarations alone.

A generic type is the same: it can hold itself, in a field or as a member, directly or through other types, only at type arguments that don't grow. One that holds a larger instance of itself would need endlessly many types, so it's an error at the type that grows, whether or not anything uses it.

A function-typed field that grows is rejected too, though nothing calls through it.

```silver
type List<T> = Cons(head: T, rest: List<T>) | Nil         // fine
type Flip<A, B>(next: Flip<B, A>?, value: A)               // fine
type Grow<T> = More(rest: Grow<(T, T)>, head: T) | Stop    // error: `Grow<T>`, then `Grow<(T, T)>`, then ...
```

## Open questions

- A type parameter as a sum member by itself, as in `type Maybe<T> = :T | Nothing`.
- Generic aliases, as in `alias Pair<T> = (T, T)`.
- Type parameters on a nested `def`.
- Leaving some type arguments to inference, as in `convert<_, Int>(x)`.
- Default type arguments, as in `def make<R: Seedable = Xoshiro256>(seed: UInt64): R` or `type Pair<A, B = A>`: what a parameter is when nothing else decides it.
- Value parameters, as in `def pow<n: Int>(x: Float)`, with compile-time evaluation.
- Whether `Option` becomes an ordinary generic sum in the prelude, with `T?` as its spelling.
- Inferring a common type when arguments disagree, which waits on the same decision for integers widening.

## Current implementation

- Type arguments that don't grow without end can still nest only 64 deep. Past that the program doesn't compile, and the error shows the instances, or the type, that led there.
- Which arguments wait for step 4 is decided by a list of forms, not by whether the argument has [a type of its own](types.md#current-implementation): number literals, `None`, `[]`, `[:]`, lambdas, a marker that a generic sum owns and a generic function or constructor named without its type arguments wait. An array, tuple, dictionary or `Some` of literals, an `if`, a block, arithmetic and a generic call that leaves a type parameter open are typed alone in step 1, and a bare `Error(e)` binds a type of its own there.
- In step 3, a return type that is only a type parameter takes an expected option's or error union's value type, not the whole of it, so `val v: Int? = id(None)` is an error.
- In step 1, an argument whose parameter type is already known when its turn comes is checked against it rather than given a type of its own, so with `f<T>(a: T, b: [T])`, `f(small, [1, 2])` adapts the literals to `small`'s type.
- In step 4, only a lambda that can't be typed at its turn is tried again after the arguments that follow it, and a bound that can now be solved is. An integer literal, and an array, tuple, `Some` or dictionary literal made only of literals with an integer literal in it, waits for a float literal among the arguments, which is the only place literals take a type together.
