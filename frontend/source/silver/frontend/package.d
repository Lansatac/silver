/// `silver`: what a programmer runs. It works out what's being asked and calls the compiler,
/// `silverc`, as a separate program. It imports none of the compiler's packages: the compiler's
/// command line is the only thing the two share.
module silver.frontend;

import std.file : exists, isFile, thisExePath;
import std.path : buildPath, dirName;
import std.process : environment, ProcessException, spawnProcess, wait;
import std.stdio : stderr, stdout;
import silver.frontend.project : TestRun;

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
    ~ "What follows the file is the program's arguments. With no file, or a directory, they follow `--`.\n"
    ~ "Options go before the file, and are the compiler's: run `silverc --help` for them, other than\n"
    ~ "--show-command, which prints the compiler's command line before running it.\n"
    ~ "A silver.toml in the file's directory or above describes its project's packages. With no file,\n"
    ~ "it's looked for from the working directory. Run `silver <command> --help` for more on each.\n"
    ~ "`silver --version` prints silver's version.";

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
        "run": "Usage: silver run [OPTION]... <file> [ARGUMENT]...              run <file>\n"
            ~ "       silver run [OPTION]... [-- ARGUMENT...]               run the program of the package silver is started in\n"
            ~ "       silver run [OPTION]... <directory> [-- ARGUMENT...]   run the program of the package at <directory>\n\n"
            ~ "What follows the file, the directory or nothing is the program's arguments, but a first `--`, which is dropped.\n"
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
            ~ "                                        packages its silver.toml names\n\n"
            ~ startedIn ~ "\nWith no path, the tests are those under that package's directory, as `silver test <directory>`.\n"
            ~ "A directory is tested with what its silver.toml names under it: the packages it describes, and those\n"
            ~ "it lists that have a silver.toml of their own, tested as from their own directory, unless an entry\n"
            ~ "says `test = false`. From the silver.toml's own directory, a package it lists outside that directory\n"
            ~ "is tested too when its entry says `test = true`. A directory under it with a silver.toml that it\n"
            ~ "doesn't name is another project, and is left out, as is any project under a directory in none.\n"
            ~ "Naming a directory tests it, whatever an entry says." ~ options,
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
    "--native-link", "--native-load", "--backend", "-b", "--output", "-o", "--filter", "--format", "--skip", "--also"];

/// `silver`'s own option, which prints the compiler's command line before running it.
enum showCommand = "--show-command";

/// The compiler's option that says `silver` is driving, so its messages name no option. Given on every run.
enum fromSilver = "--from-silver";

/// The compiler's options that say what packages there are, which inside a project only the
/// project's `silver.toml` says.
immutable packageOptions = ["--package", "--uses", "--project"];

/// The compiler's options that say what `test` runs, which inside a project the project's `silver.toml`
/// and the path given say.
immutable testedOptions = ["--also", "--skip"];

/// The compiler's options that give a native library's files, which inside a project its `silver.toml` gives.
immutable nativeOptions = ["--native-link", "--native-load"];

/// A command line after its command, taken apart at the file.
struct Arguments
{
    /// The options before the file, without `silver`'s own.
    string[] options;
    /// The file or directory, or null when there's none.
    string file;
    /// What follows the file, which is the program's, or with `dashed`, what follows `--`.
    string[] after;
    bool show;
    /// Whether `--` came where the file would be, so there's no file and what follows it is the program's.
    bool dashed;
    /// Whether `--version` is among the options, which makes the whole command silver's to answer.
    bool version_;
}

