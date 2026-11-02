module silver.codegen.toolchain;

import std.algorithm : map, sort;
import std.array : array;
import std.file : dirEntries, exists, SpanMode;
import std.path : buildNormalizedPath, dirName, setExtension;
import std.process : environment, execute, ProcessException;

/// The directory of C sources linked into every compiled program. Like
/// `standardLibraryPath()`, it's stubbed to the repository until there's an install layout.
string runtimePath()
{
    return buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..", "runtime");
}

/// The clang to use: `$SILVER_CLANG` if set, otherwise `clang` on the PATH. Null if it can't run.
string findClang()
{
    auto clang = environment.get("SILVER_CLANG", "clang");
    try
    {
        return execute([clang, "--version"]).status == 0 ? clang : null;
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
    /// clang's combined stdout and stderr.
    string output;
}

/// Compiles the IR at `irPath` together with every `.c` file in `runtimePath()` into the
/// executable `outputPath`.
LinkResult linkExecutable(string clang, string irPath, string outputPath, string[] extraFlags = [])
{
    // The IR has no target triple, so clang uses the host's; it warns about that otherwise.
    auto args = [clang, "-Wno-override-module"] ~ extraFlags ~ ["-o", outputPath, irPath];
    if (exists(runtimePath))
    {
        args ~= dirEntries(runtimePath, "*.c", SpanMode.shallow).map!(e => e.name).array.sort.release;
    }
    auto result = execute(args);
    return LinkResult(result.status == 0, result.output);
}

@("runtimePath is the repository's runtime directory")
unittest
{
    import std.path : baseName, buildPath;

    assert(runtimePath.baseName == "runtime");
    assert(exists(buildPath(dirName(runtimePath), "dub.json")));
}
