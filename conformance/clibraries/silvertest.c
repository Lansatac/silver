// A shared library the conformance harness builds with clang, for cases that call natives of a
// `native library` of their own. Its functions use no C library, so it links with nothing.
#include <stdbool.h>
#include <stdint.h>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
// What the C runtime would define for a module that uses floating point.
int _fltused = 1;
#else
#define EXPORT
#endif

EXPORT int64_t add64(int64_t a, int64_t b) { return a + b; }
EXPORT uint64_t mix64(uint32_t high, uint64_t low) { return ((uint64_t)high << 32) ^ low; }
EXPORT int32_t negate32(int32_t x) { return -x; }
EXPORT uint32_t complement32(uint32_t x) { return ~x; }
EXPORT int8_t low8(int32_t x) { return (int8_t)x; }
EXPORT uint8_t lowUnsigned8(int32_t x) { return (uint8_t)x; }
EXPORT int16_t low16(int32_t x) { return (int16_t)x; }
EXPORT uint16_t lowUnsigned16(int32_t x) { return (uint16_t)x; }
EXPORT bool both(bool a, bool b) { return a && b; }
EXPORT bool isOdd(int64_t x) { return (x & 1) != 0; }
EXPORT double scale(double x, float by) { return x * by; }
EXPORT float halve(float x) { return x / 2; }
EXPORT float narrowed(double x) { return (float)x; }
EXPORT double widened(float x) { return x; }

// A pointer the library owns: an offset into a block of its own, and the null pointer.
static char block[64];
EXPORT void *at(int64_t offset) { return block + offset; }
EXPORT void *nowhere(void) { return 0; }
EXPORT int64_t distance(void *from, void *to) { return (char *)to - (char *)from; }
EXPORT bool isNull(void *p) { return p == 0; }

// More arguments than either convention has registers for, each weighed by its position so that one
// passed in the wrong place changes the sum.
EXPORT double weighMixed(int64_t a, double b, int32_t c, float d, int64_t e, double f, int64_t g, float h, int64_t i,
    double j, int64_t k, int64_t l, int64_t m, double n, double o, double p, double q, double r, float s, uint32_t t)
{
    return a * 1 + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10 + k * 11 + l * 12
        + m * 13 + n * 14 + o * 15 + p * 16 + q * 17 + r * 18 + s * 19 + t * 20.0;
}

EXPORT int64_t weighIntegers(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, int64_t f, int64_t g, int32_t h,
    uint64_t i, bool j)
{
    return a * 1 + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + (int64_t)i * 9 + j * 10;
}

EXPORT float weighFloats(float a, float b, float c, float d, float e, float f, float g, float h, float i, double j)
{
    return a * 1 + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + (float)j * 10;
}
