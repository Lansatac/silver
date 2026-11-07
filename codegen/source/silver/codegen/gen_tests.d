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

    ir.should.contain("define i64 @\"main.same\"(i64 %x.arg) {\nentry:\n  ret i64 %x.arg\n}");
    ir.should.contain("store i64 7, ptr %a.addr");
    ir.should.contain("%.t0 = load i64, ptr %a.addr");
    ir.should.contain("call i64 @\"main.same\"(i64 %.t0)");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("7\n");
}

// Next step: binary operators. The operand type picks the instruction (`add` on i64, `fadd`
// on double; sema guarantees both sides agree), both operands are evaluated left to right
// before it, and `sdiv`/`srem` truncate toward zero with the dividend's sign, as the
// interpreter does. Until `emitExpr` handles `BinaryExpr`, this fails with "doesn't support
// binary operators yet".
@("codegen lowers Int arithmetic and comparison to the signed integer instructions")
unittest
{
    auto source = "def main(): Unit {\n    val a = -7\n    val b = 2\n"
        ~ "    printl(a / b)\n    printl(a % b)\n    printl(a * b + 1)\n"
        ~ "    printl(a < b)\n    printl(a == b)\n}";
    auto ir = generateSource(source);

    // The left operand is evaluated before the right one.
    ir.should.contain("%.t0 = load i64, ptr %a.addr");
    ir.should.contain("%.t1 = load i64, ptr %b.addr");
    ir.should.contain("sdiv i64 %.t0, %.t1");
    ir.should.contain("srem i64 ");
    ir.should.contain("@llvm.smul.with.overflow.i64(");
    ir.should.contain("@llvm.sadd.with.overflow.i64(");
    ir.should.contain("icmp slt i64 ");
    ir.should.contain("icmp eq i64 ");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("-3\n-1\n-13\ntrue\nfalse\n");
}

// Float operands use the floating-point instructions, and an Int literal that sema adapted
// to Float (`x / 4`) has to be emitted as a double constant, not as `4`.
@("codegen lowers Float arithmetic and comparison to the floating-point instructions")
unittest
{
    auto source = "def main(): Unit {\n    val x = 10.0\n"
        ~ "    printl(x / 4)\n    printl(x * 1.5 - 1.0)\n    printl(x > 4.0)\n}";
    auto ir = generateSource(source);

    ir.should.contain("fdiv double %.t0, 0x4010000000000000");
    ir.should.contain("fmul double ");
    ir.should.contain("fsub double ");
    ir.should.contain("fcmp ogt double ");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("2.5\n14\ntrue\n");
}

// Next step: `&&` and `||`. They short-circuit, so the right operand only runs when the left
// one doesn't decide the result; eager `and i1`/`or i1` would evaluate both. That means a
// conditional branch, the right operand in its own block, and a `phi` at the join that picks
// the left's value or the right's by which block it came from. The predecessor label is the
// block that actually branches to the join, which for a nested `||` inside `&&` is the inner
// join, not the block the right operand started in.
@("codegen short-circuits && and ||, evaluating the right operand only when it can matter")
unittest
{
    auto source = "def say(b: Bool): Bool {\n    printl(b)\n    b\n}\n"
        ~ "def main(): Unit {\n"
        ~ "    printl(false && say(true))\n"
        ~ "    printl(true || say(false))\n"
        ~ "    printl(true && say(false))\n"
        ~ "    printl(false || say(true))\n"
        ~ "    printl(false || (true && say(true)))\n"
        ~ "}";
    auto ir = generateSource(source);

    ir.should.contain("br i1 ");
    ir.should.contain("phi i1 ");
    ir.should.not.contain(" = and i1 ");
    ir.should.not.contain(" = or i1 ");
    // The first right operand is only reached through a branch.
    ir.indexOf("br i1 ").should.be.lessThan(ir.indexOf("call i1 @\"main.say\""));

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("false\ntrue\nfalse\nfalse\ntrue\ntrue\ntrue\ntrue\n");
}

