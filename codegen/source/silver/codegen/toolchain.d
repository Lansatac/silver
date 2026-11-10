module silver.codegen.toolchain;

import std.algorithm : map, maxElement, sort;
import std.array : array;
import std.conv : to;
import std.file : dirEntries, exists, mkdirRecurse, remove, rename, SpanMode, timeLastModified;
import std.path : buildNormalizedPath, buildPath, dirName, setExtension;
import std.process : environment, execute, ProcessException, thisProcessID;

/// The D runtime linked into every compiled program. Like `standardLibraryPath()`, it's
/// stubbed to the repository until there's an install layout.
string runtimePath()
{
    return buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..", "runtime");
}

/// The external tools that turn IR into an executable: clang compiles the IR to an object
/// file, and dmd builds the runtime and links, which brings in druntime and Phobos.
struct Toolchain
{
    string clang;
    string dmd;
}

/// Finds clang (`$SILVER_CLANG`, else `clang` on the PATH) and dmd (`$SILVER_DMD`, else
/// `dmd`). Returns what's missing, or null if both were found.
string findToolchain(out Toolchain toolchain)
{
    toolchain.clang = findTool("SILVER_CLANG", "clang");
    toolchain.dmd = findTool("SILVER_DMD", "dmd");
    if (toolchain.clang is null)
    {
        return "clang wasn't found. Install LLVM, or set SILVER_CLANG to clang's path.";
    }
    if (toolchain.dmd is null)
    {
        return "dmd wasn't found. Install it, or set SILVER_DMD to its path.";
    }
    return null;
}

private string findTool(string variable, string fallback)
{
    auto tool = environment.get(variable, fallback);
    try
    {
        return execute([tool, "--version"]).status == 0 ? tool : null;
    }
    catch (ProcessException)
    {
        return null;
    }
}

/// `path` with the platform's executable extension.
string executablePath(string path)
{
    version (Windows) return path.setExtension("exe");
    else return path;
}

private string objectPath(string path)
{
    version (Windows) return path.setExtension("obj");
    else return path.setExtension("o");
}

struct LinkResult
{
    bool succeeded;
    /// The failing tool's combined stdout and stderr.
    string output;
}

/// Compiles the IR at `irPath` and links it with the runtime and `libraries`, which are named as
/// `native library` names them, into the executable `outputPath`. `extraFlags` go to clang's
/// compile step, e.g. `-O2`.
LinkResult linkExecutable(const Toolchain toolchain, string irPath, string outputPath, const string[] libraries = [],
    string[] extraFlags = [])
{
    BuiltRuntime runtime;
    if (auto failure = buildRuntime(toolchain, runtime))
    {
        return LinkResult(false, failure);
    }

    auto objPath = objectPath(outputPath);
    scope (exit) if (exists(objPath)) remove(objPath);
    // The IR has no target triple, so clang uses the host's; it warns about that otherwise.
    auto compiled = execute([toolchain.clang, "-c", "-Wno-override-module"] ~ extraFlags
        ~ ["-o", objPath, irPath]);
    if (compiled.status != 0)
    {
        return LinkResult(false, compiled.output);
    }

    auto linked = execute(linkCommand(toolchain, objPath, runtime, libraries, outputPath));
    return LinkResult(linked.status == 0, linked.output);
}

/// The dmd command that links `objPath` with the runtime and `libraries` into `outputPath`.
string[] linkCommand(const Toolchain toolchain, string objPath, const BuiltRuntime runtime, const string[] libraries,
    string outputPath)
{
    import std.algorithm : map;
    import std.array : array;

    // dmd hands a `.lib` argument to link.exe as it is, and `-L` flags to the Unix linker.
    version (Windows) auto linked = libraries.map!(l => l ~ ".lib").array;
    else auto linked = libraries.map!(l => "-L-l" ~ l).array;
    return [toolchain.dmd, objPath, runtime.entryObject, runtime.library] ~ linked ~ ["-of=" ~ outputPath];
}

/// The compiled runtime, under `runtimePath()/build`.
struct BuiltRuntime
{
    /// Every runtime module except the entry module.
    string library;
    /// The entry module, which defines `main`. It's linked as an object file because link.exe
    /// looks for the entry point only in objects, not in a library nothing references.
    string entryObject;
}

