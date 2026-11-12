# Proposal: structural interfaces with call-site conformance

**Status: proposed, partly decided.** Nothing here is implemented. Decided in November 2026: `==` and printing aren't interfaces, and belong to the type (see "Operators and printing"). The rest is open. It builds on [generics](../language/generics.md): `<>` type parameters, bodies checked once with each `T` opaque, and monomorphization.

The [ranges proposal](ranges.md) builds on this one and suggests changes to it: an answer to open question 1, interface names as types, and overloading as a prerequisite.

## Summary

An interface describes a shape: a set of function signatures. A type satisfies an interface by having those functions, with no declaration linking the two.

The compiler looks for the functions at the place that supplies the type, not inside the generic code that uses it. The functions it finds are handed to the generic. So a module can make a library type satisfy an interface by writing an ordinary function:

```silver
import lib.foo : Foo
import lib.json

def toJson(value: Foo): JsonValue => object([("id", toJson(value.id))])

foo.toJson()    // method-call syntax, as today
encode(foo)     // Foo satisfies Json here, through the function above
```

## Motivation

- **One type, many forms.** A universal `toString` works until a value is needed as JSON in one place and YAML in another. A type should be able to gain a new named shape from code its author never saw.
- **Making other people's types fit.** A library's types won't implement the interfaces of the code using them, or of a second library. Fitting one to the other should take a function, not a wrapper type.

Both are about supplying a conformance that a type's module didn't write. Neither needs an existing operation to change its meaning.

## Goals

- "I accept a type shaped like this", with no ceremony on the type's side.
- Extending types you didn't write, locally, and using them with generic code.
- Generic bodies checked once, so errors appear at the definition or at one call and not deep inside an instantiation.
- The same behaviour on both backends, with no runtime type inspection.

## The proposal

### Interfaces and bounds

```silver
interface Json {
    def toJson(value: Self): JsonValue
}

def encode<T: Json>(item: T): String => render(toJson(item))
```

Inside `encode`, `T` is opaque and `toJson(item)` refers to the function the bound supplies. Several bounds are written `T: Json & Sized`.

### Interface parameters (decided, November 2026)

An interface can take type parameters, and a type that depends on the conforming type, such as a range's element type, is one of them. There are no associated types.

```silver
interface Range<T> { def next(range: Self): (T, Self)? }

def toArray<T>(range: Range<T>): [T] => ...
def total(range: Range<Int>): Int => ...

Countdown(3).toArray()       // T = Int, read off Countdown's next
total(["a", "b"])            // error: [String] is a Range<String>, not a Range<Int>
```

A bound is solved as a call, with whatever is known at that point:

- **A parameter that appears only in results is determined by the function found.** There can be one `next` for a type, since functions aren't overloaded on their result, so a type is a range of one element type in a given place.
- **A parameter that appears in an argument takes part in choosing the function.** With `interface Add<Rhs> { def add(a: Self, b: Rhs): Self }`, a `Vec` that has `add(Vec, Vec)` and `add(Vec, Float)` is both an `Add<Vec>` and an `Add<Float>`. A bound `T: Add<Float>` picks by overloading, and `T: Add<X>` with `X` unknown needs exactly one function to fit.
- **Inference solves a bound as soon as its type is known.** In the order in [generics](../language/generics.md#inference), that's after the arguments that have a type of their own and before the expected type, literals and lambdas, so `xs.map(x => x * 2)` knows `x` from `xs`.

### A type that appears only in the result (decided, November 2026)

Some operations produce a value of the conforming type from nothing of that type: `fromJson(json: String): Self?`, `parse`, `default`, `zero`. Functions aren't overloaded on their result, so there'd be nothing to tell one type's function from another's. Such a function takes a parameter whose only job is to carry the type, a marker from the prelude:

```silver
type Of<T>

interface FromJson { def fromJson(of: Of<Self>, json: String): Self? }

// what each type writes
def fromJson(of: Of<Point>, json: String): Point? => ...
def fromJson(of: Of<Int>, json: String): Int? => ...
```

A library puts one generic function in front, and that is what callers use:

```silver
def fromJson<T: FromJson>(json: String): T? => fromJson(Of<T>, json)

val p = fromJson<Point>(text)
val q: Point? = fromJson(text)          // T from the expected type
```

- Nothing in the lookup, overloading or conformance rules is special to these functions. `Self` is in a parameter, so `Point` is a `FromJson` when `fromJson(Of<Point>, text)` resolves, and a module can write one for a type it doesn't own.
- Conditional conformance works as elsewhere: `def zero<T: Zero>(of: Of<Box<T>>): Box<T>`.
- The front function and the ones behind it share a name because they take different numbers of arguments.
- The per-type functions already compile and run on both backends, since they're ordinary overloads over a generic marker type.

A shorter way to write the per-type function is left for later, as syntax for exactly this: `def Point.fromJson(json: String): Point?`. The name `Of` isn't settled.

### Conformance

`T` satisfies an interface at a given call if every function in the interface, with `Self` replaced by `T`, is found by this search:

1. Look up the name at the call site, exactly as a call to it would resolve: current module first, then imports. Only module-level functions are candidates, as with method-call syntax.
2. If that finds nothing that fits, look at the public functions of the module that declares `T`.

A function fits when a call to it with those argument types would resolve, and its result type is exactly the interface's (decided, November 2026). So an argument can be promoted as in any call, to an option or into a sum, and the best fit is chosen by the overloading rule:

```silver
type Point = Point2D | Point3D
def toJson(p: Point): JsonValue => ...

val p = Point2D(1, 2)
p.toJson()       // Point2D promotes into Point
encode(p)        // and Point2D is a Json, through the same function
```

- Conformance has no matching rule of its own. Whatever makes `toJson(p)` resolve makes `p`'s type a `Json`, and to the same function.
- The result isn't converted. With `next(range: Self): (T, Self)?`, a function returning the rest of the range as some wider type doesn't fit.
- `mutable` has to agree, as it does for a call: a `mutable` parameter takes only a `mutable` argument, which is never promoted.
- A type inside another isn't promoted, as in any call. A `[Point2D]` isn't a `[Point]`, so a function taking `[Self]` fits only with the type itself.
- A function in scope that fits by a promotion is found in step 1, so step 2 never reaches a function in the type's own module that would fit exactly. A plain call behaves the same way, and importing the type's module puts both in step 1, where the exact one wins.

The search itself (decided, November 2026):

- **Two imported modules that each supply a fitting function are an error**, as they are for a plain call. A call is fixed by qualifying the name. A bound has nothing to qualify, so the fix is a function in the current module that forwards to one of them, until there's an adapter form (open question 8).
- **Step 2 runs when step 1 finds nothing that fits**, not when it finds no function of the name. An unrelated `toJson(x: Int)` in scope doesn't stop `Point`'s own from being found.
- **A bound on the function found is searched from the original call site**, by the same two steps, wherever that function lives. With a library's `toJson<T: Json>(b: Box<T>)` and a local `toJson(f: Foo)`, `encode(Box(foo))` uses both.
- **For a generic type, step 2 looks in the module that declares the type itself.** For `Box<Foo>` that's `Box`'s module. `Foo`'s module is reached through the bound on `T`, not by widening this search.
- **For a built-in type, step 2 looks in the prelude.** That covers arrays, options, strings, numbers and function types.
- **Tuples conform to no declared interface for now**, because no one generic function covers every length. For `Ord` the compiler supplies the order: element by element, when every element is ordered.

Step 1 reuses the overloading rule in [functions.md](../language/functions.md): `toJson(foo)` and `encode(foo)` always choose the same function. Since the current module is tried first, a library adding its own `toJson` later can't change the behaviour of a module that already has one.

Step 2 is what lets a type work everywhere its module's functions exist, even when the caller imported only the type (`import lib.foo : Foo`).

### Conformance is as visible as its function

There is no separate form to import or export. An extension reaches exactly the modules that can see its function, so `import`, selective imports and `public import` control it.

### Operators and printing (decided, November 2026)

`==`, `!=`, printing, `String(x)` and string holes aren't interfaces. Each belongs to the type: it's the structural one, or one the type's own module writes, and no other module can supply or replace it.

- There is no `Eq` and no `Show`. Generic code compares and prints a `T` with no bound, and each instance uses the type's own. Every type is comparable: function values by where they were made, and a `Ref` by being the same cell (see [Types](../language/types.md#equality-and-ordering)).
- Ordering can't be universal, since not every type has an order, so `Ord` stays a bound. Like `==`, only the type's own module supplies it.
- A comparison or a text form with a meaning of its own is a function with a name: `toJson(x)`, or a key passed to `sortBy` or `containsBy`.

The reason is that a conformance found at a call reaches only the code that is handed it: comparisons written in the calling module, and generic functions called from it. It doesn't reach non-generic code elsewhere.

```silver
// lib/people.ag
type Person(name: Name, age: Int)      // ==, written or derived here, compares names its way

// app.ag, if it could give Name an == of its own
p.name == q.name                       // app's
p == q                                 // people's, which uses the other one for the names
```

Making it reach would mean every function takes its conformances from its caller, which lets a caller break code it can't see, and has no answer for which of several callers wins. For a declared interface the same limit is acceptable, because a library that serializes its own types its own way is doing what was written. For `==` it breaks "equal wholes have equal parts".

### Witnesses

The function chosen for a bound is its **witness**, together with any promotion of its arguments. Sema records witnesses per call, beside the type arguments. The promotions follow from the types, so a witness is still identified by its function.

- A generic calling another generic passes along the witness it was given, and searches for nothing.
- A witness that is itself generic carries its own type arguments and witnesses.
- Lookup happens once, where the concrete type is known in source. A generic body never searches by name at instantiation, which avoids D's problem of a free function next to your type being invisible inside `std.algorithm`.

### Conditional conformance

A function's own bounds express it, so nothing extra is needed:

```silver
def length<R: Sized, F>(value: Map<R, F>): Int => length(value.source)
```

`Map<R, F>` is `Sized` exactly when this function applies, which is how an adapter keeps a capability of what it wraps.

### Capability queries

```silver
def count<R: Range>(r: R): Int {
    static if R: Sized { length(r) } else { walk(r) }
}
```

Inside the branch `R` gains the bound, so both branches are checked once at the definition. The branch is chosen at monomorphization.

This is different from overloading on specificity. An overload is chosen where the call is written, so a caller holding only `R: Range` would get the slow path. `static if` sees the real type.

The query sees the module that declares `R` and any witness already passed for that bound. It runs where the caller's scope doesn't exist, so a local extension can satisfy a bound but can't turn on a fast path inside a library.

### Stored structure

A witness is harmless when nothing outlives the call. It matters when a value's invariants depend on one:

```silver
type Set<T: Ord>(...)
```

A bound on a type's parameter makes the witness part of the type's identity. `Set<Foo>` ordered by one `compare` and `Set<Foo>` ordered by another are different types.

- A generic such as `insert<T: Ord>(s: Set<T>, x: T)` uses the witness in `s`'s type and doesn't search again, so a value built in one module works correctly in another.
- Writing `Set<Foo>` searches where it's written. A signature naming a `Set<Foo>` that resolves to a different witness from the value passed is a type error, and the message has to name both functions.
- A program with one `compare` for `Foo` never sees any of this.

Since ordering, equality and hashing belong to the type, `Set<T: Ord>` and a map's keys have one witness per type and need none of this. It's left for a type bounded by a declared interface, and a first version can make that an error.

## Examples of what this replaces

| Current notes | This proposal |
| --- | --- |
| `instance Show for Point { ... }` | Removed. Ordinary functions conform. |
| Orphan rule | Removed. Local conformance is scoped, so nothing is global to protect. |
| `alias Elem = Int` bound in an instance | A parameter of the interface, read off the function found. |
| `Sema records typeArgsOf(call) and dispatchOf(call)` | Kept. `dispatchOf` holds witnesses. |

## Alternatives considered

- **D-style signature constraints, checked per instantiation.** Errors surface inside instantiations, `__traits(compiles)`-style tests silently select the wrong branch on a typo, and one answer per node in `Analysis` stops holding.
- **Nominal `instance` declarations (Haskell, Rust).** Explicit intent and global coherence, but they need the orphan rule, which rules out the local extension this proposal exists for.
- **Go's rule alone: the type's own module only.** Simple and coherent, but a type you don't own needs a wrapper type.
- **Local functions only fill gaps, with an ambiguity error if the type's module also has one.** More conservative, but `foo.toJson()` would choose the local function under the overloading rule while `encode(foo)` would be an error.
- **Signatures matching exactly, with no promotion.** A witness would be a bare function, but `p.toJson()` could work on a line above an `encode(p)` that says `p`'s type isn't a `Json`.
- **Associated types, written `R.Element`.** Reads well for "any range" and badly for "a range of `Int`", which becomes `R: Range where R.Element == Int`. It needs `.Element` on a type and `where`, and an interface like `Add<Rhs>` needs parameters anyway.
- **For a type only in the result: choosing by the expected type,** as in `val total: T = zero()` with a `zero` per type. It reverses the rule that the expected type never chooses a function.
- **For the same: writing the implementation as `def fromJson<Point>(json: String): Point?`,** to match the call. In a `def`, `<Point>` declares a type parameter, which hides an imported type on purpose, so an import would change what the declaration means.
- **For the same: `Int implements Zero with zero = intZero`.** For `sum` to work on `Int` everywhere, such bindings would have to be exported and searched as functions are, which is Scala's `given`.
- **`==` and printing as interfaces found at the call site,** so a local function changes them. Rejected: see "Operators and printing".
- **Function values not comparable, with `Eq` as a bound some types fail.** Rejected for universal `==`. The price is that two lambdas doing the same thing compare unequal.
- **Scala-style `given` declarations.** The same call-site idea, with a declaration form Silver doesn't need because ordinary functions already serve.

## Costs

- **Accidental matches.** A signature can't state laws, so an unrelated `length` satisfies `Sized`. Keeping `static if` to the declaring module limits the damage, and capability interfaces should be narrow and specifically named.
- **Conformance varies by module.** Two modules can give `Foo` different `Json`s. That is the feature, but a reader has to know that `encode(foo)` depends on what's in scope.
- **A local conformance doesn't reach non-generic code.** With a local `toJson(Point)`, `encode(point)` uses it, while a library's `toJson(line: Line)` still calls its own for the points inside. It matters only when a program has two conformances of one type to one interface, which a local function over the type's own always creates.
- **Instantiations are keyed by witnesses as well as types,** so the worklist gets larger. An instance's name, in an error or in the `.ll`, shows its witnesses only when two instances of the same types differ by them (decided, November 2026), which a program with one conformance per type never has.

## Implementation sketch

- **Sema.** Record the search result per bound at each call, and at each written type with a bounded parameter. Witness identity is structural: declaration ID, type arguments, nested witnesses.
- **Codegen.** Monomorphize through a worklist keyed by types and witnesses, with witnesses in the LLVM name only where instances would otherwise share one. Calls to a bound's function become direct calls.
- **Interpreter.** Bind the same substitution, witnesses included, in the environment. Neither backend inspects runtime types.
- **Prerequisites.** Generics and overloading land together, because a local `show(Foo)` has to coexist with other `show`s and whether a candidate fits becomes unification.

## Open questions

1. **Associated types.** Decided: there are none. The type is a parameter of the interface; see "Interface parameters".
2. **`Self` only in a return position,** as in `def zero(): Self`. Silver doesn't overload on return type, so two types in one module can't both have `zero()`, and step 1 has no argument to select with. Decided: the function takes a marker parameter that carries the type; see "A type that appears only in the result".
3. **Operators.** Decided: see "Operators and printing". A type's own module writes them as `opEquals`, `opCompare` and `opString`; see [operator functions](../language/functions.md#operator-functions). `Ord` is the bound that a type has an `opCompare`. Still open is what `opCompare` returns and whether a type gets one without writing it.
4. **`Float` and `Ord`.** NaN has no place in a three-way total order. Decided: `Float` is `Ord` by a total order with NaN after every other value, so `max(1.5, 2.5)` compiles and a sort is defined for every input. `<` on two `Float`s outside generic code is unchanged, so the two differ only when a NaN is involved.
5. **Types with no home module.** Decided: the prelude is their module; see "Conformance". Still open is tuples and declared interfaces, which needs type parameter lists of any length or a conformance the compiler builds.
6. **Derived equality and printing.** Decided: they're the type's own and not conformances, replaced only by its own module.
7. **Interface values** such as `[Json]`, holding mixed types, need a runtime representation and dynamic dispatch. Decided: not in the first version. An interface name is a type only where one concrete type stands behind it: a parameter, a result or a binding, as described in the [ranges proposal](ranges.md#an-interface-name-as-a-type-decided-november-2026). `[Json]` is an error that says to use a sum type, or to convert the values where they're collected.
8. **An explicit adapter form,** for naming a witness. Deferred, and addable later. The shape discussed is a statement private to a module:

   ```silver
   Point implements Json                                // checks the lookup here, changes nothing
   Point implements Json with toJson = pretty.toJson    // chooses, when two imports supply one
   Buffer implements Sized with length = size           // a different name, with no forwarding function
   ```

   Required, it would remove accidental matches and the duck typing with them, so it stays optional. With a `with` clause, a bound and a plain call can disagree.
9. **What counts as a match.** Decided: a function fits when the call would resolve, with the result type exact. See "Conformance".
10. **A local function over the type's own conformance** to a declared interface. Allowed as written, since the current module comes first, at the cost described under "Costs".

## Before deciding

Write a real `Range` adapter chain against this design, on paper or in `exploration/`, such as `xs.map(f).filter(g).count()` with a locally extended element type. Adapters are where witnesses accumulate in types, and that will show whether the names and error messages stay readable. It will also force an answer to question 1.