// Next step: unary operators. `-` on an Int is `sub i64 0, x`; on a Float it is `fneg`, not
// `fsub -0.0, x`, which differs on signed zero. `!` is `xor i1 x, true`. A signed literal
// beside a Float was adapted along with its sign, so `-2` there is a Float too. Until
// `emitExpr` handles `UnaryExpr`, this fails with "doesn't support unary operators yet".
@("codegen negates Ints with sub, Floats with fneg, and Bools with xor")
unittest
{
    auto source = "def main(): Unit {\n    val a = 7\n    val x = 2.5\n"
        ~ "    printl(-a)\n    printl(-x)\n    printl(!(a == 7))\n    printl(-(-a))\n    printl(x * -2)\n}";
    auto ir = generateSource(source);

    ir.should.contain("@llvm.ssub.with.overflow.i64(i64 0, ");
    ir.should.contain("fneg double ");
    ir.should.contain("xor i1 ");
    ir.should.not.contain("fsub double");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("-7\n-2.5\nfalse\n7\n-5\n");
}

// Next step: assignment. A `mutable val` already has a slot, so assigning is a store to it,
// and every read is still a fresh load, so the store is seen by later uses. Until
// `emitStatement` handles `AssignStmt`, this fails with "doesn't support assignment yet".
@("codegen assigns a mutable local by storing to its slot")
unittest
{
    auto source = "def main(): Unit {\n    mutable val total = 0\n"
        ~ "    total = total + 2\n    total = total * 5\n    printl(total)\n"
        ~ "    mutable val flag = false\n    flag = true\n    printl(flag)\n}";
    auto ir = generateSource(source);

    // One store for the declaration and one per assignment; one load per use.
    ir.count("store i64 ").should.equal(3);
    ir.count("load i64, ptr %total.addr").should.equal(3);
    ir.should.contain("store i1 true, ptr %flag.addr");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("10\ntrue\n");
}

// Next step: `if` with a value. It is `emitConditional` with the arms' type, and `else if`
// is just an `if` in the else arm, so the join of the inner one is what the outer phi sees.
// A block arm can have statements before its value. Until `emitExpr` handles `IfExpr`,
// this fails with "doesn't support `if` yet".
@("codegen lowers an if expression to a branch and a phi, chaining else-ifs")
unittest
{
    auto source = "def sign(n: Int): Int => if n < 0 => -1 else if n == 0 => 0 else 1\n"
        ~ "def main(): Unit {\n"
        ~ "    printl(sign(-5))\n    printl(sign(0))\n    printl(sign(9))\n"
        ~ "    val label = if sign(3) == 1 {\n        printl(true)\n        10\n    } else {\n        20\n    }\n"
        ~ "    printl(label)\n}";
    auto ir = generateSource(source);

    ir.should.contain("phi i64 ");
    ir.count("br i1 ").should.equal(3);

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("-1\n0\n1\ntrue\n10\n");
}

@("codegen emits string literals as unterminated globals, escaping what c\"...\" can't hold")
unittest
{
    import silver.codegen.gen : Generator;

    Generator.llvmStringBytes("plain").should.equal("plain");
    Generator.llvmStringBytes("a\"b\\c\n").should.equal(`a\22b\5Cc\0A`);
    Generator.llvmStringBytes("é").should.equal(`\C3\A9`);

    auto source = "def main(): Unit {\n    printl(" ~ `"café \"ok\""` ~ ")\n}";
    auto ir = generateSource(source);
    ir.should.contain(`@.str.0 = private unnamed_addr constant [10 x i8] c"caf\C3\A9 \22ok\22"`);
    ir.should.contain("extractvalue { ptr, i64 } { ptr @.str.0, i64 10 }, 0");
    ir.should.contain("call void @silver_printl_string(ptr %.t0, i64 %.t1)");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("café \"ok\"\n");
}

