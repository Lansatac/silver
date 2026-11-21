module silver.driver;

import std.stdio;
import std.getopt;
import std.file;
import std.path;
import std.range;

import silver.ast : Diagnostic, DiagnosticException, formatDiagnostic, Program, SourceContext;
import silver.codegen : executablePath, findToolchain, generate, linkExecutable, Optimization, optimizeIr, Toolchain;
import silver.core : lowerProgram, printCore = print;
import silver.interpreter : Evaluator, panicReport, panicStatus, ProgramFailed, RuntimeError;
import silver.loader : describePackages, load, Packages, standardPrelude;
import silver.sema : analyze, Analysis, Target;

/// Loads and analyzes `programFile`. Problems go to `context.collector`, which the caller
/// must check before using `program` or the returned Analysis.
Analysis loadAndAnalyze(string programFile, const Packages packages, SourceContext context, out Program program)
{
    try
    {
        program = load(programFile.readText, programFile, packages, standardPrelude, context);
    }
    catch (DiagnosticException e)
    {
        context.collector.report(e.diagnostic);
        return null;
    }
    if (context.collector.hasErrors)
    {
        return null;
    }
    return analyze(program, context.collector, Target.host);
}

/// Interprets the program in `programFile`, or with `emitCore`, prints the Core it lowers to.
int interpret(string programFile, const Packages packages, bool emitCore = false)
{
    auto context = new SourceContext();
    Program program;
    auto analysis = loadAndAnalyze(programFile, packages, context, program);
    printDiagnostics(context);
    if (context.collector.hasErrors)
    {
        return 1;
    }

    try
    {
        auto lowered = lowerProgram(program, analysis);
        if (emitCore)
        {
            writeln(printCore(lowered));
            return 0;
        }
        auto evaluator = new Evaluator(lowered, true);
        evaluator.run();
    }
    catch (RuntimeError e)
    {
        stdout.flush();
        stderr.writeln(panicReport(e.diagnostic, context.sources));
        return panicStatus;
    }
    catch (ProgramFailed e)
    {
        stdout.flush();
        stderr.writeln("error: ", e.msg);
        return 1;
    }
    catch (DiagnosticException e)
    {
        printDiagnostic(e.diagnostic, context);
        return 1;
    }

    return 0;
}

/// How `silver <file>` runs a program.
enum Backend
{
    interpreter,
    /// Compile to a temporary executable and run that.
    llvm,
    /// `silver test` only: run the tests both ways, and fail a test the two disagree on.
    both,
}

/// The LLVM IR for the program in `programFile`, or null after printing why there isn't any.
/// `libraries` are what it has to be linked with.
string compileToIr(string programFile, const Packages packages, out string[] libraries)
{
    auto context = new SourceContext();
    Program program;
    auto analysis = loadAndAnalyze(programFile, packages, context, program);
    printDiagnostics(context);
    if (context.collector.hasErrors)
    {
        return null;
    }
    try
    {
        auto lowered = lowerProgram(program, analysis);
        libraries = lowered.libraries.dup;
        return generate(lowered, program.sources);
    }
    catch (DiagnosticException e)
    {
        printDiagnostic(e.diagnostic, context);
        return null;
    }
}

/// Writes `content` to `path`. False after printing why it couldn't.
bool writeFile(string path, string content)
{
    try
    {
        std.file.write(path, content);
        return true;
    }
    catch (FileException e)
    {
        stderr.writeln("Couldn't write ", path, ": ", e.msg);
        return false;
    }
}

/// Compiles the program in `programFile` to the executable `outputPath`. False after printing why it failed.
bool compileToExecutable(string programFile, const Packages packages, string outputPath, Optimization optimization)
{
    string[] libraries;
    auto ir = compileToIr(programFile, packages, libraries);
    if (ir is null)
    {
        return false;
    }
    Toolchain toolchain;
    if (auto missing = findToolchain(toolchain))
    {
        stderr.writeln(missing);
        return false;
    }

    auto irPath = temporaryPath(programFile, ".ll");
    if (!writeFile(irPath, ir))
    {
        return false;
    }
    scope (exit) remove(irPath);

    auto linked = linkExecutable(toolchain, irPath, outputPath, libraries, optimization);
    if (!linked.succeeded)
    {
        stderr.writeln("Linking failed:\n", linked.output);
        return false;
    }
    return true;
}

