# Proposal: structural interfaces with call-site conformance

**Status: proposed, not decided.** Nothing here is implemented. It assumes the generics direction under discussion: `<>` type parameters, bodies checked once with each `T` opaque, and monomorphization.

The [ranges proposal](ranges.md) builds on this one and suggests changes to it: an answer to open question 1, interface names as types, and overloading as a prerequisite.

## Summary

An interface describes a shape: a set of function signatures. A type satisfies an interface by having those functions, with no declaration linking the two.

The compiler looks for the functions at the place that supplies the type, not inside the generic code that uses it. The functions it finds are handed to the generic. So a module can make a library type satisfy an interface by writing an ordinary function:

```silver
import lib.foo : Foo

def show(value: Foo): String => "Foo({value.id})"

foo.show()      // method-call syntax, as today
describe(foo)   // Foo satisfies Show here, through the function above
```

## Goals

- "I accept a type shaped like this", with no ceremony on the type's side.
- Extending types you didn't write, locally, and using them with generic code.
- Generic bodies checked once, so errors appear at the definition or at one call and not deep inside an instantiation.
- The same behaviour on both backends, with no runtime type inspection.

## The proposal

### Interfaces and bounds

```silver
interface Show {
    def show(value: Self): String
}

def describe<T: Show>(item: T): String => "item: " ~ show(item)
```

Inside `describe`, `T` is opaque and `show(item)` refers to the function the bound supplies. Several bounds are written `T: Eq & Show`.

### Conformance

`T` satisfies an interface at a given call if every function in the interface, with `Self` replaced by `T`, is found by this search:

1. Look up the name at the call site, exactly as a call to it would resolve: current module first, then imports. Only module-level functions are candidates, as with method-call syntax.
2. If that finds nothing that fits, look at the public functions of the module that declares `T`.

A signature must match exactly, including `mutable`. Adaptation and promotion don't apply, so `show(x: Point?)` doesn't make `Point` a `Show`.

Step 1 reuses the overloading rule in [functions.md](../language/functions.md): `show(foo)` and `describe(foo)` always choose the same function. Since the current module is tried first, a library adding its own `show` later can't change the behaviour of a module that already has one.

Step 2 is what lets a type work everywhere its module's functions exist, even when the caller imported only the type (`import lib.foo : Foo`).

### Conformance is as visible as its function

There is no separate form to import or export. An extension reaches exactly the modules that can see its function, so `import`, selective imports and `public import` control it.

### Witnesses

The function chosen for a bound is its **witness**. Sema records witnesses per call, beside the type arguments.

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

## Examples of what this replaces

| Current notes | This proposal |
| --- | --- |
| `instance Show for Point { ... }` | Removed. Ordinary functions conform. |
| Orphan rule | Removed. Local conformance is scoped, so nothing is global to protect. |
| `alias Elem = Int` bound in an instance | Needs a new form; see open questions. |
| `Sema records typeArgsOf(call) and dispatchOf(call)` | Kept. `dispatchOf` holds witnesses. |

## Alternatives considered

- **D-style signature constraints, checked per instantiation.** Errors surface inside instantiations, `__traits(compiles)`-style tests silently select the wrong branch on a typo, and one answer per node in `Analysis` stops holding.
- **Nominal `instance` declarations (Haskell, Rust).** Explicit intent and global coherence, but they need the orphan rule, which rules out the local extension this proposal exists for.
- **Go's rule alone: the type's own module only.** Simple and coherent, but a type you don't own needs a wrapper type.
- **Local functions only fill gaps, with an ambiguity error if the type's module also has one.** More conservative, but `foo.show()` would choose the local function under the overloading rule while `describe(foo)` would be an error.
- **Scala-style `given` declarations.** The same call-site idea, with a declaration form Silver doesn't need because ordinary functions already serve.

## Costs

- **Accidental matches.** A signature can't state laws, so an unrelated `length` satisfies `Sized`. Keeping `static if` to the declaring module limits the damage, and capability interfaces should be narrow and specifically named.
- **Conformance varies by module.** Two modules can give `Foo` different `Show`s. That is the feature, but a reader has to know that `describe(foo)` depends on what's in scope.
- **Instantiations are keyed by witnesses as well as types,** so names and the worklist get larger, and type names in errors need to show witnesses when they differ.

## Implementation sketch

- **Sema.** Record the search result per bound at each call, and at each written type with a bounded parameter. Witness identity is structural: declaration ID, type arguments, nested witnesses.
- **Codegen.** Monomorphize through a worklist keyed by types and witnesses, with witnesses in the LLVM name. Calls to a bound's function become direct calls.
- **Interpreter.** Bind the same substitution, witnesses included, in the environment. Neither backend inspects runtime types.
- **Prerequisites.** Generics and overloading land together, because a local `show(Foo)` has to coexist with other `show`s and whether a candidate fits becomes unification.

## Open questions

1. **Associated types.** With no instance to write `alias Elem = Int` in, `Elem` has to be inferred from the matching signature (`next(r: Self): Step<Elem, Self>?`) or become a type parameter (`Range<T>`). This is the largest gap, and `Range` depends on it.
2. **`Self` only in a return position,** as in `def zero(): Self`. Silver doesn't overload on return type, so two types in one module can't both have `zero()`, and step 1 has no argument to select with.
3. **Operators.** If `==` and `<` lower to `Eq` and `Ord`, should a local function change what `==` means in one module? My recommendation is no: operators use the declaring module's function or the derived one.
4. **`Float` and `Ord`.** NaN has no place in a three-way total order. Primitive `<` can stay a fast path, but `T: Ord` needs a defined answer for `Float`.
5. **Types with no home module:** arrays, options, tuples and function types. Presumably the prelude for built-in conformances and the caller's scope for everything else.
6. **Derived `Show` and `Eq`.** The simplest treatment is that they count as functions in the declaring module, unless it writes its own.
7. **Interface values** such as `[Show]`, holding mixed types, need a runtime representation and dynamic dispatch. Deferred, and addable later.
8. **An explicit adapter form,** for naming a witness at a call. Deferred, and addable later.

## Before deciding

Write a real `Range` adapter chain against this design, on paper or in `exploration/`, such as `xs.map(f).filter(g).count()` with a locally extended element type. Adapters are where witnesses accumulate in types, and that will show whether the names and error messages stay readable. It will also force an answer to question 1.
