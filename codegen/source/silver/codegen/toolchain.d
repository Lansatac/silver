module silver.codegen.toolchain;

import std.conv : to;
import std.file : exists, remove;
import std.path : buildPath, dirName, setExtension;
import std.process : environment, execute, ProcessException;

/// The D runtime linked into every compiled program, with the druntime and Phobos it was built
/// against, and on Windows MinGW's import libraries for the C runtime and the system: `runtime`
/// beside the executable. out/ has them for silver and silverc; the test executables are built in
/// build/, where the runtime is built and a link to stdlib/ is made.
string runtimePath()
{
    import std.file : thisExePath;

    return buildPath(thisExePath.dirName, "runtime");
}

/// The external tools that turn IR into an executable: clang compiles the IR, and off Windows
/// drives the platform's linker; on Windows lld-link links.
struct Toolchain
{
    string clang;
    /// lld: on Windows lld-link, which links with only the runtime's libraries, so Visual Studio
    /// isn't needed. Off Windows ld.lld if it was found, which links Phobos statically many times
    /// faster than GNU ld, or null to let clang use the system's linker.
    string lld;
}

/// Finds clang (`$SILVER_CLANG`, else `clang` on the PATH) and lld (`$SILVER_LLD`, else on Windows the
/// `lld-link` beside clang, and elsewhere `ld.lld`). Returns what's missing, or null if the toolchain was found.
string findToolchain(out Toolchain toolchain)
{
    toolchain.clang = findTool("SILVER_CLANG", "clang");
    if (toolchain.clang is null)
    {
        return "clang wasn't found. Install LLVM, or set SILVER_CLANG to clang's path.";
    }
    version (Windows)
    {
        // Beside clang, not first on the PATH, which is often dmd's older one: it's LLVM's own, of the
        // same version, and knows `/lldignoreenv`.
        auto besideClang = buildPath(dirName(onPath(toolchain.clang)), "lld-link.exe");
        toolchain.lld = findTool("SILVER_LLD", besideClang);
        if (toolchain.lld is null)
        {
            return "lld-link wasn't found beside clang, at " ~ besideClang ~ ". Install LLVM's, or set "
                ~ "SILVER_LLD to its path.";
        }
    }
    else toolchain.lld = findTool("SILVER_LLD", "ld.lld");
    return null;
}

/// `tool` itself if it's a path, else where the PATH finds it, or `tool` if nowhere.
version (Windows) private string onPath(string tool)
{
    import std.algorithm : splitter;
    import std.path : baseName, defaultExtension;

    if (tool.baseName != tool) return tool;
    foreach (directory; environment.get("PATH", "").splitter(';'))
    {
        auto candidate = buildPath(directory, tool.defaultExtension("exe"));
        if (directory.length && exists(candidate)) return candidate;
    }
    return tool;
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
    if (auto missing = findRuntime())
    {
        return LinkResult(false, missing);
    }

    version (Windows) auto objPath = outputPath.setExtension("obj");
    else auto objPath = outputPath.setExtension("o");
    scope (exit) if (exists(objPath)) remove(objPath);
    // The IR has no target triple, so clang uses the host's; it warns about that otherwise.
    auto compiled = execute([toolchain.clang, "-c", "-Wno-override-module"] ~ optimizationFlags(optimization)
        ~ ["-o", objPath, irPath]);
    if (compiled.status != 0)
    {
        return LinkResult(false, compiled.output);
    }

    auto linked = execute(linkCommand(toolchain, objPath, runtimePath, libraries, outputPath));
    return LinkResult(linked.status == 0, linked.output);
}

version (Windows) private enum runtimeLibraries = ["silver_rt.lib", "phobos64.lib"];
else private enum runtimeLibraries = ["libsilver_rt.a", "libphobos2.a"];

/// The command that links `objPath` with the libraries in `runtime` and `libraries` into `outputPath`.
string[] linkCommand(const Toolchain toolchain, string objPath, string runtime, const string[] libraries,
    string outputPath)
{
    import std.algorithm : filter, map, splitter;
    import std.array : array;

    auto linked = runtimeLibraries.map!(l => buildPath(runtime, l)).array;
    version (Windows)
    {
        // The runtime's MinGW libraries are the only ones searched for what the runtime names, such as
        // the C runtime, even where Visual Studio is installed, so a program links and runs the same with
        // or without it. `LIB`'s directories come after them, for the native libraries a program names.
        // `/OPT:NOICF` is dmd's: folding identical functions would merge ones D expects to be distinct.
        auto searched = ["/libpath:" ~ buildPath(runtime, "mingw")]
            ~ environment.get("LIB", "").splitter(';').filter!(d => d.length).map!(d => "/libpath:" ~ d).array;
        return [toolchain.lld, "/nologo", "/lldignoreenv", "/opt:noicf"] ~ searched ~ [objPath] ~ linked
            ~ libraries.map!(l => l ~ ".lib").array ~ ["/out:" ~ outputPath];
    }
    else
    {
        auto linker = toolchain.lld ? ["-fuse-ld=lld"] : [];
        // What dmd adds when it links, for Phobos.
        return [toolchain.clang] ~ linker ~ [objPath] ~ linked ~ libraries.map!(l => "-l" ~ l).array
            ~ ["-lpthread", "-lm", "-lrt", "-ldl", "-o", outputPath];
    }
}

/// Checks that the runtime's libraries are there, which programs link whether or not they're optimized.
/// Returns why one isn't, or null.
string findRuntime()
{
    if (!exists(runtimePath))
    {
        return "The runtime wasn't found. It's the directory `runtime` beside the compiler, which would be "
            ~ runtimePath ~ ".";
    }
    version (Windows) enum needed = runtimeLibraries ~ ["mingw"];
    else enum needed = runtimeLibraries;
    foreach (name; needed)
    {
        auto library = buildPath(runtimePath, name);
        if (!exists(library)) return "The runtime is missing " ~ library ~ ".";
    }
    return null;
}

@("runtimePath is build/runtime in the repository, where its build puts the runtime")
unittest
{
    import std.path : baseName;

    assert(runtimePath.baseName == "runtime" && dirName(runtimePath).baseName == "build", runtimePath);
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

@("the link command names the runtime's libraries, and each native library the way the linker takes it")
unittest
{
    auto command = linkCommand(Toolchain("clang", "lld"), "main.o", "rt", ["SDL2", "m"], "main");
    version (Windows)
    {
        import std.algorithm : canFind, endsWith, find;

        assert(command[0 .. 5] == ["lld", "/nologo", "/lldignoreenv", "/opt:noicf", "/libpath:" ~ buildPath("rt", "mingw")],
            command.to!string);
        assert(command.find("main.o")[0 .. 6] == ["main.o", buildPath("rt", "silver_rt.lib"),
            buildPath("rt", "phobos64.lib"), "SDL2.lib", "m.lib", "/out:main"], command.to!string);
    }
    else
    {
        assert(command == ["clang", "-fuse-ld=lld", "main.o", buildPath("rt", "libsilver_rt.a"),
            buildPath("rt", "libphobos2.a"), "-lSDL2", "-lm", "-lpthread", "-lm", "-lrt", "-ldl", "-o", "main"],
            command.to!string);
        assert(linkCommand(Toolchain("clang"), "main.o", "rt", [], "main")[0 .. 2] == ["clang", "main.o"]);
    }
}
