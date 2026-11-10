/// Code generation tests. Each one compiles a Silver program to IR and checks it, and links and
/// runs it when clang and dmd are available.
module silver.codegen.gen_tests;

version (unittest):

import core.exception : AssertError;
import std.algorithm : map;
import std.array : join;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : indexOf, replace;
import std.uuid : randomUUID;

import fluent.asserts;

import silver.ast;
import silver.codegen.gen : generate;
import silver.codegen.toolchain : executablePath, findToolchain, linkExecutable, Toolchain;
import silver.core : lowerProgram;
import silver.loader : load, standardLibraryPath;
import silver.sema : analyze;

/// IR for `source`, loaded as main.ag with the real stdlib. Load or sema errors fail the test,
/// so every failure here is about lowering or codegen.
string generateSource(string source, string file = __FILE__, size_t line = __LINE__)
{
    string[] libraries;
    return generateSource(source, libraries, file, line);
}

/// ditto, with the libraries the program has to be linked with.
string generateSource(string source, out string[] libraries, string file = __FILE__, size_t line = __LINE__)
{
    auto context = new SourceContext;
    auto program = load(source, "main.ag", [standardLibraryPath()], context);
    if (!context.collector.hasErrors)
    {
        auto analysis = analyze(program, context.collector);
        if (!context.collector.hasErrors)
        {
            auto lowered = lowerProgram(program, analysis);
            libraries = lowered.libraries.dup;
            return generate(lowered, program.sources);
        }
    }
    throw new AssertError("The test program failed to load or analyze:\n"
        ~ context.collector.errors.map!(d => formatDiagnostic(d, context.sources)).join("\n"), file, line);
}

struct Run
{
    int status;
    /// stdout and stderr, with Windows newlines normalized.
    string output;
}

/// Generates IR for `source` and, if clang and dmd are available, links and runs it. Returns
/// false without running when a tool is missing, so the caller can skip its checks on the
/// result. A link failure fails the test and keeps the IR on disk for inspection.
bool compileAndRun(string source, out Run run, string file = __FILE__, size_t line = __LINE__)
{
    string[] libraries;
    auto ir = generateSource(source, libraries, file, line);

    Toolchain toolchain;
    if (auto missing = findToolchain(toolchain))
    {
        writeln("    note: ", missing, " The program was generated but not run.");
        return false;
    }

    auto directory = buildPath(tempDir, "silver-codegen-" ~ randomUUID().toString());
    mkdirRecurse(directory);
    auto irPath = buildPath(directory, "main.ll");
    auto exePath = executablePath(buildPath(directory, "main"));
    write(irPath, ir);

    auto linked = linkExecutable(toolchain, irPath, exePath, libraries);
    if (!linked.succeeded)
    {
        throw new AssertError("Linking failed (IR kept at " ~ irPath ~ "):\n" ~ linked.output
            ~ "\n--- IR\n" ~ ir, file, line);
    }

    auto result = execute([exePath]);
    run = Run(result.status, result.output.replace("\r\n", "\n"));
    rmdirRecurse(directory);
    return true;
}

@("codegen compiles an empty main into a program that exits cleanly and prints nothing")
unittest
{
    Run run;
    if (!compileAndRun("def main(): Unit => ()", run)) return;

    run.status.should.equal(0);
    run.output.should.equal("");
}

// A let gets a stack slot named after its Local, stores its value there, and each use loads
// from it. Mutable locals will need the slot anyway, so immutable ones share the scheme and
// LLVM's mem2reg turns them into registers.
@("codegen stores a let's value in its slot, and a use of the local loads it")
unittest
{
    auto source = "def main(): Unit {\n    val a = 7\n    val b = a\n}";
    auto ir = generateSource(source);

    ir.should.contain("%a.addr = alloca i64");
    ir.should.contain("store i64 7, ptr %a.addr");
    ir.should.contain("%.t0 = load i64, ptr %a.addr");
    ir.should.contain("%b.addr = alloca i64");
    ir.should.contain("store i64 %.t0, ptr %b.addr");
    ir.indexOf("store i64 7, ptr %a.addr").should.be.lessThan(ir.indexOf("%.t0 = load i64, ptr %a.addr"));

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(0);
}

