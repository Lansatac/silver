import std.stdio;
import std.getopt;
import std.file;
import std.path;

import silver.ast : Diagnostic, DiagnosticException, formatDiagnostic, Program, SourceContext;
import silver.interpreter.evaluator : Evaluator;
import silver.loader : load, standardLibraryPath;

/// Interprets a string representing silver code.
int interpret(string code, string filename = "<input>")
{
    auto context = new SourceContext();
    Program program;
    try
    {
        program = load(code, filename, [standardLibraryPath()], context);
    }
    catch (DiagnosticException e)
    {
        context.collector.reportError(e.diagnostic.span, e.diagnostic.message);
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
	auto arguments = getopt(
    args);
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

	return interpret(programFile.readText, programFile);
}
