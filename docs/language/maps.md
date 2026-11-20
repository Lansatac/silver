# Maps

A map associates keys with values. Like an array it's a value: copying one never shares a change, and a `mutable val` is how a map is changed.

```silver
val ages = ["ana": 31, "bo": 27]
mutable val older = ages
older["cy"] = 40

printl(ages)     // [ana: 31, bo: 27]
printl(older)    // [ana: 31, bo: 27, cy: 40]
```

## Literals and the type

A literal writes each entry as `key: value` inside brackets. The empty map is `[:]`, which takes its type from where it's used, as `[]` does.

```silver
val empty: [String: Int] = [:]
val grid = [(0, 0): "start", (3, 4): "end"]
```

`[K: V]` is the type of a map from `K` to `V`, and another spelling of `Map<K, V>`. `Map` and its functions are available everywhere, as arrays' are.

- All keys have one type and all values another, with the same promotion as an array's elements.
- When a key appears twice, the later value wins, in the earlier key's place. Two keys written as the same constant are an error, since one of them can only be a mistake.

## Reading

`m[k]` is the value for `k`, or `None` when the map has no such key:

```silver
if val age = ages["bo"] {
    printl("bo is {age}")
}
val total = (ages["dee"] ?? 0) + 1
```

Looking up a key that isn't there is an ordinary question to ask a map, not a mistake, so the answer is an option rather than a panic. That's the difference from an array, whose index is usually known to be valid.

## Writing

`m[k] = v` adds `k`, or replaces its value if it's there. A path can end in a map, as in `game.scores[name] = 10`. A path can't pass through one, since `m[k]` is an option:

```silver
counts[word] += 1               // error: counts[word] is an Int?
graph["a"]["b"] = 1             // error: graph["a"] is a [String: Int]?
```

`update` writes a value in terms of the old one, starting from a default when the key is missing. A map inside a map is taken out, changed and put back:

```silver
counts = counts.update(word, 0, n => n + 1)

mutable val inner = graph["a"] ?? [:]
inner["b"] = 1
graph["a"] = inner
```

## Functions

| | |
| --- | --- |
| Asking | `contains(m, k)`, `length(m)`, `isEmpty(m)` |
| Changing | `without(m, k)`, `update(m, k, default, change)` |
| Viewing | `keys(m)`, `values(m)` |

Each function that changes a map returns the new map and leaves its argument alone. `without` returns the map unchanged when the key isn't there.

## Order

A map keeps its entries in the order their keys were first added. Replacing a value keeps the key's place, and a key removed with `without` and added again goes to the end.

```silver
mutable val m = ["b": 2, "a": 1]
m["c"] = 3
m["b"] = 20
printl(m)          // [b: 20, a: 1, c: 3]

for (k, v) in m {
    printl("{k}={v}")
}
```

A map is a range of `(K, V)` tuples in that order, so `for`, `map`, `filter` and the other adapters take one. `keys` and `values` are ranges in the same order.

The order means a program prints the same map the same way on every run and with either backend, and it means data read in keeps the order it came in.

## Keys

Any type can be a key, including tuples, options, arrays, maps and declared types. Keys are found by `==` and the type's `opHash`, so two keys are the same key exactly when they're equal, including for a type that replaces its equality (see [Equality and hashing](functions.md#equality-and-hashing)). Since values never change, a key can't change while a map holds it.

- `0.0` and `-0.0` are one key, since they're equal.
- `NaN` isn't equal to itself, so a `NaN` key can be added but never found, and each `m[nan] = v` adds another entry. The same goes for any key with a `NaN` inside it.
- A function value is found as `==` compares it: by its function and captures. A lambda that calls `f` is a different key from `f` itself.

## Equality and printing

Two maps are equal when they have the same keys with equal values, in any order. So `["a": 1, "b": 2] == ["b": 2, "a": 1]`, though the two print differently.

A map prints as its literal would, in order, with keys and values printed as they are in an array: `[ana: 31, bo: 27]`, and `[:]` when empty.

## Cost

Looking up, adding, replacing and removing a key take time that grows with the logarithm of the map's size, with a base large enough that it's a few steps for any map that fits in memory. Changing a map doesn't copy it, and the old value still shares most of its contents with the new one. Stepping through a map takes time in proportion to its size.

## Open questions

- A map whose keys are kept sorted, which waits on `Ord`.
- Sets.
- Whether a constant can be a map.

## Current implementation

- Map literals parse, but are rejected. Nothing else on this page is available yet.
- Every type already has the structural hash keys will be found by, on both backends: equal values hash alike, `0.0` and `-0.0` included, a `Ref` hashes by which cell it is, and a function value by its function and captures. It's `hash` in `lang.hash`, which `lang` doesn't forward, for the standard library's own use. A type can't replace it yet.