@("codegen keeps the NUL terminator for the panic messages it passes as C strings")
unittest
{
    auto ir = generateSource(`def main(): Unit {
    printl("x")
    printl(1 / 0)
}`);
    ir.should.contain(`[1 x i8] c"x"`);
    ir.should.contain(`Division by zero\00"`);
}

@("codegen prints and compares strings by length, not up to a NUL")
unittest
{
    auto source = `def main(): Unit {
    printl("a\0b")
    printl("a\0b" == "a\0c")
    printl("a\0" < "a\0b")
}`;
    generateSource(source).should.contain(`[3 x i8] c"a\00b"`);

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("a\0b\nfalse\ntrue\n");
}

@("codegen concatenates into a new buffer with no runtime call but the allocation")
unittest
{
    auto source = `def join(a: String, b: String): String => a ~ b
def main(): Unit {
    printl(join("ab", "c") ~ "é" ~ "")
    printl("" ~ "")
}`;
    auto ir = generateSource(source);
    ir.should.contain("declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)");
    ir.should.contain("define { ptr, i64 } @\"main.join\"({ ptr, i64 } %a.arg, { ptr, i64 } %b.arg)");
    ir.should.contain("call ptr @silver_alloc(i64 ");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("abcé\n\n");
}

@("codegen orders strings by the sign of the runtime's comparison")
unittest
{
    auto source = `def main(): Unit {
    printl("a" < "b")
    printl("a" <= "b")
    printl("a" > "b")
    printl("a" >= "b")
    printl("z" < "é")
    printl("a" < "aa")
}`;
    auto ir = generateSource(source);
    ir.should.contain("declare i32 @silver_string_compare(ptr, i64, ptr, i64)");
    foreach (predicate; ["slt", "sle", "sgt", "sge"])
    {
        ir.should.contain("icmp " ~ predicate ~ " i32 ");
    }

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("true\ntrue\nfalse\nfalse\ntrue\ntrue\n");
}

@("codegen takes what `read` returns through two stack slots, hoisted out of any loop")
unittest
{
    auto ir = generateSource(`def main(): Unit {
    mutable val i = 0
    while i < 2 {
        printl(read())
        i = i + 1
    }
}`);
    ir.should.contain("declare void @silver_read(ptr, ptr)");
    auto firstBlock = ir.indexOf("while.cond");
    ir.indexOf("alloca ptr").should.be.lessThan(firstBlock);
    ir.indexOf("alloca i64").should.be.lessThan(firstBlock);
}

@("codegen joins an arm's value from the block its local's initializer ended in")
unittest
{
    Run run;
    if (!compileAndRun(`def count(wanted: Bool, n: Int): Int {
    if wanted {
        val next = n + 1
        next
    } else {
        0
    }
}
def word(wanted: Bool, plural: Bool): String {
    if wanted {
        val text = if plural => "bees" else "bee"
        text ~ "!"
    } else {
        "none"
    }
}
def main(): Unit {
    printl(count(true, 1))
    printl(word(true, true))
    printl(word(false, true))
}`, run)) return;
    run.output.should.equal("2\nbees!\nnone\n");
}

@("codegen loops with while, re-evaluating the condition each time round")
unittest
{
    auto source = "def main(): Unit {\n    mutable val i = 1\n    mutable val total = 0\n"
        ~ "    while i <= 5 {\n        if i % 2 == 0 {\n            total = total + i\n        }\n"
        ~ "        i = i + 1\n    }\n    printl(total)\n    printl(i)\n"
        ~ "    while false {\n        printl(0)\n    }\n}";
    auto ir = generateSource(source);

    ir.should.contain("br label %while.cond.0\nwhile.cond.0:\n");
    ir.should.contain("br i1 %.t1, label %while.body.1, label %while.end.2");
    // The body always jumps back to the condition, never falls through.
    ir.should.contain("br label %while.cond.0\nwhile.end.2:\n");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("6\n6\n");
}

