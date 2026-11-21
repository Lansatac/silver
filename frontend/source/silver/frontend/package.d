/// `silver`: what a programmer runs. It works out what's being asked and calls the compiler,
/// `silverc`, as a separate program. It imports none of the compiler's packages: the compiler's
/// command line is the only thing the two share.
module silver.frontend;

import std.file : exists, isFile, thisExePath;
import std.path : buildPath, dirName;
import std.process : environment, ProcessException, spawnProcess, wait;
import std.stdio : stderr, stdout;

immutable usage = "Usage: silver <file>                           run <file>\n"
    ~ "       silver run [OPTION]... <file>           the same\n"
    ~ "       silver build [OPTION]... <file>         compile <file> to an executable\n"
    ~ "       silver test [OPTION]... <path>          run the tests in <path>, a file or a directory\n"
    ~ "       silver run|build [OPTION]...            run or compile the program of the project here\n"
    ~ "       silver run|build [OPTION]... <directory>\n"
    ~ "                                               the program of the package at <directory>\n"
    ~ "       silver test [OPTION]...                 run the tests of the project here\n"
    ~ "\n"
    ~ "A word that isn't one of these commands is a file, so a file named `build` is `silver ./build`.\n"
    ~ "Options go before the file, and are the compiler's: run `silverc --help` for them, other than\n"
    ~ "--show-command, which prints the compiler's command line before running it.\n"
    ~ "A silver.toml in the file's directory or above describes its project's packages. With no file,\n"
    ~ "it's looked for from the working directory. Run `silver <command> --help` for more on each.";

/// What `silver <command> --help` prints.
immutable string[string] commandUsage;

shared static this()
{
    immutable options = "\n\nOptions go before the file, and are the compiler's: run `silverc --help` for them, other than\n"
        ~ "--show-command, which prints the compiler's command line before running it.";
    immutable startedIn = "The package silver is started in is the deepest package that the nearest silver.toml at or\n"
        ~ "above the working directory describes, whose directory holds it: the silver.toml's directory for\n"
        ~ "its own package, and the `path` of a package it describes.";
    commandUsage = [
        "run": "Usage: silver run [OPTION]... <file>        run <file>\n"
            ~ "       silver run [OPTION]...               run the program of the package silver is started in\n"
            ~ "       silver run [OPTION]... <directory>   run the program of the package at <directory>\n\n"
            ~ startedIn ~ "\nA package's program is its module that declares `main`, or the one package it describes\n"
            ~ "that's a program. When several are programs, silver lists them, and one is run by its\n"
            ~ "directory, as `silver run compiler`. A package with a silver.toml of its own is run from its\n"
            ~ "directory. A library has no program, and its tests are run with `silver test`." ~ options,
        "build": "Usage: silver build [OPTION]... <file>        compile <file> to an executable\n"
            ~ "       silver build [OPTION]...               compile the program of the package silver is started in\n"
            ~ "       silver build [OPTION]... <directory>   compile the program of the package at <directory>\n\n"
            ~ startedIn ~ "\nThe program is chosen as `silver run` chooses it. Without -o, the executable is written to the\n"
            ~ "working directory, named after the file, or for a package's program, after the last segment of\n"
            ~ "the name of the package whose program it is." ~ options,
        "test": "Usage: silver test [OPTION]... <path>   run the tests in <path>, a file or a directory\n"
            ~ "       silver test [OPTION]...          run the tests of the package silver is started in, and of the\n"
            ~ "                                        packages it describes\n\n"
            ~ startedIn ~ "\nWith no path, the tests are those under that package's directory, as `silver test <directory>`.\n"
            ~ "A directory under it with a silver.toml the project doesn't use is another project, and is left out."
            ~ options,
    ];
}

/// The help `silver` prints for `request`, or null when it doesn't ask for help.
string helpFor(Request request)
{
    import std.algorithm : canFind;

    if (request.help) return "The Silver language's tool.\n" ~ usage;
    auto options = split(request.rest).options;
    if (options.canFind("--help") || options.canFind("-h")) return commandUsage[request.command];
    return null;
}

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
immutable compilerOptionsWithValues = ["--package", "--uses", "--project", "--package-file", "--scripts-in", "--program",
    "--backend", "-b", "--output", "-o", "--filter", "--format", "--skip"];

/// `silver`'s own option, which prints the compiler's command line before running it.
enum showCommand = "--show-command";

/// The compiler's option that says `silver` is driving, so its messages name no option. Given on every run.
enum fromSilver = "--from-silver";

/// The compiler's options that say what packages there are, which inside a project only the
/// project's `silver.toml` says.
immutable packageOptions = ["--package", "--uses", "--project"];

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
    /// The packages the compiler is told files with no `module` line may be beside.
    string[] scriptHomes;
    /// The package whose program `run` or `build` starts from, when no file is named, or null.
    string program;
}

