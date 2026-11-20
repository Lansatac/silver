# Modules

A module's identity is its name: its [package](#packages)'s name, then its path under the package's directory. In a package `a` at `<dir>`, `import a.b.c` loads `<dir>/b/c.ag`.

Every importable file begins with its full name, as `module a.b.c`, which must match. Only a file that is never imported may omit the declaration.

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

Two modules are imported into every module without being named. `lang`, the [package the compiler knows](#the-package-the-compiler-knows), provides names like `print`, `read` and `length`, whatever the prelude is, and the prelude provides the rest of what every module sees, as `map`. Both are ordinary implicit blanket imports with no special priority. A conflict with another blanket import is ambiguous, and qualifying settles it, as `lang.print`; an import that lists the name beats it.

The prelude declares nothing itself. It's a list of `forward import`s of `std` modules, so everything it provides has a module of its own that can be imported by name. It belongs to the standard library, and the build says which module it is: `std.prelude` unless another is named.

## Packages

A package is a name and a directory of modules. Its name is one or more segments, as `std` or `silver.core`, and a module's name is the package's name followed by the module's path under the directory:

```
package silver.core at core/source

core/source/lower.ag          module silver.core.lower
core/source/tree/node.ag      module silver.core.tree.node
```

- An import is found by the package whose name is the longest prefix of the module's name, and then by the remaining segments as folders. `silver` and `silver.core` can both be packages, in unrelated directories.
- A package lists the packages it uses, and imports only from those and itself. The list has no cycles.
- A package with a `main` is a program, and nothing can depend on it. Every other package is a library, whether or not it's the one being built.
- A file with no `module` line, run directly, is a program of its own: one module, named after the file.

How a package is written down, and where a package's source comes from, belong to the `silver` tool and aren't part of the language.

### Parts

A package can list others as its parts, as `silver` lists `silver.ast`, `silver.core` and `silver.sema`. Each part has its own directory and its own list of what it uses.

- Only the parent's list makes a package a part. A name that extends another package's means nothing by itself.
- Where a rule asks which package owns a declaration, the parts of one package count as one.
- When the parent is a program, only the part with the `main` is the program. The others are libraries, and other packages can depend on them.

### The package the compiler knows

The compiler refers to one package by name, `lang`. The standard library is an ordinary package with no rights of its own.

- `intrinsic def` and `intrinsic alias` are allowed only in `lang`.
- Every declaration the compiler refers to itself is declared there, as `Interval` is.
- `lang` depends on nothing, ships with the compiler, and can't be replaced. `std` depends on it.
- Built-in types, which no module declares, belong to `lang`.
- A function that syntax calls by name, as `x[i]` calls `opIndex`, is found as any function is, wherever it's declared.

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

Functions are never hidden by name. All the functions of one name that a module reaches are overloads of each other, so a module's own `first` doesn't hide an imported `first` that takes something else, and an import can list `first` beside the module's own. The same-level rules apply to functions that take the same parameters: two explicit ones are a duplicate, reported where the second is written, an explicit one hides a blanket one, and two blanket ones are ambiguous where a call fits both.

```silver
import graphics : scale       // declares `scale(x: Float)` and `scale(x: Int)`
def scale(x: Float): Float => x * 2.0   // error: graphics's `scale(Float)` is listed too
```

A call then [chooses](functions.md#overloading) among the module's own functions first, and among imported ones only when none of its own fits, ranked together whichever import brings them, so adding an import never changes which of the module's own functions a call means. A [conformance](interfaces.md#conformance) finds its functions as a call where it's declared would.

A name that's a constant or type at its nearest level hides functions of that name at farther ones, and functions at the nearest level hide farther constants and types.

## Forwarding

```silver
module shapes

forward import shapes.circle : Circle, area    // forwards these names to importers
forward import shapes.text                     // forwards every public name
```

A `forward import` is an import, and it also passes its names on. To a module that imports `shapes`, each forward is what the same import would be in its place: the selective one lists `Circle` and `area`, and the blanket one brings every public name of `shapes.text`. `shapes` itself is one import for them, so `Circle` is `shapes.Circle` too, and can be listed in a selective import of `shapes`. That covers functions, constants, types, aliases and interfaces. A [conformance](interfaces.md#who-sees-a-conformance) isn't a name and needs no forwarding: every module sees it.

What `shapes` passes on under a name is what the name means in `shapes`, by the levels above, among its public declarations and its forwards. So its own public declarations and what it lists beat what it forwards blanket, and functions merge:

```silver
module std.range
forward import std.array                // declares `first<T>(xs: [T])` and `val limit`
val limit: Int = 10
def first<R: Range<T>, T>(range: R): T? => ...

// in a module that imports std.range
limit                                   // std.range's own
first([1, 2, 3])                        // std.array's: both `first`s come through, and the array's fits closer
```

- The selective form forwards the names it lists, each with everything of that name. The blanket form forwards every public name of the module, including what that module forwards itself.
- Forwarding a sum forwards its members with it, so `forward import shapes.circle : Shape` gives importers `Circle` and `Square` too, and the forwarding module sees them as well. Functions don't travel with a type: a function that takes a `Shape` is forwarded only if it's listed or the forward is blanket.
- Only names are forwarded. Importing `shapes` doesn't make `shapes.circle.area` reachable; that takes an import of `shapes.circle`.
- A forwarded name has to be public in its module, and the module has to have it.
- A private declaration and a forward that lists its name are a duplicate, as with any import that lists it. Beside a blanket forward, a private declaration is what the name means inside the module, and importers get the forwarded one.
- Forward imports can't form a cycle: a module that forwards one that forwards it back, directly or through others, is an error at the forward. Plain imports can: a module may import one that forwards it, as the `std` modules import the prelude.
- `forward` is reserved only at the top level, followed by `import`. Anywhere else it's an ordinary name.

A declaration is the same declaration however it's reached, so a name that arrives through two imports, directly and through a forwarding module or through two forwarding modules, isn't ambiguous.

The same-level rules apply to what a module forwards. A forward that lists a name the module declares publicly, or one that another forward or import lists for a different declaration, is an error at the forward, and for functions that is one taking the same parameters as another explicit one. What two blanket forwards bring by one name is ambiguous only where an importer uses it, and `kit.origin` is as ambiguous there as `origin`, so the way out is to import the declaring module.

Forwarding doesn't change how a call chooses. Imported functions are ranked together whichever import brings them, so with `std.array.first<T>(xs: [T])` and `std.range.first<R: Range<T>, T>(range: R)`, `first([1, 2, 3])` is the array's whether the two arrive through the prelude, through two imports, or both. Importing `std.range` beside the prelude changes nothing, since a function reached twice is one function. A facade whose own `f(Int)` replaces a forwarded one gives a different `f(Int)` than the original module does, and importing both makes a call that fits them ambiguous.

Inside the forwarding module, its own functions come first, and what it forwards is ranked with its other imports.

## Open questions

- How a package is described: its name, directory, parts and what it uses.
- The syntax for renamed imports.
- A visibility level wider than a file and narrower than public, for what the parts of a package share.
- Whether a library's tests may see more than the library does.
- How a module hides a type's representation. A type's fields are all public, so anyone can construct it, read it or use `with` on it. A condition on the fields is [checked by a function](user-types.md#checking-a-condition), which nothing obliges other code to call. Two levels are wanted: construction private to the module with the fields still readable, which is enough for a condition, and an `opaque type`, with a public name and a constructor, fields and patterns private to its module, for a representation that should be free to change.

## Current implementation

- Renamed imports aren't available.
- Packages aren't implemented. A program is compiled whole from unnamed roots, given with `-I`, and a module's name is its whole path under one: `import a.b` loads `<root>/a/b.ag`. There are no parts, no list of what a package uses, and no difference between a program and a library.
- `lang` is the module `lang` and the modules under it, read only from the compiler's own directory. What every module sees without an import, whatever the prelude, is what the module `lang` forwards: `lang.array`, `lang.interval`, `lang.io`, `lang.panic`, `lang.range`, `lang.testing`, and `bytes` and `next` from `lang.string`. `lang`'s other modules are reached by importing them, or through the `std` modules that forward them, as `std.ref` does `lang.ref`.
- A module named as part of `lang`, by its `module` line or, without one, by its file name, is an error (`L0004`) unless it is the compiler's own file, so a program can't add to `lang` or replace it. An import in a module of `lang` of anything outside `lang` is an error too (`L0005`).
- The build can't name another prelude yet: `silver` always uses `std.prelude`, which forwards `std.range`, declares `Of` itself, and doesn't forward the other `std` modules yet. A prelude that isn't found is an error.
- Two functions of the same parameters aren't a duplicate when one's bounds ask for everything the other's do and more, and a type satisfies an interface through the functions a module can see, so those have to be imported or forwarded: see [Interfaces](interfaces.md#current-implementation).
- An explicit duplicate of functions is reported where it's written, and a call that fits both is then reported as ambiguous too.
- What two blanket forwards bring as functions of the same parameters is reported at a call or a plain or qualified use of the name, but where a bound's search or a function value meets it, as their own error (`T0043`, `T0034`).
- A sum's members travel with it only when each is written as a plain name that the sum's module declares or forwards.
- When no function fits and the module of an argument's type has one that would, the hint names an import that already brings it but doesn't list it, if there is one, and otherwise the declaring module.
