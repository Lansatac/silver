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
    ~ "Options go before the file, and are the compiler's: run `silverc --help` for them, other than\n"
    ~ "--show-command, which prints the compiler's command line before running it.\n"
    ~ "A silver.toml in the file's directory or above describes its project's packages.";

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

/// The compiler's options whose value is the next word, so that the file can be found among the
/// options. A copy of `optionsWithValues` in source/silver/driver.d, which this package can't import;
/// a test reads that one to check the two agree.
immutable compilerOptionsWithValues = ["--package", "--uses", "--parts", "--package-file", "--scripts-in", "--backend",
    "-b", "--output", "-o", "--filter", "--format", "--skip"];

/// `silver`'s own option, which prints the compiler's command line before running it.
enum showCommand = "--show-command";

/// A command line after its command, taken apart at the file.
struct Arguments
{
    /// The options before the file, without `silver`'s own.
    string[] options;
    /// The file or directory, or null when there's none.
    string file;
    /// What follows the file, which is the program's.
    string[] after;
    bool show;
}

/// Takes `rest` apart. The file is the first word that isn't an option or an option's value.
Arguments split(string[] rest)
{
    import std.algorithm : canFind, startsWith;

    Arguments result;
    for (size_t i = 0; i < rest.length; i++)
    {
        if (rest[i] == showCommand)
        {
            result.show = true;
        }
        else if (compilerOptionsWithValues.canFind(rest[i]))
        {
            result.options ~= rest[i .. i + 2 > rest.length ? rest.length : i + 2];
            i++;
        }
        else if (!rest[i].startsWith("-") || rest[i] == "-")
        {
            result.file = rest[i];
            result.after = rest[i + 1 .. $];
            return result;
        }
        else
        {
            result.options ~= rest[i];
        }
    }
    return result;
}

@("the file is the first word that's neither an option nor an option's value, and --show-command is silver's")
unittest
{
    assert(split(["-b", "llvm", "f.ag"]) == Arguments(["-b", "llvm"], "f.ag", []));
    assert(split(["--package-file", "a=x", "--uses", "a", "-O", "f.ag", "x"]) == Arguments(["--package-file", "a=x",
        "--uses", "a", "-O"], "f.ag", ["x"]));
    assert(split(["--show-command", "-o", "out", "dir"]) == Arguments(["-o", "out"], "dir", [], true));
    assert(split(["-o", "--show-command", "f.ag"]) == Arguments(["-o", "--show-command"], "f.ag", []));
    assert(split(["f.ag", "--show-command"]) == Arguments([], "f.ag", ["--show-command"]));
    assert(split(["-b"]) == Arguments(["-b"], null, []));
    assert(split([]) == Arguments.init);
}

