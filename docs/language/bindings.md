# Bindings

## Immutable and mutable

```silver
val width = 10                // immutable
val height: Int = 20          // with a type
mutable val count = 0         // can be rebound
mutable val total: Int = 0
```

An annotation is a type. An [interface](interfaces.md#only-in-a-signature) isn't one, so `val xs: Range<Int> = [1, 2, 3]` is an error: leave the annotation off, or write `[Int]`.

Mutability belongs to the binding, never to the type. A `mutable val` can be rebound and can have its fields assigned, including through a path. A `val` can do neither.

```silver
mutable val p = Point(1, 2)
p.x = 3
p = Point(4, 5)

mutable val line = Line(Point(0, 0), Point(1, 1))
line.start.x = 2
```

A value behaves as a copy. After `mutable val p = q` and `p.x = 3`, `q` is unchanged. Sharing is never observable. Shared mutable identity is not part of the language's value model.

A `mutable val` of an option type can omit its initializer and starts as `None`. Any other binding needs an initializer.

## Discarding

`val _ = value` evaluates `value` and binds nothing, and `_ = value` is shorthand for it. This is how a value is dropped on purpose. `_` also works in `if val`, `while val`, `for`, destructuring, a tuple of assignment targets, and as a parameter of a function or lambda. It declares nothing, so any number can appear in one scope or parameter list. With no value kept, `_ = None` needs no type.

## Top-level constants

```silver
val limit: Int = 100
val doubled: Int = limit * 2
val greeting: String = "limit is {limit}"
```

A constant has a lowercase name, a required type annotation, and is reached like a function (`limit`, `some.module.limit`). Top-level bindings can't be mutable. Constants may refer to each other in any order, but not in a cycle.

The type must be `Bool`, an integer type, `Float`, `Float32`, `String` or `Unit`. The initializer may use literals, unary and binary operators, parentheses, string interpolation and other constants. It's evaluated at compile time under the same rules as at runtime, so anything that would panic is a compile error.

## Shadowing

Silver largely forbids shadowing, so an ambiguity needs a different name or a qualifier:

1. Two declarations of a name in one scope are an error.
2. A local or parameter can't shadow another local or parameter of the same function.
3. The same name in sibling blocks is fine.
4. A local can be named like a function or constant of its own module, or like an imported name, and the local wins in its scope. A [method call](functions.md) still finds the function: with a local `count`, `xs.count()` is the module's `count`.
5. A local can be named like the root of an imported module path, and the local wins there. A function or constant can't, so qualified access works everywhere outside such a local's scope.

Rebinding a `mutable val` isn't shadowing, and a new `val` per loop iteration is a fresh binding.

Rule 6 lets a function take a parameter named after the module that defines its type. Inside its scope, `cards.f` is a [method call](functions.md) on the local, and the module's names are still reached bare. A qualified type such as `cards.Card` is still the module's, since a local is never a type.

```silver
import cards

def show(cards: [Card]): Unit {
    printl(cards.describe())             // describe(cards)
    val first: cards.Card = cards[0]     // the module's type
}
```

When `x.f` fails and `x` hides a module that has an `f`, the error says so:

```
Type `[Card]` has no member named `handSize`
    `cards` here is a local, which hides the module `cards`; rename the local to use `cards.handSize`
```

## Open questions

- Constants of richer types, which depends on compile-time evaluation.

## Current implementation

The implementation matches this description.
