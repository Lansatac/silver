import std.stdio;
import std.getopt;
import std.file;
import std.path;
import std.range;

import silver.ast : Diagnostic, DiagnosticException, formatDiagnostic, Program, SourceContext;
import silver.codegen : executablePath, findToolchain, generate, linkExecutable, Toolchain;
import silver.interpreter.evaluator : Evaluator;
import silver.loader : load, standardLibraryPath;
import silver.sema : analyze, Analysis;

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
    return analyze(program, context.collector);
}

/// Interprets the program in `programFile`.
int interpret(string programFile, string[] importPaths)
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
        auto evaluator = new Evaluator(program, analysis, true);
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
}

/// The LLVM IR for the program in `programFile`, or null after printing why there isn't any.
string compileToIr(string programFile, string[] importPaths)
{
    auto context = new SourceContext();
    Program program;
    auto analysis = loadAndAnalyze(programFile, importPaths, context, program);
    string ir;
    if (!context.collector.hasErrors)
    {
        ir = generate(program, analysis, context.collector);
    }
    printDiagnostics(context);
    return context.collector.hasErrors ? null : ir;
}

/// Compiles the program in `programFile` to the executable `outputPath`. False after printing why it failed.
bool compileToExecutable(string programFile, string[] importPaths, string outputPath)
{
    auto ir = compileToIr(programFile, importPaths);
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

    auto linked = linkExecutable(toolchain, irPath, outputPath);
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
        auto ir = compileToIr(programFile, importPaths);
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
    Backend backend;
	auto arguments = getopt(
    args,
    "importPath|I", "Add a path to search for imported modules", &importPaths,
    "backend|b", "run: how to run the program: interpreter (default) or llvm", &backend,
    "output|o", "build: where to write the executable (or the IR, with --emit-llvm)", &outputPath,
    "emit-llvm", "build: write LLVM IR instead of an executable", &emitLlvm,
    );
    immutable building = args.length == 3 && args[1] == "build";
	if (arguments.helpWanted || !(args.length == 2 || building))
	{
		defaultGetoptPrinter("The Silver interpreter and compiler.\n"
            ~ "Usage: silver [OPTION]... <file>         run <file>\n"
            ~ "       silver build [OPTION]... <file>   compile <file> to an executable with LLVM", arguments.options);
		return 0;
	}

	auto programFile = args[$ - 1];
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
        case Backend.interpreter: return interpret(programFile, allImportPaths);
        case Backend.llvm: return compileAndRun(programFile, allImportPaths);
    }
}