/// Compiles the program in `programFile` to an executable, or only to LLVM IR if `emitLlvm`:
/// the IR codegen writes, or when optimizing, what clang makes of it.
int build(string programFile, const Packages packages, string outputPath, bool emitLlvm, Optimization optimization)
{
    auto name = programFile.baseName.stripExtension;
    if (emitLlvm)
    {
        string[] libraries;
        auto ir = compileToIr(programFile, packages, libraries);
        if (ir is null)
        {
            return 1;
        }
        auto irPath = outputPath.empty ? name ~ ".ll" : outputPath;
        if (optimization == Optimization.none)
        {
            return writeFile(irPath, ir) ? 0 : 1;
        }
        Toolchain toolchain;
        if (auto missing = findToolchain(toolchain))
        {
            stderr.writeln(missing);
            return 1;
        }
        auto unoptimizedPath = temporaryPath(programFile, ".ll");
        if (!writeFile(unoptimizedPath, ir))
        {
            return 1;
        }
        scope (exit) remove(unoptimizedPath);
        auto optimized = optimizeIr(toolchain, unoptimizedPath, irPath);
        if (!optimized.succeeded)
        {
            stderr.writeln("Optimizing failed:\n", optimized.output);
            return 1;
        }
        return 0;
    }
    return compileToExecutable(programFile, packages,
        outputPath.empty ? executablePath(name) : outputPath, optimization) ? 0 : 1;
}

/// Compiles the program in `programFile` to a temporary executable and runs it,
/// returning its exit status.
int compileAndRun(string programFile, const Packages packages, Optimization optimization)
{
    import std.process : spawnProcess, wait;

    auto exePath = executablePath(temporaryPath(programFile, ""));
    if (!compileToExecutable(programFile, packages, exePath, optimization))
    {
        return 1;
    }
    scope (exit) remove(exePath);
    return wait(spawnProcess([exePath]));
}

/// How `silver test` reports.
enum TestFormat
{
    text,
    /// One JSON document, for tools.
    json,
}

/// Runs the tests in the file or directory at `path` that `filters` selects, reports them on
/// stdout as `format` says, and returns 0 if they all passed.
int test(string path, const Packages packages, Backend backend, Optimization optimization,
    const string[] filters = null, TestFormat format = TestFormat.text)
{
    string report;
    auto status = testReport(path, packages, backend, optimization, filters, format, report);
    write(report);
    return status;
}

/// What `test` does, with the report in `text` rather than on stdout.
int testReport(string path, const Packages packages, Backend backend, Optimization optimization,
    const string[] filters, TestFormat format, out string text)
{
    import std.algorithm : map;
    import silver.testing : jsonReport, report, runFile, succeeded, TestBackend, testFiles;

    auto testBackend = backend == Backend.both ? TestBackend.both
        : backend == Backend.llvm ? TestBackend.llvm : TestBackend.interpreter;
    auto runs = testFiles(path).map!(file => runFile(file, packages, testBackend, tempDir, optimization, filters)).array;
    auto filtered = filters.length > 0;
    text = format == TestFormat.json ? jsonReport(runs, testBackend, filtered) : report(runs, filtered);
    return succeeded(runs, filtered) ? 0 : 1;
}

/// A path in the temp directory, unique to this process, named after `programFile`.
string temporaryPath(string programFile, string extension)
{
    import std.conv : to;
    import std.process : thisProcessID;

    return buildPath(tempDir,
        "silver-" ~ thisProcessID.to!string ~ "-" ~ programFile.baseName.stripExtension ~ extension);
}

void printDiagnostics(SourceContext context)
{
    foreach (diagnostic; context.collector.diagnostics)
    {
        printDiagnostic(diagnostic, context);
    }
}

void printDiagnostic(const Diagnostic diagnostic, SourceContext context)
{
    stderr.writeln(formatDiagnostic(diagnostic, context.sources));
}

