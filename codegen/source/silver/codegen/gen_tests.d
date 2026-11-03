/// Code generation tests. Each one compiles a Silver program to IR, links it with clang and the
/// C runtime, runs it, and checks what it printed. Without clang only the IR generation step runs.
module silver.codegen.gen_tests;

version (unittest):

import core.exception : AssertError;
import std.algorithm : count, map;
import std.array : join;
import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : indexOf, replace;
import std.uuid : randomUUID;

import fluent.asserts;

import silver.ast;
import silver.codegen.gen : Fragment, generate;
import silver.codegen.toolchain : executablePath, findToolchain, linkExecutable, Toolchain;
import silver.loader : load, standardLibraryPath;
import silver.sema : analyze, Analysis;

/// IR for `source`, loaded as main.ag with the real stdlib. Load or sema errors fail the test,
/// so that every failure here is about codegen, and so do any errors codegen reports.
string generateSource(string source, string file = __FILE__, size_t line = __LINE__)
{
    auto context = new SourceContext;
    auto program = load(source, "main.ag", [standardLibraryPath()], context);
    Analysis analysis;
    if (!context.collector.hasErrors)
    {
        analysis = analyze(program, context.collector);
    }
    if (context.collector.hasErrors)
    {
        throw new AssertError("The test program failed to load or analyze:\n"
            ~ describeErrors(context), file, line);
    }

    auto ir = generate(program, analysis, context.collector);
    if (context.collector.hasErrors)
    {
        throw new AssertError("Codegen reported errors:\n" ~ describeErrors(context), file, line);
    }
    return ir;
}

private string describeErrors(SourceContext context)
{
    return context.collector.errors.map!(d => formatDiagnostic(d, context.sources)).join("\n");
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

@("codegen prints an Int with printl")
unittest
{
    Run run;
    if (!compileAndRun("def main(): Unit {\n    printl(42)\n}", run)) return;

    run.status.should.equal(0);
    run.output.should.equal("42\n");
}

@("a fragment sequenced after another keeps both in order and takes the second's value")
unittest
{
    auto first = Fragment(["  %a = alloca i64"], ["  store i64 1, ptr %a"], null);
    auto second = Fragment.instruction("%t = call i64 @f()", "%t");
    auto both = first.then(second);

    both.allocas.should.equal(["  %a = alloca i64"]);
    both.code.should.equal(["  store i64 1, ptr %a", "  %t = call i64 @f()"]);
    both.value.should.equal("%t");
    both.withValue(null).value.should.equal(null);
}

@("codegen declares each runtime function once, in first-use order")
unittest
{
    auto ir = generateSource("def main(): Unit {\n    printl(1)\n    print(true)\n    printl(2)\n}");

    ir.count("declare void @silver_printl_int(i64)").should.equal(1);
    ir.indexOf("declare void @silver_printl_int(i64)")
        .should.be.lessThan(ir.indexOf("declare void @silver_print_bool(i1 zeroext)"));
    ir.should.contain("call void @silver_printl_int(i64 1)");
}

@("codegen passes a Unit argument as no argument")
unittest
{
    auto ir = generateSource("def main(): Unit {\n    printl(())\n}");

    ir.should.contain("declare void @silver_printl_unit()");
    ir.should.contain("call void @silver_printl_unit()");
}

@("codegen evaluates call arguments in order before the call")
unittest
{
    auto source = "def one(): Int => 1\ndef two(): Int => 2\ndef third(a: Int, b: Int): Int => 3\n"
        ~ "def main(): Unit {\n    printl(third(one(), two()))\n}";
    auto ir = generateSource(source);

    auto callOne = ir.indexOf("call i64 @\"main.one\"()");
    auto callTwo = ir.indexOf("call i64 @\"main.two\"()");
    auto callThird = ir.indexOf("call i64 @\"main.third\"(i64 %.t0, i64 %.t1)");
    callOne.should.be.greaterThan(-1);
    callOne.should.be.lessThan(callTwo);
    callTwo.should.be.lessThan(callThird);
    callThird.should.be.lessThan(ir.indexOf("call void @silver_printl_int(i64 %.t2)"));

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("3\n");
}

// Next step: names. A param is already an SSA value, so reading it is just its name; a
// local lives in its slot and needs a load. Until `emitExpr` handles `Identifier`, this fails
// with "doesn't support names yet".
@("codegen reads a param directly and a local from its slot")
unittest
{
    auto source = "def same(x: Int): Int => x\n"
        ~ "def main(): Unit {\n    val a = 7\n    printl(same(a))\n}";
    auto ir = generateSource(source);

    ir.should.contain("define i64 @\"main.same\"(i64 %x) {\nentry:\n  ret i64 %x\n}");
    ir.should.contain("store i64 7, ptr %a.addr");
    ir.should.contain("%.t0 = load i64, ptr %a.addr");
    ir.should.contain("call i64 @\"main.same\"(i64 %.t0)");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("7\n");
}
