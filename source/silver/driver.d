module silver.driver;

import std.stdio;
import std.getopt;
import std.file;
import std.path;
import std.range;

import silver.ast : Diagnostic, DiagnosticException, formatDiagnostic, Program, SourceContext;
import silver.codegen : copyBeside, executablePath, findingLibraries, findToolchain, generate, linkExecutable, Optimization,
    optimizeIr, sharedLibrariesOf, Toolchain;
import silver.core : lowerProgram, printCore = print;
import silver.interpreter : Evaluator, OutputFailed, panicReport, panicStatus, ProgramExited, ProgramFailed, RuntimeError;
import silver.loader : describeNativeFiles, describePackageFiles, describePackages, describeScriptHomes, describeSilver, load,
    missingStandardLibrary, NativeFiles, nativesOf, Packages, programStart, standardPrelude, undeclared;
import silver.sema : analyze, Analysis, Target;

/// Loads and analyzes `programFile`, with the files its native libraries are given in `natives`. Problems
/// go to `context.collector`, which the caller must check before using `program` or the returned Analysis.
Analysis loadAndAnalyze(string programFile, const Packages packages, SourceContext context, out Program program,
    out NativeFiles natives)
{
    try
    {
        program = load(programFile.readText, programFile, packages, standardPrelude, context);
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
    natives = nativesOf(program, packages, context);
    if (context.collector.hasErrors)
    {
        return null;
    }
    return analyze(program, context.collector, Target.host);
}

/// Interprets the program in `programFile` with `arguments`, or with `emitCore`, prints the Core it lowers to.
int interpret(string programFile, const Packages packages, bool emitCore = false, string[] arguments = null)
{
    auto context = new SourceContext();
    Program program;
    NativeFiles natives;
    auto analysis = loadAndAnalyze(programFile, packages, context, program, natives);
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
        auto evaluator = new Evaluator(lowered, true, arguments, null, natives.load);
        evaluator.run();
    }
    catch (RuntimeError e)
    {
        stdout.flush();
        stderr.writeln(panicReport(e.diagnostic, context.sources));
        return panicStatus;
    }
    catch (ProgramFailed e)
    {
        stdout.flush();
        stderr.writeln("error: ", e.msg);
        return 1;
    }
    catch (ProgramExited e)
    {
        stdout.flush();
        return e.status;
    }
    catch (OutputFailed e)
    {
        if (!e.closedPipe)
        {
            stderr.writeln("error: ", e.msg);
        }
        endAtOnce(1);
    }
    catch (DiagnosticException e)
    {
        printDiagnostic(e.diagnostic, context);
        return 1;
    }

    return 0;
}

