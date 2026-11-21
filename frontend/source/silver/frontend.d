/// `silver`: what a programmer runs. It works out what's being asked and calls the compiler,
/// `silverc`, as a separate program. It imports none of the compiler's packages: the compiler's
/// command line is the only thing the two share.
module silver.frontend;

import std.file : exists, isFile, thisExePath;
import std.path : buildPath, dirName;
import std.process : environment, ProcessException, spawnProcess, wait;
import std.stdio : stderr, stdout;

immutable usage = "Usage: silver <file>                     run <file>\n"
    ~ "       silver run [OPTION]... <file>     the same\n"
    ~ "       silver build [OPTION]... <file>   compile <file> to an executable\n"
    ~ "       silver test [OPTION]... <path>    run the tests in <path>, a file or a directory\n"
    ~ "\n"
    ~ "A word that isn't one of these commands is a file, so a file named `build` is `silver ./build`.\n"
    ~ "Options go before the file, and are the compiler's: run `silverc --help` for them.";

immutable commands = ["run", "build", "test"];

/// What a command line asks for: the command, and what's passed on to the compiler with it.
struct Request
{
    string command;
    string[] rest;
    /// `silver` alone, or asked for help before any command.
    bool help;
}

/// Takes `words`, the command line after the program's name, apart. Only the first word can be a
/// command. Anything else there starts a `run`.
Request request(string[] words)
{
    import std.algorithm : canFind;

    if (words.length == 0 || words[0] == "--help" || words[0] == "-h") return Request(null, null, true);
    if (commands.canFind(words[0])) return Request(words[0], words[1 .. $]);
    return Request("run", words);
}

@("the first word is a command only when it's one of silver's, and a file otherwise")
unittest
{
    assert(request(["hello.ag"]) == Request("run", ["hello.ag"]));
    assert(request(["run", "hello.ag"]) == Request("run", ["hello.ag"]));
    assert(request(["build", "-o", "out", "hello.ag"]) == Request("build", ["-o", "out", "hello.ag"]));
    assert(request(["test", "geometry"]) == Request("test", ["geometry"]));
    assert(request(["./build"]) == Request("run", ["./build"]));
    assert(request(["-b", "llvm", "build"]) == Request("run", ["-b", "llvm", "build"]));
    assert(request(["run", "test"]) == Request("run", ["test"]));
    assert(request([]).help && request(["--help"]).help && request(["-h"]).help);
    assert(!request(["build", "--help"]).help);
}

/// Where the compiler is: where `SILVERC` says, or beside this program.
string compilerPath()
{
    auto named = environment.get("SILVERC", "");
    if (named.length > 0) return named;
    version (Windows) enum name = "silverc.exe";
    else enum name = "silverc";
    return buildPath(thisExePath.dirName, name);
}

/// The compiler's command line for `request`. The command is always given, so that the compiler
/// never takes the file's name for one.
string[] compilerArguments(string compiler, Request request)
{
    return [compiler, request.command] ~ request.rest;
}

@("the compiler is always told the command")
unittest
{
    assert(compilerArguments("silverc", request(["build"])) == ["silverc", "build"]);
    assert(compilerArguments("silverc", request(["./build"])) == ["silverc", "run", "./build"]);
    assert(compilerArguments("silverc", request(["-b", "llvm", "test"])) == ["silverc", "run", "-b", "llvm", "test"]);
}

/// Runs `silver` with the command line `args`, returning the exit status.
int run(string[] args)
{
    auto asked = request(args[1 .. $]);
    if (asked.help)
    {
        stdout.writeln("The Silver language's tool.\n", usage);
        return 0;
    }
    auto compiler = compilerPath();
    if (!compiler.exists || !compiler.isFile)
    {
        stderr.writefln("The compiler, silverc, isn't at '%s'.\n"
            ~ "It's looked for beside silver, or where the environment variable SILVERC says.", compiler);
        return 1;
    }
    try
    {
        // The compiler has this program's input and output, so a program it runs does too.
        immutable status = wait(spawnProcess(compilerArguments(compiler, asked)));
        // Stopped by a signal, which a shell reports as 128 more than its number.
        return status < 0 ? 128 - status : status;
    }
    catch (ProcessException e)
    {
        stderr.writefln("The compiler at '%s' couldn't be started: %s", compiler, e.msg);
        return 1;
    }
}