/// Where to look for a project's package file for `file`, the file or directory named: the working
/// directory when nothing is named, and null when there's nowhere to look.
string searchStart(string file, string workingDirectory)
{
    import std.path : absolutePath, buildNormalizedPath;

    if (file is null) return buildNormalizedPath(absolutePath(workingDirectory));
    if (file == "-") return null;
    auto path = buildNormalizedPath(absolutePath(file, workingDirectory));
    if (isDirectory(path)) return path;
    auto directory = path.dirName;
    return isDirectory(directory) ? directory : null;
}

/// What `silver` does for `request`, run from `workingDirectory`, with `compiler` as the compiler.
/// The project's facts go before the request's own options, so that options given by hand follow them.
/// With no file, `run` and `build` take the program of the package started in, and `test` its
/// directory; given a directory, `run` and `build` take the program of the package whose directory it is.
Plan plan(string compiler, Request request, string workingDirectory)
{
    import silver.frontend.project : compilerOptions, findPackageFile, formatMistake, homedAt, homesOf, Mistake,
        otherProjects, programHomes, Project, ProjectCode, readProject, scriptHomes, shownFrom, startedIn;
    import silver.frontend.toml : Span;
    import std.algorithm : map;
    import std.array : array;
    import std.path : absolutePath, buildNormalizedPath;

    auto arguments = split(request.rest);
    Plan result;
    result.show = arguments.show;
    immutable testing = request.command == "test";
    if (arguments.file == "help" && request.command == "run" && !exists(absolutePath("help", workingDirectory)))
    {
        result.mistake = "There's no file named help to run: `silver --help` describes silver's commands.";
        return result;
    }
    auto named = arguments.file is null || arguments.file == "-" ? null
        : buildNormalizedPath(absolutePath(arguments.file, workingDirectory));
    immutable byDirectory = !testing && named !is null && isDirectory(named);
    string[] facts;
    if (auto start = searchStart(arguments.file, workingDirectory))
    {
        auto shown = (string path) => shownFrom(workingDirectory, path);
        result.projectFile = findPackageFile(start);
        if (result.projectFile is null && arguments.file is null)
        {
            result.mistake = formatMistake(Mistake(null, ProjectCode.NoProject, Span(), "There's no silver.toml in "
                ~ start ~ " or any directory above it, so there's no project here to " ~ request.command ~ ": name "
                ~ (testing ? "a file or a directory, as `silver test hello.ag`" : "a file, as `silver "
                    ~ request.command ~ " hello.ag`")));
            return result;
        }
        if (result.projectFile !is null)
        {
            if (auto given = handGiven(arguments.options))
            {
                result.mistake = formatMistake(Mistake(null, ProjectCode.PackageOptionGiven, Span(), given ~ " is "
                    ~ "given by hand, and inside a project packages are described in its package file, "
                    ~ shown(result.projectFile) ~ ": what a package uses is its `uses`, and each package it uses or "
                    ~ "describes is a `[[package]]` entry"));
                return result;
            }
            Project project;
            Mistake mistake;
            if (!readProject(result.projectFile, project, mistake))
            {
                result.mistake = formatMistake(mistake, shown);
                return result;
            }
            if (arguments.file is null || byDirectory)
            {
                auto at = arguments.file is null ? startedIn(project, start) : homedAt(project, named);
                if (at is null)
                {
                    result.mistake = formatMistake(Mistake(null, ProjectCode.NotAPackageDirectory, Span(),
                        shown(named) ~ " is a directory, and no package that " ~ shown(result.projectFile)
                        ~ " describes is there, so it has no program to " ~ request.command ~ ". Its packages are "
                        ~ homesOf(project, shown) ~ "; name one of those directories, or a file"));
                    return result;
                }
                if (arguments.after.length > 0)
                {
                    result.mistake = "`" ~ arguments.after[0] ~ "` follows the directory " ~ arguments.file ~ ", and "
                        ~ "what follows it is for the program, which can't be given arguments yet.";
                    return result;
                }
                if (!testing)
                {
                    result.program = at.name;
                    result.arguments = [compiler, request.command, fromSilver] ~ compilerOptions(project, shown,
                        programHomes(project, *at)) ~ ["--program", at.name] ~ arguments.options;
                    return result;
                }
                named = at.home;
                arguments.file = shown(at.home);
            }
            auto homes = scriptHomes(project, named);
            facts = compilerOptions(project, shown, homes);
            if (testing && isDirectory(named))
            {
                foreach (other; otherProjects(project, named)) facts ~= ["--skip", shown(other)];
            }
            result.scriptHomes = homes.map!(h => h.name.idup).array;
        }
    }
    result.arguments = [compiler, request.command, fromSilver] ~ facts ~ arguments.options
        ~ (arguments.file is null ? [] : [arguments.file]) ~ arguments.after;
    return result;
}

/// The first of `packageOptions` among `options`, as it's written there, or null. A word that's
/// another option's value isn't one.
string handGiven(const string[] options)
{
    import std.algorithm : canFind, startsWith;

    for (size_t i = 0; i < options.length; i++)
    {
        foreach (name; packageOptions)
        {
            if (options[i] == name || options[i].startsWith(name ~ "=")) return name;
        }
        if (compilerOptionsWithValues.canFind(options[i])) i++;
    }
    return null;
}

