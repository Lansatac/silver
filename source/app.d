import silver.driver : endAtOnce, exactArguments, run;

/// What follows a program's file is the program's, so druntime doesn't take `--DRT-` options from it.
extern (C) __gshared bool rt_cmdline_enabled = false;

int main(string[] args)
{
    import std.exception : ErrnoException;
    import std.stdio : stdout, StdioException;

    import silver.runtime.outputerror : systemError;

    // A write to a closed pipe then fails with EPIPE, which is reported, rather than killing the process.
    version (Posix)
    {
        import core.sys.posix.signal : SIG_IGN, SIGPIPE, signal;

        signal(SIGPIPE, SIG_IGN);
    }
    // What the tool itself writes (a test report, a listing of Core) to a standard output that can't be written
    // ends it as a failed write of a program's would. An error from anything else is left to be what it was.
    int status;
    try status = run(exactArguments(args));
    catch (ErrnoException e)
    {
        if (!stdout.error) throw e;
        endedByOutput(e.errno, systemError);
    }
    catch (StdioException e)
    {
        if (!stdout.error) throw e;
        endedByOutput(e.errno, systemError);
    }
    // What's still buffered is written here, where a failure can be reported, rather than as D closes `stdout`.
    try stdout.flush();
    catch (ErrnoException e) endedByOutput(e.errno, systemError);
    catch (StdioException e) endedByOutput(e.errno, systemError);
    return status;
}

/// Ends as a failed write to standard output does: with the system's message, unless the reader closed the pipe.
private noreturn endedByOutput(int error, uint system)
{
    import std.stdio : stderr;

    import silver.interpreter : OutputFailed;

    auto failure = OutputFailed.of(error, system);
    if (!failure.closedPipe) stderr.writeln("error: ", failure.msg);
    endAtOnce(1);
}
