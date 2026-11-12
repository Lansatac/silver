/// Unrecoverable runtime errors: unwrapping `None`, an index out of range, and so on.
/// Generated code declares `silver_panic` noreturn and follows each call with `unreachable`.
module silver.runtime.panic;

import core.stdc.stdio : fflush, fprintf, stderr, stdout;
import core.stdc.stdlib : exit;
import core.stdc.string : strlen;

import silver.runtime.testing : panicInTest;

/// Prints `message` to stderr and exits with status 1, or in a test, ends the test. The message
/// should already say where in the Silver source the failure happened.
extern (C) noreturn silver_panic(const(char)* message) nothrow @nogc
{
    panicInTest(message, strlen(message));
    fflush(stdout);
    fprintf(stderr, "panic: %s\n", message);
    exit(1);
}

/// The `panic` intrinsic. `message` isn't NUL-terminated, and generated code has put the location in it.
extern (C) noreturn silver_panic_message(const(char)* message, size_t length) nothrow @nogc
{
    panicInTest(message, length);
    fflush(stdout);
    fprintf(stderr, "panic: %.*s\n", cast(int) length, message);
    exit(1);
}

/// For the runtime's own failures.
noreturn panic(string message) nothrow
{
    import std.string : toStringz;

    silver_panic(message.toStringz);
}
