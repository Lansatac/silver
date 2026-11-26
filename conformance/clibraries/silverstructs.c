// A shared library the conformance harness builds with clang, for the case that passes structures to
// natives and takes them back by value. Each shape is one the conventions pass in a way of its own.
// Its functions use no C library, so it links with nothing.
#include <stdbool.h>
#include <stdint.h>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
// What the C runtime would define for a module that uses floating point.
int _fltused = 1;
#else
#define EXPORT
#endif

typedef struct { uint8_t r, g, b, a; } Color;
typedef struct { float x, y; } Vector2;
typedef struct { float x, y, width, height; } Rectangle;
typedef struct { int32_t a, b, c, d, e; } Five;
typedef struct { int32_t count; float scale; } Mixed;
typedef struct { double value; int64_t count; } DoubleLong;
typedef struct { float a, b, c; } Triple;
typedef struct { uint8_t a, b, c; } Bytes3;
typedef struct { Vector2 from, to; } Line;
typedef struct { void *spot; void *maybe; } Held;
typedef struct { bool on; bool off; int32_t count; } Flags;
typedef struct { int32_t small; int64_t large; } IntLong;
typedef struct { float single; double wide; } FloatDouble;
typedef struct { int8_t a; int16_t b; int8_t c; } Six;
typedef struct { float value; } Single;
typedef struct { int8_t a; int64_t b; int8_t c; int64_t d; } Wide;

static char block[64];

// Small structures, each in a register or two.
EXPORT uint32_t packColor(Color c) { return c.r | (uint32_t)c.g << 8 | (uint32_t)c.b << 16 | (uint32_t)c.a << 24; }
EXPORT Color brighter(Color c, int32_t by) { return (Color){c.r + by, c.g + by, c.b + by, c.a}; }
EXPORT Vector2 addVectors(Vector2 a, Vector2 b) { return (Vector2){a.x + b.x, a.y + b.y}; }
EXPORT float cross(Vector2 a, Vector2 b) { return a.x * b.y - a.y * b.x; }
EXPORT Rectangle grow(Rectangle r, float by) { return (Rectangle){r.x - by, r.y - by, r.width + 2 * by, r.height + 2 * by}; }
EXPORT float weighRectangle(Rectangle r) { return r.x + r.y * 2 + r.width * 3 + r.height * 4; }
EXPORT Mixed nextMixed(Mixed m) { return (Mixed){m.count + 1, m.scale * 2}; }
EXPORT DoubleLong nextDoubleLong(DoubleLong d) { return (DoubleLong){d.value * 2, d.count + 1}; }
EXPORT Triple rotate(Triple t) { return (Triple){t.b, t.c, t.a}; }
EXPORT Bytes3 rotateBytes(Bytes3 t) { return (Bytes3){t.b, t.c, t.a}; }
EXPORT Line reverseLine(Line l) { return (Line){l.to, l.from}; }
EXPORT float lineWeight(Line l) { return l.from.x + l.from.y * 2 + l.to.x * 3 + l.to.y * 4; }
EXPORT Flags flipFlags(Flags f)
{
    // Field by field: a compound literal with padding has clang call memset, which isn't linked.
    Flags flipped;
    flipped.on = !f.on;
    flipped.off = !f.off;
    flipped.count = f.count + 1;
    return flipped;
}
EXPORT int32_t weighFlags(Flags f) { return f.on + f.off * 2 + f.count * 4; }

