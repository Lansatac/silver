# Modules

A module's identity is its file path. `import a.b` loads `<root>/a/b.ag`.

Every importable file begins with `module a.b`, which must match its path under its root. Only a file that is never imported may omit the declaration.

## Imports

```silver
module geometry.area
import some.library

def compute(): Float => helper(1.0)
def computeQualified(): Float => some.library.helper(1.0)
```

`import a.b` gives both unqualified access (`name`) and qualified access (`a.b.name`).

- A module's own declarations beat imports.
- A name provided by two imports is an error only where it is used, and qualifying it resolves that. For functions, that's a call that functions of both fit equally well: see [overloading](functions.md#overloading).
- Imports are private, so they aren't transitive.
- Module paths exist only at compile time and aren't values.
- Each module runs once per program.

Module-level declarations can appear in any order.

The prelude, which provides names like `print` and `read`, is an ordinary implicit import with no special priority. A conflict with another import is ambiguous, and `prelude.print` disambiguates.

The prelude declares nothing itself. It's a list of `forward import`s of `std` modules, so everything it provides has a module of its own that can be imported by name.

## Visibility

Declarations are public by default. `private` restricts one to its module:

```silver
private def helper(): Int => 1
private val limit: Int = 10
private type Detail(value: Int)
private native def primitive(): Int
```

There are no `private:` sections.

A private member can't be imported, can't be reached qualified, and doesn't take part in ambiguity between imports.

A public function or constant can't mention a private type in its signature. A public type can't have a field of a private type, a public sum can't name a private type as a member, and a public alias can't name a private type. A private alias counts as a private type in all of these. The members a private sum declares inline are private too.

`private def main` is an error.

## Forms of import

```silver
import a.b : first, Second    // selective
```

A selective import gives unqualified access to the names it lists. Every public name of the module is still reachable qualified, as `a.b.name`, so qualifying settles a clash between two selective imports. A listed name can be a function, constant, type or alias, and it brings everything of that name, so all of a module's `first` overloads, or a type along with its constructor. A sum's members are names of their own, so `import a.b : Shape` doesn't bring `Circle`. Naming something the module doesn't have, or keeps private, is an error.

Imports of the same module combine, so `import a.b : first` alongside `import a.b : second` allows both.

The rules for plain imports apply. A module's own declarations beat imports, and a name is ambiguous only where it's used, and only when more than one import gives it unqualified: `import a` with `import b : other` lets a bare `shared` mean `a.shared`.

These are also part of the design:

```silver
forward import a.b : first    // forwards names to importers
forward import a.b            // forwards every public name
```

`forward` is reserved only at the top level, followed by `import`.

Imports can also be renamed. A symbol's identity is its declaring module, so reaching one symbol through two forwarding paths isn't ambiguous.

For choosing among [overloads](functions.md#overloading), everything one import brings counts as one module: the module's own functions and those it forwards. So with `std.array.first<T>(xs: [T])` and `std.range.first<R: Range<T>, T>(range: R)` both forwarded by the prelude, `first([1, 2, 3])` is the array's, as it would be if one module declared both. Importing the two modules separately leaves that call ambiguous. Two imports that lead to the same function agree, so importing `std.range` beside the prelude changes nothing.

## Open questions

- How source roots are found. The leaning is that the compiler takes named roots only for other packages, and a file's own root comes from its declaration.
- The syntax for renamed imports.
- A visibility level wider than a file and narrower than public.
- How a module hides a type's representation. A type's fields are all public, so anyone can construct it, read it or use `with` on it. A condition on the fields is an [invariant](user-types.md#invariants). What that can't cover is a representation that should be free to change, or a condition too costly to check at every construction. An `opaque type`, with a public name and a constructor, fields and patterns private to its module, is the planned answer, to follow invariants.

## Current implementation

- `forward import` and renamed imports aren't available.
- The prelude declares its names itself.
