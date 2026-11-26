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

/// Where a release bundles LLVM's tools: `llvm` beside the executable. A checkout's build has none, so
/// the tools come from the PATH.
string bundledLlvmPath()
{
    import std.file : thisExePath;

    return buildPath(thisExePath.dirName, "llvm");
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

/// Finds clang (`$SILVER_CLANG`, else the one bundled in `llvm` beside the executable, else `clang` on the
/// PATH) and lld (`$SILVER_LLD`, else on Windows the `lld-link` beside clang, and elsewhere `ld.lld`). Returns
/// what's missing, or null if the toolchain was found.
string findToolchain(out Toolchain toolchain)
{
    auto bundled = executablePath(buildPath(bundledLlvmPath, "clang"));
    toolchain.clang = findTool("SILVER_CLANG", exists(bundled) ? bundled : "clang");
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
/// `native library` names them, into the executable `outputPath`. A library that `linkFiles` gives a
/// file is linked against that file, and the others by name. With `besideItself`, the program looks
/// for shared libraries in its own directory, which on Windows it does anyway.
LinkResult linkExecutable(const Toolchain toolchain, string irPath, string outputPath, const string[] libraries = [],
    Optimization optimization = Optimization.none, const string[string] linkFiles = null, bool besideItself = false)
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

    auto linked = execute(linkCommand(toolchain, objPath, runtimePath, libraries, outputPath, linkFiles, besideItself));
    return LinkResult(linked.status == 0, linked.output);
}

version (Windows) private enum runtimeLibraries = ["silver_rt.lib", "phobos64.lib"];
else private enum runtimeLibraries = ["libsilver_rt.a", "libphobos2.a"];

/// The command that links `objPath` with the libraries in `runtime` and `libraries` into `outputPath`,
/// each of `libraries` by the file `linkFiles` gives it, if any, and otherwise by name.
string[] linkCommand(const Toolchain toolchain, string objPath, string runtime, const string[] libraries,
    string outputPath, const string[string] linkFiles = null, bool besideItself = false)
{
    import std.algorithm : filter, map, splitter;
    import std.array : array;
    import std.path : baseName;

    auto linked = runtimeLibraries.map!(l => buildPath(runtime, l)).array;
    version (Windows)
    {
        // The runtime's MinGW libraries are the only ones searched for what the runtime names, such as
        // the C runtime, even where Visual Studio is installed, so a program links and runs the same with
        // or without it. `LIB`'s directories come after them, for the native libraries a program names.
        // `/OPT:NOICF` is dmd's: folding identical functions would merge ones D expects to be distinct.
        auto searched = ["/libpath:" ~ buildPath(runtime, "mingw")]
            ~ environment.get("LIB", "").splitter(';').filter!(d => d.length).map!(d => "/libpath:" ~ d).array;
        // lld-link takes a file of any name, a MinGW import library `libX.dll.a` among them.
        return [toolchain.lld, "/nologo", "/lldignoreenv", "/opt:noicf"] ~ searched ~ [objPath] ~ linked
            ~ libraries.map!(l => l in linkFiles ? linkFiles[l] : l ~ ".lib").array ~ ["/out:" ~ outputPath];
    }
    else
    {
        auto linker = toolchain.lld ? ["-fuse-ld=lld"] : [];
        // A file is named by `-l:` from its directory rather than by its path, so a shared library with no
        // soname is recorded as its name, not as the path it was linked from.
        string[] named;
        foreach (l; libraries)
        {
            if (auto file = l in linkFiles) named ~= ["-L" ~ dirName(*file), "-l:" ~ baseName(*file)];
            else named ~= "-l" ~ l;
        }
        // `$ORIGIN` is the linker's, which the command, an array of words, keeps from any shell.
        auto beside = besideItself ? ["-Wl,-rpath,$ORIGIN"] : [];
        // What dmd adds when it links, for Phobos.
        return [toolchain.clang] ~ linker ~ [objPath] ~ linked ~ named ~ beside
            ~ ["-lpthread", "-lm", "-lrt", "-ldl", "-o", outputPath];
    }
}

/// The shared libraries `loadFiles` gives for `libraries`, which a program linked with them loads.
string[] sharedLibrariesOf(const string[] libraries, const string[string] loadFiles)
{
    string[] files;
    foreach (l; libraries)
    {
        if (auto file = l in loadFiles) files ~= *file;
    }
    return files;
}

/// The environment a compiled program started from here is run with so that it finds `sharedLibraries`
/// where they are: their directories first in `PATH` on Windows and in `LD_LIBRARY_PATH` elsewhere. Null
/// when there are none, as the program then needs nothing added.
string[string] findingLibraries(const string[] sharedLibraries)
{
    import std.algorithm : canFind;
    import std.array : join;
    import std.path : absolutePath;

    if (sharedLibraries.length == 0) return null;
    version (Windows) enum variable = "PATH", separator = ";";
    else enum variable = "LD_LIBRARY_PATH", separator = ":";
    string[] directories;
    foreach (file; sharedLibraries)
    {
        auto directory = dirName(absolutePath(file));
        if (!directories.canFind(directory)) directories ~= directory;
    }
    auto rest = environment.get(variable, "");
    return [variable: directories.join(separator) ~ (rest.length > 0 ? separator ~ rest : "")];
}

/// Copies each of `sharedLibraries` into the directory of the executable `outputPath` under its own name,
/// unless the same file is there already. Returns why one couldn't be copied, or null.
string copyBeside(const string[] sharedLibraries, string outputPath)
{
    import std.file : copy, FileException, read;
    import std.path : absolutePath, baseName, buildNormalizedPath, filenameCmp;

    auto directory = dirName(absolutePath(outputPath));
    foreach (file; sharedLibraries)
    {
        auto target = buildPath(directory, baseName(file));
        try
        {
            if (filenameCmp(buildNormalizedPath(absolutePath(file)), buildNormalizedPath(target)) == 0) continue;
            if (exists(target) && read(target) == read(file)) continue;
            copy(file, target);
        }
        catch (FileException e)
        {
            return "The shared library " ~ file ~ " couldn't be copied beside the executable, to " ~ target ~ ": " ~ e.msg;
        }
    }
    return null;
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

@("a library given a file is linked against that file under its own name, and the others by name")
unittest
{
    import std.algorithm : canFind, find;

    auto files = ["ray": buildPath("vendor", "libraylibdll.a"), "unused": "x.a"];
    version (Windows)
    {
        auto command = linkCommand(Toolchain("clang", "lld"), "main.obj", "rt", ["ray", "m"], "main", files, true);
        assert(command.find("main.obj")[3 .. $] == [buildPath("vendor", "libraylibdll.a"), "m.lib", "/out:main"],
            command.to!string);
    }
    else
    {
        auto command = linkCommand(Toolchain("clang"), "main.o", "rt", ["ray", "m"], "main", files, true);
        assert(command.find("main.o")[3 .. 8] == ["-Lvendor", "-l:libraylibdll.a", "-lm", "-Wl,-rpath,$ORIGIN",
            "-lpthread"], command.to!string);
        assert(!linkCommand(Toolchain("clang"), "main.o", "rt", ["ray"], "main", files).canFind("-Wl,-rpath,$ORIGIN"));
    }
}

@("a compiled program run from here finds its shared libraries' directories first, and nothing is added without them")
unittest
{
    import std.algorithm : startsWith;
    import std.path : absolutePath;

    assert(findingLibraries(null) is null);
    auto added = findingLibraries([buildPath("a", "x.dll"), buildPath("a", "y.dll"), buildPath("b", "z.dll")]);
    version (Windows) enum variable = "PATH", separator = ";";
    else enum variable = "LD_LIBRARY_PATH", separator = ":";
    assert(added.length == 1 && added[variable].startsWith(absolutePath("a") ~ separator ~ absolutePath("b")),
        added.to!string);
    assert(sharedLibrariesOf(["ray", "m"], ["ray": "r.dll", "other": "o.dll"]) == ["r.dll"]);
}

@("a shared library is copied beside the executable under its own name, unless it's there already")
unittest
{
    import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;

    import std.uuid : randomUUID;

    auto directory = buildPath(tempDir, "silver-toolchain-beside-" ~ randomUUID().toString());
    mkdirRecurse(buildPath(directory, "vendor"));
    mkdirRecurse(buildPath(directory, "out"));
    scope (exit) rmdirRecurse(directory);
    auto library = buildPath(directory, "vendor", "libx.so.1");
    write(library, "one");
    auto executable = buildPath(directory, "out", "main");
    assert(copyBeside([library], executable) is null);
    assert(readText(buildPath(directory, "out", "libx.so.1")) == "one");
    write(library, "two");
    assert(copyBeside([library], executable) is null);
    assert(readText(buildPath(directory, "out", "libx.so.1")) == "two");
    // Built into the directory the library is in, there's nothing to copy.
    assert(copyBeside([library], buildPath(directory, "vendor", "main")) is null);
    assert(copyBeside([buildPath(directory, "gone.so")], executable) !is null);
}