/// Takes `rest` apart. The file is the first word that isn't an option or an option's value, and `--`
/// in its place says there's none.
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
        else if (rest[i] == "--version")
        {
            result.version_ = true;
        }
        else if (compilerOptionsWithValues.canFind(rest[i]))
        {
            result.options ~= rest[i .. i + 2 > rest.length ? rest.length : i + 2];
            i++;
        }
        else if (rest[i] == "--")
        {
            result.after = rest[i + 1 .. $];
            result.dashed = true;
            return result;
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
    assert(split(["-b", "llvm", "--", "a", "--", "-b"]) == Arguments(["-b", "llvm"], null, ["a", "--", "-b"], false, true));
    assert(split(["-o", "--", "f.ag"]) == Arguments(["-o", "--"], "f.ag", []));
    assert(split(["dir", "--", "a"]) == Arguments([], "dir", ["--", "a"]));
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

/// What ends a program given `arguments` before its `main` starts, as `silverc` and a compiled program
/// say it, or null when every one is UTF-8. A copy of `argumentsMistake` in interpreter/errors.d.
string notUtf8(const string[] arguments)
{
    import std.format : format;
    import std.utf : UTFException, validate;

    foreach (i, argument; arguments)
    {
        try validate(argument);
        catch (UTFException) return "argument %s isn't UTF-8: %s".format(i + 1, lossy(argument));
    }
    return null;
}

/// `text` as it can be shown: what's UTF-8 as it is, each other byte as `\xHH`, and an unpaired
/// surrogate, as WTF-8 writes one, as `\u{D800}`. A copy of `lossy` in interpreter/errors.d.
string lossy(const(char)[] text)
{
    import std.format : format;
    import std.utf : decode, UTFException;

    string shown;
    size_t i = 0;
    while (i < text.length)
    {
        if (i + 2 < text.length && text[i] == 0xED && text[i + 1] >= 0xA0 && text[i + 1] <= 0xBF
            && (text[i + 2] & 0xC0) == 0x80)
        {
            shown ~= format("\\u{%X}", 0xD000 | (text[i + 1] & 0x3F) << 6 | (text[i + 2] & 0x3F));
            i += 3;
            continue;
        }
        immutable start = i;
        try
        {
            decode(text, i);
            shown ~= text[start .. i];
        }
        catch (UTFException)
        {
            shown ~= format("\\x%02X", text[start]);
            i = start + 1;
        }
    }
    return shown;
}

/// The command line as it was given. On Windows druntime turns an unpaired surrogate into U+FFFD, which
/// would hand a program a different argument, so the command line is read again and such an argument
/// written as WTF-8, which isn't UTF-8 and is refused. A copy of `exactArguments` in source/silver/driver.d.
string[] exactArguments(string[] given)
{
    version (Windows)
    {
        import core.sys.windows.shellapi : CommandLineToArgvW;
        import core.sys.windows.winbase : GetCommandLineW, LocalFree;
        import core.stdc.wchar_ : wcslen;

        int count;
        auto wide = CommandLineToArgvW(GetCommandLineW(), &count);
        if (wide is null) return given;
        scope (exit) LocalFree(wide);
        auto exact = new string[](count);
        foreach (i; 0 .. count) exact[i] = wtf8(wide[i][0 .. wcslen(wide[i])]);
        return exact;
    }
    else return given;
}

/// `text` as UTF-8, with each unpaired surrogate encoded as if it were a code point.
string wtf8(const(wchar)[] text)
{
    char[] result;
    void put(uint c)
    {
        if (c < 0x80) result ~= cast(char) c;
        else if (c < 0x800) result ~= [cast(char)(0xC0 | c >> 6), cast(char)(0x80 | (c & 0x3F))];
        else if (c < 0x10000)
            result ~= [cast(char)(0xE0 | c >> 12), cast(char)(0x80 | (c >> 6 & 0x3F)), cast(char)(0x80 | (c & 0x3F))];
        else result ~= [cast(char)(0xF0 | c >> 18), cast(char)(0x80 | (c >> 12 & 0x3F)), cast(char)(0x80 | (c >> 6 & 0x3F)),
            cast(char)(0x80 | (c & 0x3F))];
    }
    for (size_t i = 0; i < text.length; i++)
    {
        uint c = text[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < text.length && text[i + 1] >= 0xDC00 && text[i + 1] < 0xE000)
        {
            c = 0x10000 + ((c - 0xD800) << 10) + (text[i + 1] - 0xDC00);
            i++;
        }
        put(c);
    }
    return result.idup;
}

@("WTF-8 is UTF-8 for text with no unpaired surrogate, and isn't UTF-8 for text with one")
unittest
{
    assert(wtf8("héllo 😀"w) == "héllo 😀");
    wchar[] lone = ['a', cast(wchar) 0xD800, 'b'];
    assert(wtf8(lone) == "a\xed\xa0\x80b");
    assert(notUtf8(["x", wtf8(lone)]) == `argument 2 isn't UTF-8: a\u{D800}b`);
    wchar[] reversed = [cast(wchar) 0xDC00, cast(wchar) 0xD800];
    assert(notUtf8([wtf8(reversed)]) == `argument 1 isn't UTF-8: \u{DC00}\u{D800}`);
}

@("the copies of the compiler's functions for reading the command line match the compiler's own")
unittest
{
    import std.file : readText;
    import std.path : buildNormalizedPath, dirName;
    import std.string : indexOf;

    auto source = (string[] path...) => readText(buildNormalizedPath([dirName(__FILE_FULL_PATH__), "..", "..", "..", ".."]
        ~ path));
    // From the body's opening brace to its closing one at the start of a line.
    string body(string text, string signature)
    {
        auto start = text.indexOf(signature);
        assert(start >= 0, "no " ~ signature);
        auto open = text.indexOf("\n{\n", start);
        return text[open .. text.indexOf("\n}\n", open) + 3];
    }
    auto ours = readText(__FILE_FULL_PATH__);
    auto driver = source("source", "silver", "driver.d");
    auto errors = source("interpreter", "source", "silver", "interpreter", "errors.d");
    auto runtime = source("runtime", "source", "silver", "runtime", "arguments.d");
    foreach (signature; ["string[] exactArguments(string[] given)", "string wtf8(const(wchar)[] text)"])
        assert(body(ours, signature) == body(driver, signature), signature ~ " differs from the driver's");
    assert(body(runtime, "string wtf8(") == body(driver, "string wtf8("), "the runtime's wtf8 differs from the driver's");
    immutable mistake = "string argumentsMistake(const string[] arguments)";
    assert(body(ours, "string notUtf8(const string[] arguments)") == body(errors, mistake),
        "notUtf8 differs from argumentsMistake");
    assert(body(runtime, mistake) == body(errors, mistake), "the runtime's argumentsMistake differs");
    foreach (copy; [ours, runtime])
        assert(body(copy, "string lossy(") == body(errors, "string lossy("), "a copy of lossy differs");
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
    /// What `--show-command` adds on stderr after the command line, or null: for `test`, what the package
    /// files name that the run leaves out.
    string note;
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
    import silver.frontend.project : compilerOptions, Facts, findPackageFile, formatMistake, homedAt, homesOf, Mistake,
        programHomes, Project, ProjectCode, projectsUnder, readProject, readTestRun, scriptHomes, shownFrom, startedIn,
        TestRun;
    import silver.frontend.toml : Span;
    import std.algorithm : canFind, map;
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
    if (testing && arguments.dashed)
    {
        result.mistake = "`silver test` runs tests, which aren't given arguments, so nothing follows `--`.";
        return result;
    }
    // Windows passes a command line as UTF-16, so a word that isn't UTF-8 can't reach silverc. Only `run`
    // gives a program its arguments, so it says what the program would; for `build` and `test`, which refuse
    // them, the word is passed on with U+FFFD in its place, so silverc says that.
    version (Windows)
    {
        import std.encoding : sanitize;

        immutable checkHere = request.command == "run";
        if (!checkHere) arguments.after = arguments.after.map!(a => sanitize(a)).array;
    }
    else immutable checkHere = false;
    // After a file, every word is the program's but a first `--`; after a directory, they follow `--`, as with
    // no file. After a file they're passed on as given, and silverc drops the `--` by the same rule.
    auto programArguments = arguments.after;
    if (byDirectory && programArguments.length > 0 && programArguments[0] != "--")
    {
        result.mistake = "`" ~ programArguments[0] ~ "` follows the directory " ~ arguments.file ~ ", and there "
            ~ "the program's arguments follow `--`, as `silver " ~ request.command ~ " " ~ arguments.file ~ " -- "
            ~ programArguments[0] ~ "`.";
        return result;
    }
    if (!arguments.dashed && programArguments.length > 0 && programArguments[0] == "--")
        programArguments = programArguments[1 .. $];
    // Elsewhere silverc checks them once the program is compiled, as it does when run by hand.
    if (checkHere)
    {
        if (auto wrong = notUtf8(programArguments))
        {
            result.mistake = "error: " ~ wrong;
            return result;
        }
    }
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
                    ~ "given by hand, and inside a project " ~ (nativeOptions.canFind(given) ? "a native library's files "
                    ~ "are given in a package file, as [native.<library>.<platform>] with `link` and `load`"
                    : testedOptions.canFind(given) ? "what's tested is decided by "
                    ~ "its package file, " ~ shown(result.projectFile) ~ ", and the path given: the `test` field of a "
                    ~ "`[[package]]` entry says whether a wider run tests that package, and naming a directory tests it"
                    : "packages are described in its package file, " ~ shown(result.projectFile) ~ ": what a package "
                    ~ "uses is its `uses`, and each package it uses or describes is a `[[package]]` entry")));
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
                if (!testing)
                {
                    result.program = at.name;
                    result.arguments = [compiler, request.command, fromSilver] ~ compilerOptions(project, shown,
                        programHomes(project, *at)) ~ ["--program", at.name] ~ arguments.options
                        ~ (programArguments.length > 0 ? ["--"] ~ programArguments : []);
                    return result;
                }
                named = at.home;
                arguments.file = shown(at.home);
            }
            const(Facts)[] homes;
            if (testing && isDirectory(named))
            {
                TestRun run;
                if (!readTestRun(result.projectFile, named, run, mistake))
                {
                    result.mistake = formatMistake(mistake, shown);
                    return result;
                }
                foreach (tested; run.tested)
                {
                    foreach (h; scriptHomes(run.project, tested))
                    {
                        if (!homes.canFind!(k => k.name == h.name)) homes ~= h;
                    }
                }
                facts = compilerOptions(run.project, shown, homes);
                foreach (skipped; run.skipped) facts ~= ["--skip", shown(skipped)];
                foreach (tested; run.tested[1 .. $]) facts ~= ["--also", shown(tested)];
                result.note = leftOutNote(run, shown);
            }
            else
            {
                homes = scriptHomes(project, named);
                facts = compilerOptions(project, shown, homes);
            }
            result.scriptHomes = homes.map!(h => h.name.idup).array;
        }
        else if (testing && named !is null && isDirectory(named))
        {
            // A directory in no project names no package, so a project under it is left out.
            foreach (other; projectsUnder(named)) facts ~= ["--skip", shown(other)];
        }
    }
    result.arguments = [compiler, request.command, fromSilver] ~ facts ~ arguments.options
        ~ (arguments.file is null ? [] : [arguments.file]) ~ arguments.after;
    return result;
}

