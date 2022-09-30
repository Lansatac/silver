import std.stdio;
import std.getopt;
import std.file;

import silver.grammar;
import silver.interpreter;

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
		stderr.writefln("'%s' is not a file!");
		return 1;
	}

	return interpret(programFile.readText);
}
