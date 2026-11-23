/// The runtime linked into every compiled Silver program. It's plain D with druntime, so
/// druntime's startup runs before any Silver code and the GC is available.
///
/// Generated IR calls into it through `extern(C)` functions only. Silver types cross that
/// boundary as:
///
///   Int -> long -> i64          Bool -> bool -> i1 zeroext
///   Float -> double -> double   String -> (const(char)*, size_t) -> ptr, i64 (no terminator)
///   Unit -> no argument, `void` return
///   [T] -> (T*, size_t) -> ptr, i64
///
/// Composite values (String, Option, closures) cross as separate scalars or a pointer, never
/// as a struct by value: hand-written IR doesn't get the platform's struct-passing rules
/// applied, and the two sides would silently disagree. A String is returned through two
/// out-pointers, for the same reason.
///
/// D exceptions mustn't unwind through Silver frames, which are `nounwind` whatever table they have,
/// so every `extern(C)` function is `nothrow` and turns failures, running out of memory among them,
/// into `silver_panic`.
module silver.runtime.entry;

/// What generated code defines to run the program's `main`, which the runtime calls on a thread of its own.
extern (C) void silver_main();

private enum stackSize = 256 * 1024 * 1024;
/// Room for the runtime's own frames below the deepest Silver one.
private enum margin = 1024 * 1024;

/// Every word after the program's name is the program's, so druntime doesn't take `--DRT-` options from
/// the command line. Its options from the environment are off unless a program turns them on.
extern (C) __gshared bool rt_cmdline_enabled = false;

/// The lowest address a Silver function may start at. Generated code checks it on entry,
/// and panics rather than running off the end of the stack.
extern (C) __gshared void* silver_stack_limit;

private void runProgram()
{
    ubyte marker;
    silver_stack_limit = &marker - stackSize + margin;
    silver_main();
}

/// The C `main` that generated code defines calls this, so the runtime can be a library like any other:
/// a linker looks for the entry point only in objects. It starts druntime as dmd's own `main` would.
extern (C) int silver_start(int argc, char** argv)
{
    return _d_run_main(argc, argv, &runMain);
}

private alias MainFunction = extern (C) int function(char[][] args);
private extern (C) int _d_run_main(int argc, char** argv, MainFunction mainFunction);

private extern (C) int runMain(char[][] args)
{
    import core.stdc.stdio : fprintf, stderr;
    import core.thread : Thread;
    import silver.runtime.arguments : takeArguments;

    // As an error returned from `main` is reported.
    if (auto mistake = takeArguments(cast(string[]) args))
    {
        fprintf(stderr, "error: %.*s\n", cast(int) mistake.length, mistake.ptr);
        return 1;
    }
    auto thread = new Thread(&runProgram, stackSize);
    thread.start();
    thread.join();
    return 0;
}
