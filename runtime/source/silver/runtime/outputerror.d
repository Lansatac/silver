/// What a failed write to standard output was, for the runtime and the interpreter to answer alike: whether the
/// reader closed the pipe, and the message otherwise.
module silver.runtime.outputerror;

import core.stdc.errno : EBADF, EPIPE;

version (Windows)
{
    private extern (C) int* __doserrno() nothrow @nogc;

    private enum noData = 232, brokenPipe = 109;
}

/// The Win32 error behind the C library's last failure, which `errno` folds: the library maps every Win32 error
/// it has no errno for, a write to a closed pipe (`ERROR_NO_DATA`) among them, to EINVAL. 0 where there's none.
/// Read right after the failed call, before anything else can set it.
uint systemError() nothrow @nogc
{
    version (Windows) return *__doserrno();
    else return 0;
}

struct OutputError
{
    /// The reader closed the pipe, so the program ends without a message.
    bool closedPipe;
    private char[512] buffer;
    private size_t used;

    /// The system's message for the failure, in UTF-8.
    const(char)[] message() const return nothrow @nogc { return buffer[0 .. used]; }
}

/// Classifies a failure given the C library's `error` (an errno) and, on Windows, the `system` error read with it.
/// A closed pipe is EPIPE, or on Windows `ERROR_NO_DATA` or `ERROR_BROKEN_PIPE`, whatever errno they became.
OutputError describeOutputError(int error, uint system) nothrow @nogc
{
    import core.stdc.string : strerror, strlen;

    OutputError result;
    version (Windows) result.closedPipe = system == noData || system == brokenPipe;
    else result.closedPipe = error == EPIPE;
    if (result.closedPipe) return result;

    version (Windows)
    {
        // A bad descriptor is the library's own refusal, with no system error behind it.
        if (system != 0 && error != EBADF && windowsMessage(system, result)) return result;
    }
    auto text = strerror(error);
    auto length = strlen(text);
    if (length > result.buffer.length) length = result.buffer.length;
    result.buffer[0 .. length] = text[0 .. length];
    result.used = length;
    return result;
}

version (Windows)
{
    private bool windowsMessage(uint system, ref OutputError result) nothrow @nogc
    {
        import core.sys.windows.winbase : FormatMessageW, FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS;
        import core.sys.windows.winnls : CP_UTF8, WideCharToMultiByte;

        wchar[256] wide = void;
        auto count = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, null, system, 0,
            wide.ptr, cast(uint) wide.length, null);
        while (count > 0 && (wide[count - 1] == '\r' || wide[count - 1] == '\n' || wide[count - 1] == ' ')) count--;
        if (count == 0) return false;
        auto bytes = WideCharToMultiByte(CP_UTF8, 0, wide.ptr, cast(int) count, result.buffer.ptr,
            cast(int) result.buffer.length, null, null);
        if (bytes <= 0) return false;
        result.used = bytes;
        return true;
    }
}
