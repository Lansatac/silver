/// The runtime linked into every compiled Silver program. It's plain D with druntime, so
/// druntime's startup runs before any Silver code and the GC is available.
///
/// Generated IR calls into it through `extern(C)` functions only. Silver types cross that
/// boundary as:
///
///   Int -> long -> i64          Bool -> bool -> i1 zeroext
///   Float -> double -> double   String -> (const(char)*, size_t) -> ptr, i64 (no terminator)
///   Unit -> no argument, `void` return
///
/// Composite values (String, Option, closures) cross as separate scalars or a pointer, never
/// as a struct by value: hand-written IR doesn't get the platform's struct-passing rules
/// applied, and the two sides would silently disagree. A String is returned through two
/// out-pointers, for the same reason.
///
/// D exceptions mustn't unwind through Silver frames, which have no unwind info, so every
/// `extern(C)` function is `nothrow` and turns failures into `silver_panic`.
module silver.runtime.entry;

/// Generated code's entry point, which runs the program's `main`.
extern (C) void silver_main();

void main()
{
    silver_main();
}