@("codegen prints an Int with printl")
unittest
{
    Run run;
    if (!compileAndRun("def main(): Unit {\n    printl(42)\n}", run)) return;

    run.status.should.equal(0);
    run.output.should.equal("42\n");
}

@("codegen declares each runtime function once, and suffixes an Any argument with its type")
unittest
{
    import std.algorithm : count;

    auto ir = generateSource("def main(): Unit {\n    printl(1)\n    print(())\n    printl(2)\n}");

    ir.count("declare void @silver_printl_int(i64)").should.equal(1);
    ir.should.contain("call void @silver_printl_int(i64 1)");
    ir.should.contain("call void @silver_printl_int(i64 2)");
}

@("codegen passes a Unit argument as no argument")
unittest
{
    auto ir = generateSource("def main(): Unit {\n    printl(())\n}");

    ir.should.contain("declare void @silver_printl_unit()");
    ir.should.contain("call void @silver_printl_unit()");
}

@("codegen passes a local to a native by loading it from its slot")
unittest
{
    Run run;
    if (!compileAndRun("def main(): Unit {\n    val a = 7\n    print(a)\n    printl(())\n}", run)) return;

    run.output.should.equal("7()\n");
}

@("codegen picks signed or unsigned instructions from the operands' type")
unittest
{
    auto source = "def main(): Unit {\n    val a: Int8 = -7\n    val b: Int8 = 2\n    val c: UInt8 = 250\n"
        ~ "    printl(a / b)\n    printl(a % b)\n    printl(a >> 1)\n    printl(c >> 1)\n"
        ~ "    printl(a < b)\n    printl(c > 3)\n}";
    auto ir = generateSource(source);

    ir.should.contain("sdiv i8");
    ir.should.contain("srem i8");
    ir.should.contain("ashr i8");
    ir.should.contain("lshr i8");
    ir.should.contain("icmp slt i8");
    ir.should.contain("icmp ugt i8");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("-3\n-1\n-4\n125\ntrue\ntrue\n");
}

@("codegen lowers Float arithmetic to the floating-point instructions, negating with fneg")
unittest
{
    auto source = "def main(): Unit {\n    val a = 1.5\n    printl(a * 2.0 - 0.5)\n    printl(-a)\n    printl(a != a)\n}";
    auto ir = generateSource(source);

    ir.should.contain("fneg double");
    ir.should.contain("fcmp une double");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("2.5\n-1.5\nfalse\n");
}

@("codegen declares a native from its signature and calls it with the C calling convention")
unittest
{
    auto source = "import std.math\nimport std.time\ndef main(): Unit {\n    printl(sqrt(16.0))\n    val now = nowNanos()\n"
        ~ "    printl(now > 1600000000000000000)\n}";
    auto ir = generateSource(source);

    ir.should.contain("declare ccc double @sqrt(double)");
    ir.should.contain("call ccc double @sqrt(double 0x4030000000000000)");
    ir.should.contain("declare ccc i64 @silver_nowNanos()");
    ir.should.not.contain("silver_sqrt");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("4\ntrue\n");
}

// C passes `bool` and integers narrower than `int` extended to 32 bits, and LLVM leaves that to
// the attributes, so without them the callee can read garbage in the upper bits.
@("codegen extends Bool and small integers at the C boundary, on parameters and results")
unittest
{
    auto ir = generateSource("native def f(a: Int8, b: UInt16, c: Bool, d: Int32, e: UInt64): UInt8\n"
        ~ "native def g(): Int16\nnative def h(): Bool\n"
        ~ "def main(): Unit {\n    val x = f(-1, 2, true, 3, 4)\n    val y = g()\n    val z = h()\n}");

    ir.should.contain("declare ccc zeroext i8 @f(signext i8, zeroext i16, zeroext i1, i32, i64)");
    ir.should.contain("call ccc zeroext i8 @f(signext i8 -1, zeroext i16 2, zeroext i1 true, i32 3, i64 4)");
    ir.should.contain("declare ccc signext i16 @g()");
    ir.should.contain("declare ccc zeroext i1 @h()");
}

