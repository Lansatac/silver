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

A parameter can be written as a tuple pattern, which takes its argument apart: the names in it are the parts, and the tuple as a whole has no name. Its type is written after the pattern.

```silver
def area((width, height): (Int, Int)): Int => width * height

area((3, 4))        // 12: one argument, a tuple
```

- The pattern is what [`val` takes](tuples.md#destructuring): names, `_`, and tuples of those, at least two. The function's type is as if the parameter had a name: `area` is a `((Int, Int)) -> Int`.
- It can't be `mutable`, since there's no one place to write back to. A function of an interface, a `native def` and an `intrinsic def` take names only.

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
((name, age)) => age >= 18
(total, (_, age)) => total + age
```

So a named function is `def name` followed by a lambda, except that a named block body drops the arrow.

- The return type can always be omitted. It is inferred from the `return`s and the final value.
- Parameter types can be omitted when the context supplies a function type, such as an annotated binding, a call's parameter, or a field. Otherwise leaving them out is an error.
- Parentheses can be omitted only for a single untyped parameter.
- A call checks its non-lambda arguments first, so they can inform a lambda's parameter types.
- A parameter written as a [tuple pattern](#declarations) takes one tuple apart, and needs its own parentheses: `((name, age)) => ...` takes a pair, where `(name, age) => ...` takes two arguments. It's what a chain over pairs wants, as in `ages.iterate().filter(((_, age)) => age >= 18)`.
- A pattern's type comes from the context like any parameter's. Where nothing supplies it, a type is written on the whole, `((a, b): (Int, String)) => ...`, or on every part, `((a: Int, b: String)) => ...`. A type on only some parts is checked against those parts, as in a `val`, and doesn't say what the rest are.
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

`x?.f(args)` calls `f` on `x`'s value when `x` is an option or error union, and is otherwise `None` or `x`'s error, without evaluating `args`. Its type follows the [`?.` rule](options.md#through-a-value-), and on an error union, the errors of `x` and `f` are [listed together](errors.md#where-errors-meet):

```silver
val port = settings?.lookup("port")             // Int? when settings: Settings? and lookup gives Int?
val json = readFile("dub.json")?.parse()?        // passes on readFile's errors or parse's
```

A field `f` holding a function is called the same way.

## Type functions

A function can belong to a type rather than take a value of it. The type is written before its name, with a `.`, and it's called on the type the same way:

```silver
def Point.origin(): Point => Point(0, 0)
def Point.fromText(text: String): Point? => ...
def Int.fromText(text: String): Int? => parseInt(text)

val o = Point.origin()
val n = Int.fromText("12")
```

It's for a function that has no value of the type to be given, most often one that makes a value of it, and it's how an [interface](interfaces.md#a-type-only-in-the-result) asks for one.

- It's a module-level function in every other way: it can be private, generic and overloaded, and it can serve a conformance. A plain call `fromText(text)` doesn't reach it; only a call on a type does.
- Type functions of one name are overloads of each other, told apart by the type and then the parameters as usual, so `Point.fromText` and `Int.fromText` above are two. A type function and an ordinary function of the same name are never duplicates: `def Point.describe()` and `def describe(p: Point)` are both fine.
- The type at a call has to be the declared one, or an instance of it, since nothing promotes a type: `Circle.area()` doesn't reach `def Shape.area()` when `Circle` is a member of the sum `Shape`.
- In a declaration, any type can go before the `.`, as in `def [T].empty(): [T]` or `def T?.none(): T?`.
- A name in that type that isn't a type where the declaration is written is a type parameter, as in a [conformance](interfaces.md#conformance), and a bound is written on it there. The function's own type parameters follow its name:

  ```silver
  def Stack<T>.empty(): Stack<T> => Stack([])
  def Box<T: FromText>.fromText(text: String): Box<T>? => ...
  def Stack<T>.fromRange<R: Range<T>>(items: R): Stack<T> => ...
  ```

  Type arguments written at a call are the function's own. The type's come from the type the call names.
- At a call, what's before the `.` names a type: a type's name, qualified or not, an alias, a built-in type such as `Int`, a type parameter, or `Self` inside an interface. A generic type can have its arguments written, as in `Stack<Int>.empty()`, or leave them to [inference](generics.md#inference) as a constructor does, so `val s: Stack<Int> = Stack.empty()` works. A type written with punctuation, such as `[Int]` or `Int?`, can't be written there, since `[Int]` is an array: an alias or a type parameter names it.
- A name that's a type means the type before `.`, never its constructor, so `Point.describe()` calls the type function `describe` of `Point`, and passing the constructor is `describe(Point)`.
- A marker is a value, so `Unknown.f()` is a method call on that value, and a type function can't be declared for a marker: `def f(_: Unknown)` does the same, since the marker is the type's only value.
- `Point.fromText` without a call isn't a function value. `text => Point.fromText(text)` is one.
- In a generic function, a type parameter's bounds supply its type functions, called on the parameter as `T.fromText(text)`.

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

- Two `def`s of one name in a scope are allowed when their parameter types differ, or when they differ in which parameters are `mutable`. A different return type doesn't make them differ, and neither does an alias of the same type or other names for the type parameters.
- An argument passed as `mutable` fits only a `mutable` parameter, and one passed without it only a parameter that isn't, so the call says which of two such functions it means. That lets the pure and in-place forms of one operation share a name:

  ```silver
  def next(g: Gen): (UInt64, Gen)?      // as a range: the value and the generator after it
  def next(mutable g: Gen): UInt64      // in place

  next(g)            // the first
  next(mutable g)    // the second
  g.next()           // the first, since a method call doesn't pass its receiver as `mutable`
  ```

  A call that leaves out `mutable` reaches the other function rather than an error, which the result's type almost always catches: the pure form has to give back the new value, and a result that's dropped is an error.
- A local or parameter holding a function wins outright and isn't overloaded. Nested `def`s are the exception: those of one name in a block are overloads of each other, chosen as module-level functions are, and each closes over what it uses.

  ```silver
  val k = 5
  def show(x: Int): String => "Int {x + k}"
  def show(x: String): String => "String {x}"

  show(1)      // "Int 6"
  show("a")    // "String a"
  ```

  A `def` in an inner block of a name an enclosing block has already declared hides it, as any local does, and isn't an overload.
- The type a call is expected to have never makes one function better than another, since functions aren't overloaded on their return type. What it gives a type parameter has to suit the arguments, though, so it can rule a function out.
- A [bound](interfaces.md#bounds) takes no part. Two functions with the same parameter types are duplicates whatever their bounds, and the bounds of the function chosen are checked afterwards, so one that fails is an error at the call and never passes the call to another function; see [Interfaces](interfaces.md#choosing-a-function).
- Inside a function with a bound, the functions the bound supplies are among the current module's.

A call chooses among the functions of its name like this:

1. Only those taking as many arguments are candidates, and as many type arguments when some are written. If that leaves one, it's called as a function with no overloads would be.
2. Each argument that has a type of its own is typed, once. Some arguments' types depend on where they go, and those are compared with each candidate's parameter by their shape instead: literals, `None`, `[]`, lambdas without their result type written, names of generic or overloaded functions, [arithmetic on literals](numbers.md#literals), arrays, tuples and `Some`s made only of these, and `if`s, `match`es and blocks whose values are all of these. An arm that can't finish, because it ends in `return`, `break`, `continue` or `tail`, has no value to count, and a block's earlier statements don't count. Such an `if` fits a parameter as well as its worst-fitting value does. They're checked against the chosen function's parameters afterwards. A lambda fits a function parameter that takes as many parameters as it does, with the types it annotates.
3. Each generic candidate's type parameters are bound as a call of it alone would bind them, by [inference](generics.md#inference), in a trial that records nothing, so the choice and the call can't disagree. An argument compared by its shape binds what it would be given on its own, so `[Some(1), None]` binds as an `[Int?]`, and a lambda binds what its annotations say. A bound that holds binds what its interface's parameters say, as in inference, and one that fails doesn't rule the candidate out. The expected type binds too, and the arguments have to suit what it binds, but it never makes one candidate better than another.
4. A candidate fits when every argument [fits](types.md#steps) its parameter, and costs the number of steps that takes, per argument. A candidate that fits every argument beats another if it costs no more for each argument and less for one, so with `type Held = :Box<Int> | :Box<String>`, `g(Box(1))` calls `g(b: Box<Int>?)`, one step, rather than `g(h: Held?)`, two. When two fit every argument equally well, a function that isn't generic beats a generic one, and a generic function beats another that takes everything it takes, as `f<T>(x: [T])` beats `f<T>(x: T)`. Last, an integer literal is [an integer first](numbers.md#literals): a function that reads no integer literal argument later than another, and one earlier, beats it, where an integer type is earlier than `Float` and `Float` earlier than `Float32`. So with `h(x: Int8)` and `h(x: Float)`, `h(1)` calls `h(Int8)`, and with `k(x: Float32)` and `k(x: Float)`, `k(1)` calls `k(Float)`.
5. If no candidate fits, or more than one fits better than all the others, the call is an error. When nothing fits only because of what the expected type bound, the choice is made again without it, and the argument is then an error against the one chosen, as it would be with no overloads.
6. The bounds of the function chosen are checked. A lambda is typed before that, so a bound on its result is checked like any other.

The current module's functions come first, unless an imported function takes the arguments in fewer steps. The imported functions are ranked instead when none of the current module's fits, or when one of them costs no more than each of the current module's that fit for every argument, and less for one. Every imported function of the name is then ranked together, by step 4, whichever import brings it. If two fit equally well, the call is ambiguous, and qualifying it resolves that. A function is the same function however it's reached, so one that arrives through two imports counts once.

A parameter that is only a type parameter, as in `first<C>(c: C)`, takes any argument as it is, so it never makes an imported function the nearer one: the module's `first(x: Int?)` keeps `first(1)`. A parameter that has a shape, as `[T]` or `Dictionary<K, V>` has, counts like any other.

Fitting equally well isn't enough for an imported function: the tie-breaks of step 4 are never weighed between the current module and an import, so the module's generic function is called before an imported one that isn't generic.

```silver
import shapes    // def encode(s: Square): String
import encoding  // def encode<T>(x: T?): String

encode(Square(2))  // shapes.encode, which fits exactly
encode(Circle(1))  // encoding.encode, the only one that fits
```

A function over a sum therefore leaves each member's own functions alone, in the module that declares it too:

```silver
type Json = :String | :Int | :[Json] | :[String: Json]

def opIndex(value: Json, key: String): Json? {
    match value {
        members: [String: Json] => members[key]  // lang's opIndex: a dictionary as it is
        _ => None
    }
}

def length(value: Json): Int {
    match value {
        items: [Json] => length(items)           // lang's length, not this one again
        _ => 0
    }
}
```

So an import, or a new overload in a library, changes which of the current module's own functions a call means only for a call that reached its function by promoting or injecting an argument, and only by taking that argument in fewer steps. A call whose arguments are exactly its function's parameters never moves. Among imported functions, a new overload that fits a call better than the one it reached takes the call, as it would if one module declared both, and one that fits equally well makes the call ambiguous. It also means a module can declare its own `printl(p: Point)` and still call `lang`'s `printl` with anything else.

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
| `a + b`, `a - b`, `a * b`, `a / b`, `a % b` | `opAdd(a, b)`, `opSub(a, b)`, `opMul(a, b)`, `opDiv(a, b)`, `opRem(a, b)`, unless both are built-in numbers |
| `-a` | `opNeg(a)`, unless `a` is a built-in number |
| `a & b`, `a \| b`, `a ^ b` | `opAnd(a, b)`, `opOr(a, b)`, `opXor(a, b)`, unless both are built-in numbers |
| `a << n`, `a >> n` | `opShl(a, n)`, `opShr(a, n)`, unless both are built-in numbers |
| `~a` | `opNot(a)`, unless `a` is a built-in number |
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

### Arithmetic

`+ - * / %` and prefix `-` on two built-in numbers are built in. On anything else they call an operator function, so a type gets them by someone writing the function.

```silver
type Vec2(x: Float, y: Float)

def opAdd(a: Vec2, b: Vec2): Vec2 => Vec2(a.x + b.x, a.y + b.y)
def opSub(a: Vec2, b: Vec2): Vec2 => Vec2(a.x - b.x, a.y - b.y)
def opMul(v: Vec2, k: Float): Vec2 => Vec2(v.x * k, v.y * k)
def opMul(k: Float, v: Vec2): Vec2 => Vec2(v.x * k, v.y * k)
def opMul(a: Vec2, b: Vec2): Float => a.x * b.x + a.y * b.y
def opNeg(v: Vec2): Vec2 => Vec2(-v.x, -v.y)

val p = Vec2(1.0, 2.0) + Vec2(3.0, 4.0)     // opAdd: Vec2(4.0, 6.0)
p * 2.0                                      // opMul(Vec2, Float)
2.0 * p                                      // opMul(Float, Vec2): the operands are never swapped
-p                                           // opNeg
p - p * 0.5                                  // usual precedence: opSub(p, opMul(p, 0.5))
p / 2.0                                      // error: `a / b` calls `opDiv`, and no `opDiv` here takes `Vec2` and `Float`

mutable val q = p
q += p                                       // q = opAdd(q, p)
mutable val ps = [p, p]
ps[0] += p                                   // ps[0] is read once, and written back
```

- The function is chosen where the operator is written, as any call of that name with those operands would be: by overloading, with a generic function or one a [bound](interfaces.md) supplies, with a literal operand taking the type its parameter asks for, as `p * 2` does for `opMul(Vec2, Float)`, and with an operand promoted as an argument is. So the function has to be in scope there, and a module can write one for a type it didn't declare. Each operand is evaluated once, left then right.
- The result is whatever the function returns, so `p * p` above is a `Float`. An [interface](interfaces.md) is what makes it the operands' type, as `def opAdd(a: Self, b: Self): Self` does.
- `a op= b` is `a = a op b`, with the place `a` read once, through fields and elements as for a built-in operator. There's no function for a compound assignment. There's no `%=` for anything. `a - b` is never `a + -b`, and operands are never swapped, so each form a type wants is a function of its own.
- Two built-in numbers are built in, whatever functions are in scope, and keep their own errors: `1 + 1.5` with an `Int` and a `Float` is still an error that values never convert, and not a missing `opAdd`.
- An operator function whose parameters are all built-in numbers is an error where it's declared, since no operator calls a function for two built-in numbers, so it could never be called. Only that case is refused: an operator function on a built-in type that isn't a number, such as `def opAdd(a: String, b: String): String`, is allowed, and is called where it's in scope. It can have a parameter of another type, or be generic: `opAdd<T>(a: T, b: T)` is allowed. It's never called for operands known to be two built-in numbers, but inside a generic function whose operands are of a type parameter, `a + b` calls it for any `T`, even when the function is used with numbers.
- The wrapping operators `+% -% *%` are built in only, and an operator that calls a function isn't allowed in a top-level [constant](bindings.md#top-level-constants), which can't call one.
- `+` doesn't join strings or arrays, which `~` does. When no `opAdd` takes a String or an array, the error says so.
- An operator function is an ordinary function. It can be called by name, as `a.opAdd(b)`, be private, and be used as a value.

### Bitwise operators and shifts

`& | ^ << >>` and prefix `~` work the same way, for a type that is a set of flags or a bit pattern.

```silver
type Flags(bits: UInt32)

def opOr(a: Flags, b: Flags): Flags => Flags(a.bits | b.bits)
def opAnd(a: Flags, b: Flags): Flags => Flags(a.bits & b.bits)
def opNot(a: Flags): Flags => Flags(~a.bits)
def opShl(a: Flags, n: Int): Flags => Flags(a.bits << n)

val resizable = Flags(1)
val vsync = Flags(2)
val window = resizable | vsync      // opOr
window & vsync == vsync             // opAnd, then ==: & binds tighter than ==
~vsync                              // opNot
vsync << 2                          // opShl(vsync, 2): the literal takes the parameter's type, an Int here
mutable val f = resizable
f |= vsync                          // f = opOr(f, vsync)
f <<= 1                             // f = opShl(f, 1)
```

- Everything under [Arithmetic](#arithmetic) holds: two built-in numbers are built in (a Float operand of a bitwise operator is its own error), so a function that takes only built-in numbers is an error where it's declared, any other operands call the function chosen where the operator is written, operands are never swapped, and `a op= b` is `a = a op b`. There's no function for a compound assignment, and a `~=` is still concatenation.
- A shift amount has its own type, as it does for built-in integers, so `opShl` and `opShr` can take any type for it: `opShl(a: Flags, n: Int)`, `opShl(a: Flags, n: UInt8)` and `opShl(a: Flags, c: Count)` are overloads of one name, chosen by the amount, and nothing requires `a` and `n` to be alike.
- The other operands of `& | ^` aren't required to be alike either: `opOr(a: Flags, b: UInt32)` is its own function, and `a | b` on a `Flags` and a `UInt32` is an error without it.
- Prefix `~` is bitwise not and binary `~` is concatenation, so only the prefix form is `opNot`. `&&`, `||` and `!` aren't operator functions. A `Float` is a built-in number, so `&` on one keeps its own error whatever functions are in scope.

### How syntax finds its function

Syntax finds its function in one of three ways, by what the syntax is for:

- **Indexing and arithmetic are calls.** `x[i]`, `x[i] = v`, slices, and `+ - * / %`, prefix `-`, and the [bitwise operators](#bitwise-operators-and-shifts) on anything but two built-in numbers mean the calls in the table, chosen where they're written as any call is, just as `x.f()` means `f(x)`. So indexing a type needs its `opIndex` in scope, as calling `x.length()` needs `length`, and a module can write one for a type it didn't declare. No [conformance](interfaces.md#conformance) is involved.
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

`opHash(x): UInt` is the hash a [dictionary](dictionaries.md) uses for its keys. Values that are equal have to hash alike, so a type that replaces `opEquals` replaces `opHash` too, and writing one without the other is an error.

```silver
def opEquals<K, V>(a: Dictionary<K, V>, b: Dictionary<K, V>): Bool {
    if length(a) != length(b) { return false }
    for (k, v) in a {
        if b[k] != Some(v) { return false }
    }
    true
}
def opHash<K, V>(d: Dictionary<K, V>): UInt => ...    // combines the entries in any order
```

- Each takes the declared type it's for, and nothing else: `opEquals(a: T, b: T): Bool`, `opHash(x: T): UInt` and `opString(x: T): String`, with no `mutable` parameter.
- One written for a generic type is for every instance of it. It takes the type with type parameters of its own, as `opEquals<T>(a: Box<T>, b: Box<T>)` does, and they can't have bounds.
- They're used wherever a value of the type is compared, hashed or printed: inside an option, an array, a tuple, a field or a sum, in generic code, and in what a closure captured.
- Each is for the type it names. One written for a sum is for values of the sum, and not for a value whose type is one of its members; one written for a member is for that member, inside its sum too:

  ```silver
  type Coin = Heads(year: Int) | Tails(year: Int)
  def opString(coin: Coin): String => ...        // "heads" or "tails"

  printl([Heads(1990)])                          // [heads]: building a member a sum owns gives the sum
  printl([1990].map(Heads).array())              // [Heads(1990)]: the constructor as a function gives a `Heads`
  ```
- A [pattern](user-types.md) takes a value apart by its members and fields, whatever its `opEquals` says.
- `hash(x)`, from `std.hash`, is the hash of any value, through its type's `opHash` when it has one. A type's `opHash` calls it for the parts it hashes, and several parts are hashed together as a tuple:

  ```silver
  import std.hash

  def opHash(p: Path): UInt => hash((p.root, p.parts))
  ```

Structural equality is right for nearly every type. These functions are for a type whose fields can differ for values that mean the same thing, such as a collection whose layout depends on the order it was built in. A comparison that ignores part of a value, such as positions in source or the case of a name, is an ordinary function, passed where it's needed, and not a replacement for `==`.

A function that's useful to call by name keeps a plain name, even where syntax uses it: `length`; `next`, which `for` calls through the type's conformance to [`Range`](control-flow.md#for); and `compare`, which `<` calls through its conformance to [`Ord`](types.md#ordering).

## Open questions

- Whether `x.f()` can drop its parentheses.
- Whether a method call can have a `mutable` receiver.
- Whether a call that no nested overload fits falls through to the module's functions of the name, as module-level overloading falls through to imports. Today the nested defs hide them:

  ```silver
  def show(x: Bool): String => "bool"
  def main(): Unit {
      def show(x: Int): String => "int"
      def show(x: String): String => "string"
      show(true)     // an error today; "bool" if it fell through
      true.show()    // "bool": a method call finds module-level functions only, so the two differ
  }
  ```
- With overloading, that a nested def can't call one declared after it matters more: nested overloads can't call each other both ways.

## Current implementation

- A nested function can call itself and those declared before it, but not one declared after it.
- An `opEquals`, `opHash` or `opString` for `Ref` isn't used.
- Nested `def`s of one name in a block are overloads of each other, and are the only functions of the name a call in their scope considers (see the open question): a nested `def` hides the module's functions and imports of its name even when none of the block's fits. They are never found by a method call `x.f()` or by an operator, as a single nested `def` isn't. A nested `def` has no type parameters, so the choice is by the arguments alone, as for any call of non-generic functions. Two that take the same parameter types are `T0035`, a `def` beside a `val` or parameter of the name is `S0001`. As a value, an overloaded nested `def` needs the exact function type expected, as module-level overloads do.
- When more than one candidate is left, an `if`, `match` or block is typed before any is chosen, even when its values are all literals, so it doesn't adapt to the chosen parameter: `f(if c => 1 else 2)` gives an `Int` even if the only `f` it could fit takes a `UInt8`. A literal written directly as the argument does adapt.
- Of the arguments compared by their shape, `None` and `[]` count one step wherever they go.
- Arithmetic on literals isn't compared by its shape yet: it's an `Int`, as [Numbers](numbers.md#current-implementation) describes, so `f(1 + 2)` doesn't fit an `f(x: UInt8)`.
- An arithmetic or bitwise operator's literal operand takes the type its operator function's parameter asks for, but arithmetic made of literals doesn't: `p * (1 + 2)` passes an `Int`, so it needs an `opMul` that takes one.
- An operator finds the module-level functions and a bound's, as `x[i]` does, so a nested `def opAdd` or a local `val opMul` holding a function is found by a written call `opAdd(a, b)` but not by `a + b`, and likewise for the bitwise operators. An `opAdd` of another arity is an ordinary function, and a nested `def` of an operator function's name isn't checked for taking only numbers.
- A method call's receiver needs a type of its own, so `None.f()` and `[].f()` are errors. An integer literal receiver adapts, as in `(200).f()` with `f(x: UInt8)`.
- Two native functions of one name in a module have to bind different C symbols, and two intrinsics can't share a name.
- A `mutable` first parameter is rejected for a method call. A later `mutable` argument is fine.
- `tail` isn't available.
- Type functions aren't built. A function for a type only in its result takes a parameter of the marker type `Of<T>` from `std.of`, as [Interfaces](interfaces.md#current-implementation) describes, and `Point.describe()` is still a method call with `Point`'s constructor as its receiver.
