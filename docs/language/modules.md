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

- A module's own declarations, and imports that list a name, beat imports that bring every name: see [which declaration a name means](#which-declaration-a-name-means).
- A name two blanket imports provide is an error only where it is used, and qualifying it resolves that. For functions, that's a call that functions of both fit equally well: see [overloading](functions.md#overloading).
- Imports are private, so they aren't transitive.
- Module paths exist only at compile time and aren't values.
- Each module runs once per program.

Module-level declarations can appear in any order.

The prelude, which provides names like `print` and `read`, is an ordinary implicit blanket import with no special priority. A conflict with another blanket import is ambiguous, and `prelude.print` disambiguates; an import that lists the name beats it.

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

A public function or constant can't mention a private type in its signature, and a public function whose result type is an [interface](interfaces.md#an-interface-name-as-a-result-type) can't return one. A public type can't have a field of a private type, a public sum can't name a private type as a member, and a public alias can't name a private type. A private alias counts as a private type wherever one of these writes it. What a function returns through an interface name isn't written, and is the type the alias names, so a private alias of a public type isn't caught there. The members a private sum declares are private too.

`private def main` is an error.

## Forms of import

```silver
import a.b : first, Second    // selective
```

A selective import gives unqualified access to the names it lists. Every public name of the module is still reachable qualified, as `a.b.name`. A listed name can be a function, constant, type or alias, and it brings everything of that name, so all of a module's `first` overloads, or a type along with its constructor. A sum's members are names of their own, so `import a.b : Shape` doesn't bring `Circle`. Naming something the module doesn't have, or keeps private, is an error.

Imports of the same module combine, so `import a.b : first` alongside `import a.b : second` allows both.

Imports can also be renamed, which is part of the design and has no syntax yet.

## Which declaration a name means

A name can reach a module from its own declarations, from imports that list it, and from imports that bring every name. The first two are explicit: the module wrote the name. Nearer beats farther, in this order:

1. the module's own declarations, and selective imports and forwards that list the name,
2. blanket imports and forwards, including the prelude.

For constants, types, aliases, interfaces and sum members, an explicit one hides what blanket imports bring by the name:

```silver
import geometry               // declares `val origin`
import graphics : origin      // declares another `origin`

origin                        // graphics's: the listed one beats the blanket one
```

Two explicit declarations of one name are a duplicate, reported where the second is written, since the module asked for both. That covers a module's own declaration and an import that lists the name, and two imports that list it for different declarations. Two blanket imports that bring one name are ambiguous only where it's used, and qualifying settles it, since neither was asked for by name:

```silver
import geometry               // declares `val origin`
import graphics : origin      // error: graphics's `origin` and this module's are both written here
val origin: Point = Point(0.0, 0.0)
```

```silver
import geometry               // declares `val origin`
import graphics               // declares another `origin`

draw(circle)                  // fine: only geometry has `draw`
origin                        // error: both imports bring an `origin`
geometry.origin               // fine
```

Functions are never hidden by name. All the functions of one name that a module reaches are overloads of each other, so a module's own `first` doesn't hide an imported `first` that takes something else, and an import can list `first` beside the module's own. The same-level rules apply to functions that take the same parameters (or differ only in bounds neither of which asks for everything the other does): two explicit ones are a duplicate, reported where the second is written, an explicit one hides a blanket one, and two blanket ones are ambiguous where a call fits both.

```silver
import graphics : scale       // declares `scale(x: Float)` and `scale(x: Int)`
def scale(x: Float): Float => x * 2.0   // error: graphics's `scale(Float)` is listed too
```