@("codegen calls a native returning Unit as void, and one returning Never as noreturn")
unittest
{
    auto source = "native def srand(seed: UInt32): Unit\nnative def exit(status: Int32): Never\n"
        ~ "def main(): Unit {\n    srand(7)\n    printl(1)\n    exit(3)\n    printl(2)\n}";
    auto ir = generateSource(source);

    ir.should.contain("declare ccc void @srand(i32)\n");
    ir.should.contain("call ccc void @srand(i32 7)");
    ir.should.contain("declare ccc void @exit(i32) noreturn");
    ir.should.contain("call ccc void @exit(i32 3)\n  unreachable");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(3);
    run.output.should.equal("1\n");
}

@("codegen calls a Silver function directly, passing its arguments and using its result")
unittest
{
    auto source = "def add(a: Int, b: Int): Int => a + b\ndef answer(): Int => 42\n"
        ~ "def main(): Unit {\n    printl(add(3, 4))\n    printl(answer())\n}";
    auto ir = generateSource(source);

    ir.should.contain("define i64 @\"main.add\"(i64 %a, i64 %b)");
    ir.should.contain("call i64 @\"main.add\"(i64 3, i64 4)");
    ir.should.contain("call i64 @\"main.answer\"()");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(0);
    run.output.should.equal("7\n42\n");
}

@("codegen leaves a Unit parameter out of the definition and the call, but still evaluates its argument")
unittest
{
    auto source = "def second(u: Unit, x: Int): Int => x\n"
        ~ "def main(): Unit {\n    printl(second(printl(1), 2))\n}";
    auto ir = generateSource(source);

    ir.should.contain("define i64 @\"main.second\"(i64 %x)");
    ir.should.contain("call i64 @\"main.second\"(i64 2)");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("1\n2\n");
}

@("codegen passes a mutable argument as a pointer to its slot, which the callee reads through")
unittest
{
    auto source = "def show(mutable n: Int): Unit => printl(n)\n"
        ~ "def forward(mutable n: Int): Unit => show(mutable n)\n"
        ~ "def main(): Unit {\n    mutable val count = 5\n    forward(mutable count)\n}";
    auto ir = generateSource(source);

    ir.should.contain("define void @\"main.show\"(ptr %n)");
    ir.should.contain("load i64, ptr %n");
    ir.should.not.contain("%n.addr");
    ir.should.contain("call void @\"main.forward\"(ptr %count.addr)");
    ir.should.contain("call void @\"main.show\"(ptr %n)");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("5\n");
}

@("codegen ends the block after a call to a Silver function that returns Never")
unittest
{
    auto source = "native def exit(status: Int32): Never\ndef stop(): Never => exit(3)\n"
        ~ "def main(): Unit {\n    stop()\n    printl(1)\n}";
    auto ir = generateSource(source);

    ir.should.contain("call void @\"main.stop\"()\n  unreachable");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(3);
    run.output.should.equal("");
}

@("codegen reports two natives that bind one symbol with different signatures")
unittest
{
    import std.exception : collectException;

    auto error = collectException!DiagnosticException(generateSource(
        "native(\"abs\") def a(x: Int32): Int32\nnative(\"abs\") def b(x: Int64): Int64\n"
        ~ "def main(): Unit {\n    val x = a(1)\n    val y = b(2)\n}"));
    assert(error !is null);
    error.diagnostic.code.should.equal(DiagnosticCode.NotImplemented);
}

version (linux)
{
    @("codegen links the native library a program's natives come from")
    unittest
    {
        string[] libraries;
        auto source = "native library \"m\"\nnative def cbrt(x: Float): Float\ndef main(): Unit {\n    printl(cbrt(27.0))\n}";
        generateSource(source, libraries);
        libraries.should.equal(["m"]);

        Run run;
        if (!compileAndRun(source, run)) return;
        run.output.should.equal("3\n");
    }
}
