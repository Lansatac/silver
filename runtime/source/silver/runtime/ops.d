/// Operators the IR can't do in one instruction. Each is the same D expression the
/// interpreter evaluates, so the two backends agree by construction.
module silver.runtime.ops;

import core.stdc.string : strcmp;

extern (C) nothrow:

bool silver_string_equals(const(char)* a, const(char)* b) { return strcmp(a, b) == 0; }
