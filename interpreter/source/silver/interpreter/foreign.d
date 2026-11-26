/// Calling C from the interpreter: finding a native's symbol, and calling it as the platform's
/// convention says, through a trampoline that loads the registers and stack words `describeCall`
/// gives, so the interpreter passes what compiled code passes. `callC` is the one way in, so libffi
/// could replace the trampoline without anything else changing.
module silver.interpreter.foreign;

import silver.core.abi;

/// What the result registers held when a C function returned: `rax` and `rdx`, and the low 64 bits
/// of `xmm0` and `xmm1`.
struct Returned
{
    ulong[2] integers;
    ulong[2] floats;
}

/// Calls the C function at `address` as `call` describes, with `words` holding the bits of each part
/// of each argument in order, a narrow integer already extended as the part says and a `float` in the
/// low 32 bits. A result that comes back through a hidden pointer is written to `hidden`.
Returned callC(const(void)* address, const ref CallDescription call, const(ulong)[] words, void* hidden = null)
{
    assert(call.convention == hostConvention, "the trampoline follows only the convention it runs under");
    CallFrame frame;
    frame.function_ = address;
    ulong[16] few;
    auto stack = call.stackWords <= few.length ? few[0 .. call.stackWords] : new ulong[call.stackWords];
    if (call.result.passing == Passing.hidden)
    {
        auto place = call.result.parts[0].place;
        assert(hidden !is null && place.where == Where.integerRegister, "a hidden result pointer is in an integer register");
        frame.integers[place.index] = cast(ulong) hidden;
    }
    size_t next;
    foreach (ref argument; call.arguments)
    {
        foreach (part; argument.parts)
        {
            auto bits = words[next++];
            final switch (part.place.where)
            {
                case Where.integerRegister:
                    frame.integers[part.place.index] = bits;
                    break;
                case Where.floatRegister:
                    frame.floats[part.place.index] = bits;
                    break;
                case Where.stack:
                    stack[part.place.index] = bits;
                    break;
            }
        }
    }
    assert(next == words.length, "a word for each part");
    frame.stack = stack.ptr;
    frame.stackWords = stack.length;
    trampoline(&frame);
    if (nativeOutOfMemory)
    {
        import core.exception : onOutOfMemoryError;

        nativeOutOfMemory = false;
        onOutOfMemoryError();
    }
    return Returned(frame.integerResults, frame.floatResults);
}

/// The registers and stack words of a call. The trampoline reads and writes it by these offsets.
private struct CallFrame
{
    const(void)* function_;
    const(ulong)* stack;
    size_t stackWords;
    /// Win64 uses the first four.
    ulong[6] integers;
    /// Win64 uses the first four.
    ulong[8] floats;
    ulong[2] integerResults;
    ulong[2] floatResults;
}

static assert(CallFrame.stack.offsetof == 8 && CallFrame.stackWords.offsetof == 16 && CallFrame.integers.offsetof == 24
    && CallFrame.floats.offsetof == 72 && CallFrame.integerResults.offsetof == 136 && CallFrame.floatResults.offsetof == 152);

version (D_InlineAsm_X86_64) {}
else static assert(0, "calling a native from the interpreter needs dmd's x86-64 assembler");