/// Takes `-O`, `--optimize[=bool]` and `-O<level>` out of `args`, setting `optimize` as the last one says.
/// There is one optimized mode, so the levels are `-O0`, none, and `-O2`, which is `-O`. Returns
/// what's wrong with a level that is neither.
string takeOptimization(ref string[] args, out bool optimize)
{
    import std.algorithm : startsWith;

    string[] rest;
    foreach (arg; args)
    {
        if (arg == "--optimize" || arg == "--optimize=true" || arg == "-O" || arg == "-O2") optimize = true;
        else if (arg == "-O0" || arg == "--optimize=false") optimize = false;
        else if (arg.startsWith("-O"))
        {
            return "`" ~ arg ~ "` isn't an optimization level: there's -O, also spelled -O2, and -O0 for none.";
        }
        else rest ~= arg;
    }
    args = rest;
    return null;
}

@("-O and -O2 optimize, -O0 doesn't, the last one wins, and any other level is a mistake")
unittest
{
    bool optimize;
    auto args = ["silver", "-b", "llvm", "-O2", "f.ag"];
    assert(takeOptimization(args, optimize) is null && optimize);
    assert(args == ["silver", "-b", "llvm", "f.ag"]);

    args = ["silver", "build", "-O", "-O0", "f.ag"];
    assert(takeOptimization(args, optimize) is null && !optimize);
    args = ["silver", "build", "-O0", "--optimize", "f.ag"];
    assert(takeOptimization(args, optimize) is null && optimize);
    args = ["silver", "build", "-o", "out", "f.ag"];
    assert(takeOptimization(args, optimize) is null && !optimize && args.length == 5);

    args = ["silver", "build", "--optimize=false", "-O", "f.ag"];
    assert(takeOptimization(args, optimize) is null && optimize);
    args = ["silver", "build", "-O", "--optimize=false", "f.ag"];
    assert(takeOptimization(args, optimize) is null && !optimize);

    args = ["silver", "build", "--optimize=false", "-O", "f.ag"];
    assert(takeOptimization(args, optimize) is null && optimize);
    args = ["silver", "build", "-O", "--optimize=false", "f.ag"];
    assert(takeOptimization(args, optimize) is null && !optimize);

    args = ["silver", "build", "-O3", "f.ag"];
    assert(takeOptimization(args, optimize) !is null);
}

immutable usage = "Usage: silverc [run] [OPTION]... <file>   run <file>\n"
    ~ "       silverc build [OPTION]... <file>   compile <file> to an executable with LLVM\n"
    ~ "       silverc test [OPTION]... <path>    run the tests in <path>, a file or a directory";

/// Takes the command off the front of `args`. Only the first word can be one, so a file named
/// `build` is run by giving it as `./build`, or after an option.
string takeCommand(ref string[] args)
{
    if (args.length < 2 || (args[1] != "run" && args[1] != "build" && args[1] != "test")) return "run";
    immutable command = args[1];
    args = args[0] ~ args[2 .. $];
    return command;
}

@("only the first word is a command, and a file with no command is run")
unittest
{
    auto args = ["silverc", "build", "-o", "out", "f.ag"];
    assert(takeCommand(args) == "build" && args == ["silverc", "-o", "out", "f.ag"]);
    args = ["silverc", "run", "test"];
    assert(takeCommand(args) == "run" && args == ["silverc", "test"]);
    args = ["silverc", "./build"];
    assert(takeCommand(args) == "run" && args == ["silverc", "./build"]);
    args = ["silverc", "-b", "llvm", "build"];
    assert(takeCommand(args) == "run" && args.length == 4);
    args = ["silverc"];
    assert(takeCommand(args) == "run");
}

