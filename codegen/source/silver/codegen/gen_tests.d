/// Code generation tests. Each one compiles a Silver program to IR and checks it, and links and
/// runs it when clang and dmd are available.
module silver.codegen.gen_tests;

version (unittest):

import core.exception : AssertError;
import std.algorithm : canFind, count, endsWith, filter, map, startsWith;
import std.array : join;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : escapeShellCommand, escapeShellFileName, execute, executeShell;
import std.stdio : writeln;
import std.string : indexOf, replace;
import std.uuid : randomUUID;

import fluent.asserts;

import silver.ast;
import silver.codegen.gen : generate;
import silver.codegen.toolchain : executablePath, findToolchain, linkExecutable, Optimization, Toolchain;
import silver.core : lowerProgram;
import silver.loader : load, standardLibraryPath, standardPrelude;
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
    auto program = load(source, "main.ag", [standardLibraryPath()], standardPrelude, context);
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
/// result. `inputPath` is the program's standard input, if it has one. A link failure fails the
/// test and keeps the IR on disk for inspection.
bool compileAndRun(string source, out Run run, Optimization optimization = Optimization.none, string inputPath = null,
    string file = __FILE__, size_t line = __LINE__)
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

    auto linked = linkExecutable(toolchain, irPath, exePath, libraries, optimization);
    if (!linked.succeeded)
    {
        throw new AssertError("Linking failed (IR kept at " ~ irPath ~ "):\n" ~ linked.output
            ~ "\n--- IR\n" ~ ir, file, line);
    }

    auto result = inputPath is null ? execute([exePath])
        : executeShell(escapeShellCommand(exePath) ~ " < " ~ escapeShellFileName(inputPath));
    run = Run(result.status, result.output.replace("\r\n", "\n"));
    rmdirRecurse(directory);
    return true;
}

/// The name of the struct type defined as `fields` in `ir`, which fails the test if there is none.
string structNamed(string ir, string fields, string file = __FILE__, size_t line = __LINE__)
{
    import std.string : lineSplitter;

    auto definition = " = type " ~ fields;
    foreach (text; ir.lineSplitter)
    {
        if (text.endsWith(definition)) return text[0 .. $ - definition.length];
    }
    throw new AssertError("No struct type is defined as " ~ fields ~ " in:\n" ~ ir, file, line);
}

