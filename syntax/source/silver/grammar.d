module silver.grammar;

import pegged.grammar;

debug import std.stdio;

mixin(pegged.grammar.grammar(import("Silver.peg")));