/// What's wrong with `command` (`run`, `build` or `test`), given `files`, which is what its options
/// left, and those options, or null. `format` is what `--format` gave, or null without it.
string commandLineMistake(string command, const string[] files, string outputPath, bool optimize,
    Backend backend, const string[] filters = null, string format = null)
{
    immutable building = command == "build";
    immutable testing = command == "test";
    if (files.length != 1)
    {
        // `-o f.ag` takes the file as its value. Options stop at the file, so that what follows it
        // can be the program's once a program can read it.
        return (files.length == 0 && !outputPath.empty
            ? "-o needs a value, and took `" ~ outputPath ~ "`, which leaves no file to compile."
            : files.length == 0 ? "No file was given."
            : "Too many arguments: `" ~ files[1] ~ "` follows `" ~ files[0] ~ "`. Options go before the"
                ~ " file, and a program can't be given arguments yet.")
            ~ "\n" ~ usage ~ "\nRun `silverc --help` for the options.";
    }
    if (!outputPath.empty && !building)
    {
        return "-o applies to `silver build`, which is what writes a file.";
    }
    // The interpreter has nothing to optimize, and saying so beats ignoring the flag.
    if (optimize && !building && backend == Backend.interpreter)
    {
        return "-O applies to compiled programs: use it with `silver build`, or with `-b llvm`"
            ~ (testing ? " or `-b both`" : "");
    }
    if (filters.length > 0 && !testing)
    {
        return "--filter applies to `silver test`, which is what runs tests.";
    }
    foreach (filter; filters)
    {
        if (filter.empty) return "--filter needs part of a test's name: an empty one would select every test.";
    }
    if (format !is null && !testing)
    {
        return "--format applies to `silver test`, which is what writes a report.";
    }
    if (format !is null && format != "text" && format != "json")
    {
        return "`" ~ format ~ "` isn't a format for `silver test`: there's text, the default, and json.";
    }
    return null;
}

