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
import silver.loader : load, standardLibraryPath, standardPrelude;
import silver.sema : analyze, Analysis, Target;

/// Loads and analyzes `programFile`. Problems go to `context.collector`, which the caller
/// must check before using `program` or the returned Analysis.
Analysis loadAndAnalyze(string programFile, string[] importPaths, SourceContext context, out Program program)
{
    try
    {
        program = load(programFile.readText, programFile, importPaths, standardPrelude, context);
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
int interpret(string programFile, string[] importPaths, bool emitCore = false)
{
    auto context = new SourceContext();
    Program program;
    auto analysis = loadAndAnalyze(programFile, importPaths, context, program);
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
string compileToIr(string programFile, string[] importPaths, out string[] libraries)
{
    auto context = new SourceContext();
    Program program;
    auto analysis = loadAndAnalyze(programFile, importPaths, context, program);
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
bool compileToExecutable(string programFile, string[] importPaths, string outputPath, Optimization optimization)
{
    string[] libraries;
    auto ir = compileToIr(programFile, importPaths, libraries);
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
int build(string programFile, string[] importPaths, string outputPath, bool emitLlvm, Optimization optimization)
{
    auto name = programFile.baseName.stripExtension;
    if (emitLlvm)
    {
        string[] libraries;
        auto ir = compileToIr(programFile, importPaths, libraries);
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
    return compileToExecutable(programFile, importPaths,
        outputPath.empty ? executablePath(name) : outputPath, optimization) ? 0 : 1;
}

/// Compiles the program in `programFile` to a temporary executable and runs it,
/// returning its exit status.
int compileAndRun(string programFile, string[] importPaths, Optimization optimization)
{
    import std.process : spawnProcess, wait;

    auto exePath = executablePath(temporaryPath(programFile, ""));
    if (!compileToExecutable(programFile, importPaths, exePath, optimization))
    {
        return 1;
    }
    scope (exit) remove(exePath);
    return wait(spawnProcess([exePath]));
}

/// Runs the tests in the file or directory at `path`, reports them, and returns 0 if they all passed.
int test(string path, string[] importPaths, Backend backend, Optimization optimization)
{
    import std.algorithm : map;
    import silver.testing : report, runFile, succeeded, TestBackend, testFiles;

    auto testBackend = backend == Backend.both ? TestBackend.both
        : backend == Backend.llvm ? TestBackend.llvm : TestBackend.interpreter;
    auto runs = testFiles(path).map!(file => runFile(file, importPaths, testBackend, tempDir, optimization)).array;
    write(report(runs));
    return succeeded(runs) ? 0 : 1;
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

immutable usage = "Usage: silver [OPTION]... <file>         run <file>\n"
    ~ "       silver build [OPTION]... <file>   compile <file> to an executable with LLVM\n"
    ~ "       silver test [OPTION]... <path>    run the tests in <path>, a file or a directory";

/// What's wrong with the command line `args` (after its options were taken) and those options, or null.
/// `args[1]` is `build` or `test` for those commands, and the file is what follows.
string commandLineMistake(string[] args, string outputPath, bool optimize, Backend backend)
{
    immutable command = args.length >= 2 && (args[1] == "build" || args[1] == "test") ? args[1] : "";
    immutable building = command == "build";
    immutable testing = command == "test";
    immutable files = args.length - (command.empty ? 1 : 2);
    if (files != 1)
    {
        // `-o f.ag` takes the file as its value.
        return (files == 0 && !outputPath.empty
            ? "-o needs a value, and took `" ~ outputPath ~ "`, which leaves no file to compile."
            : files == 0 ? "No file was given." : "Too many arguments.")
            ~ "\n" ~ usage ~ "\nRun `silver --help` for the options.";
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
    return null;
}

@("a command with no file left is missing its file, whatever options it was given")
unittest
{
    import std.algorithm : canFind;

    assert(commandLineMistake(["silver", "build"], "", false, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake(["silver", "test"], "", false, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake(["silver", "build"], "hello.ag", false, Backend.interpreter).canFind("-o needs a value"));
    assert(commandLineMistake(["silver", "build"], "", true, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake(["silver"], "", false, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake(["silver", "a.ag", "b.ag"], "", false, Backend.interpreter).canFind("Too many"));
    assert(commandLineMistake(["silver", "build", "a.ag", "b.ag"], "", false, Backend.interpreter).canFind("Too many"));
    assert(commandLineMistake(["silver", "build", "a.ag"], "out", true, Backend.interpreter) is null);
    assert(commandLineMistake(["silver", "a.ag"], "out", false, Backend.interpreter).canFind("applies to `silver build`"));
    assert(commandLineMistake(["silver", "a.ag"], "", true, Backend.interpreter).canFind("compiled programs"));
    assert(commandLineMistake(["silver", "a.ag"], "", true, Backend.llvm) is null);
    assert(commandLineMistake(["silver", "test", "a"], "", true, Backend.interpreter).canFind("-b both"));
}

@("an unwritable path is reported, not thrown")
unittest
{
    assert(!writeFile(buildPath(tempDir, "silver-no-such-directory", "x.ll"), "x"));
}

/// Runs the driver with the command line `args`, returning the exit status.
int run(string[] args)
{
    string[] importPaths;
    string outputPath;
    bool emitLlvm;
    bool emitCore;
    Backend backend;
    bool optimize;
    GetoptResult arguments;
    if (auto mistake = takeOptimization(args, optimize))
    {
        stderr.writeln(mistake, "\nRun `silver --help` for the options.");
        return 1;
    }
    try
    {
        arguments = getopt(
    args,
    config.caseSensitive,
    "importPath|I", "Add a path to search for imported modules", &importPaths,
    "backend|b", "run, test: how to run the program: interpreter (default), llvm, or for tests, both", &backend,
    "output|o", "build: where to write the executable (or the IR, with --emit-llvm)", &outputPath,
    "optimize|O", "build, and run or test with -b llvm: have clang optimize the compiled program."
        ~ " -O2 is the same, and -O0 is the default, no optimization", &optimize,
    "emit-llvm", "build: write LLVM IR instead of an executable, optimized with -O", &emitLlvm,
    "emit-core", "print the Core the program lowers to instead of running it", &emitCore,
    );
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg, "\nRun `silver --help` for the options.");
        return 1;
    }
    if (arguments.helpWanted)
    {
        defaultGetoptPrinter("The Silver interpreter and compiler.\n" ~ usage, arguments.options);
        return 0;
    }
    if (auto mistake = commandLineMistake(args, outputPath, optimize, backend))
    {
        stderr.writeln(mistake);
        return 1;
    }
    immutable building = args[1] == "build";
    immutable testing = args[1] == "test";
    immutable optimization = optimize ? Optimization.full : Optimization.none;

	auto programFile = args[$ - 1];
    if (testing)
    {
        if (!programFile.exists)
        {
            stderr.writefln("'%s' doesn't exist!", programFile);
            return 1;
        }
        return test(programFile, importPaths, backend, optimization);
    }
	if(!programFile.exists || !programFile.isFile)
	{
		stderr.writefln("'%s' is not a file!", programFile);
		return 1;
	}

    auto allImportPaths = importPaths.chain([standardLibraryPath(), programFile.dirName]).array;
    if (building)
    {
        return build(programFile, allImportPaths, outputPath, emitLlvm, optimization);
    }
    final switch (backend)
    {
        case Backend.interpreter: return interpret(programFile, allImportPaths, emitCore);
        case Backend.llvm: return compileAndRun(programFile, allImportPaths, optimization);
        case Backend.both:
            stderr.writeln("Only `silver test` runs a program both ways");
            return 1;
    }
}
