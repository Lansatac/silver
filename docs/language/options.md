# Options

Silver has no null. Absence is an option, written `T?`, whose values are `Some(x)` and `None`.

```silver
val present: Int? = Some(1)
val promoted: Int? = 1
val absent: Int? = None
```

A type carries at most one `?`. A nested option is written with parentheses, `(Int?)?`.

## Typing

`T` promotes to `T?`, never the reverse. When a literal is checked against `T?`, it adapts to `T` first, so `val limit: UInt8? = 255` works, and `Some(255)` checks its argument against `UInt8`.

`None` needs a type from context. It works with `if` arms, so `if c => Some(1) else None` is an `Int?`, and `if c => 1 else None` is too. `val x = None`, `printl(None)` and `None == None` are errors because nothing supplies a type.

Nothing collapses. `Some(None)` is distinct from `None`, and `(Int?)?` is distinct from `Int?`.

## Unwrapping

`if val` and `while val` unwrap an option. See [Control flow](control-flow.md).

`match` handles options with the patterns `Some(p)` and `None`. See [User types](user-types.md).

### Default: `??`

`a ?? b` is the payload of `a`, or else `b`, which is evaluated only when needed.

With `a: T?`, the result is:

- `T?` if `b` is syntactically `Some(...)` or `None`
- `T` if `b` has type `T`, even when `T` is itself an option
- `T?` if `b` is any other option
- otherwise `T`, with `b` checked against `T` and literals adapting

`??` is right-associative, sits between comparison and bit-or, and binds tighter than `..`. So `a ?? b + 1` is `a ?? (b + 1)`, and `a ?? b == c` is `(a ?? b) == c`.

### Early exit: postfix `?`

`x?` is the payload of `x`. If `x` is `None`, the enclosing function or lambda returns `None`. The enclosing function must return some `U?`.

```silver
def sum(a: Int?, b: Int?): Int? {
    val first = a?
    val second = b?
    first + second
}
```

A bare `x?` used only to exit early must be written `_ = x?`, like any unused value.

`?`, `??`, `if val` and `?.` work on an error union, `T ! E`, as well. See [Errors](errors.md).

### Asserting: postfix `!`

`x!` is the payload of `x`. If `x` is `None`, the program panics at that line, showing `x` as written:

```silver
val port = lookup("port")!
```

```
panic: server.ag(4,16): `lookup("port")` was None
```

It's how a caller says that a missing value here would be a bug. It follows its operand on the same line. See [Errors](errors.md#asserting-it-worked-).

### Through a value: `?.`

`a?.b` with `a: T?` and a field `b: U` is `U?`. If the field is already `U?`, the result stays `U?`, so `a?.b?.c` is one flat option. For a field, `T` must be a declared type, so `?.` doesn't reach through nested options, and a `?.` path can't be assigned through.

`a?.f(args)` is the [method call](functions.md#method-call-syntax) `a.f(args)` on `a`'s value, with its result typed as a field's would be. When `a` is `None`, `args` aren't evaluated:

```silver
def twice(x: Int): Int => x * 2
def positive(x: Int): Int? => if x > 0 => x else None
def say(x: Int): Unit => printl(x)

val some: Int? = 3
val none: Int? = None
some?.twice()        // Some(6)
some?.positive()     // Some(3), not Some(Some(3))
none?.twice()        // None
some?.say()          // prints 3
```

A `?.` whose field or call gives `Unit` can stand as a statement, since all it drops is whether it ran. One whose call gives a `Unit?` of its own can't, since that `None` means something.

Whether the result is wrapped again depends on the types as the code is written, so in a generic function, `x?.f()` with `f` giving a `T` is a `T?` even where `T` is itself an option.

`?.` binds as tightly as `.`, so `x?.f()` is a call through `?.`, not `x?` followed by `.f()`. To pass on `x`'s absence first and call `f` on what's left, write `(x?).f()`.

## Equality and ordering

`==` and `!=` work on `T?`. When exactly one side is an option, the other is checked against it and promoted, so `value == 3` and `value == None` both work. Ordering isn't defined on options.

## Current implementation

- `Some` can't be passed as a function value.