@("a command with no file left is missing its file, whatever options it was given")
unittest
{
    import std.algorithm : canFind;

    assert(commandLineMistake("build", [], "", false, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake("test", [], "", false, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake("build", [], "hello.ag", false, Backend.interpreter).canFind("-o needs a value"));
    assert(commandLineMistake("build", [], "", true, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake("run", [], "", false, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake("run", ["a.ag", "b.ag"], "", false, Backend.interpreter).canFind("Too many"));
    assert(commandLineMistake("build", ["a.ag", "b.ag"], "", false, Backend.interpreter).canFind("Too many"));
    assert(commandLineMistake("build", ["a.ag"], "out", true, Backend.interpreter) is null);
    assert(commandLineMistake("run", ["a.ag"], "out", false, Backend.interpreter).canFind("applies to `silver build`"));
    assert(commandLineMistake("run", ["a.ag"], "", true, Backend.interpreter).canFind("compiled programs"));
    assert(commandLineMistake("run", ["a.ag"], "", true, Backend.llvm) is null);
    assert(commandLineMistake("test", ["a"], "", true, Backend.interpreter).canFind("-b both"));
}

@("an unwritable path is reported, not thrown")
unittest
{
    assert(!writeFile(buildPath(tempDir, "silver-no-such-directory", "x.ll"), "x"));
}

@("--filter and --format are for silver test, and take a name and a known format")
unittest
{
    import std.algorithm : canFind;

    assert(commandLineMistake("test", ["a.ag"], "", false, Backend.interpreter, ["x", "y"], "json") is null);
    assert(commandLineMistake("test", ["a.ag"], "", false, Backend.interpreter, null, "text") is null);
    assert(commandLineMistake("run", ["a.ag"], "", false, Backend.interpreter, ["x"]).canFind("--filter applies"));
    assert(commandLineMistake("build", ["a.ag"], "", false, Backend.interpreter, null, "json").canFind("--format applies"));
    assert(commandLineMistake("test", ["a.ag"], "", false, Backend.interpreter, ["x", ""]).canFind("empty one"));
    assert(commandLineMistake("test", ["a.ag"], "", false, Backend.interpreter, null, "xml").canFind("there's text, the default, and json"));
}

version (unittest)
{
    /// A fresh directory under the temp dir holding `files` (name to text). The caller removes it.
    private string testDirectory(string name, string[string] files)
    {
        auto directory = buildPath(tempDir, "silver-driver-" ~ name);
        if (directory.exists) rmdirRecurse(directory);
        mkdirRecurse(directory);
        foreach (file, text; files) std.file.write(buildPath(directory, file), text);
        return directory;
    }

    /// What `silver test` reports for `path` with `filters` in `format` on `backend`, with each
    /// location relative to `path` or the directory it is in, and its exit status in `status`. False
    /// without running when a compiled backend has no toolchain.
    private bool tested(string path, Backend backend, const string[] filters, TestFormat format,
        out string report, out int status)
    {
        import std.array : replace;

        Toolchain toolchain;
        if (backend != Backend.interpreter && findToolchain(toolchain) !is null) return false;
        Packages packages;
        assert(describePackages(null, null, null, null, packages) is null);
        status = testReport(path, packages, backend, Optimization.none, filters, format, report);
        auto prefix = (path.isDir ? path : path.dirName) ~ dirSeparator;
        report = report.replace(format == TestFormat.json ? prefix.replace(`\`, `\\`) : prefix, "");
        return true;
    }

    private immutable filterFixture = [
        "shape.ag": "def area(n: Int): Int => n * n\ntest \"area of one\" => expect(area(1) == 1)\n"
            ~ "test \"area of two\" => expect(area(2) == 5)\ntest \"Area of three\" => expect(area(3) == 9)",
        "shape.test.ag": "test \"area from the companion\" => expect(area(4) == 16)",
        "other.ag": "test \"other\" => expect(true)",
    ];
}

@("--filter runs the tests whose name contains any filter, case-sensitively, across a directory and its companions, on every backend")
unittest
{
    auto directory = testDirectory("filter", filterFixture.dup);
    scope (exit) rmdirRecurse(directory);

    foreach (backend; [Backend.interpreter, Backend.llvm, Backend.both])
    {
        string report;
        int status;
        if (!tested(buildPath(directory, "shape.ag"), backend, ["area of"], TestFormat.text, report, status)) continue;
        assert(report == "FAIL \"area of two\" at shape.ag(3,6)\n    shape.ag(3,23): Expectation failed: area(2) == 5\n"
            ~ "        left: 4\n        right: 5\n1 passed, 1 failed, 2 filtered out\n", report);
        assert(status == 1);

        assert(tested(directory, backend, ["one", "companion", "other"], TestFormat.text, report, status));
        assert(report == "3 passed, 0 failed, 2 filtered out\n", report);
        assert(status == 0);

        assert(tested(directory, backend, ["area of one", "Other"], TestFormat.text, report, status));
        assert(report == "1 passed, 0 failed, 4 filtered out\n", report);

        assert(tested(directory, backend, ["nothing"], TestFormat.text, report, status));
        assert(report == "No tests match the filter\n" && status == 1, report);
    }
}

@("--format json reports every test and the summary as one document, alike on every backend")
unittest
{
    import std.algorithm : canFind;
    import std.array : replace;

    auto directory = testDirectory("json", filterFixture.dup);
    scope (exit) rmdirRecurse(directory);
    auto expected = `{
  "version": 1,
  "backend": "BACKEND",
  "files": [
    {
      "file": "shape.ag",
      "problem": null,
      "diagnostics": []
    }
  ],
  "tests": [
    {
      "name": "area of two",
      "file": "shape.ag",
      "line": 3,
      "column": 6,
      "status": "failed",
      "failures": [
        {
          "kind": "expectation",
          "file": "shape.ag",
          "line": 3,
          "column": 23,
          "text": "Expectation failed: area(2) == 5\n    left: 4\n    right: 5",
          "message": null,
          "source": "area(2) == 5",
          "left": "4",
          "right": "5"
        }
      ],
      "output": ""
    },
    {
      "name": "area from the companion",
      "file": "shape.test.ag",
      "line": 1,
      "column": 6,
      "status": "passed",
      "failures": [],
      "output": ""
    }
  ],
  "summary": {
    "tests": 2,
    "passed": 1,
    "failed": 1,
    "panicked": 0,
    "filteredOut": 2,
    "filesNotRun": 0,
    "succeeded": false
  }
}
`;
    foreach (backend; [Backend.interpreter, Backend.llvm, Backend.both])
    {
        string report;
        int status;
        if (!tested(buildPath(directory, "shape.ag"), backend, ["two", "companion"], TestFormat.json, report, status)) continue;
        auto name = backend == Backend.interpreter ? "interpreter" : backend == Backend.llvm ? "llvm" : "both";
        assert(report == expected.replace("BACKEND", name), report);
        assert(status == 1);

        assert(tested(directory, backend, ["nothing"], TestFormat.json, report, status));
        assert(report.canFind(`"tests": []`) && report.canFind(`"filteredOut": 5`) && report.canFind(`"succeeded": false`));
        assert(status == 1);
    }

    string report;
    int status;
    std.file.write(buildPath(directory, "broken.ag"), "test \"t\" => expect(missing)");
    assert(tested(directory, Backend.interpreter, null, TestFormat.json, report, status));
    assert(report.canFind(`"file": "broken.ag",
      "problem": "it has errors",
      "diagnostics": [
        "broken.ag(1,20): Error S0002: Unknown name 'missing'`), report);
    assert(report.canFind(`"filesNotRun": 1`) && status == 1);
}

/// Runs the driver with the command line `args`, returning the exit status.
int run(string[] args)
{
    string[] packageOptions;
    string[] usesOptions;
    string[] partsOptions;
    string outputPath;
    bool emitLlvm;
    bool emitCore;
    Backend backend;
    bool optimize;
    string[] filters;
    string format;
    GetoptResult arguments;
    immutable command = takeCommand(args);
    if (auto mistake = takeOptimization(args, optimize))
    {
        stderr.writeln(mistake, "\nRun `silverc --help` for the options.");
        return 1;
    }
    try
    {
        arguments = getopt(
    args,
    config.caseSensitive,
    config.stopOnFirstNonOption,
    "package", "a package, as name=directory: the module name.a.b is directory/a/b.ag", &packageOptions,
    "uses", "what a package uses, as name=package,package, or for a file with no module line, package,package",
        &usesOptions,
    "parts", "a package's parts, as name=part,part", &partsOptions,
    "backend|b", "run, test: how to run the program: interpreter (default), llvm, or for tests, both", &backend,
    "output|o", "build: where to write the executable (or the IR, with --emit-llvm)", &outputPath,
    "optimize|O", "build, and run or test with -b llvm: have clang optimize the compiled program."
        ~ " -O2 is the same, and -O0 is the default, no optimization", &optimize,
    "emit-llvm", "build: write LLVM IR instead of an executable, optimized with -O", &emitLlvm,
    "emit-core", "print the Core the program lowers to instead of running it", &emitCore,
    "filter", "test: run only the tests whose name contains this, case-sensitively; given more than once,"
        ~ " those matching any of them", &filters,
    "format", "test: how to report: text (default), or json, one JSON document on stdout", &format,
    );
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg, "\nRun `silverc --help` for the options.");
        return 1;
    }
    if (arguments.helpWanted)
    {
        defaultGetoptPrinter("The Silver interpreter and compiler.\n" ~ usage, arguments.options);
        return 0;
    }
    if (auto mistake = commandLineMistake(command, args[1 .. $], outputPath, optimize, backend, filters, format))
    {
        stderr.writeln(mistake);
        return 1;
    }
    Packages packages;
    if (auto mistake = describePackages(packageOptions, usesOptions, partsOptions, null, packages))
    {
        stderr.writeln(mistake, "\nRun `silverc --help` for the options.");
        return 1;
    }
    immutable building = command == "build";
    immutable testing = command == "test";
    immutable optimization = optimize ? Optimization.full : Optimization.none;

	auto programFile = args[$ - 1];
    if (testing)
    {
        if (!programFile.exists)
        {
            stderr.writefln("'%s' doesn't exist!", programFile);
            return 1;
        }
        return test(programFile, packages, backend, optimization, filters,
            format == "json" ? TestFormat.json : TestFormat.text);
    }
	if(!programFile.exists || !programFile.isFile)
	{
		stderr.writefln("'%s' is not a file!", programFile);
		return 1;
	}

    if (building)
    {
        return build(programFile, packages, outputPath, emitLlvm, optimization);
    }
    final switch (backend)
    {
        case Backend.interpreter: return interpret(programFile, packages, emitCore);
        case Backend.llvm: return compileAndRun(programFile, packages, optimization);
        case Backend.both:
            stderr.writeln("Only `silver test` runs a program both ways");
            return 1;
    }
}
