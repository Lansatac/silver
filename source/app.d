import std.stdio;
import std.getopt;
import std.file;
import std.path;
import std.range;

import silver.ast : Diagnostic, DiagnosticException, formatDiagnostic, Program, SourceContext;
import silver.codegen : executablePath, findToolchain, generate, linkExecutable, Toolchain;
import silver.core : lowerProgram, printCore = print;
import silver.interpreter.evaluator : Evaluator;
import silver.loader : load, standardLibraryPath;
import silver.sema : analyze, Analysis, Target;

/// Loads and analyzes `programFile`. Problems go to `context.collector`, which the caller
/// must check before using `program` or the returned Analysis.
Analysis loadAndAnalyze(string programFile, string[] importPaths, SourceContext context, out Program program)
{
    try
    {
        program = load(programFile.readText, programFile, importPaths, context);
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
    catch (DiagnosticException e)
    {
        writeln();
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

/// Compiles the program in `programFile` to the executable `outputPath`. False after printing why it failed.
bool compileToExecutable(string programFile, string[] importPaths, string outputPath)
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
    std.file.write(irPath, ir);
    scope (exit) remove(irPath);

    auto linked = linkExecutable(toolchain, irPath, outputPath, libraries);
    if (!linked.succeeded)
    {
        stderr.writeln("Linking failed:\n", linked.output);
        return false;
    }
    return true;
}

/// Compiles the program in `programFile` to an executable, or only to LLVM IR if `emitLlvm`.
int build(string programFile, string[] importPaths, string outputPath, bool emitLlvm)
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
        std.file.write(outputPath.empty ? name ~ ".ll" : outputPath, ir);
        return 0;
    }
    return compileToExecutable(programFile, importPaths,
        outputPath.empty ? executablePath(name) : outputPath) ? 0 : 1;
}

/// Compiles the program in `programFile` to a temporary executable and runs it,
/// returning its exit status.
int compileAndRun(string programFile, string[] importPaths)
{
    import std.process : spawnProcess, wait;

    auto exePath = executablePath(temporaryPath(programFile, ""));
    if (!compileToExecutable(programFile, importPaths, exePath))
    {
        return 1;
    }
    scope (exit) remove(exePath);
    return wait(spawnProcess([exePath]));
}

/// Runs the tests in the file or directory at `path`, reports them, and returns 0 if they all passed.
int test(string path, string[] importPaths, Backend backend)
{
    import std.algorithm : map;
    import silver.testing : report, runFile, succeeded, TestBackend, testFiles;

    auto testBackend = backend == Backend.both ? TestBackend.both
        : backend == Backend.llvm ? TestBackend.llvm : TestBackend.interpreter;
    auto runs = testFiles(path).map!(file => runFile(file, importPaths, testBackend, tempDir)).array;
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

///Application entry point
int main(string[] args)
{
    string[] importPaths;
    string outputPath;
    bool emitLlvm;
    bool emitCore;
    Backend backend;
	auto arguments = getopt(
    args,
    "importPath|I", "Add a path to search for imported modules", &importPaths,
    "backend|b", "run, test: how to run the program: interpreter (default), llvm, or for tests, both", &backend,
    "output|o", "build: where to write the executable (or the IR, with --emit-llvm)", &outputPath,
    "emit-llvm", "build: write LLVM IR instead of an executable", &emitLlvm,
    "emit-core", "print the Core the program lowers to instead of running it", &emitCore,
    );
    immutable building = args.length == 3 && args[1] == "build";
    immutable testing = args.length == 3 && args[1] == "test";
	if (arguments.helpWanted || !(args.length == 2 || building || testing))
	{
		defaultGetoptPrinter("The Silver interpreter and compiler.\n"
            ~ "Usage: silver [OPTION]... <file>         run <file>\n"
            ~ "       silver build [OPTION]... <file>   compile <file> to an executable with LLVM\n"
            ~ "       silver test [OPTION]... <path>    run the tests in <path>, a file or a directory", arguments.options);
		return 0;
	}

	auto programFile = args[$ - 1];
    if (testing)
    {
        if (!programFile.exists)
        {
            stderr.writefln("'%s' doesn't exist!", programFile);
            return 1;
        }
        return test(programFile, importPaths, backend);
    }
	if(!programFile.exists || !programFile.isFile)
	{
		stderr.writefln("'%s' is not a file!", programFile);
		return 1;
	}

    auto allImportPaths = importPaths.chain([standardLibraryPath(), programFile.dirName]).array;
    if (building)
    {
        return build(programFile, allImportPaths, outputPath, emitLlvm);
    }
    final switch (backend)
    {
        case Backend.interpreter: return interpret(programFile, allImportPaths, emitCore);
        case Backend.llvm: return compileAndRun(programFile, allImportPaths);
        case Backend.both:
            stderr.writeln("Only `silver test` runs a program both ways");
            return 1;
    }
}