A call then [chooses](functions.md#overloading) among the module's own functions first, and among imported ones only when none of its own fits, with each import's functions ranked as one group, so adding an import never changes which of the module's own functions a call means. The functions a bound's search finds are the ones a call finds.

A name that's a constant or type at its nearest level hides functions of that name at farther ones, and functions at the nearest level hide farther constants and types.

## Forwarding

```silver
module shapes

forward import shapes.circle : Circle, area    // forwards these names to importers
forward import shapes.text                     // forwards every public name
```

A `forward import` is an import, and it also passes its names on. To a module that imports `shapes`, each forward is what the same import would be in its place: the selective one lists `Circle` and `area`, and the blanket one brings every public name of `shapes.text`. `shapes` itself is one import for them, so `Circle` is `shapes.Circle` too, and can be listed in a selective import of `shapes`. That covers functions, constants, types, aliases and interfaces, and the functions that make a type satisfy an [interface](interfaces.md), so a library can pass on an interface's module and its importers need nothing else.

What `shapes` passes on under a name is what the name means in `shapes`, by the levels above, among its public declarations and its forwards. So its own public declarations and what it lists beat what it forwards blanket, and functions merge:

```silver
module std.range
forward import std.array                // declares `first<T>(xs: [T])` and `val limit`
val limit: Int = 10
def first<R: Range<T>, T>(range: R): T? => ...

// in a module that imports std.range
limit                                   // std.range's own
first([1, 2, 3])                        // std.array's: both `first`s come through, ranked as one module's
```

- The selective form forwards the names it lists, each with everything of that name. The blanket form forwards every public name of the module, including what that module forwards itself.
- Forwarding a sum forwards its members with it, so `forward import shapes.circle : Shape` gives importers `Circle` and `Square` too, and the forwarding module sees them as well. Functions don't travel with a type: a function that takes a `Shape`, or one that makes a type satisfy an interface, is forwarded only if it's listed or the forward is blanket.
- Only names are forwarded. Importing `shapes` doesn't make `shapes.circle.area` reachable; that takes an import of `shapes.circle`.
- A forwarded name has to be public in its module, and the module has to have it.
- A private declaration and a forward that lists its name are a duplicate, as with any import that lists it. Beside a blanket forward, a private declaration is what the name means inside the module, and importers get the forwarded one.
- Forward imports can form a cycle. Each module in it gives its importers what the others give it, by the same levels. A cycle in which what one module passes on by a name changes what another does, and back, never settles, and is an error at the forward.
- `forward` is reserved only at the top level, followed by `import`. Anywhere else it's an ordinary name.

A declaration is the same declaration however it's reached, so a name that arrives through two imports, directly and through a forwarding module or through two forwarding modules, isn't ambiguous.

The same-level rules apply to what a module forwards. A forward that lists a name the module declares publicly, or one that another forward or import lists for a different declaration, is an error at the forward, and for functions that is one taking the same parameters as another explicit one. What two blanket forwards bring by one name is ambiguous only where an importer uses it, and `kit.origin` is as ambiguous there as `origin`, so the way out is to import the declaring module.

For choosing among overloads, everything one import brings counts as one module: the module's own functions and those it forwards. So with `std.array.first<T>(xs: [T])` and `std.range.first<R: Range<T>, T>(range: R)` both forwarded by the prelude, `first([1, 2, 3])` is the array's, as it would be if one module declared both. Importing the two modules separately leaves that call ambiguous. Two imports that lead to the same functions agree, so importing `std.range` beside the prelude changes nothing: an import whose functions that fit a call are all among another import's is ranked with that one. That holds only while nothing on the way hides one of those functions: a facade whose own `f(Int)` replaces a forwarded one gives a different `f(Int)` than the original module does, and importing both makes a call ambiguous.

Inside the forwarding module, its own functions come first, and what all its forwards bring is then one group, as its importers rank it, so the prelude's own code would choose the array's `first` for `first([1, 2, 3])` as a program does. Its other imports are groups of their own.

## Open questions

- How source roots are found. The leaning is that the compiler takes named roots only for other packages, and a file's own root comes from its declaration.
- The syntax for renamed imports.
- A visibility level wider than a file and narrower than public.
- How a module hides a type's representation. A type's fields are all public, so anyone can construct it, read it or use `with` on it. A condition on the fields is an [invariant](user-types.md#invariants). What that can't cover is a representation that should be free to change, or a condition too costly to check at every construction. An `opaque type`, with a public name and a constructor, fields and patterns private to its module, is the planned answer, to follow invariants.

## Current implementation

- Renamed imports aren't available.
- The prelude declares its names itself, and doesn't forward `std` modules yet.
- An explicit duplicate of functions is reported where it's written, and a call that fits both is then reported as ambiguous too.
- What two blanket forwards bring as functions of the same parameters is reported at a call or a plain or qualified use of the name, but where a bound's search or a function value meets it, as their own error (`T0043`, `T0034`).
- A sum's members travel with it only when each is written as a plain name that the sum's module declares or forwards.
- When no function fits and the module of an argument's type has one that would, the hint names an import that already brings it but doesn't list it, if there is one, and otherwise the declaring module.
