module silver.codegen.toolchain;

import std.conv : to;
import std.file : exists, remove;
import std.path : buildPath, dirName, setExtension;
import std.process : environment, execute, ProcessException;

/// The D runtime linked into every compiled program: `runtime` beside the executable, where the
/// compiler's build puts it in both modes. The test executables are built beside it too.
string runtimePath()
{
    import std.file : thisExePath;

    return buildPath(thisExePath.dirName, "runtime");
}

/// The external tools that turn IR into an executable: clang compiles the IR to an object
/// file, and dmd links, which brings in druntime and Phobos.
struct Toolchain
{
    string clang;
    string dmd;
    /// Whether dmd's C compiler should link with lld, which links Phobos statically many
    /// times faster than GNU ld. Only looked for off Windows, where dmd uses its own linker.
    bool lld;
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
    version (Windows) {}
    else toolchain.lld = findTool("SILVER_LLD", "ld.lld") !is null;
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

/// How far clang optimizes the generated module. The IR is the same either way, and so is what
/// the program does: every check is in the IR, and no flag here lets clang assume one away.
enum Optimization
{
    none,
    full,
}

private string[] optimizationFlags(Optimization optimization)
{
    return optimization == Optimization.full ? ["-O2"] : [];
}

/// Writes the IR at `irPath` to `outputPath` as clang optimizes it.
LinkResult optimizeIr(const Toolchain toolchain, string irPath, string outputPath)
{
    auto optimized = execute([toolchain.clang, "-S", "-emit-llvm", "-Wno-override-module"]
        ~ optimizationFlags(Optimization.full) ~ ["-o", outputPath, irPath]);
    return LinkResult(optimized.status == 0, optimized.output);
}

/// Compiles the IR at `irPath` and links it with the runtime and `libraries`, which are named as
/// `native library` names them, into the executable `outputPath`.
LinkResult linkExecutable(const Toolchain toolchain, string irPath, string outputPath, const string[] libraries = [],
    Optimization optimization = Optimization.none)
{
    string runtime;
    if (auto missing = findRuntime(runtime, optimization))
    {
        return LinkResult(false, missing);
    }

    auto objPath = objectPath(outputPath);
    scope (exit) if (exists(objPath)) remove(objPath);
    // The IR has no target triple, so clang uses the host's; it warns about that otherwise.
    auto compiled = execute([toolchain.clang, "-c", "-Wno-override-module"] ~ optimizationFlags(optimization)
        ~ ["-o", objPath, irPath]);
    if (compiled.status != 0)
    {
        return LinkResult(false, compiled.output);
    }

    auto linked = execute(linkCommand(toolchain, objPath, runtime, libraries, outputPath));
    return LinkResult(linked.status == 0, linked.output);
}

/// The dmd command that links `objPath` with the runtime and `libraries` into `outputPath`.
string[] linkCommand(const Toolchain toolchain, string objPath, string runtime, const string[] libraries,
    string outputPath)
{
    import std.algorithm : map;
    import std.array : array;

    // dmd hands a `.lib` argument to link.exe as it is, and `-L` flags to the Unix linker.
    version (Windows) auto linked = libraries.map!(l => l ~ ".lib").array;
    else auto linked = libraries.map!(l => "-L-l" ~ l).array;
    auto linker = toolchain.lld ? ["-Xcc=-fuse-ld=lld"] : [];
    return [toolchain.dmd] ~ linker ~ [objPath, runtime] ~ linked ~ ["-of=" ~ outputPath];
}

/// Where the runtime for `optimization` is. Each mode has a directory of its own.
string runtimeBuildPath(Optimization optimization)
{
    return buildPath(runtimePath, optimization == Optimization.full ? "optimized" : "unoptimized");
}

/// Finds the runtime library for `optimization`. Returns why it isn't there, or null with `library` set.
string findRuntime(out string library, Optimization optimization = Optimization.none)
{
    version (Windows) enum name = "silver_rt.lib";
    else enum name = "libsilver_rt.a";
    library = buildPath(runtimeBuildPath(optimization), name);
    if (exists(library)) return null;
    if (!exists(runtimePath))
    {
        return "The runtime wasn't found. It's the directory `runtime` beside the compiler, which would be "
            ~ runtimePath ~ ".";
    }
    return "The runtime is missing " ~ library ~ ".";
}

@("runtimePath is out/runtime in the repository, where its build puts the runtime")
unittest
{
    import std.path : baseName;

    assert(runtimePath.baseName == "runtime" && dirName(runtimePath).baseName == "out", runtimePath);
    assert(exists(buildPath(dirName(dirName(runtimePath)), "runtime", "dub.json")));
}

@("a program linked with the runtime runs its silver_main and can print")
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
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

        declare i32 @silver_start(i32, ptr)
        define i32 @main(i32 %argc, ptr %argv) {
        entry:
          %status = call i32 @silver_start(i32 %argc, ptr %argv)
          ret i32 %status
        }
    `);

    foreach (optimization; [Optimization.none, Optimization.full])
    {
        auto linked = linkExecutable(toolchain, irPath, exePath, [], optimization);
        assert(linked.succeeded, linked.output);
        auto run = execute([exePath]);
        assert(run.status == 0, run.output);
        // The runtime writes the platform's newline.
        assert(run.output.replace("\r\n", "\n") == "42\n2.5\nfalse\nhi()\n", run.output);

        string runtime;
        assert(findRuntime(runtime, optimization) is null);
        assert(dirName(runtime) == runtimeBuildPath(optimization), runtime);
    }
}

@("the optimized runtime has a directory of its own and keeps the runtime's checks")
unittest
{
    import std.algorithm : canFind;
    import std.file : readText;
    import std.json : parseJSON;

    assert(runtimeBuildPath(Optimization.none) != runtimeBuildPath(Optimization.full));
    auto recipe = readText(buildPath(dirName(dirName(runtimePath)), "runtime", "dub.json"));
    string[] flags(string configuration)
    {
        foreach (c; parseJSON(recipe)["configurations"].array)
        {
            if (c["name"].str != configuration) continue;
            string[] all;
            if (auto given = "dflags" in c) foreach (f; given.array) all ~= f.str;
            return all;
        }
        assert(false, "no configuration " ~ configuration);
    }
    assert(flags("unoptimized") == []);
    assert(flags("optimized") == ["-O", "-inline"]);
    assert(!recipe.canFind("-release") && !recipe.canFind("boundscheck"));
}

@("the link command names each native library the way the platform's linker takes it")
unittest
{
    auto runtime = "rt.a";
    auto command = linkCommand(Toolchain("clang", "dmd"), "main.o", runtime, ["SDL2", "m"], "main");
    version (Windows) auto expected = ["SDL2.lib", "m.lib"];
    else auto expected = ["-L-lSDL2", "-L-lm"];
    assert(command == ["dmd", "main.o", "rt.a"] ~ expected ~ ["-of=main"], command.to!string);
}

@("the link command asks for lld when the toolchain found it")
unittest
{
    auto runtime = "rt.a";
    auto command = linkCommand(Toolchain("clang", "dmd", true), "main.o", runtime, [], "main");
    assert(command == ["dmd", "-Xcc=-fuse-ld=lld", "main.o", "rt.a", "-of=main"], command.to!string);
}
