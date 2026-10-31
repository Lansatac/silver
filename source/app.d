import std.stdio;
import std.getopt;
import std.file;
import std.path;

import silver.ast : DiagnosticException, SourceMap;
import silver.interpreter.evaluator : Evaluator;
import silver.loader : load, standardLibraryPath;

/// Interprets a string representing silver code.
int interpret(string code, string filename = "<input>")
{
    auto sources = new SourceMap;
    try
    {
        auto program = load(code, filename, [standardLibraryPath()], sources);
        auto evaluator = new Evaluator(program, true);
        evaluator.run();
    }
    catch (DiagnosticException e)
    {
        stderr.writeln(sources.format(e.diagnostic));
        return 1;
    }

    return 0;
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
	if(!programFile.isFile)
	{
		stderr.writefln("'%s' is not a file!", programFile);
		return 1;
	}

	return interpret(programFile.readText, programFile);
}
