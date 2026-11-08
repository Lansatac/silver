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
- A name provided by two imports is an error only where it is used, and qualifying it resolves that.
- Imports are private, so they aren't transitive.
- Module paths exist only at compile time and aren't values.
- Each module runs once per program.

Module-level declarations can appear in any order.

The prelude, which provides names like `print` and `read`, is an ordinary implicit import with no special priority. A conflict with another import is ambiguous, and `prelude.print` disambiguates.

## Visibility

Declarations are public by default. `private` restricts one to its module:

```silver
private def helper(): Int => 1
private val limit: Int = 10
private type Detail(value: Int)
private native def primitive(): Int
type Handle(private id: Int)
```

There are no `private:` sections.

A private member can't be imported, can't be reached qualified, and doesn't take part in ambiguity between imports.

A public function or constant can't mention a private type in its signature. A public type can't have a public field of a private type.

A private field blocks construction, field access and `with` on that field outside the module. Equality and printing are unaffected. A type with a private field therefore needs a factory function.

`private def main` is an error.

## Forms of import

These are also part of the design, in addition to plain `import`:

```silver
import a.b : first, second    // selective
static import a.b             // qualified only
public import a.b : first     // forwards names to importers
```

Imports can also be renamed. A symbol's identity is its declaring module, so reaching one symbol through two forwarding paths isn't ambiguous.

## Open questions

- How source roots are found. The leaning is that the compiler takes named roots only for other packages, and a file's own root comes from its declaration.
- The syntax for renamed imports.
- A visibility level wider than a file and narrower than public.

## Current implementation

- `private` isn't available.
- Only plain `import a.b` is available.
