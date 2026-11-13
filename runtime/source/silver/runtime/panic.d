/// Unrecoverable runtime errors: unwrapping `None`, an index out of range, and so on.
/// Generated code declares `silver_panic` noreturn and follows each call with `unreachable`.
module silver.runtime.panic;

import core.stdc.stdio : fflush, fprintf, stderr, stdout;
import core.stdc.stdlib : exit;
import core.stdc.string : strlen;

import silver.runtime.testing : panicInTest;

/// Prints `message` to stderr after `location`, which says where in the Silver source the failure
/// happened and is null for a failure of the runtime's own, and exits with `panicStatus`. In a test
/// it ends the test instead, or the `panics` call it's inside.
extern (C) noreturn silver_panic(const(char)* location, const(char)* message) nothrow @nogc
{
    silver_panic_message(location, message, strlen(message));
}

/// The `panic` intrinsic, whose `message` isn't NUL-terminated.
extern (C) noreturn silver_panic_message(const(char)* location, const(char)* message, size_t length) nothrow @nogc
{
    panicInTest(location, message, length);
    fflush(stdout);
    if (location is null) fprintf(stderr, "panic: %.*s\n", cast(int) length, message);
    else fprintf(stderr, "panic: %s: %.*s\n", location, cast(int) length, message);
    exit(panicStatus);
}

/// A panic's exit status, which the interpreter's driver also uses. An error returned from `main` exits with 1.
enum panicStatus = 101;

/// `main` returned an error, which `message` is, formatted. Not NUL-terminated.
extern (C) noreturn silver_exit_error(const(char)* message, size_t length) nothrow @nogc
{
    fflush(stdout);
    fprintf(stderr, "error: %.*s\n", cast(int) length, message);
    exit(1);
}

/// For the runtime's own failures.
noreturn panic(string message) nothrow
{
    import std.string : toStringz;

    silver_panic(null, message.toStringz);
}