@("the copy of the compiler's options with values matches the compiler's own")
unittest
{
    import std.algorithm : sort;
    import std.file : readText;
    import std.path : buildNormalizedPath, dirName;
    import std.regex : matchAll, regex;
    import std.string : indexOf;

    auto driver = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..", "source", "silver", "driver.d");
    auto text = readText(driver);
    auto start = text.indexOf("immutable optionsWithValues = [");
    assert(start >= 0, "no optionsWithValues in " ~ driver);
    auto end = text.indexOf("];", start);
    string[] theirs;
    foreach (m; matchAll(text[start .. end], regex(`"([^"]*)"`))) theirs ~= m[1];
    auto ours = compilerOptionsWithValues.dup;
    assert(theirs.sort.release == ours.sort.release, "the front end's copy differs from " ~ driver);
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

/// What `silver` will do for a request: the compiler's command line, or the mistake that stops it.
struct Plan
{
    string[] arguments;
    /// Print `arguments` before running them.
    bool show;
    /// The message for a mistake in a package file, when there is one, and the compiler isn't run.
    string mistake;
    /// The project's package file, absolute, or null when there's none.
    string projectFile;
    /// The packages and parts the compiler is told files with no `module` line may be beside.
    string[] scriptHomes;
}

/// Where to look for a project's package file for `file`, the file or directory named, or null
/// when nothing is named and there's nowhere to look.
string searchStart(string file, string workingDirectory)
{
    import std.path : absolutePath, buildNormalizedPath;

    if (file is null || file == "-") return null;
    auto path = buildNormalizedPath(absolutePath(file, workingDirectory));
    if (isDirectory(path)) return path;
    auto directory = path.dirName;
    return isDirectory(directory) ? directory : null;
}

/// What `silver` does for `request`, run from `workingDirectory`, with `compiler` as the compiler.
/// The project's facts go before the request's own options, so that options given by hand follow them.
Plan plan(string compiler, Request request, string workingDirectory)
{
    import silver.frontend.project : compilerOptions, findPackageFile, formatMistake, Mistake, otherProjects, Project,
        readProject, scriptHomes, shownFrom;
    import std.algorithm : map;
    import std.array : array;
    import std.path : absolutePath;

    auto arguments = split(request.rest);
    Plan result;
    result.show = arguments.show;
    string[] facts;
    if (auto start = searchStart(arguments.file, workingDirectory))
    {
        auto shown = (string path) => shownFrom(workingDirectory, path);
        result.projectFile = findPackageFile(start);
        if (result.projectFile !is null)
        {
            Project project;
            Mistake mistake;
            if (!readProject(result.projectFile, project, mistake))
            {
                result.mistake = formatMistake(mistake, shown);
                return result;
            }
            auto homes = scriptHomes(project, absolutePath(arguments.file, workingDirectory));
            facts = compilerOptions(project, shown, homes);
            if (request.command == "test" && isDirectory(absolutePath(arguments.file, workingDirectory)))
            {
                foreach (other; otherProjects(project, start)) facts ~= ["--skip", shown(other)];
            }
            result.scriptHomes = homes.map!(h => h.name.idup).array;
        }
    }
    result.arguments = [compiler, request.command] ~ facts ~ arguments.options
        ~ (arguments.file is null ? [] : [arguments.file]) ~ arguments.after;
    return result;
}

@("with no package file the compiler is given the command line as it is, always with its command")
unittest
{
    auto directory = makeTree("frontend-plain", ["hello.ag": "def main(): Unit {}"]);
    scope (exit) rmdirRecurse(directory);
    Plan of(string[] words) => plan("silverc", request(words), directory);

    assert(of(["build"]).arguments == ["silverc", "build"]);
    assert(of(["./build"]).arguments == ["silverc", "run", "./build"]);
    assert(of(["-b", "llvm", "test"]).arguments == ["silverc", "run", "-b", "llvm", "test"]);
    auto hello = of(["--show-command", "-b", "llvm", "hello.ag"]);
    assert(hello.arguments == ["silverc", "run", "-b", "llvm", "hello.ag"] && hello.show && hello.projectFile is null);
    assert(of(["missing/x.ag"]).arguments == ["silverc", "run", "missing/x.ag"]);
}

/// `arguments` as a shell would read them back, for showing.
string commandLine(const string[] arguments)
{
    import std.algorithm : any;
    import std.array : join, replace;

    string[] words;
    foreach (a; arguments)
    {
        immutable plain = a.length > 0 && !a.any!(c => c == ' ' || c == '"' || c == '\t');
        words ~= plain ? a : "\"" ~ a.replace("\"", "\\\"") ~ "\"";
    }
    return words.join(" ");
}

@("the command line shown quotes what has a space")
unittest
{
    assert(commandLine(["silverc", "run", "--package", "a=my dir", "f.ag", ""]) == `silverc run --package "a=my dir" f.ag ""`);
}

/// Runs `silver` with the command line `args`, returning the exit status.
int run(string[] args)
{
    import std.file : getcwd;

    auto asked = request(args[1 .. $]);
    if (asked.help)
    {
        stdout.writeln("The Silver language's tool.\n", usage);
        return 0;
    }
    auto compiler = compilerPath();
    auto planned = plan(compiler, asked, getcwd());
    if (planned.mistake !is null)
    {
        stderr.writeln(planned.mistake);
        return 1;
    }
    if (!compiler.exists || !compiler.isFile)
    {
        stderr.writefln("The compiler, silverc, isn't at '%s'.\n"
            ~ "It's looked for beside silver, or where the environment variable SILVERC says.", compiler);
        return 1;
    }
    if (planned.show) stderr.writeln(commandLine(planned.arguments));
    try
    {
        // The compiler has this program's input and output, so a program it runs does too.
        immutable status = wait(spawnProcess(planned.arguments));
        // Stopped by a signal, which a shell reports as 128 more than its number.
        return status < 0 ? 128 - status : status;
    }
    catch (ProcessException e)
    {
        stderr.writefln("The compiler at '%s' couldn't be started: %s", compiler, e.msg);
        return 1;
    }
}

private bool isDirectory(string path)
{
    import std.file : isDir;

    try return exists(path) && isDir(path);
    catch (Exception) return false;
}

version (unittest)
{
    import std.file : rmdirRecurse;

    /// A fresh directory under the temp directory holding `files` (path to text). A path ending in
    /// `/` is an empty directory. The caller removes it.
    string makeTree(string name, string[string] files)
    {
        import std.file : mkdirRecurse, tempDir, write;
        import std.path : buildNormalizedPath;

        auto directory = buildNormalizedPath(tempDir, "silver-" ~ name);
        if (exists(directory)) rmdirRecurse(directory);
        mkdirRecurse(directory);
        foreach (path, text; files)
        {
            auto full = buildPath(directory, path);
            if (path.length > 0 && path[$ - 1] == '/')
            {
                mkdirRecurse(full);
                continue;
            }
            mkdirRecurse(full.dirName);
            write(full, text);
        }
        return directory;
    }
}