version (Windows)
{
    /// Copies the stack words above 32 bytes of shadow space, loads every argument register, calls,
    /// and keeps the result registers. RBX holds the frame across the call, as a callee preserves it.
    private extern (C) void trampoline(CallFrame* frame) nothrow
    {
        asm nothrow
        {
            naked;
            push RBP;
            mov RBP, RSP;
            push RBX;
            push RSI;
            push RDI;
            push R12;
            mov RBX, RCX;
            // 32 bytes of shadow space and the stack words, rounded to keep RSP 16-byte aligned.
            mov RAX, [RBX + 16];
            lea RAX, [RAX * 8 + 47];
            and RAX, -16;
            sub RSP, RAX;
            mov RSI, [RBX + 8];
            mov RCX, [RBX + 16];
            lea RDI, [RSP + 32];
        copy:
            test RCX, RCX;
            jz copied;
            mov RAX, [RSI];
            mov [RDI], RAX;
            add RSI, 8;
            add RDI, 8;
            dec RCX;
            jmp copy;
        copied:
            movq XMM0, [RBX + 72];
            movq XMM1, [RBX + 80];
            movq XMM2, [RBX + 88];
            movq XMM3, [RBX + 96];
            mov RCX, [RBX + 24];
            mov RDX, [RBX + 32];
            mov R8, [RBX + 40];
            mov R9, [RBX + 48];
            call qword ptr [RBX];
            mov [RBX + 136], RAX;
            mov [RBX + 144], RDX;
            movq [RBX + 152], XMM0;
            movq [RBX + 160], XMM1;
            lea RSP, [RBP - 32];
            pop R12;
            pop RDI;
            pop RSI;
            pop RBX;
            pop RBP;
            ret;
        }
    }
}
else
{
    /// Copies the stack words, loads every argument register, calls, and keeps the result registers.
    /// RBX holds the frame across the call, as a callee preserves it. AL is an upper bound on the xmm
    /// registers used, which only a function with variable arguments reads.
    private extern (C) void trampoline(CallFrame* frame) nothrow
    {
        asm nothrow
        {
            naked;
            push RBP;
            mov RBP, RSP;
            push RBX;
            push R12;
            mov RBX, RDI;
            mov RAX, [RBX + 16];
            lea RAX, [RAX * 8 + 15];
            and RAX, -16;
            sub RSP, RAX;
            mov RSI, [RBX + 8];
            mov RCX, [RBX + 16];
            mov RDI, RSP;
        copy:
            test RCX, RCX;
            jz copied;
            mov RAX, [RSI];
            mov [RDI], RAX;
            add RSI, 8;
            add RDI, 8;
            dec RCX;
            jmp copy;
        copied:
            movq XMM0, [RBX + 72];
            movq XMM1, [RBX + 80];
            movq XMM2, [RBX + 88];
            movq XMM3, [RBX + 96];
            movq XMM4, [RBX + 104];
            movq XMM5, [RBX + 112];
            movq XMM6, [RBX + 120];
            movq XMM7, [RBX + 128];
            mov RDI, [RBX + 24];
            mov RSI, [RBX + 32];
            mov RDX, [RBX + 40];
            mov RCX, [RBX + 48];
            mov R8, [RBX + 56];
            mov R9, [RBX + 64];
            mov EAX, 8;
            call qword ptr [RBX];
            mov [RBX + 136], RAX;
            mov [RBX + 144], RDX;
            movq [RBX + 152], XMM0;
            movq [RBX + 160], XMM1;
            lea RSP, [RBP - 16];
            pop R12;
            pop RBX;
            pop RBP;
            ret;
        }
    }
}

/// The address of the C function `symbol`: in the shared library `library` names, or without one,
/// in the runtime's natives and then the C library. Null, with `problem` saying why, when it can't
/// be found.
const(void)* findNative(string symbol, string library, out string problem)
{
    import std.format : format;

    if (library is null)
    {
        if (auto runtime = symbol in runtimeNatives) return *runtime;
        foreach (handle; cLibrary)
        {
            if (auto address = symbolIn(handle, symbol)) return address;
        }
        problem = "`%s` is in neither Silver's runtime nor the C library".format(symbol);
        return null;
    }
    auto handles = loaded(library);
    if (handles.length == 0)
    {
        problem = "the library `%s` can't be loaded: interpreting needs it as the shared library %s, where the system finds shared libraries, and can't use a static one"
            .format(library, sharedLibraryFile(library));
        return null;
    }
    foreach (handle; handles)
    {
        if (auto address = symbolIn(handle, symbol)) return address;
    }
    problem = "`%s` isn't in %s".format(symbol, sharedLibraryFile(library));
    return null;
}

/// The file a shared library `name` is in, as the system's loader looks for it.
string sharedLibraryFile(string name)
{
    version (Windows) return name ~ ".dll";
    else return "lib" ~ name ~ ".so";
}

/// The runtime's natives, which the interpreter compiles in.
private immutable const(void)*[string] runtimeNatives;

/// Whether a runtime native running on this thread ran out of memory, which `callC` reports once it
/// returns, since nothing can be thrown through the trampoline.
private bool nativeOutOfMemory;

private void noteOutOfMemory() nothrow @nogc
{
    nativeOutOfMemory = true;
}