@("codegen builds a type's value on the heap and reads its fields back")
unittest
{
    auto source = `type Point(x: Int, y: Int)
type Reading(id: Int, ok: Bool, ratio: Float, label: String)

def yOf(p: Point): Int => p.y

def main(): Unit {
    val p = Point(3, 4)
    printl(p.x)
    printl(yOf(p))
    printl(Point(5, 6).y)

    val r = Reading(7, true, 1.5, "hi")
    printl(r.id)
    printl(r.ok)
    printl(r.ratio)
    printl(r.label)
}`;
    generateSource(source).should.contain("declare ptr @silver_alloc(i64)");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(0);
    run.output.should.equal("3\n4\n6\n7\ntrue\n1.5\nhi\n");
}

@("codegen emits one global per marker, whether or not it's used")
unittest
{
    auto source = `type Used
type Unused
def takes(u: Used): Int => 1
def main(): Unit {
    printl(takes(Used))
}`;
    generateSource(source).count("private unnamed_addr constant i8 0").should.equal(2);

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("1\n");
}

@("codegen passes a marker around like any other value")
unittest
{
    auto source = `type Origin
type Tagged(tag: Origin, n: Int)

def takes(o: Origin): Int => 1
def gives(): Origin => Origin

def main(): Unit {
    val o = Origin
    printl(takes(o))
    printl(takes(gives()))
    printl(Tagged(o, 2).n)
    printl(takes(Tagged(Origin, 3).tag))
}`;
    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(0);
    run.output.should.equal("1\n1\n2\n1\n");
}

@("codegen uses a constructor as a value without calling it")
unittest
{
    auto source = `type Point(x: Int, y: Int)

def ignores(make: (Int, Int) -> Point): Int => 1

def main(): Unit {
    val make = Point
    printl(ignores(make))
    printl(ignores(Point))
}`;
    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(0);
    run.output.should.equal("1\n1\n");
}

@("codegen leaves Unit fields out of a type's layout, wherever they are")
unittest
{
    auto source = `type Holder(first: Int, gap: Unit, second: Int, last: Unit)
type OnlyUnit(nothing: Unit)

def say(): Unit => printl("said")

def main(): Unit {
    val h = Holder(1, say(), 2, ())
    printl(h.first)
    printl(h.second)
    printl(h.gap)
    printl(h.last)
    printl(OnlyUnit(()).nothing)
}`;
    auto ir = generateSource(source);
    ir.should.contain("getelementptr ({ i64, i64 }, ptr null, i32 1)");
    ir.should.contain("getelementptr ({  }, ptr null, i32 1)");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(0);
    run.output.should.equal("said\n1\n2\n()\n()\n()\n");
}

/// The errors codegen reports for `source`, which must load and analyze cleanly.
private string codegenErrors(string source, string file = __FILE__, size_t line = __LINE__)
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

    generate(program, analysis, context.collector);
    return describeErrors(context);
}

@("codegen assigns a field by building a new object, leaving the old one alone")
unittest
{
    auto ir = generateSource(`type Point(x: Int, y: Int)

def main(): Unit {
    mutable val p = Point(1, 2)
    p.x = 5
}`);
    ir.should.contain("insertvalue { i64, i64 } ");
    ir.should.contain(", i64 5, 0");
    ir.should.not.contain("store i64 5");
    // Writes to the copy, and to `p` when it's bound and rebound; none to the old object.
    ir.count("store { i64, i64 }").should.equal(1);
    ir.count("store ptr").should.equal(2);
}

