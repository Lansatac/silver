module silver.interpreter.tests;

version (unittest)
{
    import fluent.asserts;

    import silver.ast : formatDiagnostic, SourceContext;
    import silver.core : lowerProgram;
    import silver.interpreter.evaluator : Evaluator;
    import silver.loader : load, Packages, standardPrelude, withStandardLibrary;
    import silver.sema : analyze;

    /// Runs `source` as the driver does, failing on anything the loader or sema reports, started in
    /// `directory` when there is one.
    private string run(string source, string directory = null)
    {
        import std.algorithm : map;
        import std.array : join;

        auto context = new SourceContext;
        auto program = load(source, "test", Packages(withStandardLibrary([])), standardPrelude, context);
        assert(!context.collector.hasErrors, context.collector.errors
                .map!(d => formatDiagnostic(d, context.sources)).join("\n"));
        auto analysis = analyze(program, context.collector);
        assert(!context.collector.hasErrors, context.collector.errors
                .map!(d => formatDiagnostic(d, context.sources)).join("\n"));
        auto evaluator = new Evaluator(lowerProgram(program, analysis), false, null, directory);
        evaluator.run();
        return evaluator.output;
    }

    /// Runs `body` as the body of `main`.
    private string runMain(string body)
    {
        return run("def main(): Unit {\n" ~ body ~ "\n}");
    }
}

@("a let binds its value, and a let reusing a name in a sibling block is a local of its own")
unittest
{
    runMain(`
    val a = 1
    val b = a + 2
    printl(b)
    {
        val c = 10
        printl(c)
    }
    {
        val c = b * 2
        printl(c)
    }
`).should.equal("3\n10\n6\n");
}

@("a Float32 is computed and printed in single precision")
unittest
{
    runMain(`
    val big = Float32(16777216.0)
    printl(big + Float32(1.0) == big)
    printl(Float32(0.1) + Float32(0.2))
    printl(Float(Float32(0.1)))
    printl(Float32(1e300))
    printl(Int(Float32(2.9)))
`).should.equal("true\n0.3\n0.10000000149011612\ninf\n2\n");
}

@("a native the interpreter has is called by its symbol")
unittest
{
    run("native def sqrt(x: Float): Float\nnative def pow(base: Float, exponent: Float): Float\n"
        ~ "native(\"silver_nowNanos\") def nowNanos(): Int\ndef main(): Unit {\n    printl(sqrt(16))\n    printl(pow(2, 10))\n"
        ~ "    val now = nowNanos()\n    printl(now > 1600000000000000000)\n}").should.equal("4.0\n1024.0\ntrue\n");
}

@("a native type is the real pointer, and an option of one crosses into C as one that may be null")
unittest
{
    run("import std.c\nnative def strchr(text: CString, c: CInt): CString?\nnative def strlen(text: CString): CSize\n"
        ~ "def main(): Unit {\n    val text = toCString(\"abc\")\n    printl(fromCString(strchr(text, 98) ?? text))\n"
        ~ "    printl(strchr(text, 122))\n    printl(strlen(text))\n    printl(String(text) == String(text))\n}")
        .should.equal("Some(bc)\nNone\n3\ntrue\n");
}

@("read reports input it can't read as InputFailed, with the OS's message")
unittest
{
    // Windows can't open a directory as a file.
    version (Posix)
    {
        import std.file : tempDir;
        import std.stdio : File, stdin;

        auto original = stdin;
        stdin = File(tempDir, "rb");
        scope (exit) stdin = original;
        runMain("printl(read())").should.equal("Error(couldn't read input: Is a directory)\n");
    }
}

@("a relative path is relative to the directory the program is given, and an absolute one isn't")
unittest
{
    import std.array : replace;
    import std.conv : to;
    import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    auto directory = buildPath(tempDir, "silver-interpreter-directory-" ~ thisProcessID.to!string);
    mkdirRecurse(directory);
    scope (exit) rmdirRecurse(directory);
    // An absolute path, with `/` so it needs no escaping in Silver.
    auto elsewhere = buildPath(directory, "elsewhere.txt").replace("\\", "/");
    auto source = "import std.file\ndef main(): Unit ! IoError {\n    writeFile(\"here.txt\", \"near\")?\n"
        ~ "    writeFile(\"" ~ elsewhere ~ "\", \"far\")?\n"
        ~ "    printl(readFile(\"here.txt\")?)\n    printl(exists(\"here.txt\"))\n}";
    run(source, directory).should.equal("near\ntrue\n");
    readText(buildPath(directory, "here.txt")).should.equal("near");
    readText(elsewhere).should.equal("far");
}