shared static this()
{
    import silver.runtime.clock : clockOutOfMemory, silver_localOffsetSeconds, silver_monotonicNanos, silver_nowNanos;

    clockOutOfMemory = &noteOutOfMemory;

    const(void)*[string] table;
    table["silver_nowNanos"] = &silver_nowNanos;
    table["silver_monotonicNanos"] = &silver_monotonicNanos;
    table["silver_localOffsetSeconds"] = &silver_localOffsetSeconds;
    runtimeNatives = cast(immutable) table;
}

/// The C library's modules, where a native in a module with no `native library` is looked for:
/// the C runtime that compiled programs link, on Windows, and the process's own symbols elsewhere,
/// libc's and libm's among them.
private const(void*)[] cLibrary()
{
    version (Windows) return [loadedFile("ucrtbase.dll"), loadedFile("vcruntime140.dll")];
    else
    {
        import core.sys.posix.dlfcn : dlopen, RTLD_NOW;

        return [dlopen(null, RTLD_NOW)];
    }
}

/// The shared library `library` names, loaded: on Linux the shared libraries its `.so` names instead
/// when that is a linker script, as glibc's `libm.so` and `libc.so` are, which the linker follows and
/// the loader doesn't. Empty when it can't be loaded.
private void*[] loaded(string library)
{
    auto file = sharedLibraryFile(library);
    if (auto handle = loadedFile(file)) return [handle];
    version (linux)
    {
        void*[] handles;
        foreach (named; sharedLibrariesOfScript(linkerScriptFor(file)))
        {
            if (auto handle = loadedFile(named)) handles ~= handle;
        }
        return handles;
    }
    else return null;
}

version (linux)
{
    /// The text of the linker script that the linker would find as `file`, or null: the first `file`
    /// in the linker's directories that isn't an ELF file.
    private string linkerScriptFor(string file)
    {
        import std.algorithm : splitter;
        import std.file : exists, isFile, read;
        import std.path : buildPath;
        import std.process : environment;

        string[] directories;
        foreach (variable; ["LIBRARY_PATH", "LD_LIBRARY_PATH"])
        {
            foreach (directory; environment.get(variable, "").splitter(':')) if (directory.length) directories ~= directory;
        }
        directories ~= ["/usr/local/lib/x86_64-linux-gnu", "/usr/local/lib", "/lib/x86_64-linux-gnu",
            "/usr/lib/x86_64-linux-gnu", "/lib64", "/usr/lib64", "/lib", "/usr/lib"];
        foreach (directory; directories)
        {
            auto path = buildPath(directory, file);
            try
            {
                if (!exists(path) || !isFile(path)) continue;
                auto text = cast(string) read(path, 4096);
                return text.length >= 4 && text[0 .. 4] == "\x7fELF" ? null : text;
            }
            catch (Exception) continue;
        }
        return null;
    }

    /// The shared libraries a linker script's `GROUP` and `INPUT` name, in order, as paths or names:
    /// every word that names a `.so` file, those under `AS_NEEDED` included, and no static library.
    private string[] sharedLibrariesOfScript(string script)
    {
        import std.algorithm : canFind, countUntil, endsWith, splitter;

        // Bytes, not UTF-8: the file may be neither ELF nor text.
        auto bytes = cast(const(ubyte)[]) script;
        // Comments, which may hold any words, go first.
        ubyte[] text;
        while (bytes.length > 0)
        {
            auto start = bytes.countUntil(cast(const(ubyte)[]) "/*");
            if (start < 0)
            {
                text ~= bytes;
                break;
            }
            text ~= bytes[0 .. start];
            auto end = bytes[start .. $].countUntil(cast(const(ubyte)[]) "*/");
            bytes = end < 0 ? null : bytes[start + end + 2 .. $];
        }
        string[] named;
        foreach (word; text.splitter!(c => c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == '(' || c == ')' || c == ','))
        {
            if (word.canFind(cast(const(ubyte)[]) ".so.") || (word.length > 3 && word.endsWith(cast(const(ubyte)[]) ".so")))
            {
                named ~= (cast(const(char)[]) word).idup;
            }
        }
        return named;
    }

    @("a linker script's shared libraries are what its GROUP names, without its comments or static libraries")
    unittest
    {
        auto script = "/* GNU ld script\n   Use the shared library, but some functions are only in libx.so.9 */\n"
            ~ "OUTPUT_FORMAT(elf64-x86-64)\nGROUP ( /usr/lib/libc.so.6 /usr/lib/libc_nonshared.a  AS_NEEDED ( /lib64/ld-linux-x86-64.so.2 ) )\n";
        assert(sharedLibrariesOfScript(script) == ["/usr/lib/libc.so.6", "/lib64/ld-linux-x86-64.so.2"]);
        assert(sharedLibrariesOfScript(null) == []);
    }

    @("a file that is neither ELF nor text names no libraries, and is no exception")
    unittest
    {
        assert(sharedLibrariesOfScript("\xff\xfe\x00GROUP ( \xc3 )") == []);
    }
}