/// Builds the runtime unless it's newer than every runtime source. Returns why the build
/// failed, or null with `runtime` set.
string buildRuntime(const Toolchain toolchain, out BuiltRuntime runtime)
{
    import std.algorithm : filter;

    auto sourceDirectory = buildPath(runtimePath, "source");
    auto sources = dirEntries(sourceDirectory, "*.d", SpanMode.depth).map!(e => e.name).array.sort.release;
    auto entrySource = buildPath(sourceDirectory, "silver", "runtime", "entry.d");
    auto librarySources = sources.filter!(s => buildNormalizedPath(s) != buildNormalizedPath(entrySource)).array;
    version (Windows)
    {
        enum libraryName = "silver_rt.lib";
        enum entryName = "entry.obj";
    }
    else
    {
        enum libraryName = "libsilver_rt.a";
        enum entryName = "entry.o";
    }
    auto buildDirectory = buildPath(runtimePath, "build");
    runtime = BuiltRuntime(buildPath(buildDirectory, libraryName), buildPath(buildDirectory, entryName));

    // Tests link programs from several threads, and several test processes can run at once.
    synchronized
    {
        auto newestSource = sources.map!(s => timeLastModified(s)).maxElement;
        bool upToDate(string output) => exists(output) && timeLastModified(output) >= newestSource;
        if (upToDate(runtime.library) && upToDate(runtime.entryObject))
        {
            return null;
        }

        mkdirRecurse(buildDirectory);
        auto include = "-I" ~ sourceDirectory;
        if (auto failure = runDmd(toolchain, runtime.library, ["-lib", include] ~ librarySources))
        {
            return failure;
        }
        return runDmd(toolchain, runtime.entryObject, ["-c", include, entrySource]);
    }
}

/// Runs dmd with `args` to produce `output`. It's built under a name of its own and renamed
/// into place, so another process never links a half-written file.
private string runDmd(const Toolchain toolchain, string output, string[] args)
{
    auto partial = output ~ "." ~ thisProcessID.to!string;
    auto built = execute([toolchain.dmd] ~ args ~ ["-of=" ~ partial]);
    if (built.status != 0)
    {
        return "building the runtime failed:\n" ~ built.output;
    }
    rename(partial, output);
    return null;
}

@("runtimePath is the repository's runtime directory")
unittest
{
    import std.path : baseName;

    assert(runtimePath.baseName == "runtime");
    assert(exists(buildPath(dirName(runtimePath), "dub.json")));
}

@("a program linked with the runtime runs its silver_main and can print")
unittest
{
    import std.file : rmdirRecurse, tempDir, write;
    import std.stdio : writeln;
    import std.string : replace;
    import std.uuid : randomUUID;

    Toolchain toolchain;
    if (auto missing = findToolchain(toolchain))
    {
        writeln("    note: ", missing, " The runtime link test was skipped.");
        return;
    }

    auto directory = buildPath(tempDir, "silver-toolchain-" ~ randomUUID().toString());
    mkdirRecurse(directory);
    scope (exit) rmdirRecurse(directory);
    auto irPath = buildPath(directory, "main.ll");
    auto exePath = executablePath(buildPath(directory, "main"));
    write(irPath, `
        @.str = private unnamed_addr constant [2 x i8] c"hi"
        declare void @silver_printl_int(i64)
        declare void @silver_printl_float(double)
        declare void @silver_printl_bool(i1 zeroext)
        declare void @silver_print_string(ptr, i64)
        declare void @silver_printl_unit()
        declare ptr @silver_alloc(i64)

        define void @silver_main() {
        entry:
          %p = call ptr @silver_alloc(i64 8)
          store i64 42, ptr %p
          %n = load i64, ptr %p
          call void @silver_printl_int(i64 %n)
          call void @silver_printl_float(double 2.5)
          call void @silver_printl_bool(i1 zeroext false)
          call void @silver_print_string(ptr @.str, i64 2)
          call void @silver_printl_unit()
          ret void
        }
    `);

    auto linked = linkExecutable(toolchain, irPath, exePath);
    assert(linked.succeeded, linked.output);
    auto run = execute([exePath]);
    assert(run.status == 0, run.output);
    // The runtime writes the platform's newline.
    assert(run.output.replace("\r\n", "\n") == "42\n2.5\nfalse\nhi()\n", run.output);
}

@("the link command names each native library the way the platform's linker takes it")
unittest
{
    auto runtime = BuiltRuntime("rt.a", "entry.o");
    auto command = linkCommand(Toolchain("clang", "dmd"), "main.o", runtime, ["SDL2", "m"], "main");
    version (Windows) auto expected = ["SDL2.lib", "m.lib"];
    else auto expected = ["-L-lSDL2", "-L-lm"];
    assert(command == ["dmd", "main.o", "entry.o", "rt.a"] ~ expected ~ ["-of=main"], command.to!string);
}