@("a native that can't be found is an error before main, at its first call, not a panic")
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectException;
    import silver.ast : DiagnosticCode, DiagnosticException;
    import silver.interpreter.errors : RuntimeError;
    import silver.interpreter.foreign : sharedLibraryFile;

    auto error = collectException!DiagnosticException(run("native def silver_no_such_function(x: Float): Float\n"
        ~ "def main(): Unit {\n    printl(1)\n    printl(silver_no_such_function(8.0))\n}"));
    assert(error !is null && cast(RuntimeError) error is null);
    error.diagnostic.code.should.equal(DiagnosticCode.MissingNativeBinding);
    error.diagnostic.message.should.equal("`silver_no_such_function` can't be called when interpreting: "
        ~ "`silver_no_such_function` is in neither Silver's runtime nor the C library");
    error.diagnostic.span.start.should.equal(96);

    error = collectException!DiagnosticException(run("native library \"silver_no_such_library\"\nnative def f(): Unit\n"
        ~ "def main(): Unit => f()"));
    assert(error !is null && cast(RuntimeError) error is null);
    error.diagnostic.code.should.equal(DiagnosticCode.MissingNativeBinding);
    assert(error.diagnostic.message.canFind(sharedLibraryFile("silver_no_such_library"))
        && error.diagnostic.message.canFind("can't use a static one"), error.diagnostic.message);
}

@("two natives that bind one symbol with signatures C passes differently are refused, as when compiling")
unittest
{
    import std.exception : collectException;
    import silver.ast : DiagnosticCode, DiagnosticException;

    auto error = collectException!DiagnosticException(run("native(\"llabs\") def a(x: Int64): Int64\n"
        ~ "native(\"llabs\") def b(x: Float): Float\ndef main(): Unit {\n    printl(a(-1))\n    printl(b(1.0))\n}"));
    assert(error !is null);
    error.diagnostic.code.should.equal(DiagnosticCode.NotImplemented);
    error.diagnostic.message.should.contain("`llabs`");

    // Aliases of one type, and handles of two types, are passed alike.
    run("import std.c\nnative type A\nnative type B\nnative(\"strchr\") def a(s: CString, c: CInt): A?\n"
        ~ "native(\"strchr\") def b(s: CString, c: Int32): B?\ndef main(): Unit {\n"
        ~ "    printl(a(toCString(\"x\"), 120) == None)\n    printl(b(toCString(\"x\"), 121) == None)\n}")
        .should.equal("false\ntrue\n");
}

@("a native parameter narrower than C's int is refused when called, as Windows leaves its upper bits undefined")
unittest
{
    import std.exception : collectException;
    import silver.ast : DiagnosticCode;
    import silver.interpreter.errors : RuntimeError;

    auto error = collectException!RuntimeError(run("native def abs(x: Int8): Int8\ndef main(): Unit {\n"
        ~ "    printl(abs(-3))\n}"));
    assert(error !is null);
    error.diagnostic.code.should.equal(DiagnosticCode.MissingNativeBinding);
    error.diagnostic.message.should.contain("narrower than C's `int`");
}

@("a native can be declared with any types C passes the same way, a pointer as a 64-bit integer included")
unittest
{
    run("import std.c\nnative def malloc(size: UInt32): UInt64\nnative def free(address: UInt64): Unit\n"
        ~ "native def strcmp(a: CString, b: CString): UInt8\ndef main(): Unit {\n    val address = malloc(8)\n"
        ~ "    printl(address != 0)\n    free(address)\n    printl(strcmp(toCString(\"a\"), toCString(\"b\")))\n}")
        .should.equal("true\n255\n");
}

@("an instance of a generic function prints with its type arguments")
unittest
{
    run("type Box<T>(value: T)\ndef identity<T>(x: T): T => x\ndef main(): Unit {\n    printl(identity<Int>)\n"
        ~ "    printl(Box<String>)\n}").should.equal("identity<Int>\nBox<String>\n");
}

@("the test helper fails on a module that doesn't load, rather than resolving without it")
unittest
{
    import core.exception : AssertError;
    import std.algorithm : canFind;
    import std.exception : collectException;

    auto e = collectException!Throwable(run("import std.nosuch\ndef main(): Unit {\n    nosuch.g()\n}"));
    assert(cast(AssertError) e !is null && e.msg.canFind("nosuch"),
            "expected the helper's assertion naming the missing module, got " ~ (e is null ? "nothing" : typeid(e).name ~ ": " ~ e.msg));
}