/// The shared library `file`, loaded by the system's own search, or null. A library stays loaded.
private void* loadedFile(string file)
{
    version (Windows)
    {
        import core.sys.windows.winbase : LoadLibraryW;
        import std.utf : toUTF16z;

        return LoadLibraryW(file.toUTF16z);
    }
    else
    {
        import core.sys.posix.dlfcn : dlopen, RTLD_NOW;
        import std.string : toStringz;

        return dlopen(file.toStringz, RTLD_NOW);
    }
}

private const(void)* symbolIn(const(void)* handle, string symbol)
{
    import std.string : toStringz;

    if (handle is null) return null;
    version (Windows)
    {
        import core.sys.windows.winbase : GetProcAddress;
        import core.sys.windows.windef : HMODULE;

        return GetProcAddress(cast(HMODULE) handle, symbol.toStringz);
    }
    else
    {
        import core.sys.posix.dlfcn : dlsym;

        return dlsym(cast(void*) handle, symbol.toStringz);
    }
}

@("the trampoline passes each kind of scalar in the registers and stack words the convention gives it")
unittest
{
    import core.stdc.math : pow, sqrtf;

    CType[] scalars(const CKind[] kinds...)
    {
        CType[] types;
        foreach (kind; kinds) types ~= scalar(kind);
        return types;
    }

    auto call = describeCall(scalars(CKind.double_, CKind.double_), scalar(CKind.double_), hostConvention);
    auto returned = callC(&pow, call, [bitsOf(2.0), bitsOf(10.0)]);
    assert(*cast(double*) &returned.floats[0] == 1024);

    call = describeCall(scalars(CKind.float_), scalar(CKind.float_), hostConvention);
    returned = callC(&sqrtf, call, [bitsOf(2.0f)]);
    assert(*cast(float*) &returned.floats[0] == sqrtf(2.0f));

    with (CKind) call = describeCall(scalars(int64, double_, int32, float_, int64, double_, int64, float_, int64, double_,
        int64, int64, int64, double_, double_, double_, double_, double_, float_, int8), scalar(double_), hostConvention);
    assert(call.stackWords > 0);
    ulong[] words = [1, bitsOf(2.0), cast(uint) -3, bitsOf(4.0f), 5, bitsOf(6.0), 7, bitsOf(8.0f), 9, bitsOf(10.0), 11,
        12, 13, bitsOf(14.0), bitsOf(15.0), bitsOf(16.0), bitsOf(17.0), bitsOf(18.0), bitsOf(19.0f), cast(ulong) -20L];
    returned = callC(&weighed, call, words);
    assert(*cast(double*) &returned.floats[0] == weighedSum);
}

@("a native is found in the runtime, the C library and a shared library, and a missing one says why")
unittest
{
    import std.algorithm : canFind;

    string problem;
    assert(findNative("silver_nowNanos", null, problem) !is null && problem is null);
    assert(findNative("strlen", null, problem) !is null);
    assert(findNative("sqrtf", null, problem) !is null);
    assert(findNative("silver_no_such_function", null, problem) is null);
    assert(problem == "`silver_no_such_function` is in neither Silver's runtime nor the C library", problem);
    assert(findNative("f", "silver_no_such_library", problem) is null);
    assert(problem.canFind(sharedLibraryFile("silver_no_such_library")) && problem.canFind("can't use a static one"), problem);
}

