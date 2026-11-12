# Syntax

## Source files

A source file has the extension `.ag`. Its top level holds declarations only: `module`, `import`, `def`, `native` and `intrinsic` declarations, `type`, `alias`, constants and tests. A program's entry module defines `def main(): Unit`, which takes no parameters.

## Comments

```silver
// to the end of the line
/* a block comment /* which can nest */ */
```

## Names

Case is significant and enforced. A name starting with an uppercase letter is a type or constructor. A name starting with a lowercase letter or `_` is a value, binding or module.

The reserved words are `alias`, `break`, `continue`, `def`, `else`, `false`, `for`, `if`, `import`, `in`, `intrinsic`, `invariant`, `match`, `module`, `mutable`, `native`, `private`, `return`, `tail`, `true`, `type`, `val`, `while`, `with` and `_`.

`test` is reserved only in one position: at the top level, followed by a string. It remains usable as a name everywhere else.

## Punctuation

`:` means "has type": `name: Type`, for parameters, fields, bindings and return types. Map entries are its one other use. `->` appears only in function types, and `=>` introduces a single expression. `{}` is always a block, except for a hole inside a string.

## Statements and newlines

Statements are separated by a newline or `;`.

A newline separates statements only when the token before it can end a statement **and** the token after it can begin one. Everywhere else it is whitespace. So these need no continuation marker:

```silver
val total = first +
    second

val result = source
    .first()
    .second()

val either = isReady
    || isForced
```

Some tokens can both continue an expression and begin a statement: `-`, `~`, `!`, `(` and `[`. A line starting with one of them begins a new statement. (`-%` is not one of them: no statement can begin with it, so it continues the line above.) To continue across such a line, put the operator at the end of the previous line, or use parentheses.

```silver
val a = x -
    1          // x - 1

val b = (x
    - 1)       // x - 1
```

`return` can end a statement, so `return` followed by a newline returns `()`.

Inside `()` and `[]`, newlines are allowed after the opening bracket, around commas, and before the closing bracket. A `{}` block nested in brackets still separates its statements as usual.

An expression statement whose value isn't used must have type `Unit`, except for the last one in a block, which is the block's value. This catches an accidental split such as `val y = x` followed by a line reading `- 1`. To drop a value on purpose, write `_ = value`.

## Operator precedence

From loosest to tightest:

| Operators | Associativity |
| --- | --- |
| `if`, `while`, `for`, `match`, lambdas | |
| `\|\|` | left |
| `&&` | left |
| `==` `!=` | none |
| `<` `<=` `>` `>=` | none |
| `..` | none |
| `??` | right |
| `\|` | left |
| `^` | left |
| `&` | left |
| `<<` `>>` | left |
| `+` `-` `~` `+%` `-%` | left |
| `*` `/` `%` `*%` | left |
| prefix `-` `!` `~` | |
| postfix: call, index, `.`, `?.`, `?`, `with` | left |

The condition of an `if` or `while`, the iterable of a `for` and the subject of a `match` are parsed below lambda level. A lambda in one of those positions needs parentheses.

## Current implementation

- `tail` isn't reserved yet.
