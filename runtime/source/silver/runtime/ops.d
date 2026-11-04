/// Operators the IR can't do in one instruction. Each is the same D expression the
/// interpreter evaluates, so the two backends agree by construction.
module silver.runtime.ops;

import core.stdc.string : strcmp;
import std.math;

extern (C) nothrow:

long silver_pow_int(long base, long exponent) { return base ^^ exponent; }
double silver_pow_float(double base, double exponent) { return base ^^ exponent; }
bool silver_string_equals(const(char)* a, const(char)* b) { return strcmp(a, b) == 0; }
