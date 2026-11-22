# Proposal: attributes

**Status: decided in outline, and nothing is built.** An attribute is a value of an ordinary type, written on a field where the type is declared, and read by the library that declared the attribute's type. A library reaches the fields themselves through an interface, [`Record`](#a-types-fields-record). What's [assumed](#assumed-until-decided) and what's [open](#open-questions) is listed at the end. This builds on [interfaces](../language/interfaces.md) and adds no other kind of generic code.

## Summary

An attribute says something about a field that its name and type don't: the key it's written under, the number it has in a binary format, that it's left out.

```silver
import json

type Address(number: Int, street: String)

type PersonRecord(
    @Key("Name")
    name: String?,
    address: Address?
)

conform Address: ToJson & FromJson
conform PersonRecord: ToJson & FromJson

val person = PersonRecord("Joe", Address(123, "street"))
val text = person.toJson().write()                       // {"Name":"Joe","address":{"number":123,"street":"street"}}
val roundTrip = fromJson<PersonRecord>(parse(text)?)?    // equal to person
```

`Key` is a type the `json` library declares, and the library is what reads it. Without attributes, renaming one key means writing `toJson` and `fromJson` for the type by hand.

## An attribute is a value of a type

There's no separate kind of declaration. A library declares the types its attributes are, as it declares any type:

```silver
type Key(name: String)      // the key a field is written under
type Skip                   // the field is left out
type Tag(number: Int)       // a field's number in a binary format
```

So what holds for a type holds for an attribute:

```silver
@Key("Name") name: String       // a Key
@Kye("Name") name: String       // error: no type `Kye`
@Key(5) name: String            // error: `Key` takes a `String`
```

- It's named as a type is, imported and qualified the same way, and can be `private`.
- Two libraries' attributes are two types, and can't be mistaken for each other.
- A library asks for attributes of its own types, and never sees another's.

## Writing an attribute

An attribute is `@`, a type, and that type's arguments, before a field:

```silver
type Account(
    @Key("ID") id: Int,
    @Skip @Key("pw")
    password: String,
    balance: Float
)
```

- The type is any product or marker in scope.
- Its arguments are what a [constant](../language/bindings.md#top-level-constants) can be: literals, operators on them, and other constants.
- A marker takes no arguments and no parentheses.
- A field can have several, on one line or over several, and at most one of each type.

### What an attribute doesn't do

An attribute says something about the declaration, and not about a value. Two values are equal, hash and print as they would without it, a field is read and written the same, and the type is the same type. Nothing happens because an attribute is there, until some code asks for it.

## Reading attributes

```silver
intrinsic def attributes<T, A>(of: Of<T>, attribute: Of<A>): [A?]

attributes(Of<Account>, Of<Key>)      // [Some(Key("ID")), Some(Key("pw")), None]
attributes(Of<Account>, Of<Skip>)     // [None, Some(Skip), None]
attributes(Of<Int>, Of<Key>)          // []
```

- It gives one entry for each field, in the order the fields are declared, with `None` where the field has no attribute of that type.
- A type that isn't a product has no fields, and gives `[]`.
- The values are ordinary ones: matched, compared and passed on as any value is.
- [`Of<T>`](../language/interfaces.md#a-type-only-in-the-result) carries each type, so both are worked out from the call, in generic code too:

```silver
def keys<T: Record<F>, F>(of: Of<T>): [String] {
    val names = fieldNames(Of<T>)
    val tagged = attributes(Of<T>, Of<Key>)
    mutable val out: [String] = []
    for i in 0..length(names) {
        out ~= [tagged[i]?.name ?? names[i]]
    }
    out
}

keys(Of<PersonRecord>)      // ["Name", "address"]
```

## A type's fields: `Record`

An attribute is only useful to code that works on a type's fields without knowing the type. `lang` declares the shape of a product as a type, and an interface that gives it:

```silver
type End
type Field<H, R>(value: H, rest: R)

interface Record<F> {
    def fields(value: Self): F
    def fieldNames(of: Of<Self>): [String]
    def record(of: Of<Self>, fields: F): Self
}
```

Every product conforms, by a conformance the compiler supplies. `F` is the type's fields in the order they're declared, each a `Field` holding one value and the rest, ending in `End`:

```silver
// PersonRecord is a Record<Field<String?, Field<Address?, End>>>

fields(person)                    // Field(Some("Joe"), Field(Some(Address(123, "street")), End))
fieldNames(Of<PersonRecord>)      // ["name", "address"]
record(Of<PersonRecord>, Field(None, Field(None, End)))     // PersonRecord(None, None)
```

- `fieldNames` gives the names as declared. An attribute never changes them: `keys` above is the library's.
- A marker has no fields, so it's a `Record<End>`.
- A generic product conforms for every argument: a `Box<T>` is a `Record<Field<T, End>>`.
- A sum, a tuple and a built-in type aren't records.
- Nothing else declares a conformance to `Record`: a type has the one it's given.
- `record` builds the value as the type's constructor does, with every check the constructor makes.

### Writing for every record

A library handles `End` and `Field<H, R>`, and one generic function takes any record whose fields it can handle:

```silver
interface JsonFields {
    def writeFields(fields: Self, names: [String], members: [String: Json]): [String: Json]
}

def writeFields(fields: End, names: [String], members: [String: Json]): [String: Json] => members

def writeFields<H: ToJson, R: JsonFields>(fields: Field<H, R>, names: [String], members: [String: Json]): [String: Json] {
    mutable val out = members
    out[names[0]] = toJson(fields.value)
    writeFields(fields.rest, names[1..], out)
}

conform End: JsonFields
conform Field<H, R>: JsonFields when H: ToJson, R: JsonFields

def toJson<T: Record<F>, F: JsonFields>(value: T): Json {
    val none: [String: Json] = [:]
    writeFields(fields(value), keys(Of<T>), none)
}
```

`conform PersonRecord: ToJson` then finds that `toJson`, as [a conformance finds any function](../language/interfaces.md#conformance). A type that needs what no attribute says writes its own `toJson`, which is chosen first because it isn't generic.

- Each of these is checked once, where it's written.
- A field the library can't handle is an error at the `conform` line: with a `Float` field and no `conform Float: ToJson`, `conform Mixed: ToJson` is refused.
- Calling `toJson(person)` needs no `conform` line. Passing a `PersonRecord` where a `ToJson` is wanted does.

## What it costs

- An attribute costs nothing where it isn't read. Reading gives an array that's the same every time, which a library can keep.
- Going through `Record` builds the chain of `Field`s and passes the names along it. Measured on two million round trips of a `PersonRecord` through `toJson` and `fromJson`, compiled with `-O`, it took about 10% longer than functions written by hand for the type. Both build a dictionary, which is most of the time, so a format that writes bytes directly would show more.

## Assumed until decided

- An attribute goes on a field only.
- Every product is a `Record` without asking. Construction is public today, so `record` reaches nothing that a constructor call doesn't. Once [construction can be private to a type's module](../language/user-types.md#open-questions), `record` for such a type is the module's too.

## Open questions

- An attribute on a sum's member, with an interface for sums as `Record` is for products: a JSON discriminator, and a field number for each member.
- An attribute on a type, a function, a parameter or a test.
- Checking attributes when the program is compiled. A library finds a duplicate `Tag` number or an empty key when it first reads them, while the program runs.
- Richer arguments, such as an array or another type's value, which wait on constants of those types.
- An attribute for a type declared elsewhere. A type's attributes are written with it, so its module imports each library it's tagged for, and a type from another package is handled by writing its functions.
- Whether an error about a field should name the field instead of its place in the chain of `Field`s.
- The names `attributes`, `Record`, `Field` and `End`.
- Fields read in place at compile time, as `static for f in fields<T>`, which would generate the code written by hand and waits on compile-time evaluation. It could replace the chain inside a library without changing what a user writes.
