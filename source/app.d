import std.stdio;
import std.getopt;
import std.file;
import std.path;
import std.range;

import silver.ast : Diagnostic, DiagnosticException, formatDiagnostic, Program, SourceContext;
import silver.interpreter.evaluator : Evaluator;
import silver.loader : load, standardLibraryPath;
import silver.sema : analyze;

/// Interprets a string representing silver code.
int interpret(string code, string filename = "<input>", string[] importPaths)
{
    auto context = new SourceContext();
    Program program;
    try
    {
        program = load(code, filename, importPaths, context);
    }
    catch (DiagnosticException e)
    {
        context.collector.report(e.diagnostic);
    }

    if (!context.collector.hasErrors)
    {
        analyze(program, context.collector);
    }

    foreach (diagnostic; context.collector.diagnostics)
    {
        printDiagnostic(diagnostic, context);
    }
    if (context.collector.hasErrors)
    {
        return 1;
    }

    try
    {
        auto evaluator = new Evaluator(program, true);
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

void printDiagnostic(const Diagnostic diagnostic, SourceContext context)
{
    stderr.writeln(formatDiagnostic(diagnostic, context.sources));
}

///Application entry point
int main(string[] args)
{
    string[] importPaths;
	auto arguments = getopt(
    args,
    "importPath|I", "Add a path to search for imported modules", &importPaths
    );
	if (arguments.helpWanted || args.length != 2)
	{
		defaultGetoptPrinter("The Silver interpreter. Usage: silver [OPTION]... <file>", arguments.options);
		return 0;
	}

	auto programFile = args[1];
	if(!programFile.exists || !programFile.isFile)
	{
		stderr.writefln("'%s' is not a file!", programFile);
		return 1;
	}

    auto programDir = programFile.dirName;

	return interpret(programFile.readText, programFile, importPaths.chain([standardLibraryPath(), programDir]).array);
}
