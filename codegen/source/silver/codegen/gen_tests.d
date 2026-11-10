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
    auto context = new SourceContext;
    auto program = load(source, "main.ag", [standardLibraryPath()], context);
    if (!context.collector.hasErrors)
    {
        auto analysis = analyze(program, context.collector);
        if (!context.collector.hasErrors) return generate(lowerProgram(program, analysis), program.sources);
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
    auto ir = generateSource(source, file, line);

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

    auto linked = linkExecutable(toolchain, irPath, exePath);
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