/// Ends the process with `status` without flushing standard output, whose buffer holds what a failed write left
/// there: C's exit would write it again, and D's `stdout` complain when it can't.
noreturn endAtOnce(int status)
{
    import core.stdc.stdlib : _Exit;

    stderr.flush();
    _Exit(status);
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
/// `libraries` are what it has to be linked with, and `natives` the files given for them.
string compileToIr(string programFile, const Packages packages, out string[] libraries, out NativeFiles natives)
{
    auto context = new SourceContext();
    Program program;
    auto analysis = loadAndAnalyze(programFile, packages, context, program, natives);
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

/// Writes `content` to `path`. False after printing why it couldn't.
bool writeFile(string path, string content)
{
    try
    {
        std.file.write(path, content);
        return true;
    }
    catch (FileException e)
    {
        stderr.writeln("Couldn't write ", path, ": ", e.msg);
        return false;
    }
}

/// Compiles the program in `programFile` to the executable `outputPath`, with the shared libraries that
/// `packages` gives for the libraries it's linked with in `sharedLibraries`. With `copyLibraries`, those
/// are copied beside it, where it finds them. False after printing why it failed.
bool compileToExecutable(string programFile, const Packages packages, string outputPath, Optimization optimization,
    bool copyLibraries, out string[] sharedLibraries)
{
    string[] libraries;
    NativeFiles natives;
    auto ir = compileToIr(programFile, packages, libraries, natives);
    if (ir is null)
    {
        return false;
    }
    sharedLibraries = sharedLibrariesOf(libraries, natives.load);
    Toolchain toolchain;
    if (auto missing = findToolchain(toolchain))
    {
        stderr.writeln(missing);
        return false;
    }

    auto irPath = temporaryPath(programFile, ".ll");
    if (!writeFile(irPath, ir))
    {
        return false;
    }
    scope (exit) remove(irPath);

    immutable beside = copyLibraries && sharedLibraries.length > 0;
    auto linked = linkExecutable(toolchain, irPath, outputPath, libraries, optimization, natives.link, beside);
    if (!linked.succeeded)
    {
        stderr.writeln("Linking failed:\n", linked.output);
        return false;
    }
    if (beside)
    {
        if (auto failed = copyBeside(sharedLibraries, outputPath))
        {
            stderr.writeln(failed);
            return false;
        }
    }
    return true;
}

/// Compiles the program in `programFile` to an executable, or only to LLVM IR if `emitLlvm`:
/// the IR codegen writes, or when optimizing, what clang makes of it. Without `outputPath`, what's
/// written is named `name`, or after the file when that's null, in the working directory.
int build(string programFile, const Packages packages, string outputPath, bool emitLlvm, Optimization optimization,
    string name = null)
{
    if (name is null) name = programFile.baseName.stripExtension;
    if (outputPath.empty)
    {
        auto written = emitLlvm ? name ~ ".ll" : executablePath(name);
        if (written.exists && written.isDir)
        {
            stderr.writeln("The ", emitLlvm ? "IR" : "executable", " would be written to ", written,
                ", which is a directory: give where to write it with -o.");
            return 1;
        }
    }
    else if (outputPath.exists && outputPath.isDir)
    {
        stderr.writeln("-o names ", outputPath, ", which is a directory: give the file to write.");
        return 1;
    }
    if (emitLlvm)
    {
        string[] libraries;
        NativeFiles natives;
        auto ir = compileToIr(programFile, packages, libraries, natives);
        if (ir is null)
        {
            return 1;
        }
        auto irPath = outputPath.empty ? name ~ ".ll" : outputPath;
        if (optimization == Optimization.none)
        {
            return writeFile(irPath, ir) ? 0 : 1;
        }
        Toolchain toolchain;
        if (auto missing = findToolchain(toolchain))
        {
            stderr.writeln(missing);
            return 1;
        }
        auto unoptimizedPath = temporaryPath(programFile, ".ll");
        if (!writeFile(unoptimizedPath, ir))
        {
            return 1;
        }
        scope (exit) remove(unoptimizedPath);
        auto optimized = optimizeIr(toolchain, unoptimizedPath, irPath);
        if (!optimized.succeeded)
        {
            stderr.writeln("Optimizing failed:\n", optimized.output);
            return 1;
        }
        return 0;
    }
    string[] sharedLibraries;
    return compileToExecutable(programFile, packages, outputPath.empty ? executablePath(name) : outputPath, optimization,
        true, sharedLibraries) ? 0 : 1;
}

/// Compiles the program in `programFile` to a temporary executable and runs it with `arguments`,
/// returning its exit status.
int compileAndRun(string programFile, const Packages packages, Optimization optimization, string[] arguments = null)
{
    import silver.interpreter : argumentsMistake;
    import std.process : ProcessException, spawnProcess, wait;

    auto exePath = executablePath(temporaryPath(programFile, ""));
    string[] sharedLibraries;
    if (!compileToExecutable(programFile, packages, exePath, optimization, false, sharedLibraries))
    {
        return 1;
    }
    scope (exit) remove(exePath);
    // The executable would say the same, but on Windows an argument that isn't UTF-8 can't be passed to it.
    if (auto mistake = argumentsMistake(arguments))
    {
        stderr.writeln("error: ", mistake);
        return 1;
    }
    try return wait(spawnProcess([exePath] ~ arguments, findingLibraries(sharedLibraries)));
    catch (ProcessException e)
    {
        // As when the arguments are longer than the system takes.
        stderr.writeln("The compiled program couldn't be started: ", e.msg);
        return 1;
    }
}

/// How `silver test` reports.
enum TestFormat
{
    text,
    /// One JSON document, for tools.
    json,
}

/// Runs the tests in the files or directories at `paths` that `filters` selects, reports them on
/// stdout as `format` says, in one report, and returns 0 if they all passed.
int test(const string[] paths, const Packages packages, Backend backend, Optimization optimization,
    const string[] filters = null, TestFormat format = TestFormat.text, const string[] skipped = null)
{
    string report;
    auto status = testReport(paths, packages, backend, optimization, filters, format, report, skipped);
    write(report);
    return status;
}

/// What `test` does, with the report in `text` rather than on stdout. No file under a directory of
/// `skipped` is run, and a file under more than one of `paths` is run once.
int testReport(const string[] paths, const Packages packages, Backend backend, Optimization optimization,
    const string[] filters, TestFormat format, out string text, const string[] skipped = null)
{
    import std.algorithm : canFind, map;
    import silver.testing : jsonReport, report, runFile, succeeded, TestBackend, testFiles;

    auto testBackend = backend == Backend.both ? TestBackend.both
        : backend == Backend.llvm ? TestBackend.llvm : TestBackend.interpreter;
    string[] files;
    string[] seen;
    foreach (path; paths)
    {
        foreach (file; testFiles(path, skipped))
        {
            auto key = buildNormalizedPath(absolutePath(file));
            if (seen.canFind!(s => filenameCmp(s, key) == 0)) continue;
            seen ~= key;
            files ~= file;
        }
    }
    auto runs = files.map!(file => runFile(file, packages, testBackend, tempDir, optimization, filters)).array;
    auto filtered = filters.length > 0;
    text = format == TestFormat.json ? jsonReport(runs, testBackend, filtered) : report(runs, filtered);
    return succeeded(runs, filtered) ? 0 : 1;
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

/// Takes `-O`, `--optimize[=bool]` and `-O<level>` out of `args`, setting `optimize` as the last one says.
/// There is one optimized mode, so the levels are `-O0`, none, and `-O2`, which is `-O`. Returns
/// what's wrong with a level that is neither.
string takeOptimization(ref string[] args, out bool optimize)
{
    import std.algorithm : startsWith;

    string[] rest;
    foreach (arg; args)
    {
        if (arg == "--optimize" || arg == "--optimize=true" || arg == "-O" || arg == "-O2") optimize = true;
        else if (arg == "-O0" || arg == "--optimize=false") optimize = false;
        else if (arg.startsWith("-O"))
        {
            return "`" ~ arg ~ "` isn't an optimization level: there's -O, also spelled -O2, and -O0 for none.";
        }
        else rest ~= arg;
    }
    args = rest;
    return null;
}

@("-O and -O2 optimize, -O0 doesn't, the last one wins, and any other level is a mistake")
unittest
{
    bool optimize;
    auto args = ["silver", "-b", "llvm", "-O2", "f.ag"];
    assert(takeOptimization(args, optimize) is null && optimize);
    assert(args == ["silver", "-b", "llvm", "f.ag"]);

    args = ["silver", "build", "-O", "-O0", "f.ag"];
    assert(takeOptimization(args, optimize) is null && !optimize);
    args = ["silver", "build", "-O0", "--optimize", "f.ag"];
    assert(takeOptimization(args, optimize) is null && optimize);
    args = ["silver", "build", "-o", "out", "f.ag"];
    assert(takeOptimization(args, optimize) is null && !optimize && args.length == 5);

    args = ["silver", "build", "--optimize=false", "-O", "f.ag"];
    assert(takeOptimization(args, optimize) is null && optimize);
    args = ["silver", "build", "-O", "--optimize=false", "f.ag"];
    assert(takeOptimization(args, optimize) is null && !optimize);

    args = ["silver", "build", "--optimize=false", "-O", "f.ag"];
    assert(takeOptimization(args, optimize) is null && optimize);
    args = ["silver", "build", "-O", "--optimize=false", "f.ag"];
    assert(takeOptimization(args, optimize) is null && !optimize);

    args = ["silver", "build", "-O3", "f.ag"];
    assert(takeOptimization(args, optimize) !is null);
}

/// The version stamped at build time by the stampversion program.
immutable versionText = import("version.txt");

immutable usage = "Usage: silverc [run] [OPTION]... <file> [ARGUMENT]...   run <file> with the arguments\n"
    ~ "       silverc build [OPTION]... <file>   compile <file> to an executable with LLVM\n"
    ~ "       silverc test [OPTION]... <path>    run the tests in <path>, a file or a directory\n"
    ~ "       silverc run|build [OPTION]... --program <package> [-- ARGUMENT...]\n"
    ~ "                                          run or compile the program of <package>, in place of a file";

/// Takes the command off the front of `args`. Only the first word can be one, so a file named
/// `build` is run by giving it as `./build`, or after an option.
string takeCommand(ref string[] args)
{
    if (args.length < 2 || (args[1] != "run" && args[1] != "build" && args[1] != "test")) return "run";
    immutable command = args[1];
    args = args[0] ~ args[2 .. $];
    return command;
}

@("only the first word is a command, and a file with no command is run")
unittest
{
    auto args = ["silverc", "build", "-o", "out", "f.ag"];
    assert(takeCommand(args) == "build" && args == ["silverc", "-o", "out", "f.ag"]);
    args = ["silverc", "run", "test"];
    assert(takeCommand(args) == "run" && args == ["silverc", "test"]);
    args = ["silverc", "./build"];
    assert(takeCommand(args) == "run" && args == ["silverc", "./build"]);
    args = ["silverc", "-b", "llvm", "build"];
    assert(takeCommand(args) == "run" && args.length == 4);
    args = ["silverc"];
    assert(takeCommand(args) == "run");
}

/// The options whose value is the next word, as `-o out`. `--output=out` needs no entry. The front end,
/// `silver`, keeps a copy of this list to find the file among the options it passes on
/// (`compilerOptionsWithValues` in frontend/source/silver/frontend/package.d), and a test there reads
/// this one to check the two agree.
immutable optionsWithValues = ["--package", "--uses", "--project", "--package-file", "--scripts-in", "--program",
    "--native-link", "--native-load", "--backend", "-b", "--output", "-o", "--filter", "--format", "--skip", "--also"];

/// Takes the program's words off `args` and returns them. The file is the first word that isn't an
/// option or an option's value, and options stop there: what follows is the program's, except a first
/// `--`, which is dropped. `--` where the file would be ends the options too, so with `--program`, which
/// is given in place of a file, the program's words follow it. getopt's own `stopOnFirstNonOption` can't
/// do this, since it takes an option's value for the first non-option.
string[] takeAfterFile(ref string[] args)
{
    import std.algorithm : canFind, startsWith;

    for (size_t i = 1; i < args.length; i++)
    {
        if (args[i] == "--")
        {
            auto after = args[i + 1 .. $];
            args = args[0 .. i];
            return after;
        }
        if (optionsWithValues.canFind(args[i])) i++;
        else if (!args[i].startsWith("-") || args[i] == "-")
        {
            auto after = args[i + 1 .. $];
            args = args[0 .. i + 1];
            return after.length > 0 && after[0] == "--" ? after[1 .. $] : after;
        }
    }
    return null;
}

@("options stop at the file, which is the first word that's neither an option nor an option's value")
unittest
{
    auto args = ["silverc", "--package", "a=a", "--project", "k=a,b", "--uses", "a", "-b", "llvm", "f.ag"];
    assert(takeAfterFile(args) == [] && args.length == 10);
    args = ["silverc", "-O", "--emit-llvm", "--output=out", "f.ag", "-O", "x"];
    assert(takeAfterFile(args) == ["-O", "x"] && args == ["silverc", "-O", "--emit-llvm", "--output=out", "f.ag"]);
    args = ["silverc", "-o", "f.ag"];
    assert(takeAfterFile(args) == [] && args.length == 3);
    args = ["silverc", "f.ag", "-o", "out"];
    assert(takeAfterFile(args) == ["-o", "out"] && args == ["silverc", "f.ag"]);
    args = ["silverc", "--package", "a=a", "--package-file", "a=a/silver.toml", "f.ag", "x"];
    assert(takeAfterFile(args) == ["x"] && args.length == 6);
    args = ["silverc", "--program", "app", "--", "-b", "x"];
    assert(takeAfterFile(args) == ["-b", "x"] && args == ["silverc", "--program", "app"]);
    args = ["silverc", "--program=app", "--"];
    assert(takeAfterFile(args) == [] && args == ["silverc", "--program=app"]);
    // The first `--` after the file is dropped, and only that one.
    args = ["silverc", "f.ag", "--", "x"];
    assert(takeAfterFile(args) == ["x"] && args == ["silverc", "f.ag"]);
    args = ["silverc", "f.ag", "--", "--", "x"];
    assert(takeAfterFile(args) == ["--", "x"]);
    args = ["silverc", "f.ag", "a", "--", "b"];
    assert(takeAfterFile(args) == ["a", "--", "b"]);
    args = ["silverc", "--program", "app", "--", "--"];
    assert(takeAfterFile(args) == ["--"]);
    // Where the file would be, `--` ends the options, so without --program there's no file.
    args = ["silverc", "-b", "llvm", "--", "f.ag", "x"];
    assert(takeAfterFile(args) == ["f.ag", "x"] && args == ["silverc", "-b", "llvm"]);
}

@("--package-file names a declared package and its file, and anything else is refused before loading")
unittest
{
    import std.algorithm : canFind;

    auto directory = testDirectory("package-file",["main.ag": "def main(): Unit {}"]);
    scope (exit) rmdirRecurse(directory);
    auto main = buildPath(directory, "main.ag");
    auto saved = stderr;
    stderr = File(buildPath(directory, "stderr.txt"), "w");
    scope (exit) stderr = saved;

    assert(run(["silverc", "run", "--package", "a=" ~ directory, "--package-file", "a=silver.toml", main]) == 0);
    assert(run(["silverc", "run", "--package", "a=" ~ directory, "--package-file", "a", main]) == 1);
    assert(run(["silverc", "run", "--package-file", "b=silver.toml", main]) == 1);
    stderr.close();
    auto written = readText(buildPath(directory, "stderr.txt"));
    assert(written.canFind("--package-file takes a package and the file") && written.canFind("'b', which no --package"),
        written);
}

@("--scripts-in gives a file with no module line what a package uses, and the package when it's a library")
unittest
{
    import std.algorithm : canFind;

    auto directory = testDirectory("scripts-in", [
        "geo/shapes.ag": "module geo.shapes\n\ndef sides(): Int => 4",
        "geo/demo.ag": "import geo.shapes\n\ndef main(): Unit {\n    printl(sides())\n}",
        "tool/main.ag": "module tool.main\n\ndef main(): Unit {}",
        "tool/try.ag": "import tool.main\n\ndef main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto geo = buildPath(directory, "geo");
    auto tool = buildPath(directory, "tool");
    auto saved = stderr;
    stderr = File(buildPath(directory, "stderr.txt"), "w");
    scope (exit) stderr = saved;

    auto packages = ["--package", "geo=" ~ geo, "--package", "tool=" ~ tool];
    assert(run(["silverc", "run"] ~ packages ~ ["--scripts-in", "geo=" ~ geo, buildPath(geo, "demo.ag")]) == 0);
    assert(run(["silverc", "run"] ~ packages ~ [buildPath(geo, "demo.ag")]) == 1);
    assert(run(["silverc", "run"] ~ packages ~ ["--scripts-in", "tool=" ~ tool, buildPath(tool, "try.ag")]) == 1);
    assert(run(["silverc", "run"] ~ packages ~ ["--scripts-in", "nope=" ~ geo, buildPath(geo, "demo.ag")]) == 1);
    stderr.close();
    auto written = readText(buildPath(directory, "stderr.txt"));
    assert(written.canFind("nothing can use a program, not even a file beside it"), written);
    assert(written.canFind("--scripts-in names 'nope', which no --package or --project declares"), written);
}

@("--from-silver makes the hints say what to write in a silver.toml, and without it they name the options")
unittest
{
    import std.algorithm : canFind;
    import std.regex : matchFirst, regex;

    auto directory = testDirectory("from-silver", [
        "app.ag": "import geometry.area\n\ndef main(): Unit {}",
        "lib/area.ag": "module lib.area\nimport units.length\n\ndef main(): Unit {}",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto app = buildPath(directory, "app.ag");
    // What a run writes to stderr and, since `test` reports there, stdout.
    string written(string[] args)
    {
        auto savedOut = stdout;
        auto savedErr = stderr;
        auto outPath = buildPath(directory, "stdout.txt");
        auto errPath = buildPath(directory, "stderr.txt");
        stdout = File(outPath, "w");
        stderr = File(errPath, "w");
        immutable status = run(args);
        stdout.close();
        stderr.close();
        stdout = savedOut;
        stderr = savedErr;
        assert(status == 1);
        return readText(errPath) ~ readText(outPath);
    }

    auto lone = written(["silverc", "run", "--from-silver", app]);
    assert(lone.canFind("A file in no project uses only the standard library. To use 'geometry', put a `silver.toml`"),
        lone);
    assert(lone.matchFirst(regex(`--[a-z]`)).empty, lone);
    auto tested = written(["silverc", "test", "--from-silver", directory]);
    assert(tested.canFind("To use 'geometry'") && tested.matchFirst(regex(`--[a-z]`)).empty, tested);
    auto byHand = written(["silverc", "run", app]);
    assert(byHand.canFind("Give `--package geometry=<directory>` to declare one"), byHand);
    auto module_ = written(["silverc", "run", "--from-silver", "--package", "lib=" ~ buildPath(directory, "lib"),
        buildPath(directory, "lib", "area.ag")]);
    assert(module_.canFind("'lib' is described in no `silver.toml`") && module_.matchFirst(regex(`--[a-z]`)).empty,
        module_);
}

@("--program runs a declared package's program in place of a file, and is refused with a file, for test, or undeclared")
unittest
{
    import std.algorithm : canFind;

    auto directory = testDirectory("program", [
        "app/main.ag": "module app.main\n\ndef main(): Unit {}",
        "geo/shapes.ag": "module geo.shapes\n\ndef sides(): Int => 4",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto app = buildPath(directory, "app");
    auto saved = stderr;
    stderr = File(buildPath(directory, "stderr.txt"), "w");
    scope (exit) stderr = saved;

    auto packages = ["--package", "app=" ~ app, "--package", "geo=" ~ buildPath(directory, "geo")];
    assert(run(["silverc", "run"] ~ packages ~ ["--program", "app"]) == 0);
    Toolchain toolchain;
    immutable compiles = findToolchain(toolchain) is null;
    if (compiles) assert(run(["silverc", "run", "-b", "llvm"] ~ packages ~ ["--program", "app"]) == 0);
    assert(run(["silverc", "run"] ~ packages ~ ["--program", "geo"]) == 1);
    assert(run(["silverc", "run"] ~ packages ~ ["--program", "nope"]) == 1);
    assert(run(["silverc", "run"] ~ packages ~ ["--program", "app", buildPath(app, "main.ag")]) == 1);
    assert(run(["silverc", "test"] ~ packages ~ ["--program", "app", app]) == 1);
    assert(run(["silverc", "run"] ~ packages ~ ["--program", "app", "--program", "geo"]) == 1);
    assert(run(["silverc", "build", "-o", directory] ~ packages ~ ["--program", "app"]) == 1);
    auto output = buildPath(directory, "built");
    if (compiles)
    {
        assert(run(["silverc", "build", "-o", executablePath(output)] ~ packages ~ ["--program", "app"]) == 0);
        assert(executablePath(output).exists);
    }
    stderr.close();
    auto written = readText(buildPath(directory, "stderr.txt"));
    assert(written.canFind("Error L0014: The package 'geo' is a library"), written);
    assert(written.canFind("--program names 'nope', which no --package or --project declares"), written);
    assert(written.canFind("--program says which package's program to run, so no file is given with it, and `"), written);
    assert(written.canFind("--program applies to `run` and `build`: `silverc test` is given"), written);
    assert(written.canFind("--program is given once, naming one package, and was given 2 times."), written);
    assert(written.canFind(", which is a directory: give the file to write."), written);
}

/// What's wrong with `command` (`run`, `build` or `test`), given `files`, which is what its options
/// left, and those options, or null. `format` is what `--format` gave, and `program` what `--program`
/// gave, or null without them. `bySilver` says whether `silver` is driving. `arguments` are what
/// follows the file, or `--` with `--program`, which only `run` takes.
string commandLineMistake(string command, const string[] files, string outputPath, bool optimize,
    Backend backend, const string[] filters = null, string format = null, const string[] skipped = null,
    string program = null, bool bySilver = false, const string[] also = null, const string[] arguments = null)
{
    immutable building = command == "build";
    immutable testing = command == "test";
    immutable help = bySilver ? "\nRun `silver --help` for its commands." : "\n" ~ usage ~ "\nRun `silverc --help` for the options.";
    if (program !is null && testing)
    {
        return "--program applies to `run` and `build`: `" ~ (bySilver ? "silver" : "silverc")
            ~ " test` is given a directory or a file.";
    }
    if (program !is null && files.length > 0)
    {
        return "--program says which package's program to " ~ command ~ ", so no file is given with it, and `"
            ~ files[0] ~ "` was." ~ (building ? "" : " The program's arguments follow `--`.");
    }
    if (program is null && files.length != 1)
    {
        // `-o f.ag` takes the file as its value.
        return (files.length == 0 && !outputPath.empty
            ? "-o needs a value, and took `" ~ outputPath ~ "`, which leaves no file to compile."
            : files.length == 0 && arguments.length > 0 ? "No file was given: `--` ends the options, and what follows it "
                ~ "is the program's, so the file goes before it."
            : files.length == 0 ? "No file was given."
            : "Too many arguments: `" ~ files[1] ~ "` follows `" ~ files[0] ~ "`.") ~ help;
    }
    if (arguments.length > 0 && building)
    {
        return "`" ~ arguments[0] ~ "` follows " ~ (program is null ? "`" ~ files[0] ~ "`" : "`--`") ~ ", and a "
            ~ "program is given its arguments when it's run, not when it's built."
            ~ (program is null ? " Options go before the file." : "") ~ help;
    }
    if (arguments.length > 0 && testing)
    {
        return "`" ~ arguments[0] ~ "` follows `" ~ files[0] ~ "`, and `test` takes one path. Options go before it."
            ~ help;
    }
    if (!outputPath.empty && !building)
    {
        return "-o applies to `silver build`, which is what writes a file.";
    }
    // The interpreter has nothing to optimize, and saying so beats ignoring the flag.
    if (optimize && !building && backend == Backend.interpreter)
    {
        return "-O applies to compiled programs: use it with `silver build`, or with `-b llvm`"
            ~ (testing ? " or `-b both`" : "");
    }
    if (filters.length > 0 && !testing)
    {
        return "--filter applies to `silver test`, which is what runs tests.";
    }
    foreach (filter; filters)
    {
        if (filter.empty) return "--filter needs part of a test's name: an empty one would select every test.";
    }
    if (skipped.length > 0 && !testing)
    {
        return "--skip applies to `silver test`, which is what runs the files of a directory.";
    }
    if (also.length > 0 && !testing)
    {
        return "--also applies to `silver test`, which is what runs the tests of several paths.";
    }
    if (format !is null && !testing)
    {
        return "--format applies to `silver test`, which is what writes a report.";
    }
    if (format !is null && format != "text" && format != "json")
    {
        return "`" ~ format ~ "` isn't a format for `silver test`: there's text, the default, and json.";
    }
    return null;
}

/// What's wrong with skipping each of `skipped` when testing `paths`, or null: each has to be a
/// directory strictly inside one of them, and can't be or hold any of them.
string skipMistake(const string[] paths, const string[] skipped)
{
    import std.algorithm : any, equal, filter;
    import std.array : join;
    import std.path : filenameCmp, pathSplitter;

    bool inside(string directory, string path)
    {
        auto inner = pathSplitter(buildNormalizedPath(absolutePath(directory))).array;
        auto outer = pathSplitter(buildNormalizedPath(absolutePath(path))).array;
        return inner.length > outer.length && inner[0 .. outer.length].equal!((a, b) => filenameCmp(a, b) == 0)(outer);
    }
    auto directories = paths.filter!(p => p.isDir).array;
    foreach (directory; skipped)
    {
        if (!directory.exists || !directory.isDir)
            return "--skip names " ~ directory ~ ", which isn't a directory.";
        if (directories.length == 0)
            return "--skip applies when a directory is tested, and " ~ paths[0] ~ " is a file.";
        if (!directories.any!(path => inside(directory, path)))
            return "--skip names " ~ directory ~ ", which isn't inside " ~ (directories.length == 1 ? directories[0]
                ~ ", the directory tested." : "any of the directories tested, " ~ directories.join(", ") ~ ".");
        foreach (path; paths)
        {
            immutable same = filenameCmp(buildNormalizedPath(absolutePath(path)),
                buildNormalizedPath(absolutePath(directory))) == 0;
            if (same || inside(path, directory))
                return "--skip names " ~ directory ~ ", which " ~ (same ? "is " : "holds ") ~ path ~ ", given to be "
                    ~ "tested, so the two disagree.";
        }
    }
    return null;
}

@("--skip leaves out a directory inside the one tested, and is refused for anything else")
unittest
{
    import std.algorithm : canFind;

    auto directory = testDirectory("skip", [
        "a.ag": "test \"a\" => expect(true)",
        "inner/b.ag": "test \"b\" => expect(false)",
        "inner/deeper/c.ag": "test \"c\" => expect(false)",
        "other/d.ag": "test \"d\" => expect(true)",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto inner = buildPath(directory, "inner");
    assert(skipMistake([directory], [inner]) is null);
    assert(skipMistake([directory], [buildPath(directory, "gone")]).canFind("isn't a directory"));
    assert(skipMistake([directory], [directory]).canFind("isn't inside"));
    assert(skipMistake([inner], [buildPath(directory, "other")]).canFind("isn't inside"));
    assert(skipMistake([buildPath(directory, "a.ag")], [inner]) == "--skip applies when a directory is tested, and "
        ~ buildPath(directory, "a.ag") ~ " is a file.");
    assert(commandLineMistake("run", ["a.ag"], "", false, Backend.interpreter, null, null, [inner])
        .canFind("--skip applies to `silver test`"));

    Packages packages;
    assert(describePackages(null, null, null, null, packages) is null);
    string report;
    assert(testReport([directory], packages, Backend.interpreter, Optimization.none, null, TestFormat.text, report,
        [inner]) == 0);
    assert(report == "2 passed, 0 failed\n", report);
    assert(testReport([directory], packages, Backend.interpreter, Optimization.none, null, TestFormat.text, report) == 1);
}

@("--also tests more paths in the same run: one report and one summary, with --filter and --skip across all")
unittest
{
    import std.algorithm : canFind, count, endsWith;
    import std.array : replace;
    import std.json : parseJSON;

    auto directory = testDirectory("also", [
        "a/one.ag": "test \"one\" => expect(true)\ntest \"one fails\" => expect(false)",
        "a/inner/two.ag": "test \"two\" => expect(true)",
        "b/three.ag": "test \"three\" => expect(true)",
        "b/left/four.ag": "test \"four\" => expect(false)",
        "c.ag": "test \"five\" => expect(true)",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto a = buildPath(directory, "a");
    auto b = buildPath(directory, "b");
    auto c = buildPath(directory, "c.ag");
    // What a run writes to stdout, with its status, and what it writes to stderr.
    string written(string[] args, out int status, out string errors)
    {
        auto savedOut = stdout;
        auto savedErr = stderr;
        auto outPath = buildPath(directory, "stdout.txt");
        auto errPath = buildPath(directory, "stderr.txt");
        stdout = File(outPath, "w");
        stderr = File(errPath, "w");
        status = run(args);
        stdout.close();
        stderr.close();
        stdout = savedOut;
        stderr = savedErr;
        errors = readText(errPath);
        return readText(outPath).replace("\r\n", "\n");
    }

    int status;
    string errors;
    auto text = written(["silverc", "test", "--also", b, "--also", c, a], status, errors);
    assert(status == 1 && text.count("passed") == 1, text);
    assert(text.canFind("FAIL \"one fails\"") && text.canFind("FAIL \"four\"") && text.endsWith("4 passed, 2 failed\n"),
        text);
    text = written(["silverc", "test", "--also", b, "--skip", buildPath(b, "left"), a], status, errors);
    assert(status == 1 && text.endsWith("3 passed, 1 failed\n"), text);
    text = written(["silverc", "test", "--also", b, "--skip", buildPath(b, "left"), "--filter", "t", a], status, errors);
    assert(status == 0 && text == "2 passed, 0 failed, 2 filtered out\n", text);
    // A path given twice, or one inside another, runs its files once.
    text = written(["silverc", "test", "--also", buildPath(a, "inner"), "--also", a, a], status, errors);
    assert(text.endsWith("2 passed, 1 failed\n"), text);

    Toolchain toolchain;
    immutable compiles = findToolchain(toolchain) is null;
    foreach (backend; compiles ? ["interpreter", "llvm", "both"] : ["interpreter"])
    {
        text = written(["silverc", "test", "-b", backend, "--format", "json", "--also", b, "--skip", buildPath(b, "left"),
            "--also", c, a], status, errors);
        auto json = parseJSON(text);
        assert(status == 1 && json["summary"]["passed"].integer == 4 && json["summary"]["failed"].integer == 1, text);
        string[] files;
        foreach (file; json["files"].array) files ~= file["file"].str;
        assert(files == [buildPath(a, "inner", "two.ag"), buildPath(a, "one.ag"), buildPath(b, "three.ag"), c], text);
    }

    assert(written(["silverc", "test", "--also", buildPath(directory, "gone"), a], status, errors) == "" && status == 1);
    assert(errors.canFind("doesn't exist"), errors);
    written(["silverc", "test", "--also", b, "--skip", buildPath(b, "left"), c], status, errors);
    assert(status == 0, errors);
    written(["silverc", "test", "--also", c, "--skip", buildPath(directory), a], status, errors);
    assert(status == 1 && errors.canFind("isn't inside " ~ a ~ ", the directory tested."), errors);
    written(["silverc", "test", "--also", buildPath(a, "inner"), "--skip", buildPath(a, "inner"), a], status, errors);
    assert(status == 1 && errors.canFind("--skip names " ~ buildPath(a, "inner") ~ ", which is " ~ buildPath(a, "inner")
        ~ ", given to be tested, so the two disagree."), errors);
    written(["silverc", "test", "--also", buildPath(a, "inner"), "--skip", buildPath(directory, "a"), directory], status,
        errors);
    assert(status == 1 && errors.canFind("which holds " ~ a), errors);
    written(["silverc", "run", "--also", b, c], status, errors);
    assert(status == 1 && errors.canFind("--also applies to `silver test`"), errors);
}

@("a command with no file left is missing its file, whatever options it was given")
unittest
{
    import std.algorithm : canFind, endsWith;

    assert(commandLineMistake("build", [], "", false, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake("test", [], "", false, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake("build", [], "hello.ag", false, Backend.interpreter).canFind("-o needs a value"));
    assert(commandLineMistake("build", [], "", true, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake("run", [], "", false, Backend.interpreter).canFind("No file was given"));
    assert(commandLineMistake("run", ["a.ag", "b.ag"], "", false, Backend.interpreter).canFind("Too many"));
    assert(commandLineMistake("build", ["a.ag", "b.ag"], "", false, Backend.interpreter).canFind("Too many"));
    auto fromSilver = commandLineMistake("run", ["a.ag", "b.ag"], "", false, Backend.interpreter, null, null, null, null,
        true);
    assert(fromSilver.endsWith("\nRun `silver --help` for its commands.") && !fromSilver.canFind("silverc"), fromSilver);
    assert(commandLineMistake("build", ["a.ag"], "out", true, Backend.interpreter) is null);
    assert(commandLineMistake("run", ["a.ag"], "out", false, Backend.interpreter).canFind("applies to `silver build`"));
    assert(commandLineMistake("run", ["a.ag"], "", true, Backend.interpreter).canFind("compiled programs"));
    assert(commandLineMistake("run", ["a.ag"], "", true, Backend.llvm) is null);
    assert(commandLineMistake("test", ["a"], "", true, Backend.interpreter).canFind("-b both"));
}

@("only run takes the program's arguments: build and test refuse what follows the file")
unittest
{
    import std.algorithm : canFind;

    assert(commandLineMistake("run", ["a.ag"], "", false, Backend.interpreter, null, null, null, null, false, null,
        ["x", "-b"]) is null);
    assert(commandLineMistake("run", [], "", false, Backend.interpreter, null, null, null, "app", false, null, ["x"])
        is null);
    auto built = commandLineMistake("build", ["a.ag"], "", false, Backend.interpreter, null, null, null, null, false,
        null, ["x"]);
    assert(built.canFind("`x` follows `a.ag`, and a program is given its arguments when it's run"), built);
    assert(commandLineMistake("build", [], "", false, Backend.interpreter, null, null, null, "app", false, null, ["x"])
        .canFind("`x` follows `--`"));
    assert(commandLineMistake("test", ["dir"], "", false, Backend.interpreter, null, null, null, null, false, null, ["x"])
        .canFind("`x` follows `dir`, and `test` takes one path"));
    assert(commandLineMistake("run", ["a"], "", false, Backend.interpreter, null, null, null, "app")
        .canFind("The program's arguments follow `--`."));
}

@("arguments too long for the system to start the compiled program with are reported, not thrown")
unittest
{
    import std.array : replicate;

    Toolchain toolchain;
    if (findToolchain(toolchain) !is null) return;
    auto directory = testDirectory("arguments-too-long", ["show.ag": "def main(args: [String]): Unit {\n    printl(length(args))\n}"]);
    scope (exit) rmdirRecurse(directory);
    auto savedErr = stderr;
    auto errPath = buildPath(directory, "stderr.txt");
    stderr = File(errPath, "w");
    scope (exit) stderr = savedErr;
    // Longer than a Windows command line (32,767 characters) and than one argument on Linux (131,072 bytes).
    int status;
    try status = run(["silverc", "-b", "llvm", buildPath(directory, "show.ag"), "a".replicate(200_000)]);
    catch (Exception e) assert(0, "a D exception reached the user: " ~ e.msg);
    stderr.close();
    // Where the system takes them, the program runs; where it doesn't, that's said and the status is 1.
    assert(status == 0 || (status == 1 && readText(errPath).length > 0));
}

@("a program is given what follows its file, or `--` after --program, on both backends, and refuses an argument that isn't UTF-8")
unittest
{
    import std.algorithm : canFind;
    import std.array : replace;

    auto directory = testDirectory("arguments", [
        "show.ag": "def main(args: [String]): Unit {\n    printl(args)\n}",
        "app/main.ag": "module app.main\n\ndef main(args: [String]): Unit {\n    printl(args)\n}",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto show = buildPath(directory, "show.ag");
    string written(string[] args, out int status, out string errors)
    {
        auto savedOut = stdout;
        auto savedErr = stderr;
        auto outPath = buildPath(directory, "stdout.txt");
        auto errPath = buildPath(directory, "stderr.txt");
        stdout = File(outPath, "w");
        stderr = File(errPath, "w");
        status = run(args);
        stdout.close();
        stderr.close();
        stdout = savedOut;
        stderr = savedErr;
        errors = readText(errPath);
        return readText(outPath).replace("\r\n", "\n");
    }

    Toolchain toolchain;
    immutable compiles = findToolchain(toolchain) is null;
    foreach (backend; compiles ? ["interpreter", "llvm"] : ["interpreter"])
    {
        int status;
        string errors;
        auto text = written(["silverc", "-b", backend, show, "-b", "llvm", "", "a b"], status, errors);
        assert(status == 0 && text == "[-b, llvm, , a b]\n", text ~ errors);
        text = written(["silverc", "run", "-b", backend, "--package", "app=" ~ buildPath(directory, "app"), "--program",
            "app", "--", "x", "--", "y"], status, errors);
        assert(status == 0 && text == "[x, --, y]\n", text ~ errors);
        text = written(["silverc", "-b", backend, show, "ok", "b\xff"], status, errors);
        assert(status == 1 && text == "" && errors.canFind(`error: argument 2 isn't UTF-8: b\xFF`), text ~ errors);
    }
}

@("an unwritable path is reported, not thrown")
unittest
{
    assert(!writeFile(buildPath(tempDir, "silver-no-such-directory", "x.ll"), "x"));
}

@("--filter and --format are for silver test, and take a name and a known format")
unittest
{
    import std.algorithm : canFind;

    assert(commandLineMistake("test", ["a.ag"], "", false, Backend.interpreter, ["x", "y"], "json") is null);
    assert(commandLineMistake("test", ["a.ag"], "", false, Backend.interpreter, null, "text") is null);
    assert(commandLineMistake("run", ["a.ag"], "", false, Backend.interpreter, ["x"]).canFind("--filter applies"));
    assert(commandLineMistake("build", ["a.ag"], "", false, Backend.interpreter, null, "json").canFind("--format applies"));
    assert(commandLineMistake("test", ["a.ag"], "", false, Backend.interpreter, ["x", ""]).canFind("empty one"));
    assert(commandLineMistake("test", ["a.ag"], "", false, Backend.interpreter, null, "xml").canFind("there's text, the default, and json"));
}

version (unittest)
{
    /// A fresh directory under the temp dir holding `files` (name to text). The caller removes it.
    private string testDirectory(string name, string[string] files)
    {
        import std.uuid : randomUUID;
        auto directory = buildPath(tempDir, "silver-driver-" ~ name ~ "-" ~ randomUUID().toString());
        mkdirRecurse(directory);
        foreach (file, text; files)
        {
            mkdirRecurse(dirName(buildPath(directory, file)));
            std.file.write(buildPath(directory, file), text);
        }
        return directory;
    }

    /// What `silver test` reports for `path` with `filters` in `format` on `backend`, with each
    /// location relative to `path` or the directory it is in, and its exit status in `status`. False
    /// without running when a compiled backend has no toolchain.
    private bool tested(string path, Backend backend, const string[] filters, TestFormat format,
        out string report, out int status)
    {
        import std.array : replace;

        Toolchain toolchain;
        if (backend != Backend.interpreter && findToolchain(toolchain) !is null) return false;
        Packages packages;
        assert(describePackages(null, null, null, null, packages) is null);
        status = testReport([path], packages, backend, Optimization.none, filters, format, report);
        auto prefix = (path.isDir ? path : path.dirName) ~ dirSeparator;
        report = report.replace(format == TestFormat.json ? prefix.replace(`\`, `\\`) : prefix, "");
        return true;
    }

    private immutable filterFixture = [
        "shape.ag": "def area(n: Int): Int => n * n\ntest \"area of one\" => expect(area(1) == 1)\n"
            ~ "test \"area of two\" => expect(area(2) == 5)\ntest \"Area of three\" => expect(area(3) == 9)",
        "shape.test.ag": "test \"area from the companion\" => expect(area(4) == 16)",
        "other.ag": "test \"other\" => expect(true)",
    ];
}

@("--filter runs the tests whose name contains any filter, case-sensitively, across a directory and its companions, on every backend")
unittest
{
    auto directory = testDirectory("filter", filterFixture.dup);
    scope (exit) rmdirRecurse(directory);

    foreach (backend; [Backend.interpreter, Backend.llvm, Backend.both])
    {
        string report;
        int status;
        if (!tested(buildPath(directory, "shape.ag"), backend, ["area of"], TestFormat.text, report, status)) continue;
        assert(report == "FAIL \"area of two\" at shape.ag(3,6)\n    shape.ag(3,23): Expectation failed: area(2) == 5\n"
            ~ "        left: 4\n        right: 5\n1 passed, 1 failed, 2 filtered out\n", report);
        assert(status == 1);

        assert(tested(directory, backend, ["one", "companion", "other"], TestFormat.text, report, status));
        assert(report == "3 passed, 0 failed, 2 filtered out\n", report);
        assert(status == 0);

        assert(tested(directory, backend, ["area of one", "Other"], TestFormat.text, report, status));
        assert(report == "1 passed, 0 failed, 4 filtered out\n", report);

        assert(tested(directory, backend, ["nothing"], TestFormat.text, report, status));
        assert(report == "No tests match the filter\n" && status == 1, report);
    }
}

@("--format json reports every test and the summary as one document, alike on every backend")
unittest
{
    import std.algorithm : canFind;
    import std.array : replace;

    auto directory = testDirectory("json", filterFixture.dup);
    scope (exit) rmdirRecurse(directory);
    auto expected = `{
  "version": 1,
  "backend": "BACKEND",
  "files": [
    {
      "file": "shape.ag",
      "problem": null,
      "diagnostics": []
    }
  ],
  "tests": [
    {
      "name": "area of two",
      "file": "shape.ag",
      "line": 3,
      "column": 6,
      "status": "failed",
      "failures": [
        {
          "kind": "expectation",
          "file": "shape.ag",
          "line": 3,
          "column": 23,
          "text": "Expectation failed: area(2) == 5\n    left: 4\n    right: 5",
          "message": null,
          "source": "area(2) == 5",
          "left": "4",
          "right": "5"
        }
      ],
      "output": ""
    },
    {
      "name": "area from the companion",
      "file": "shape.test.ag",
      "line": 1,
      "column": 6,
      "status": "passed",
      "failures": [],
      "output": ""
    }
  ],
  "summary": {
    "tests": 2,
    "passed": 1,
    "failed": 1,
    "panicked": 0,
    "filteredOut": 2,
    "filesNotRun": 0,
    "succeeded": false
  }
}
`;
    foreach (backend; [Backend.interpreter, Backend.llvm, Backend.both])
    {
        string report;
        int status;
        if (!tested(buildPath(directory, "shape.ag"), backend, ["two", "companion"], TestFormat.json, report, status)) continue;
        auto name = backend == Backend.interpreter ? "interpreter" : backend == Backend.llvm ? "llvm" : "both";
        assert(report == expected.replace("BACKEND", name), report);
        assert(status == 1);

        assert(tested(directory, backend, ["nothing"], TestFormat.json, report, status));
        assert(report.canFind(`"tests": []`) && report.canFind(`"filteredOut": 5`) && report.canFind(`"succeeded": false`));
        assert(status == 1);
    }

    string report;
    int status;
    std.file.write(buildPath(directory, "broken.ag"), "test \"t\" => expect(missing)");
    assert(tested(directory, Backend.interpreter, null, TestFormat.json, report, status));
    assert(report.canFind(`"file": "broken.ag",
      "problem": "it has errors",
      "diagnostics": [
        "broken.ag(1,20): Error S0002: Unknown name 'missing'`), report);
    assert(report.canFind(`"filesNotRun": 1`) && status == 1);
}

/// The command line as it was given. On Windows druntime turns an unpaired surrogate into U+FFFD, which
/// would hand a program a different argument, so the command line is read again and such an argument
/// written as WTF-8, which isn't UTF-8 and is refused. The front end keeps a copy
/// (`exactArguments` in frontend/source/silver/frontend/package.d).
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
    import silver.interpreter : argumentsMistake;

    assert(wtf8("héllo 😀"w) == "héllo 😀");
    wchar[] lone = ['a', cast(wchar) 0xD800, 'b'];
    assert(wtf8(lone) == "a\xed\xa0\x80b");
    assert(argumentsMistake(["x", wtf8(lone)]) == `argument 2 isn't UTF-8: a\u{D800}b`);
    wchar[] reversed = [cast(wchar) 0xDC00, cast(wchar) 0xD800];
    assert(argumentsMistake([wtf8(reversed)]) == `argument 1 isn't UTF-8: \u{DC00}\u{D800}`);
}

/// Runs the driver with the command line `args`, returning the exit status.
int run(string[] args)
{
    import std.algorithm : canFind;
    import std.array : split;

    string[] packageOptions;
    string[] usesOptions;
    string[] projectOptions;
    string[] packageFileOptions;
    string[] scriptsInOptions;
    string[] nativeLinks;
    string[] nativeLoads;
    string[] skipped;
    string[] also;
    string[] programs;
    bool fromSilver;
    string outputPath;
    bool emitLlvm;
    bool emitCore;
    bool showVersion;
    Backend backend;
    bool optimize;
    string[] filters;
    string format;
    GetoptResult arguments;
    immutable command = takeCommand(args);
    auto afterFile = takeAfterFile(args);
    // Only the program's arguments are checked when it starts: a path that isn't UTF-8 is a path
    // elsewhere, but on Windows it can't be one, and std.file would throw.
    version (Windows)
    {
        import silver.interpreter : argumentsMistake;

        if (argumentsMistake(args) !is null)
        {
            stderr.writeln("A word given to silverc before the program's arguments isn't UTF-8.");
            return 1;
        }
    }
    if (auto mistake = takeOptimization(args, optimize))
    {
        stderr.writeln(mistake, "\nRun `silverc --help` for the options.");
        return 1;
    }
    try
    {
        arguments = getopt(
    args,
    config.caseSensitive,
    // An option that takes a value is in `optionsWithValues` too.
    "package", "a package, as name=directory: the module name.a.b is directory/a/b.ag", &packageOptions,
    "uses", "what a package uses, as name=package,package, or for a file with no module line, package,package",
        &usesOptions,
    "project", "the packages a package describes, which with it are one project, as name=package,package; with no"
        ~ " --package for name, it has no modules of its own", &projectOptions,
    "package-file", "the package file a package was described in, as name=file, which messages then name instead of"
        ~ " these options; silver gives it", &packageFileOptions,
    "scripts-in", "a directory whose files with no module line are beside a package, as name=directory: such a file"
        ~ " uses what the package uses, and the package too unless it's a program; silver gives it", &scriptsInOptions,
    "program", "run, build: in place of a file, a package whose program to start from: the package's own, or the one"
        ~ " of the packages it describes that's a program; silver gives it when no file is named", &programs,
    "native-link", "the file a compiled program is linked against for a native library that a package's modules name,"
        ~ " as package:library=file, in place of finding the library by its name; silver gives it from silver.toml",
        &nativeLinks,
    "native-load", "the shared library to load for a native library that a package's modules name, as"
        ~ " package:library=file: interpreting loads it, a built program has it copied beside it, and a compiled program"
        ~ " run from here finds it; silver gives it from silver.toml", &nativeLoads,
    "from-silver", "silver gives it, so that messages say what a user of silver can do rather than naming these"
        ~ " options", &fromSilver,
    "backend|b", "run, test: how to run the program: interpreter (default), llvm, or for tests, both", &backend,
    "output|o", "build: where to write the executable (or the IR, with --emit-llvm)", &outputPath,
    "optimize|O", "build, and run or test with -b llvm: have clang optimize the compiled program."
        ~ " -O2 is the same, and -O0 is the default, no optimization", &optimize,
    "emit-llvm", "build: write LLVM IR instead of an executable, optimized with -O", &emitLlvm,
    "version", "print silverc's version and stop", &showVersion,
    "emit-core", "print the Core the program lowers to instead of running it", &emitCore,
    "filter", "test: run only the tests whose name contains this, case-sensitively; given more than once,"
        ~ " those matching any of them", &filters,
    "format", "test: how to report: text (default), or json, one JSON document on stdout", &format,
    "skip", "test: a directory inside one tested whose files aren't run, given once for each; silver gives it"
        ~ " for another project there, and for a package a silver.toml names but doesn't test", &skipped,
    "also", "test: another file or directory whose tests are run and reported with the path's, in one report, given"
        ~ " once for each; silver gives it for a project outside the directory tested that a silver.toml opts in",
        &also,
    );
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg, "\nRun `silverc --help` for the options.");
        return 1;
    }
    if (arguments.helpWanted)
    {
        defaultGetoptPrinter("The Silver interpreter and compiler.\n" ~ usage, arguments.options);
        return 0;
    }
    if (showVersion)
    {
        writeln("silverc ", versionText);
        return 0;
    }
    if (programs.length > 1)
    {
        stderr.writeln("--program is given once, naming one package, and was given ", programs.length, " times.");
        return 1;
    }
    immutable program = programs.length == 0 ? null : programs[0];
    if (auto mistake = commandLineMistake(command, args[1 .. $], outputPath, optimize, backend, filters, format,
        skipped, program, packageFileOptions.length > 0 || fromSilver, also, afterFile))
    {
        stderr.writeln(mistake);
        return 1;
    }
    Packages packages;
    auto mistake = describePackages(packageOptions, usesOptions, projectOptions, null, packages);
    if (mistake is null && fromSilver) describeSilver(packages);
    if (mistake is null) mistake = describePackageFiles(packageFileOptions, packages);
    if (mistake is null) mistake = describeScriptHomes(scriptsInOptions, null, packages);
    if (mistake is null) mistake = describeNativeFiles(nativeLinks, nativeLoads, packages);
    if (mistake is null && program !is null && !packages.declared.canFind!(p => p.name == program))
        mistake = undeclared("--program", program);
    if (mistake !is null)
    {
        stderr.writeln(mistake, "\nRun `silverc --help` for the options.");
        return 1;
    }
    if (auto missing = missingStandardLibrary())
    {
        stderr.writeln(missing);
        return 1;
    }
    immutable building = command == "build";
    immutable testing = command == "test";
    immutable optimization = optimize ? Optimization.full : Optimization.none;

    string programFile;
    string outputName;
    if (program !is null)
    {
        auto context = new SourceContext();
        string chosen;
        programFile = programStart(program, command, packages, context, chosen);
        printDiagnostics(context);
        if (programFile is null || context.collector.hasErrors) return 1;
        outputName = chosen.split(".")[$ - 1];
    }
    else programFile = args[$ - 1];
    if (testing)
    {
        auto paths = programFile ~ also;
        foreach (path; paths)
        {
            if (!path.exists)
            {
                stderr.writefln("'%s' doesn't exist!", path);
                return 1;
            }
        }
        if (auto refused = skipMistake(paths, skipped))
        {
            stderr.writeln(refused);
            return 1;
        }
        return test(paths, packages, backend, optimization, filters,
            format == "json" ? TestFormat.json : TestFormat.text, skipped);
    }
	if(!programFile.exists || !programFile.isFile)
	{
		stderr.writefln("'%s' is not a file!", programFile);
		return 1;
	}

    if (building)
    {
        return build(programFile, packages, outputPath, emitLlvm, optimization, outputName);
    }
    final switch (backend)
    {
        case Backend.interpreter: return interpret(programFile, packages, emitCore, afterFile);
        case Backend.llvm: return compileAndRun(programFile, packages, optimization, afterFile);
        case Backend.both:
            stderr.writeln("Only `silver test` runs a program both ways");
            return 1;
    }
}

@("--program for a package whose directory isn't there says so, and doesn't call the package a library")
unittest
{
    import std.algorithm : canFind;

    auto directory = testDirectory("program-missing", ["app/main.ag": "module app.main\n\ndef main(): Unit {}"]);
    scope (exit) rmdirRecurse(directory);
    auto saved = stderr;
    stderr = File(buildPath(directory, "stderr.txt"), "w");
    scope (exit) stderr = saved;

    assert(run(["silverc", "run", "--package", "app=" ~ buildPath(directory, "nope"), "--program", "app"]) == 1);
    stderr.close();
    auto written = readText(buildPath(directory, "stderr.txt"));
    assert(!written.canFind("is a library"), written);
    assert(written.canFind("Error L0013: The package 'app' is at ") && written.canFind(", which isn't a directory"),
        written);
}
