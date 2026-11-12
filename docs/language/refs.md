# Shared references

Every value in Silver behaves as a copy: changing one through a `mutable val` or a `mutable` parameter never changes another. A `Ref<T>` is the exception. It's a cell holding a `T` that can be replaced, and every copy of the `Ref` is the same cell.

```silver
import std.ref

val counter = Ref(0)
val bump = () => counter.update(n => n + 1)

bump()
bump()
printl(counter.get())      // 2
```

`Ref` is in `std.ref` and isn't imported by default, so sharing shows in a module's imports and in the types that use it.

## Operations

| | |
| --- | --- |
| `Ref(value)` | a new cell holding `value`, of type `Ref<T>` |
| `get(ref)` | what the cell holds now |
| `set(ref, value)` | replaces what the cell holds |
| `update(ref, change)` | replaces what the cell holds with `change` applied to it |

`get`, `set` and `update` are ordinary functions, so they're usually written `ref.get()`, `ref.set(value)` and `ref.update(change)`. `set` and `update` return `Unit`.

```silver
def get<T>(ref: Ref<T>): T
def set<T>(ref: Ref<T>, value: T): Unit
def update<T>(ref: Ref<T>, change: (T) -> T): Unit
```

A value read with `get` is a value like any other. Replacing the cell's contents afterwards doesn't change it.

```silver
val names = Ref(["a"])
val before = names.get()
names.update(all => all ~ ["b"])
printl(before)             // [a]
printl(names.get())        // [a, b]
```

### `update`

`update` is the way to change what a cell holds in terms of what it held. It can change the contents in place, where `ref.set(change(ref.get()))` has to copy them first.

While `change` runs, the cell is empty. Reading, setting or updating the same `Ref` from inside `change` is a panic.

## What a `Ref` is

- A `Ref` is a value of type `Ref<T>`. It can be bound with `val`, passed, returned, stored in a field or an array, and captured by a lambda. Capturing one is how a lambda keeps state between calls or shares it with its creator.
- The binding holding a `Ref` doesn't need to be `mutable` for the cell to be changed. `mutable val r = Ref(0)` means `r` can be made to name a different cell.
- `Ref` used as a value is a function, like any constructor: `val cells = [1, 2].map(Ref<Int>)`.
- A `Ref` has no fields. It isn't taken apart by a pattern, and `with` doesn't apply.
- `T` can be any type that can be a type argument.

## Equality and printing

- Two `Ref`s are equal when they're the same cell. Their contents aren't compared, so `Ref(1) == Ref(1)` is false, the answer doesn't change when a cell is written, and a cell that leads back to itself compares without trouble. To compare contents, write `get(a) == get(b)`.

  ```silver
  val a = Ref(1)
  val b = a
  a == b          // true
  a == Ref(1)     // false
  ```

- A type that contains a `Ref` compares it the same way, as does a lambda that captured one.
- A `Ref` prints as its contents would in a product: `Ref(2)`, `Ref([a, b])`. A cell that leads back to itself can't be printed: the program panics with a stack overflow.

## Constants

A constant can't be a `Ref`, or have a type that contains one. A `Ref` at module level would be a mutable global, which Silver doesn't have. This holds however much a constant's initializer is allowed to compute.

## Open questions

- Passing a cell's contents as a `mutable` argument, as in `advance(mutable ref)`.
- Assignment forms such as `ref += 1`.
- A reference that doesn't keep its cell alive, for structures that point back at their owner.

## Current implementation

All of this is implemented on both backends, except `==`: a `Ref` isn't comparable yet, and neither is a type that contains one. Using a `Ref` from inside its own `update` panics with "Ref is being updated" (`R0010`).