// Shapes whose pieces clang types by the field at their start: { i32, i64 }, { float, double }, i48, float. Changed
// in place, since a compound literal with padding has clang call memset, which isn't linked.
EXPORT IntLong nextIntLong(IntLong v) { v.small += 1; v.large *= 2; return v; }
EXPORT FloatDouble nextFloatDouble(FloatDouble v) { v.single += 1; v.wide *= 2; return v; }
EXPORT Six nextSix(Six v) { v.a += 1; v.b *= 2; v.c -= 1; return v; }
// The bytes of a Six as C sees them, padding included, and then the parameter scribbled over, as C may: Win64
// passes it as the address of the caller's copy.
EXPORT uint64_t sixBytesThenScribble(Six s)
{
    volatile unsigned char *bytes = (volatile unsigned char *)&s;
    uint64_t seen = 0;
    for (int i = 0; i < (int)sizeof s; i++) seen |= (uint64_t)bytes[i] << (8 * i);
    for (int i = 0; i < (int)sizeof s; i++) bytes[i] = 0xAB;
    return seen;
}
EXPORT Single halveSingle(Single v) { v.value /= 2; return v; }
// The raw bytes of a structure, padding included: Flags crosses in a register, Wide in memory.
EXPORT uint64_t flagsBytes(Flags f) { return *(volatile uint64_t *)&f; }
EXPORT uint64_t wideBytes(Wide w) { volatile uint64_t *words = (volatile uint64_t *)&w; return words[0] ^ words[2]; }

// Over 16 bytes: in memory both ways.
EXPORT Five fiveFrom(int32_t start) { return (Five){start, start + 1, start + 2, start + 3, start + 4}; }
EXPORT int64_t weighFive(Five f) { return f.a + f.b * 2 + f.c * 3 + f.d * 4 + (int64_t)f.e * 5; }
EXPORT Five reverseFive(Five f) { return (Five){f.e, f.d, f.c, f.b, f.a}; }

// Pointers the library owns, one of them null when there's no second.
EXPORT Held hold(int64_t offset, bool second) { return (Held){block + offset, second ? block + offset + 1 : 0}; }
EXPORT int64_t heldDistance(Held h) { return h.maybe ? (char *)h.maybe - (char *)h.spot : -1; }
EXPORT int64_t spotOffset(Held h) { return (char *)h.spot - block; }

// More structures than either convention has registers for, each weighed by its position.
EXPORT float weighRectangles(Rectangle a, Rectangle b, Rectangle c, Rectangle d, Rectangle e)
{
    return weighRectangle(a) + weighRectangle(b) * 2 + weighRectangle(c) * 3 + weighRectangle(d) * 4
        + weighRectangle(e) * 5;
}

EXPORT int64_t weighHelds(Held a, Held b, Held c, Held d)
{
    return heldDistance(a) + heldDistance(b) * 2 + heldDistance(c) * 3 + heldDistance(d) * 4 + spotOffset(d) * 5;
}

// Enough structures passed in memory that the interpreter keeps their copies off its own stack.
EXPORT int64_t weighFives(Five a, Five b, Five c, Five d, Five e, Five f, Five g, Five h, Five i, Five j, Five k)
{
    return weighFive(a) + weighFive(b) * 2 + weighFive(c) * 3 + weighFive(d) * 4 + weighFive(e) * 5 + weighFive(f) * 6
        + weighFive(g) * 7 + weighFive(h) * 8 + weighFive(i) * 9 + weighFive(j) * 10 + weighFive(k) * 11;
}

// Structures mixed with scalars, after enough doubles that one structure no longer fits in the xmm
// registers left and goes on the stack, while the float after it still has one.
EXPORT double weighMixedCall(int64_t a, Vector2 b, double c, Color d, Five e, float f, DoubleLong g, int32_t h,
    double i, double j, double k, Rectangle m, Rectangle n, float o)
{
    return a + cross(b, (Vector2){1, 1}) * 2 + c * 3 + packColor(d) * 4.0 + weighFive(e) * 5 + f * 6 + g.value * 7
        + g.count * 7 + h * 8 + i * 9 + j * 10 + k * 11 + weighRectangle(m) * 13 + weighRectangle(n) * 14 + o * 15;
}

// A result through a hidden pointer, with arguments after it in registers and on the stack.
EXPORT Five combine(Five f, int32_t a, Vector2 v, double d, int64_t e, Color c)
{
    return (Five){f.a + a, f.b + (int32_t)v.x, f.c + (int32_t)v.y, f.d + (int32_t)d, f.e + (int32_t)e + c.a};
}