/// What the package files name that `run` leaves out, as `--show-command` says it, or null.
string leftOutNote(const TestRun run, string delegate(string) shown)
{
    import std.array : join;

    if (run.leftOut.length == 0) return null;
    string[] each;
    foreach (l; run.leftOut)
    {
        each ~= shown(l.directory) ~ (l.outside ? ", outside the directory tested, with no `test = true`"
            : ", with `test = false`");
    }
    return "Not tested, though a silver.toml names them: " ~ each.join("; ");
}

/// The first of `packageOptions` and `testedOptions` among `options`, as it's written there, or null. A word that's
/// another option's value isn't one.
string handGiven(const string[] options)
{
    import std.algorithm : canFind, startsWith;

    for (size_t i = 0; i < options.length; i++)
    {
        foreach (name; packageOptions ~ testedOptions ~ nativeOptions)
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

    foreach (option; [["--also", "../alone"], ["--skip", "sub"], ["--skip=sub"]])
    {
        auto p = plan("silverc", request(["test"] ~ option), project);
        immutable given = option[0][0 .. 6];
        assert(p.arguments is null && p.mistake == "Error F0036: " ~ given ~ " is given by hand, and inside a project "
            ~ "what's tested is decided by its package file, silver.toml, and the path given: the `test` field of a "
            ~ "`[[package]]` entry says whether a wider run tests that package, and naming a directory tests it", p.mistake);
        auto alone = plan("silverc", request(["test"] ~ option ~ "."), buildPath(directory, "alone"));
        assert(alone.mistake is null && alone.arguments == ["silverc", "test", "--from-silver"] ~ option ~ ".",
            alone.arguments.commandLine);
    }
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

/// The version stamped at build time by the stampversion program.
immutable versionText = import("version.txt");

/// Runs `silver` with the command line `args`, returning the exit status.
int run(string[] args)
{
    import std.algorithm : canFind;
    import std.file : getcwd;

    auto asked = request(args[1 .. $]);
    if (auto help = helpFor(asked))
    {
        stdout.writeln(help);
        return 0;
    }
    if (split(asked.rest).version_)
    {
        stdout.writeln("silver ", versionText);
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
    if (planned.show)
    {
        stderr.writeln(commandLine(planned.arguments));
        if (planned.note !is null) stderr.writeln(planned.note);
    }
    // Windows passes a command line as UTF-16, so a word that isn't UTF-8 can't be passed on. The
    // program's arguments were checked by `plan`; this is a path or an option.
    version (Windows)
    {
        if (notUtf8(planned.arguments) !is null)
        {
            stderr.writeln("A word given to silver isn't UTF-8, so it can't be passed on to the compiler.");
            return 1;
        }
    }
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

    /// Removes a directory and all in it, read-only files too: git's objects are read-only, and on
    /// Windows rmdirRecurse can't delete one.
    void removeTree(string directory)
    {
        version (Windows)
        {
            import core.sys.windows.winnt : FILE_ATTRIBUTE_READONLY;
            import std.file : dirEntries, setAttributes, SpanMode;

            foreach (entry; dirEntries(directory, SpanMode.depth))
                if (!entry.isDir) setAttributes(entry.name, entry.attributes & ~FILE_ATTRIBUTE_READONLY);
        }
        rmdirRecurse(directory);
    }

    /// A fresh directory under the temp directory holding `files` (path to text). A path ending in
    /// `/` is an empty directory. The caller removes it.
    string makeTree(string name, string[string] files)
    {
        import std.file : mkdirRecurse, tempDir, write;
        import std.path : buildNormalizedPath;
        import std.uuid : randomUUID;

        auto directory = buildNormalizedPath(tempDir, "silver-" ~ name ~ "-" ~ randomUUID().toString());
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

version (unittest)
{
    /// A root shaped like the compiler's: libraries and programs it describes, one described package
    /// opted out, packages with files of their own under it (one opted out, one listing packages of its
    /// own), a project under it that it doesn't name, a folder of scripts, and packages outside it.
    string[string] testRunTree(bool optIn)
    {
        auto tool = "name = \"tool\"\n\n"
            ~ "[[package]]\nname = \"tool.ast\"\npath = \"ast\"\n\n"
            ~ "[[package]]\nname = \"tool.syntax\"\npath = \"syntax\"\nuses = [\"tool.ast\"]\n\n"
            ~ "[[package]]\nname = \"tool.compiler\"\npath = \"compiler\"\nsource = \"source\"\nuses = [\"tool.syntax\"]\n\n"
            ~ "[[package]]\nname = \"tool.frontend\"\npath = \"frontend\"\n\n"
            ~ "[[package]]\nname = \"tool.docs\"\npath = \"docs\"\ntest = false\n\n"
            ~ "[[package]]\npath = \"stdlib\"\n\n"
            ~ "[[package]]\npath = \"vendor\"\ntest = false\n\n"
            ~ "[[package]]\npath = \"lib\"\ntest = true\n\n"
            ~ "[[package]]\npath = \"../geometry\"\n" ~ (optIn ? "test = true\n\n" : "\n")
            ~ "[[package]]\npath = \"../loose\"\ntest = false\n\n"
            ~ "[[package]]\npath = \"vendorlib/core\"\n";
        return [
            "tool/silver.toml": tool,
            "tool/ast/": "", "tool/syntax/": "", "tool/compiler/source/": "", "tool/frontend/": "", "tool/docs/": "",
            "tool/scripts/try.ag": "",
            "tool/stdlib/silver.toml": "name = \"stdlib\"",
            "tool/vendor/silver.toml": "name = \"vendor\"",
            "tool/lib/silver.toml": "name = \"lib\"\nsource = \"src\"\n[[package]]\npath = \"inner\"\n"
                ~ "[[package]]\npath = \"../../outside\"\ntest = true",
            "tool/lib/src/": "",
            "tool/lib/inner/silver.toml": "name = \"inner\"",
            "tool/fixtures/proj/silver.toml": "name = \"proj\"",
            "tool/vendorlib/silver.toml": "name = \"vlib\"\n[[package]]\nname = \"vlib.core\"\npath = \"core\"\n"
                ~ "[[package]]\nname = \"vlib.extra\"\npath = \"extra\"",
            "tool/vendorlib/core/": "", "tool/vendorlib/extra/": "",
            "outside/silver.toml": "name = \"outside\"",
            "geometry/silver.toml": "name = \"geometry\"\nsource = \"src\"\nuses = [\"units\"]\n"
                ~ "[[package]]\npath = \"../units\"\n[[package]]\npath = \"extras\"\n"
                ~ "[[package]]\nname = \"geometry.shapes\"\npath = \"shapes\"\n"
                ~ "[[package]]\nname = \"geometry.old\"\npath = \"old\"\ntest = false",
            "geometry/src/": "", "geometry/shapes/": "", "geometry/old/": "",
            "geometry/extras/silver.toml": "name = \"extras\"",
            "units/silver.toml": "name = \"units\"",
            "loose/silver.toml": "name = \"loose\"",
        ];
    }

    /// What a plan tests, skips, gives `--scripts-in` for and declares, with directories relative to
    /// `base` and written with `/`.
    struct Tested
    {
        string path;
        string[] also;
        string[] skipped;
        string[] scripts;
        string[] declared;
    }

    Tested testedBy(Plan p, string base, string workingDirectory)
    {
        import std.algorithm : canFind, sort;
        import std.array : replace;
        import std.path : absolutePath, buildNormalizedPath, relativePath;
        import std.string : indexOf;

        assert(p.mistake is null, p.mistake);
        auto shown = (string path) => relativePath(buildNormalizedPath(absolutePath(path, workingDirectory)), base)
            .replace("\\", "/");
        Tested t;
        auto words = p.arguments;
        for (size_t i = 3; i < words.length; i++)
        {
            if (words[i] == "--also") t.also ~= shown(words[++i]);
            else if (words[i] == "--skip") t.skipped ~= shown(words[++i]);
            else if (words[i] == "--package-file")
            {
                i++;
                t.declared ~= words[i][0 .. words[i].indexOf('=')];
            }
            else if (compilerOptionsWithValues.canFind(words[i])) i++;
            else t.path = shown(words[i]);
        }
        t.skipped.sort;
        t.declared.sort;
        t.scripts = p.scriptHomes.dup.sort.release;
        return t;
    }
}

@("silver test tests what its file names under the directory, what it opts in outside it, and nothing else")
unittest
{
    import std.algorithm : canFind;
    import std.array : join;

    auto base = makeTree("frontend-test-run", testRunTree(true));
    scope (exit) rmdirRecurse(base);
    auto tool = buildPath(base, "tool");
    Tested from(string[] words, string[] at...) => testedBy(plan("silverc", request(["test"] ~ words),
        buildPath(base ~ at)), base, buildPath(base ~ at));

    // From the root: every package it describes but docs, stdlib, and lib with what lib's file names under
    // it, and geometry outside, alone; not vendor, loose, or lib's own opt-in, which is outside. The one
    // package of vendorlib's project it lists is tested, and the rest of that project isn't.
    auto root = from([], "tool");
    assert(root.path == "tool" && root.also == ["geometry", "tool/vendorlib/core"], root.also.join(","));
    assert(root.skipped == ["geometry/extras", "geometry/old", "tool/docs", "tool/fixtures/proj", "tool/vendor",
        "tool/vendorlib"], root.skipped.join(","));
    // geometry's dependency is declared, and lib's opt-in, which nothing uses, isn't read for the run.
    assert(root.declared.canFind("units") && !root.declared.canFind("outside") && !root.declared.canFind("loose")
        && root.declared.canFind("inner") && root.declared.canFind("stdlib"), root.declared.join(","));
    assert(root.scripts.canFind("geometry.shapes") && root.scripts.canFind("tool.ast") && root.scripts.canFind("inner")
        && !root.scripts.canFind("units"), root.scripts.join(","));
    assert(from([], "tool", "scripts") == root);
    assert(from(["."], "tool") == root);
    assert(from(["tool"]) == root);
    auto p = plan("silverc", request(["test"]), tool);
    assert(p.note == "Not tested, though a silver.toml names them: docs, with `test = false`; vendor, with `test = "
        ~ "false`; " ~ buildPath(base, "loose") ~ ", with `test = false`", p.note);

    // From inside one described package, that package; from its source, the same.
    auto ast = from([], "tool", "ast");
    assert(ast.path == "tool/ast" && ast.also == [] && ast.skipped == [] && ast.scripts == ["tool.ast"], ast.path);
    assert(from([], "tool", "compiler", "source").path == "tool/compiler");
    // Naming a directory the file opts out tests it.
    auto docs = from(["docs"], "tool");
    assert(docs.path == "tool/docs" && docs.also == [] && docs.skipped == [], docs.skipped.join(","));
    auto vendor = from(["vendor"], "tool");
    assert(vendor.path == "tool/vendor" && vendor.declared == ["vendor"], vendor.declared.join(","));
    // A nested file's own opt-in counts when silver test starts from it.
    auto lib = from([], "tool", "lib");
    assert(lib.path == "tool/lib" && lib.also == ["outside"] && lib.skipped == [], lib.also.join(","));
    // An opted-in project tested from its own directory follows its own file.
    auto geometry = from([], "geometry");
    assert(geometry.path == "geometry" && geometry.skipped == ["geometry/old"] && geometry.also == [],
        geometry.skipped.join(","));
    // A plain folder under the root is tested with what the root names under it, and nothing outside.
    auto fixtures = from(["fixtures"], "tool");
    assert(fixtures.path == "tool/fixtures" && fixtures.skipped == ["tool/fixtures/proj"] && fixtures.also == []);
}

@("an entry outside the directory is tested only when it opts in, and a directory in no project leaves out the projects under it")
unittest
{
    import std.algorithm : canFind;
    import std.array : join;

    auto base = makeTree("frontend-test-run-out", testRunTree(false));
    scope (exit) rmdirRecurse(base);
    auto root = testedBy(plan("silverc", request(["test"]), buildPath(base, "tool")), base, buildPath(base, "tool"));
    assert(root.also == ["tool/vendorlib/core"] && root.skipped == ["tool/docs", "tool/fixtures/proj", "tool/vendor",
        "tool/vendorlib"], root.skipped.join(","));
    assert(!root.declared.canFind("geometry") && !root.declared.canFind("units"), root.declared.join(","));

    auto none = plan("silverc", request(["test", "."]), base);
    assert(none.mistake is null && none.projectFile is null);
    auto lone = testedBy(none, base, base);
    assert(lone.path == "." && lone.skipped == ["geometry", "loose", "outside", "tool", "units"], lone.skipped.join(","));
    assert(none.arguments[0 .. 3] == ["silverc", "test", "--from-silver"]);
}


@("an entry's test = false is honoured when its directory is inside another package the file tests")
unittest
{
    import std.algorithm : canFind;
    import std.array : join;

    auto base = makeTree("frontend-review-opt-out-inside", [
        "root/silver.toml": "name = \"app\"\nsource = \"src\"\n\n[[package]]\npath = \"vl\"\n\n"
            ~ "[[package]]\npath = \"vl/extra\"\ntest = false\n",
        "root/src/": "",
        "root/vl/silver.toml": "name = \"vl\"\nsource = \"src\"\n[[package]]\nname = \"vl.extra\"\npath = \"extra\"\n",
        "root/vl/src/": "", "root/vl/extra/": "",
    ]);
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "root");
    auto p = plan("silverc", request(["test"]), root);
    auto t = testedBy(p, base, root);
    // The note says vl/extra isn't tested, so the run has to leave it out.
    assert(p.note !is null && p.note.canFind("extra"), p.note);
    assert(t.skipped.canFind("root/vl/extra"), "vl/extra is tested though its entry says test = false: skipped "
        ~ t.skipped.join(","));

    // The same inside a package outside opted in: an entry not opted in, or opted out, leaves its package out.
    auto outer = makeTree("frontend-review-opt-out-outside", [
        "root/silver.toml": "name = \"app\"

[[package]]
path = \"../ext\"
test = true

"
            ~ "[[package]]
path = \"../ext/shapes\"

[[package]]
path = \"../ext/other\"
test = false
",
        "ext/silver.toml": "name = \"ext\"
source = \"src\"
[[package]]
name = \"ext.shapes\"
path = \"shapes\"
"
            ~ "[[package]]
name = \"ext.other\"
path = \"other\"
[[package]]
name = \"ext.kept\"
path = \"kept\"
",
        "ext/src/": "", "ext/shapes/": "", "ext/other/": "", "ext/kept/": "",
    ]);
    scope (exit) rmdirRecurse(outer);
    root = buildPath(outer, "root");
    p = plan("silverc", request(["test"]), root);
    t = testedBy(p, outer, root);
    assert(t.also == ["ext"] && t.skipped == ["ext/other", "ext/shapes"], t.skipped.join(","));
    assert(p.note.canFind("shapes, outside the directory tested") && p.note.canFind("other, with `test = false`"), p.note);
}
