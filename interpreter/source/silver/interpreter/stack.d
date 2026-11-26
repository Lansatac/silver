/// Keeps deep Silver recursion from overflowing the interpreter's own stack. A depth count
/// wouldn't do, since what one Silver call costs depends on the expressions it's nested in.
module silver.interpreter.stack;

import core.thread : Thread;

private enum stackSize = 512 * 1024 * 1024;
/// Room for the interpreter's work between two checks, and for unwinding after one fails.
private enum margin = 4 * 1024 * 1024;

/// The lowest address a check allows on this thread; zero on a thread not running a program.
private size_t stackLimit;

/// Runs `program` on a thread with a large stack, rethrowing whatever it throws.
void runOnLargeStack(void delegate() program)
{
    auto thread = new Thread({
        ubyte marker;
        stackLimit = cast(size_t) &marker - stackSize + margin;
        program();
    }, stackSize);
    thread.start();
    thread.join();
}

/// Whether the stack is nearly used up, which is a panic with `stackOverflow`. Anything that
/// recurses with the depth of a Silver value or call has to check this.
bool stackNearlyFull()
{
    ubyte marker;
    return cast(size_t) &marker < stackLimit;
}

/// What the panic says when the stack is nearly used up.
enum stackOverflow = "Stack overflow";