/// The lines of `ir` between the one that starts with `first` and the next `}`.
string[] functionLines(string ir, string first, string file = __FILE__, size_t line = __LINE__)
{
    import std.algorithm : countUntil;
    import std.array : array;
    import std.string : lineSplitter;

    auto lines = ir.lineSplitter.array;
    auto start = lines.countUntil!(text => text.startsWith(first));
    if (start < 0) throw new AssertError("No line starts with " ~ first ~ " in:\n" ~ ir, file, line);
    return lines[start .. start + lines[start .. $].countUntil("}")];
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

@("codegen's read reports input it can't read as ReadFailed, with the OS's message")
unittest
{
    // Windows can't make a directory a program's standard input.
    version (Posix)
    {
        Run run;
        if (!compileAndRun("def main(): Unit {\n    printl(read())\n}", run, Optimization.none, tempDir)) return;

        run.status.should.equal(0);
        run.output.should.equal("Error(ReadFailed(Is a directory))\n");
    }
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
    auto source = "native def sqrt(x: Float): Float\nnative(\"silver_nowNanos\") def nowNanos(): Int\n"
        ~ "def main(): Unit {\n    printl(sqrt(16.0))\n    val now = nowNanos()\n"
        ~ "    printl(now > 1600000000000000000)\n}";
    auto ir = generateSource(source);

    ir.should.contain("declare ccc double @sqrt(double) nobuiltin");
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

    ir.should.contain("declare ccc void @srand(i32) nobuiltin\n");
    ir.should.contain("call ccc void @srand(i32 7)");
    ir.should.contain("declare ccc void @exit(i32) nobuiltin noreturn");
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

    ir.should.contain("define internal i64 @\"main.add\"(i64 %a, i64 %b)");
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

    ir.should.contain("define internal i64 @\"main.second\"(i64 %x)");
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

    ir.should.contain("define internal void @\"main.show\"(ptr %n)");
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

@("codegen gives a reused name a slot of its own, and a let's slot comes after those in its value")
unittest
{
    auto source = "def main(): Unit {\n    {\n        val c = 1\n        printl(c)\n    }\n    {\n        val c = 2\n        printl(c)\n    }\n"
        ~ "    val a = {\n        val b = 3\n        b\n    }\n    printl(a)\n}";
    auto ir = generateSource(source);

    ir.should.contain("store i64 1, ptr %c.addr\n");
    ir.should.contain("store i64 2, ptr %c.addr.1\n");
    ir.should.contain("  %c.addr = alloca i64\n  %c.addr.1 = alloca i64\n  %b.addr = alloca i64\n  %a.addr = alloca i64\n");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("1\n2\n3\n");
}

@("codegen lays an option out as a tag and a payload, a sum as a tag and a pointer, and an all-marker sum as its tag")
unittest
{
    auto source = "type Color = Red | Green\ntype Shape = Circle(r: Float) | Empty\n"
        ~ "def main(): Unit {\n    val o: Int? = 1\n    val c = Green\n    val s: Shape = Circle(1.0)\n"
        ~ "    printl(o)\n    printl(c)\n    printl(s)\n}";
    auto ir = generateSource(source);

    ir.should.contain("%o.addr = alloca " ~ structNamed(ir, "{ i8, i64 }"));
    ir.should.contain("%c.addr = alloca i32");
    ir.should.contain("%s.addr = alloca " ~ structNamed(ir, "{ i32, ptr }"));

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("Some(1)\nGreen\nCircle(1)\n");
}

@("codegen passes a lambda its environment after its params, and calls a named function as a value through a thunk")
unittest
{
    auto source = "def double(x: Int): Int => x * 2\n"
        ~ "def main(): Unit {\n    val n = 10\n    val add: (Int) -> Int = x => x + n\n    val f = double\n"
        ~ "    printl(add(1))\n    printl(f(4))\n}";
    auto ir = generateSource(source);

    ir.should.contain("(i64 %x, ptr %.env)");
    ir.should.contain("@\".thunk.");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("11\n8\n");
}

@("codegen names each instance of a generic function apart, with its type arguments quoted")
unittest
{
    auto source = "type Box<T>(value: T)\ndef identity<T>(x: T): T => x\n"
        ~ "def main(): Unit {\n    printl(identity(1))\n    printl(identity(\"s\"))\n    printl(identity(Box([1.5])))\n}";
    auto ir = generateSource(source);

    ir.should.contain("define internal i64 @\"main.identity<Int>.");
    auto slice = structNamed(ir, "{ ptr, i64 }");
    ir.should.contain("define internal " ~ slice ~ " @\"main.identity<String>.");
    ir.should.contain("define internal " ~ slice ~ " @\"main.identity<Box<[Float]>>.");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("1\ns\nBox([1.5])\n");
}

@("codegen lays out each instance of a generic type from its own field and member types")
unittest
{
    auto source = "type Pair<A, B>(left: A, right: B)\ntype Result<T, E> = Good(value: T) | Bad(error: E)\ntype Tag<T>\n"
        ~ "def main(): Unit {\n    val p = Pair(1, 2.5)\n    val q = Pair((), true)\n    val r: Result<Int, String> = Good(1)\n"
        ~ "    val t = Tag<Int>\n    printl(p)\n    printl(q)\n    printl(r)\n    printl(t)\n}";
    auto ir = generateSource(source);

    ir.should.contain("%p.addr = alloca " ~ structNamed(ir, "{ i64, double }"));
    ir.should.contain("%q.addr = alloca i1");
    ir.should.contain("%r.addr = alloca " ~ structNamed(ir, "{ i32, ptr }"));
    ir.should.not.contain("%t.addr");

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("Pair(1, 2.5)\nPair((), true)\nGood(1)\nTag\n");
}

@("codegen passes and returns a declared type as its fields' scalars, and boxes only one that holds itself")
unittest
{
    auto source = "type Point(x: Int, y: Int)
type Line(from: Point, to: Point?)
type Node(value: Int, next: Node?)
"
        ~ "def shift(line: Line): Line => if line.from.x > 0 => line with (from = Point(0, 0)) else line
"
        ~ "def main(): Unit {
    val line = shift(Line(Point(1, 2), Point(3, 4)))
    val node = Node(1, Node(2, None))
"
        ~ "    printl(line)
    printl(node)
}";
    auto ir = generateSource(source);

    // A `Bool` is a byte in a struct, and a bit everywhere else.
    auto line = structNamed(ir, "{ i64, i64, i8, i64, i64 }");
    ir.should.contain("define internal " ~ line ~ " @\"main.shift\"(i64 %line.0, i64 %line.1, i1 %line.2, i64 %line.3, i64 %line.4)");
    ir.should.contain("%line.addr = alloca " ~ line);
    ir.should.contain("%node.addr = alloca ptr");
    ir.should.contain("getelementptr " ~ structNamed(ir, "{ i64, i8, ptr }"));

    // A struct is laid out in memory, built to be returned and taken apart after a call, and is
    // never another instruction's operand or result: every line naming one is one of these.
    import std.string : lineSplitter;

    auto allowed = [" = type ", " = alloca ", " = getelementptr ", " = insertvalue ", " = extractvalue ", "  ret ",
        " = call ", "define ", "call void @llvm.memcpy.", "@silver_alloc(", "@silver_array_append(", " constant ", "attributes #"];
    auto others = ir.lineSplitter.filter!(text => (text.canFind("%T.") || text.canFind("{"))
        && !text.startsWith("define ") && !allowed.canFind!(use => text.canFind(use)));
    others.should.equal(cast(string[])[]);
    ir.lineSplitter.filter!(text => text.canFind(" = call ") && text.canFind("%T.") && !text.canFind(" = call %T.")
        && !text.canFind("ptrtoint")).should.equal(cast(string[])[]);

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("Line(Point(0, 0), Some(Point(3, 4)))
Node(1, Some(Node(2, None)))
");
}

@("codegen names each struct type once, so reaching into a wide product doesn't spell it out")
unittest
{
    import std.algorithm : maxElement;
    import std.string : lineSplitter;

    auto source = "type Wide(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int, j: Int, k: Int, l: Int)\n"
        ~ "def sum(w: Wide): Int => w.a + w.l\n"
        ~ "def main(): Unit {\n    val w = Wide(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)\n    printl(sum(w with (l = 30)))\n}";
    auto ir = generateSource(source);

    auto wide = structNamed(ir, "{ i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64 }");
    ir.count(" = type { i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64 }").should.equal(1);
    ir.should.contain("getelementptr " ~ wide ~ ", ptr %w.addr, i32 0, i32 11");
    ir.lineSplitter.filter!(text => text.canFind(" = getelementptr ")).map!(text => text.length).maxElement.should.be.lessThan(80);

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("31\n");
}

@("codegen loads only the field read from an array's element, a sum's payload and an option in a local")
unittest
{
    auto source = "type Wide(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int, j: Int, k: Int, l: Int)\n"
        ~ "type Shape = Box(wide: Wide, tag: Int) | Nothing\n"
        ~ "def third(ws: [Wide]): Int => ws[0].c\n"
        ~ "def tagOf(shape: Shape): Int => match shape {\n    Box(_, tag) => tag\n    Nothing => 0\n}\n"
        ~ "def last(maybe: Wide?): Int => if val w = maybe => w.l else 0\n"
        ~ "def main(): Unit {\n    val w = Wide(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)\n"
        ~ "    printl(third([w]))\n    printl(tagOf(Box(w, 13)))\n    printl(last(w))\n    printl(last(None))\n}";
    auto ir = generateSource(source);

    size_t loads(string name) => functionLines(ir, "define internal i64 @\"main." ~ name ~ "\"").count!(text => text.canFind(" = load "));
    // The stack limit, the array's two scalars and the field.
    loads("third").should.equal(4);
    // Neither reads the twelve fields of the `Wide` beside the one wanted.
    loads("tagOf").should.be.lessThan(12);
    loads("last").should.be.lessThan(24);

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("3\n13\n12\n0\n");
}

@("codegen copies a wide value that is already in memory whole, and writes only the field an assignment replaces")
unittest
{
    auto source = "type Wide(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int, j: Int, k: Int, l: Int)\n"
        ~ "type Shape = Box(wide: Wide) | Nothing\n"
        ~ "def swap(w: Wide): Wide {\n    mutable val out = w\n    out = out with (a = out.l, l = out.a)\n    out\n}\n"
        ~ "def keep(ws: [Wide], w: Wide): [Wide] {\n    mutable val all = ws\n    all ~= [w]\n    all[0] = w\n    all\n}\n"
        ~ "def main(): Unit {\n    val w = Wide(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)\n    val copy = w\n    val box = Box(copy)\n"
        ~ "    val late = () => copy.l\n    val kept = keep([swap(w)], copy)\n"
        ~ "    printl(swap(w))\n    printl(box)\n    printl(late())\n    printl(kept[1].a + kept[0].l + kept.length())\n}";
    auto ir = generateSource(source);

    size_t stores(string[] lines) => lines.count!(text => text.canFind("  store i64"));
    size_t copies(string[] lines) => lines.count!(text => text.canFind("@llvm.memcpy"));
    // Its parameter's twelve scalars arriving, the two fields swapped, and nothing else.
    auto swap = functionLines(ir, "define internal " ~ structNamed(ir, "{ i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64 }") ~ " @\"main.swap\"");
    stores(swap).should.equal(14);
    copies(swap).should.equal(4);
    // The appended element and the assigned one, besides the array that assigning copies. Neither
    // is stored a scalar at a time, as the parameter is.
    auto keep = functionLines(ir, "define internal " ~ structNamed(ir, "{ ptr, i64 }") ~ " @\"main.keep\"");
    stores(keep).should.be.lessThan(24);
    copies(keep).should.equal(3);
    keep.count!(text => text.canFind("@silver_array_append")).should.equal(2);
    // `copy`, the sum's payload and the lambda's capture.
    copies(functionLines(ir, "define internal void @\"main.main\"")).should.equal(3);

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("Wide(12, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 1)\nBox(Wide(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12))\n12\n"
        ~ "15\n");
}

@("codegen reads a local's value before the code that assigns the local, in an array, an append and a record")
unittest
{
    auto source = "type Wide(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int, j: Int, k: Int, l: Int)\n"
        ~ "def wide(n: Int): Wide => Wide(n, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)\n"
        ~ "def bump(mutable w: Wide): Int {\n    w = wide(w.a + 100)\n    w.a\n}\n"
        ~ "def main(): Unit {\n    mutable val w = wide(1)\n    val both = [w, {\n        w = wide(2)\n        w\n    }]\n    printl(both[0].a * 10 + both[1].a)\n"
        ~ "    mutable val all = [wide(0)]\n    all ~= [w, {\n        w = wide(3)\n        w\n    }]\n    printl(all[1].a * 10 + all[2].a)\n"
        ~ "    w = w with (a = bump(mutable w), b = w.a)\n    printl(w.a * 1000 + w.b)\n"
        ~ "    w = w with (a = w.c, c = w.a)\n    printl(w.a * 1000 + w.c)\n"
        ~ "    all[0] = w\n    w = wide(9)\n    printl(all[0].a)\n}";

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("12\n23\n103103\n3103\n3\n");
}

@("codegen marks what lets clang optimize, and an optimized program prints and panics as an unoptimized one does")
unittest
{
    auto source = "type Node(value: Int, next: Node?)\n"
        ~ "def pick(xs: [Int], node: Node): Int => xs[node.value]\n"
        ~ "def main(): Unit {\n    printl(pick([10, 20, 30], Node(1, None)))\n    printl(pick([10, 20, 30], Node(3, None)))\n}";
    auto ir = generateSource(source);
    ir.should.contain("define internal void @\"main.main\"() #0 {");
    ir.should.contain("attributes #0 = { nounwind uwtable }");
    ir.should.contain("declare noalias ptr @silver_alloc(i64) nounwind allockind(\"alloc,uninitialized\") allocsize(0)");
    ir.should.contain("declare void @silver_panic(ptr, ptr) nounwind noreturn cold");

    Run plain, optimized;
    if (!compileAndRun(source, plain) || !compileAndRun(source, optimized, Optimization.full)) return;
    plain.status.should.equal(101);
    plain.output.startsWith("20\npanic: ").should.equal(true);
    optimized.should.equal(plain);
}
// Review 6 (silver-23b.9): with -O, `main.main` and whatever else is inlined into `silver_main` take
// its attributes, and LLVM infers `nounwind` for it without `uwtable`, so the outermost frames get no
// unwind table. A D Error from the runtime (out of memory) then aborts with "uncaught exception reached
// top of stack" (status 134), where unoptimized it reaches Thread.join (status 139 there today).
@("silver_main, which an optimized program's main is inlined into, keeps an unwind table")
unittest
{
    auto ir = generateSource("def main(): Unit {\n    printl(1)\n}");
    ir.should.contain("attributes #0 = { nounwind uwtable }");
    ir.should.contain("define void @silver_main() #0 {");
}

// LLVM knows the C library's functions by name, and would work out `pow(2.0, 10.0)` itself or call
// `exp2` for `pow(2.0, x)`, neither of which rounds as the library's `pow` does.
@("a native is an opaque call when optimized, whatever C library function it's named like")
unittest
{
    auto source = "native def pow(base: Float, exponent: Float): Float\nnative def sin(x: Float): Float\n"
        ~ "native def exp2(x: Float): Float\n"
        ~ "def main(): Unit {\n    val hidden = [2.0, 0.3]\n    mutable val differs = 0\n"
        ~ "    for i in 0..2000 {\n        val x = Float(i) * 0.149 - 150.0\n"
        ~ "        if pow(2.0, x) != pow(hidden[0], x) { differs += 1 }\n    }\n"
        ~ "    printl(differs)\n    printl(sin(1.0) == sin(hidden[1] + 0.7))\n    printl(exp2(3.0))\n}";
    auto ir = generateSource(source);
    ir.should.contain("declare ccc double @pow(double, double) nobuiltin");
    ir.should.contain("declare ccc double @exp2(double) nobuiltin");

    Run plain, optimized;
    if (!compileAndRun(source, plain) || !compileAndRun(source, optimized, Optimization.full)) return;
    plain.output.should.equal("0\ntrue\n8\n");
    optimized.should.equal(plain);
}

// Room claimed at the frontier and then not filled is lost, and the next append copies the array.
@("appending a literal asks for room only after any element that can leave has been evaluated")
unittest
{
    auto source = "def parse(i: Int): Int? => if i % 2 == 0 => Some(i) else None\n"
        ~ "def keepEven(mutable xs: [Int], i: Int): Int? {\n    xs ~= [parse(i)?]\n    Some(i)\n}\n"
        ~ "def keepAll(mutable xs: [Int?], i: Int): Unit {\n    xs ~= [parse(i)]\n}\n"
        ~ "def evens(n: Int): [Int] {\n    mutable val xs: [Int] = []\n"
        ~ "    for i in 0..n { xs ~= [if i % 2 == 1 { continue } else { i }, i] }\n    xs\n}\n"
        ~ "def main(): Unit {\n    mutable val xs: [Int] = []\n    mutable val all: [Int?] = []\n"
        ~ "    for i in 0..5 {\n        _ = keepEven(mutable xs, i)\n        keepAll(mutable all, i)\n    }\n"
        ~ "    printl(xs)\n    printl(all)\n    printl(evens(5))\n}";
    auto ir = generateSource(source);

    /// Whether `first` comes before `second` in the function `name`.
    bool ordered(string name, string first, string second)
    {
        import std.array : split;

        foreach (chunk; ir.split("\n}\n"))
        {
            auto at = chunk.indexOf("define internal ");
            if (at < 0 || !chunk[at .. $][0 .. chunk[at .. $].indexOf("\n")].canFind("@\"main." ~ name ~ "\"(")) continue;
            auto a = chunk.indexOf(first, at);
            auto b = chunk.indexOf(second, at);
            assert(a >= 0 && b >= 0, chunk);
            return a < b;
        }
        assert(0, "no function " ~ name);
    }

    ordered("keepEven", "@\"main.parse\"", "@silver_array_append").should.equal(true);
    ordered("keepAll", "@silver_array_append", "@\"main.parse\"").should.equal(true);
    ordered("evens", ".after.jump", "@silver_array_append").should.equal(true);

    Run run;
    if (!compileAndRun(source, run)) return;
    run.output.should.equal("[0, 2, 4]\n[Some(0), None, Some(2), None, Some(4)]\n[0, 0, 2, 2, 4, 4]\n");
}
