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
- A type parameter is in scope in the whole declaration: parameter and return types, the body, field types and sum members.
- Two type parameters of one declaration can't share a name, and a type parameter can't be named like a built-in type or like a type or alias declared in its own module. It hides an imported type of the same name, so a library that adds a type can't break a module that already uses the name as a parameter.
- A type parameter doesn't have to appear in the parameters. `def empty<T>(): [T] => []` is fine, and so is a type that never stores its parameter.

## Inside a generic declaration

A body is checked once, where it's written, with each type parameter standing for a type about which nothing is known. Whatever passes there works for every type argument, so an error never appears inside an instance.

A value whose type is `T` can be bound, passed, returned, stored and captured. Any type can be built from `T`: `T?`, `[T]`, `(T, Int)`, `(T) -> T`, `Box<T>`. Promotion works as usual, so a `T` is accepted where a `T?` is expected.

Nothing else is known about `T`, so:

- `T` is assignable only to itself. A literal can't be a `T`.
- A type that mentions a type parameter isn't ordered. `<` on a `T` is an error.
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

A function that needs an order takes it as a parameter for now, as `larger` does below.

## Generic types

A generic type is named with its arguments, as in `Box<Int>` or `Result<Int, String>`. `Box<Int>` and `Box<String>` are different types.

- The number of arguments has to match. `Box` alone isn't a type, and arguments on a type that takes none are an error.
- A type argument can be any type except `Any`.
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

They can also be written out, after the name. It's all of them or none:

```silver
val e = empty<Int>()
val b = Box<UInt8>(1)
```

Type arguments on a constructor are those of the type it names, so `Ok<Int>(1)` names the member `Ok<Int>`.

### Inference

When type arguments aren't written, each type parameter is found from the call alone, in this order:

1. The arguments that have a type of their own, left to right. An argument of type `A` where `T?` is expected gives `T = A`, unless `A` is an option.
2. The expected type, where there is one, for any parameter still unknown. It's matched against the return type.
3. The remaining arguments: integer literals, lambdas, `None` and `[]`. A literal whose type is still open takes its default type. A lambda needs its parameter types to be known by now, or annotated, and its body then gives its return type. When the parameter returns an option, as in `(S) -> (T, S)?`, that return type is an option too, so a body ending in `(a, b)` returns `Some((a, b))`, just as it would if the type were written out.

The first thing that determines a parameter decides it. There is no search for a common type, so `pair(1, 2.0)` with `pair<T>(a: T, b: T)` is a type mismatch at the second argument.

Once the parameters are known, every argument is checked against its parameter type in the ordinary way, so literals adapt and values promote:

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

A generic function that calls itself with an ever larger type, such as `def grow<T>(x: T): Unit => grow([x])`, would need endlessly many instances. Instances nested too deeply are an error that shows the chain.

## Open questions

- Bounds: saying what a type parameter can do, as in `T: Ord` or `T: Json`, so generic code can order values and use functions written for them. This is the interfaces design, which isn't settled. See [the proposal](../proposals/interfaces.md).- A type parameter as a sum member by itself, as in `type Maybe<T> = T | Nothing`.
- Generic aliases, as in `alias Pair<T> = (T, T)`.
- Type parameters on a nested `def`.
- Leaving some type arguments to inference, as in `convert<_, Int>(x)`.
- Value parameters, as in `def pow<n: Int>(x: Float)`, with compile-time evaluation.
- Whether `Option` becomes an ordinary generic sum in the prelude, with `T?` as its spelling.
- Inferring a common type when arguments disagree, which waits on the same decision for integers widening.

## Current implementation

- A value whose type mentions a type parameter can't yet be compared with `==`, printed, converted with `String(x)` or put in a string hole. Each is an error, and a function that needs one takes it as a parameter.
- Type arguments can nest 64 deep. Past that the program doesn't compile, and the error shows the instances, or the type, that led there.
- An alias of an instance, as in `alias IntBox = Box<Int>`, is a type like any other, but its name can't build a value: write `Box<Int>(1)`.
- Inference treats two more kinds of argument as having no type of their own, as `None` does: a marker that a generic sum owns, such as `Nil`, and a generic function or constructor named without its type arguments. Each binds nothing, and is checked once the type arguments are known.
- In step 1, an argument whose parameter type is already known when its turn comes is checked against it rather than given a type of its own, so with `f<T>(a: T, b: [T])`, `f(small, [1, 2])` adapts the literals to `small`'s type.
- In step 3, a lambda whose parameter types aren't known at its turn is tried again after the arguments that follow it.
- Interpreted, a function value that's an instance prints as its function's name, without type arguments.