@("with no package file the compiler is given the command line as it is, always with its command")
unittest
{
    auto directory = makeTree("frontend-plain", ["hello.ag": "def main(): Unit {}"]);
    scope (exit) rmdirRecurse(directory);
    Plan of(string[] words) => plan("silverc", request(words), directory);

    assert(of(["./build"]).arguments == ["silverc", "run", "--from-silver", "./build"]);
    assert(of(["-b", "llvm", "test"]).arguments == ["silverc", "run", "--from-silver", "-b", "llvm", "test"]);
    auto hello = of(["--show-command", "-b", "llvm", "hello.ag"]);
    assert(hello.arguments == ["silverc", "run", "--from-silver", "-b", "llvm", "hello.ag"] && hello.show && hello.projectFile is null);
    assert(of(["missing/x.ag"]).arguments == ["silverc", "run", "--from-silver", "missing/x.ag"]);
}

@("the compiler's package options are refused inside a project, however written, and passed on outside one")
unittest
{
    auto directory = makeTree("frontend-hand-options", [
        "project/silver.toml": "name = \"p\"",
        "project/main.ag": "def main(): Unit {}",
        "alone/main.ag": "def main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto project = buildPath(directory, "project");

    immutable names = ["--package", "--uses", "--project", "--uses"];
    foreach (i, option; [["--package", "x=y"], ["--uses", "x"], ["--project=p=p.a"], ["--uses=x"]])
    {
        auto p = plan("silverc", request(option ~ "main.ag"), project);
        immutable given = names[i];
        assert(p.arguments is null && p.mistake == "Error F0036: " ~ given ~ " is given by hand, and inside a project "
            ~ "packages are described in its package file, silver.toml: what a package uses is its `uses`, and each "
            ~ "package it uses or describes is a `[[package]]` entry", p.mistake);
        assert(plan("silverc", request(["test"] ~ option), project).mistake !is null);
        auto alone = plan("silverc", request(option ~ "main.ag"), buildPath(directory, "alone"));
        assert(alone.mistake is null && alone.arguments == ["silverc", "run", "--from-silver"] ~ option ~ "main.ag",
            alone.arguments.commandLine);
    }
    // After the file, it's the program's.
    assert(plan("silverc", request(["main.ag", "--uses", "x"]), project).mistake is null);
}

@("with no file and no package file at or above the working directory there's nothing to run, build or test")
unittest
{
    auto directory = makeTree("frontend-no-file", ["sub/": ""]);
    scope (exit) rmdirRecurse(directory);
    auto sub = buildPath(directory, "sub");
    foreach (command; ["run", "build", "test"])
    {
        auto p = plan("silverc", request([command, "-b", "llvm"]), sub);
        assert(p.arguments is null && p.mistake == "Error F0033: There's no silver.toml in " ~ sub ~ " or any directory "
            ~ "above it, so there's no project here to " ~ command ~ ": name a file" ~ (command == "test"
                ? " or a directory, as `silver test hello.ag`" : ", as `silver " ~ command ~ " hello.ag`"), p.mistake);
    }
    // Given a directory, the line is passed on as before.
    assert(plan("silverc", request(["run", "sub"]), directory).arguments == ["silverc", "run", "--from-silver", "sub"]);
    assert(plan("silverc", request(["help"]), directory).mistake == "There's no file named help to run: `silver --help` "
        ~ "describes silver's commands.");
}

@("silver's help describes its own commands, and each command's help points at the compiler's for the options")
unittest
{
    import std.algorithm : canFind, startsWith;

    assert(helpFor(request([])).canFind("silver run|build [OPTION]...            run or compile the program of the project here"));
    assert(helpFor(request(["--help"])).canFind("Run `silver <command> --help`"));
    foreach (command; ["run", "build", "test"])
    {
        auto help = helpFor(request([command, "--help"]));
        assert(help.startsWith("Usage: silver " ~ command) && help.canFind("run `silverc --help` for them"), help);
        assert(helpFor(request([command, "-b", "llvm", "-h"])) == help);
    }
    assert(helpFor(request(["-b", "llvm", "--help"])) == commandUsage["run"]);
    assert(helpFor(request(["run", "f.ag", "--help"])) is null);
    assert(helpFor(request(["build", "f.ag"])) is null);
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
    if (auto help = helpFor(asked))
    {
        stdout.writeln(help);
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

@("an option's value that reads like a package option isn't refused as one inside a project")
unittest
{
    auto directory = makeTree("frontend-review-hand-values", [
        "project/silver.toml": "name = \"p\"",
        "project/main.ag": "def main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto project = buildPath(directory, "project");

    foreach (words; [["build", "-o", "--uses", "main.ag"], ["test", "--filter", "--package", "main.ag"],
        ["build", "--output", "--project=x", "main.ag"]])
    {
        auto p = plan("silverc", request(words), project);
        assert(p.mistake is null, p.mistake);
    }
}
