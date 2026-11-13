/// Running a program's tests. Generated code runs each one through a guard that the test can
/// jump back to, so a panic, or `?` on `None`, ends only that test.
///
/// What happens is written to stdout as records for `silver test` to read, each a kind letter, the
/// length of its text, a newline, the text and a newline:
///
///   T  a test starts; the text is its index      F  an `expect` failed
///   S  the test stopped, as `?` on `None` does   P  the test panicked
///   O  some of what the test printed             E  the test is over
///
/// A `panics` call runs its work through a guard of its own, nested in the test's. A panic under
/// it is kept for the call to hand back rather than recorded.
///
/// A test with no `E` crashed. `SILVER_TEST_FROM` names the index to start at, so the runner can
/// carry on after one.
module silver.runtime.testing;

import core.stdc.stdio : fflush, fprintf, fwrite, snprintf, stdout;
import core.stdc.stdlib : abort, getenv, realloc, strtoull;
import core.stdc.string : strlen;

/// Whether the program is running its tests rather than `main`.
__gshared bool testing;
/// Whether a test is running, which is when a panic returns to the guard.
private __gshared bool inTest;
private alias Jump = extern (C) void function() nothrow @nogc;
private __gshared Jump escape;
private __gshared size_t firstTest;
/// How many `panics` calls are running, each inside the one before.
private __gshared size_t panicsDepth;
/// The guard each of them runs under, `jumpSize` pointers apiece.
private __gshared void** outerGuards;
private __gshared size_t outerGuardsRoom;
private __gshared const(char)* caughtMessage;
private __gshared size_t caughtLength;
/// How many pointers LLVM's setjmp buffer holds.
private enum jumpSize = 5;

version (Windows)
{
    private enum _O_BINARY = 0x8000;
    private extern (C) int _setmode(int descriptor, int mode) nothrow @nogc;
}

extern (C) nothrow:

/// Starts running tests. `jump` returns to the guard of the running test.
void silver_test_start(Jump jump)
{
    testing = true;
    escape = jump;
    // Text mode would write each newline as two bytes, which the records' lengths don't count.
    version (Windows) _setmode(1, _O_BINARY);
    if (auto from = getenv("SILVER_TEST_FROM")) firstTest = cast(size_t) strtoull(from, null, 10);
}

/// Whether test `index` is to run. If it is, it's begun.
bool silver_test_begin(size_t index)
{
    if (index < firstTest) return false;
    char[24] digits;
    auto length = cast(size_t) snprintf(digits.ptr, digits.length, "%zu", index);
    record('T', digits.ptr, length);
    inTest = true;
    return true;
}

/// Ends the running test, however it ended.
void silver_test_end()
{
    inTest = false;
    record('E', null, 0);
}

/// Output while testing, which the runner shows only for a test that fails.
void testOutput(const(char)[] text) @nogc
{
    record('O', text.ptr, text.length);
}

/// `expect` failing: `message` says where, and the test carries on.
void silver_test_failed(const(char)* message, size_t length)
{
    record('F', message, length);
}

/// The test stopping, as `?` on `None` stops it.
noreturn silver_test_stopped(const(char)* message, size_t length)
{
    record('S', message, length);
    leave();
}

/// A panic in a test, which ends it, or ends the `panics` call it's under. Returns if no test is
/// running.
void panicInTest(const(char)* location, const(char)* message, size_t length) @nogc
{
    if (!inTest) return;
    if (panicsDepth > 0)
    {
        caughtMessage = message;
        caughtLength = length;
        escape();
        assert(0, "the guard doesn't return here");
    }
    auto locationLength = location is null ? 0 : strlen(location);
    fprintf(stdout, "P %zu\n", locationLength == 0 ? length : locationLength + 2 + length);
    if (locationLength > 0)
    {
        fwrite(location, 1, locationLength, stdout);
        fwrite(": ".ptr, 1, 2, stdout);
    }
    if (length > 0) fwrite(message, 1, length, stdout);
    fwrite("\n".ptr, 1, 1, stdout);
    fflush(stdout);
    leave();
}

/// Starts a `panics` call, keeping the guard that `jump` holds while the call's own is there.
void silver_panics_enter(void** jump)
{
    if (panicsDepth == outerGuardsRoom)
    {
        outerGuardsRoom = outerGuardsRoom == 0 ? 8 : outerGuardsRoom * 2;
        outerGuards = cast(void**) realloc(outerGuards, outerGuardsRoom * jumpSize * (void*).sizeof);
        if (outerGuards is null) abort();
    }
    outerGuards[panicsDepth * jumpSize .. (panicsDepth + 1) * jumpSize] = jump[0 .. jumpSize];
    panicsDepth++;
}

/// Ends a `panics` call, however its work ended, putting back the guard it was under.
void silver_panics_leave(void** jump)
{
    panicsDepth--;
    jump[0 .. jumpSize] = outerGuards[panicsDepth * jumpSize .. (panicsDepth + 1) * jumpSize];
}

/// The message of the panic that ended the `panics` call that has just left, without its location.
void silver_panics_message(const(char)** data, size_t* length)
{
    *data = caughtMessage;
    *length = caughtLength;
    caughtMessage = null;
}

private noreturn leave() @nogc
{
    inTest = false;
    escape();
    assert(0, "the guard doesn't return here");
}

private void record(char kind, const(char)* text, size_t length) @nogc
{
    fprintf(stdout, "%c %zu\n", kind, length);
    if (length > 0) fwrite(text, 1, length, stdout);
    fwrite("\n".ptr, 1, 1, stdout);
    // Flushed at once, so a crash loses none of it.
    fflush(stdout);
}
