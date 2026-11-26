import silver.driver : endAtOnce, exactArguments, run;

/// What follows a program's file is the program's, so druntime doesn't take `--DRT-` options from it.
extern (C) __gshared bool rt_cmdline_enabled = false;

int main(string[] args)
{
    import std.exception : ErrnoException;
    import std.stdio : stdout, StdioException;

    import silver.interpreter : OutputFailed;

    // A write to a closed pipe then fails with EPIPE, which is reported, rather than killing the process.
    version (Posix)
    {
        import core.sys.posix.signal : SIG_IGN, SIGPIPE, signal;

        signal(SIGPIPE, SIG_IGN);
    }
    // What the tool itself writes to a closed pipe (a test report to `head`) ends it as the same failure of
    // a program's would: quietly, with status 1. Any other failure of a run is left to be what it was.
    int status;
    try status = run(exactArguments(args));
    catch (ErrnoException e)
    {
        if (OutputFailed.of(e.errno).closedPipe) endAtOnce(1);
        throw e;
    }
    catch (StdioException e)
    {
        if (OutputFailed.of(e.errno).closedPipe) endAtOnce(1);
        throw e;
    }
    // What's still buffered is written here, where a failure can be reported, rather than as D closes `stdout`.
    try stdout.flush();
    catch (ErrnoException e) endedByOutput(e.errno);
    catch (StdioException e) endedByOutput(e.errno);
    return status;
}

/// Ends as a failed write to standard output does: with the system's message, unless the reader closed the pipe.
private noreturn endedByOutput(int error)
{
    import std.stdio : stderr;

    import silver.interpreter : OutputFailed;

    auto failure = OutputFailed.of(error);
    if (!failure.closedPipe) stderr.writeln("error: ", failure.msg);
    endAtOnce(1);
}
