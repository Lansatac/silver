# Dictionaries

A dictionary associates keys with values. Like an array it's a value: copying one never shares a change, and a `mutable val` is how a dictionary is changed.

```silver
val ages = ["ana": 31, "bo": 27]
mutable val older = ages
older["cy"] = 40

printl(ages)     // [ana: 31, bo: 27]
printl(older)    // [ana: 31, bo: 27, cy: 40]
```

## Literals and the type

A literal writes each entry as `key: value` inside brackets. The empty dictionary is `[:]`, which takes its type from where it's used, as `[]` does: an annotation, a parameter, a field or a result type, or a dictionary it's written beside.

```silver
val empty: [String: Int] = [:]
val grid = [(0, 0): "start", (3, 4): "end"]

val scores = if fresh { [:] } else { ["ana": 3] }    // [String: Int]
val rounds = [["ana": 3], [:]]                       // [[String: Int]]
```

`val x = [:]` needs an annotation, since nothing says what its keys and values are.

`[K: V]` is the type of a dictionary from `K` to `V`, and another spelling of `Dictionary<K, V>`. An error names the type as `[K: V]`. `Dictionary` and its functions are available everywhere, as arrays' are.

- All keys have one type and all values another, with the same promotion as an array's elements.
- When a key appears twice, the later value wins, in the earlier key's place. Two keys written as the same constant are an error, since one of them can only be a mistake.

## Reading

`d[k]` is the value for `k`, or `None` when the dictionary has no such key:

```silver
if val age = ages["bo"] {
    printl("bo is {age}")
}
val total = (ages["dee"] ?? 0) + 1
```

Looking up a key that isn't there is an ordinary question to ask a dictionary, not a mistake, so the answer is an option rather than a panic. That's the difference from an array, whose index is usually known to be valid.

## Writing

`d[k] = v` adds `k`, or replaces its value if it's there. A path can end in a dictionary, as in `game.scores[name] = 10`. A path can't pass through one, since `d[k]` is an option:

```silver
counts[word] += 1               // error: counts[word] is an Int?
graph["a"]["b"] = 1             // error: graph["a"] is a [String: Int]?
```

A value is written in terms of the old one by reading it with a default. A dictionary inside a dictionary is taken out, changed and put back:

```silver
counts[word] = (counts[word] ?? 0) + 1

mutable val inner = graph["a"] ?? [:]
inner["b"] = 1
graph["a"] = inner
```

`update` does the same with a function, where one is already at hand: `counts = counts.update(word, 0, n => n + 1)`.

## Functions

| | |
| --- | --- |
| Asking | `contains(d, k)`, `length(d)`, `isEmpty(d)` |
| Changing | `without(d, k)`, `update(d, k, default, change)` |
| Viewing | `keys(d)`, `values(d)` |
| Building | `dictionary(range)` |

Each function that changes a dictionary returns the new dictionary and leaves its argument alone. `without` returns the dictionary unchanged when the key isn't there.

`dictionary` makes one from a range of `(K, V)` pairs, as `array` makes an array, with a later pair replacing an earlier one of the same key:

```silver
val byName = people.map(p => (p.name, p)).dictionary()
val lengths = words.map(word => (word, length(word))).dictionary()
```

## Order

A dictionary keeps its entries in the order their keys were first added. Replacing a value keeps the key's place, and a key removed with `without` and added again goes to the end.

```silver
mutable val d = ["b": 2, "a": 1]
d["c"] = 3
d["b"] = 20
printl(d)          // [b: 20, a: 1, c: 3]

for (k, v) in d {
    printl("{k}={v}")
}
```

The order means a program prints the same dictionary the same way on every run and with either backend, and it means data read in keeps the order it came in.

## Looping

A dictionary isn't a [range](ranges.md) itself, since the rest of one after its first entry would be another dictionary. It's an [`Iterable`](ranges.md#iterable): `iterate(d)` gives a range of its `(K, V)` entries in order, which is what `for` steps and what the functions over ranges take. `keys(d)` and `values(d)` are ranges in the same order.

```silver
val adults = ages.filter(((_, age)) => age >= 18).dictionary()
val total = ages.fold(0, (sum, (_, age)) => sum + age)
```

## Keys

Any type can be a key, including tuples, options, arrays, dictionaries and declared types. Keys are found by `==` and the type's `opHash`, so two keys are the same key exactly when they're equal, including for a type that replaces its equality (see [Equality and hashing](functions.md#equality-and-hashing)). Since values never change, a key can't change while a dictionary holds it.

- `0.0` and `-0.0` are one key, since they're equal.
- A key has to be equal to itself. `NaN` isn't, so adding a `NaN` key, or a key with a `NaN` inside it, panics: it could never be found again.
- A function value is found as `==` compares it: by its function and captures. A lambda that calls `f` is a different key from `f` itself.

## Equality and printing

Two dictionaries are equal when they have the same keys with equal values, in any order. So `["a": 1, "b": 2] == ["b": 2, "a": 1]`, though the two print differently.

A dictionary prints as its literal would, in order, with keys and values printed as they are in an array: `[ana: 31, bo: 27]`, and `[:]` when empty.

## Cost

Looking up, adding, replacing and removing a key take time that grows with the logarithm of the dictionary's size, with a base large enough that it's a few steps for any dictionary that fits in memory. Changing a dictionary doesn't copy it, and the old value still shares most of its contents with the new one, however many dictionaries are made from one. Stepping through a dictionary takes time in proportion to its size.

## Open questions

- A dictionary whose keys are kept sorted, by their `Ord`.
- Sets.
- Whether a constant can be a dictionary.

## Current implementation

- Everything above is built. `Dictionary<K, V>` and its functions are plain Silver in `stdlib/lang/dictionary.ag`, and a literal is an empty dictionary with each entry written into it in turn.
- `[:]` takes its type from an annotation, a parameter or a field it's given to, a result type, the other side of `??` or `==`, the option, error union or sum it's promoted into, the other arm of an `if` or a `match`, the other elements of an array or values of a dictionary, and a type parameter that another argument decides, as in `put([:], "a", 1)`. With none of those, as in `val x = [:]`, `first([:])` or `Some([:])`, it's `T0015`, which asks for an annotation.
- An expected type doesn't reach a `[:]` or a `[]` inside a generic constructor that is itself an argument, as in `val t: Table<String, Int> = Table(Branch(0, [:]), 0)`, which is `T0015`.
- The same constant as two keys is caught when both are literals, with a sign or as tuples of literals, compared by the value the key type holds rather than by spelling: `["a": 1, "a": 2]`, `[(1, 2): 0, (1, 2): 1]`, `[0x10: 1, 16: 2]`, `[0.1: 1, 0.10: 2]`, `[0.0: 1, -0.0: 2]`, and for `Float32` keys two literals that round to one `Float32`. Two names for one constant aren't caught, and the later value wins as for any repeated key.
- `keys`, `values` and `iterate` give the types `Keys<K, V>`, `Values<K, V>` and `Entries<K, V>`, which a `val` infers. Writing one of those names needs `import lang.dictionary`.
- A dictionary's fields can be read and it can be built with its constructor by a module that imports `lang.dictionary`, which nothing checks.
- The panic for a key that isn't equal to itself is reported at the line in `lang.dictionary` that panics, not at the caller's.
- It's slow on the interpreter, where a lookup is tens of microseconds, since it's Silver run by a tree walker. Compiled, 200,000 keys are added, read and stepped through in under a second.