version (linux)
@("a library whose .so is a linker script, as glibc's libm.so is, is found when interpreting as the linker finds it")
unittest
{
    string problem;
    assert(findNative("cbrt", "m", problem) !is null, problem);
}

version (unittest)
{
    private ulong bitsOf(double value) => *cast(ulong*) &value;
    private ulong bitsOf(float value) => *cast(uint*) &value;

    /// Each argument times its position, so an argument in the wrong place changes the sum.
    private extern (C) double weighed(long a, double b, int c, float d, long e, double f, long g, float h, long i,
        double j, long k, long l, long m, double n, double o, double p, double q, double r, float s, byte t)
    {
        double[] all = [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t];
        double sum = 0;
        foreach (position, value; all) sum += value * (position + 1);
        return sum;
    }

    private double weighedSum()
    {
        double sum = 0;
        foreach (position; 0 .. 20)
        {
            double value = position + 1;
            if (position == 2 || position == 19) value = -value;
            sum += value * (position + 1);
        }
        return sum;
    }
}

/// A copy of `text`'s bytes followed by a NUL, as the runtime's `silver_toCString` makes it. The
/// collector keeps it while a `Handle` points to it.
void* toCString(const(char)[] text)
{
    auto copy = new char[text.length + 1];
    copy[0 .. text.length] = text;
    copy[text.length] = 0;
    return copy.ptr;
}

/// The bytes up to the NUL as a String, or null if they aren't UTF-8. An empty String is not null.
string fromCString(const(void)* pointer)
{
    import core.stdc.string : strlen;

    auto bytes = (cast(const(ubyte)*) pointer)[0 .. strlen(cast(const(char)*) pointer)];
    if (!isUtf8(bytes)) return null;
    return bytes.length == 0 ? "" : (cast(const(char)[]) bytes).idup;
}

/// Whether `bytes` are UTF-8, as `std.utf.validate` decides it but without the exception it
/// throws, which costs milliseconds: no overlong form, surrogate, or code point past U+10FFFF.
private bool isUtf8(const(ubyte)[] bytes)
{
    size_t i = 0;
    while (i < bytes.length)
    {
        auto lead = bytes[i];
        if (lead < 0x80)
        {
            i++;
            continue;
        }
        size_t following;
        uint lowest;
        if ((lead & 0xE0) == 0xC0)
        {
            following = 1;
            lowest = 0x80;
        }
        else if ((lead & 0xF0) == 0xE0)
        {
            following = 2;
            lowest = 0x800;
        }
        else if ((lead & 0xF8) == 0xF0)
        {
            following = 3;
            lowest = 0x10000;
        }
        else return false;
        if (bytes.length - i <= following) return false;
        uint code = lead & (0x3F >> following);
        foreach (b; bytes[i + 1 .. i + 1 + following])
        {
            if ((b & 0xC0) != 0x80) return false;
            code = (code << 6) | (b & 0x3F);
        }
        if (code < lowest || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return false;
        i += 1 + following;
    }
    return true;
}

/// `0x` and the address in lowercase hex digits, as the runtime prints a native type's value.
string addressText(const(void)* address)
{
    import std.format : format;

    return format("0x%x", cast(size_t) address);
}

@("a C string is a copy with a NUL, and comes back only if it's UTF-8")
unittest
{
    auto copy = cast(char*) toCString("a\0b");
    assert(copy[0 .. 4] == "a\0b\0");
    assert(fromCString(toCString("héllo")) == "héllo");
    assert(fromCString(toCString("")) !is null);
    assert(addressText(cast(void*) 0xab12) == "0xab12");
    // Overlong, surrogate, past U+10FFFF, five bytes, cut short, a stray continuation, a bad lead.
    foreach (bad; ["\xff", "\xC0\x80", "\xE0\x80\x80", "\xED\xA0\x80", "\xF4\x90\x80\x80", "\xF8\x88\x80\x80\x80",
        "\xE2\x82", "a\x80", "\xC3("])
    {
        assert(fromCString(toCString(bad)) is null, bad);
    }
    foreach (good; ["߿", "퟿", "", "￿", "\U0010FFFF", "aé日"])
    {
        assert(fromCString(toCString(good)) == good, good);
    }
}
