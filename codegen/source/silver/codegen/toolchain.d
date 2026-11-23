module silver.codegen.toolchain;

import std.conv : to;
import std.file : exists;
import std.path : buildPath, dirName, setExtension;
import std.process : environment, execute, ProcessException;

/// The D runtime linked into every compiled program, with the druntime and Phobos it was built
/// against: `runtime` beside the executable, where the compiler's build puts them. The test
/// executables are built beside it too.
string runtimePath()
{
    import std.file : thisExePath;

    return buildPath(thisExePath.dirName, "runtime");
}

/// The external tool that turns IR into an executable: clang compiles the IR and, as the driver
/// of the platform's linker, links it with the runtime.
struct Toolchain
{
    string clang;
    /// Whether clang should link with lld, which links Phobos statically many times faster than
    /// GNU ld. Only looked for off Windows, where clang uses the MSVC linker.
    bool lld;
}

/// Finds clang (`$SILVER_CLANG`, else `clang` on the PATH). Returns what's missing, or null if it
/// was found.
string findToolchain(out Toolchain toolchain)
{
    toolchain.clang = findTool("SILVER_CLANG", "clang");
    if (toolchain.clang is null)
    {
        return "clang wasn't found. Install LLVM, or set SILVER_CLANG to clang's path.";
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
    string[] runtime;
    if (auto missing = findRuntime(runtime))
    {
        return LinkResult(false, missing);
    }
    auto linked = execute(linkCommand(toolchain, irPath, runtime, libraries, outputPath, optimization));
    return LinkResult(linked.status == 0, linked.output);
}

/// The clang command that compiles `irPath` and links it with `runtime` and `libraries` into `outputPath`.
string[] linkCommand(const Toolchain toolchain, string irPath, const string[] runtime, const string[] libraries,
    string outputPath, Optimization optimization = Optimization.none)
{
    import std.algorithm : map;
    import std.array : array;

    // clang passes `-lname` to the MSVC linker as `name.lib`.
    auto linked = libraries.map!(l => "-l" ~ l).array;
    auto linker = toolchain.lld ? ["-fuse-ld=lld"] : [];
    // What dmd adds when it links: Phobos's own dependencies off Windows, and on Windows no
    // identical-code folding, which would merge functions D expects to have distinct addresses.
    version (Windows) auto system = ["-Wl,/OPT:NOICF"];
    else auto system = ["-lpthread", "-lm", "-lrt", "-ldl"];
    // The IR has no target triple, so clang uses the host's; it warns about that otherwise.
    return [toolchain.clang, "-Wno-override-module"] ~ optimizationFlags(optimization) ~ linker
        ~ [irPath] ~ runtime ~ linked ~ system ~ ["-o", outputPath];
}

/// Finds the runtime's libraries, which programs link whether or not they're optimized: the runtime, and
/// the druntime and Phobos it was built against. Returns why one isn't there, or null with `libraries` set.
string findRuntime(out string[] libraries)
{
    version (Windows) enum names = ["silver_rt.lib", "phobos64.lib"];
    else enum names = ["libsilver_rt.a", "libphobos2.a"];
    if (!exists(runtimePath))
    {
        return "The runtime wasn't found. It's the directory `runtime` beside the compiler, which would be "
            ~ runtimePath ~ ".";
    }
    foreach (name; names)
    {
        auto library = buildPath(runtimePath, name);
        if (!exists(library)) return "The runtime is missing " ~ library ~ ".";
        libraries ~= library;
    }
    return null;
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
    }
}

@("the runtime is built optimized and keeps its own checks")
unittest
{
    import std.algorithm : canFind, map;
    import std.array : array;
    import std.file : readText;
    import std.json : parseJSON;

    auto recipe = readText(buildPath(dirName(dirName(runtimePath)), "runtime", "dub.json"));
    auto flags = parseJSON(recipe)["dflags"].array.map!(f => f.str).array;
    assert(flags.canFind("-O") && flags.canFind("-inline"), flags.to!string);
    assert(!recipe.canFind("-release") && !recipe.canFind("boundscheck"));
}

@("the link command names each native library the way clang takes it")
unittest
{
    auto command = linkCommand(Toolchain("clang"), "main.ll", ["rt.a", "phobos.a"], ["SDL2", "m"], "main");
    version (Windows) auto system = ["-Wl,/OPT:NOICF"];
    else auto system = ["-lpthread", "-lm", "-lrt", "-ldl"];
    assert(command == ["clang", "-Wno-override-module", "main.ll", "rt.a", "phobos.a", "-lSDL2", "-lm"] ~ system
        ~ ["-o", "main"], command.to!string);
}

@("the link command asks for lld when the toolchain found it, and optimizes when asked")
unittest
{
    auto command = linkCommand(Toolchain("clang", true), "main.ll", ["rt.a"], [], "main", Optimization.full);
    assert(command[0 .. 5] == ["clang", "-Wno-override-module", "-O2", "-fuse-ld=lld", "main.ll"], command.to!string);
}