@("codegen rebuilds every object on the way to a nested field")
unittest
{
    auto source = `type Point(x: Int, y: Int)
type Line(start: Point, end: Point)

def main(): Unit {
    mutable val line = Line(Point(1, 2), Point(3, 4))
    val before = line
    line.end.y = 9
    printl(line.end.y)
    printl(line.start.y)
    printl(before.end.y)
}`;
    auto ir = generateSource(source);
    ir.count("insertvalue").should.equal(2);

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(0);
    run.output.should.equal("9\n2\n4\n");
}

@("codegen finds a field's place in the layout when assigning past a Unit field")
unittest
{
    auto source = `type Holder(gap: Unit, n: Int)

def main(): Unit {
    mutable val h = Holder((), 1)
    h.n = 2
    h.gap = ()
    printl(h.n)
}`;
    auto ir = generateSource(source);
    ir.should.contain(", i64 2, 0");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(0);
    run.output.should.equal("2\n");
}

@("codegen reports types it can't lay out instead of crashing on them")
unittest
{
    enum message = "types with `Any` or `Never` fields";
    codegenErrors(`type Box(v: Any)

def main(): Unit {
    mutable val b = Box(1)
    b.v = 2
}`).should.contain(message);

    codegenErrors(`type Box(v: Any)

def main(): Unit {
    val make = Box
}`).should.contain(message);
}

@("codegen reports native functions used as values")
unittest
{
    codegenErrors(`def main(): Unit {
    val p = printl
    p(1)
}`).should.contain("native functions as values");

    codegenErrors(`def run(f: (Any) -> Unit): Unit => f(1)

def main(): Unit => ()`).should.contain("calling a value that takes `Any`");
}

@("codegen generates one equality function per compared type, including its fields' types")
unittest
{
    auto ir = generateSource(`type Point(x: Int, y: Int)
type Line(start: Point, end: Point)
type Unrelated(n: Int)

def main(): Unit {
    printl(Line(Point(1, 2), Point(3, 4)) == Line(Point(1, 2), Point(3, 4)))
    printl(Line(Point(1, 2), Point(3, 4)) != Line(Point(1, 2), Point(3, 4)))
    printl(Point(1, 2) == Point(1, 2))
}`);
    ir.count(`define private i1 @"main.Line_eq"`).should.equal(1);
    ir.count(`define private i1 @"main.Point_eq"`).should.equal(1);
    ir.count("Unrelated_eq").should.equal(0);
}

@("codegen compares every field but stops at the first difference")
unittest
{
    auto ir = generateSource(`type Named(name: String, n: Int, f: Float, gap: Unit)

def main(): Unit {
    printl(Named("a", 1, 1.5, ()) == Named("a", 1, 1.5, ()))
}`);
    ir.should.contain("silver_string_compare");
    ir.should.contain("icmp eq i64");
    ir.should.contain("fcmp oeq double");
    ir.count("phi i1").should.equal(3);
}

@("codegen reports comparing options, even inside a type that contains itself")
unittest
{
    enum message = "comparing options";
    codegenErrors(`def same(a: Int?, b: Int?): Bool => a == b

def main(): Unit => ()`).should.contain(message);

    codegenErrors(`type Node(n: Int, next: Node?)

def same(a: Node, b: Node): Bool => a == b

def main(): Unit => ()`).should.contain(message);
}

@("codegen checks Int division for zero, panicking with the source location")
unittest
{
    auto source = "def divide(a: Int, b: Int): Int => a / b\ndef main(): Unit {\n    printl(divide(7, 2))\n    printl(divide(1, 0))\n}";
    auto ir = generateSource(source);
    ir.should.contain("declare void @silver_panic(ptr) noreturn");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(1);
    run.output.should.equal("3\npanic: main.ag(1,36): Division by zero\n");
}

@("codegen doesn't check Float division, which gives infinity")
unittest
{
    auto ir = generateSource("def main(): Unit => printl(1.0 / 0.0)");
    ir.should.not.contain("silver_panic");
}

@("codegen checks integer arithmetic for overflow, panicking with the source location")
unittest
{
    auto source = "def add(a: Int, b: Int): Int => a + b\ndef main(): Unit {\n    printl(add(1, 2))\n"
        ~ "    printl(add(9223372036854775807, 1))\n}";
    auto ir = generateSource(source);
    ir.should.contain("declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64, i64)");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.status.should.equal(1);
    run.output.should.equal("3\npanic: main.ag(1,33): Integer overflow\n");
}

@("codegen doesn't check the wrapping operators")
unittest
{
    auto ir = generateSource("def f(a: Int): Int => a &+ a &- a &* a\ndef main(): Unit => printl(f(1))");
    ir.should.not.contain("with.overflow");
    ir.should.contain("add i64 ");
    ir.should.contain("sub i64 ");
    ir.should.contain("mul i64 ");
}

@("codegen picks unsigned instructions for unsigned types, at their own width")
unittest
{
    auto ir = generateSource("def f(a: UInt8, b: UInt8): Bool => a / b > a % b >> 1\n"
        ~ "def main(): Unit => printl(f(4, 2))");
    ir.should.contain("udiv i8 ");
    ir.should.contain("urem i8 ");
    ir.should.contain("lshr i8 ");
    ir.should.contain("icmp ugt i8 ");
    ir.should.not.contain("sdiv");
    ir.should.not.contain("srem");
    ir.should.not.contain("ashr");
}

@("codegen emits a negated literal as a constant, since its magnitude may not fit the type")
unittest
{
    auto ir = generateSource("def main(): Unit {\n    val a: Int8 = -128\n    printl(a)\n}");
    ir.should.contain("store i8 -128, ");
    ir.should.not.contain("with.overflow");
}

@("a constant is a private global, loaded where it's used, and a Unit constant has none")
unittest
{
    auto ir = generateSource(`val limit: UInt8 = 255
val name: String = "silver"
val nothing: Unit = ()
def main(): Unit {
    printl(limit)
    printl(name)
    printl(nothing)
}`);
    ir.should.contain(`@"main.limit" = private unnamed_addr constant i8 255`);
    ir.should.contain(`@"main.name" = private unnamed_addr constant { ptr, i64 } { ptr @.str.`);
    ir.should.contain(`load { ptr, i64 }, ptr @"main.name"`);
    ir.should.contain(`load i8, ptr @"main.limit"`);
    ir.should.not.contain(`@"main.nothing"`);
}

@("an interpolated string joins all its parts in one buffer")
unittest
{
    auto ir = generateSource(`def f(x: Int, y: Float): String => "a{x}b{y}c"
def main(): Unit => printl(f(1, 2.0))`);
    ir.count("call ptr @silver_alloc").should.equal(1);
    ir.count("call void @llvm.memcpy").should.equal(5);
}

@("a hole holding only a String shares its buffer, which can't be observed")
unittest
{
    auto ir = generateSource(`def f(x: String): String => "{x}"
def main(): Unit => printl(f("a"))`);
    ir.should.not.contain("silver_alloc");
}

@("a type's formatter is generated once, for each type formatted, and print uses it")
unittest
{
    auto ir = generateSource(`type Inner(x: Int)
type Outer(a: Inner, b: Inner)
type Unused(x: Int)
def main(): Unit {
    printl(Outer(Inner(1), Inner(2)))
    printl("{Outer(Inner(3), Inner(4))}")
}`);
    ir.count(`define private { ptr, i64 } @"main.Outer_format"`).should.equal(1);
    ir.count(`define private { ptr, i64 } @"main.Inner_format"`).should.equal(1);
    ir.should.not.contain("Unused_format");
    ir.should.contain("silver_printl_string");
}

@("a call with a Never argument isn't emitted, since it's never reached")
unittest
{
    auto ir = generateSource("def spin(): Never { return spin() }\ndef main(): Unit => printl(spin())");
    ir.should.not.contain("@silver_printl");
}
