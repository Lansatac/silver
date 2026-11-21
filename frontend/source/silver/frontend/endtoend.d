/// Runs `silver` and `silverc` on the projects under frontend/tests, and on ones built in the temp
/// directory. Both executables have to be built at the repository's root first, which `dub build`
/// does and `runTests.sh` does before testing.
module silver.frontend.endtoend;

version (unittest):

import silver.frontend : makeTree, plan, Plan, request;
import std.algorithm : canFind, endsWith, startsWith;
import std.array : replace;
import std.file : exists, rmdirRecurse, tempDir;
import std.path : buildNormalizedPath, buildPath, dirName;
static import std.process;

immutable root = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..");
immutable fixtures = buildPath(root, "frontend", "tests");

version (Windows) enum exe = ".exe";
else enum exe = "";

/// The built executable `name` at the repository's root, failing the test when it isn't there.
string built(string name)
{
    auto path = buildPath(root, name ~ exe);
    assert(exists(path), path ~ " isn't there: the front end's end-to-end tests run the built executables, so run "
        ~ "`dub build` at the repository's root first");
    return path;
}

struct Ran
{
    int status;
    /// Standard output and error together, with `\r\n` as `\n`.
    string output;
}

Ran runIn(string[] arguments, string workingDirectory)
{
    auto result = std.process.execute(arguments, null, std.process.Config.none, size_t.max, workingDirectory);
    return Ran(result.status, result.output.replace("\r\n", "\n"));
}

/// What `silver words` plans from `workingDirectory`, run with the built compiler.
Ran planned(string[] words, string workingDirectory)
{
    auto p = plan(built("silverc"), request(words), workingDirectory);
    assert(p.mistake is null, p.mistake);
    return runIn(p.arguments, workingDirectory);
}

/// `silver words` itself, run from `workingDirectory`.
Ran silver(string[] words, string workingDirectory)
{
    built("silverc");
    return runIn([built("silver")] ~ words, workingDirectory);
}

void expectRan(Ran ran, string output, int status = 0)
{
    import std.conv : text;

    assert(ran.status == status && ran.output == output, "exit status " ~ text(ran.status) ~ ", output:\n" ~ ran.output);
}

@("a program uses libraries found by [paths], one of which uses the other, on both backends")
unittest
{
    auto shop = buildPath(fixtures, "uses-path", "shop");
    foreach (backend; [["-b", "interpreter"], ["-b", "llvm"]])
    {
        expectRan(planned(backend ~ "src/main.ag", shop), "25\n5\n");
        expectRan(planned(backend ~ buildPath("shop", "src", "main.ag"), dirName(shop)), "25\n5\n");
    }
    expectRan(planned([buildPath(shop, "src", "main.ag")], tempDir), "25\n5\n");
}

@("silver build makes an executable of a program in a project")
unittest
{
    auto directory = makeTree("frontend-build", null);
    scope (exit) rmdirRecurse(directory);
    auto output = buildPath(directory, "shop" ~ exe);
    expectRan(planned(["build", "-o", output, "src/main.ag"], buildPath(fixtures, "uses-path", "shop")), "");
    expectRan(runIn([output], directory), "25\n5\n");
}

@("silver test runs a library's tests and a part's companion tests, on both backends")
unittest
{
    foreach (backend; ["interpreter", "llvm"])
    {
        expectRan(planned(["test", "-b", backend, "geometry"], buildPath(fixtures, "uses-path")), "1 passed, 0 failed\n");
        expectRan(planned(["test", "-b", backend, "ast"], buildPath(fixtures, "compiler-shape")), "2 passed, 0 failed\n");
        expectRan(planned(["test", "-b", backend, buildPath("ast", "node.ag")], buildPath(fixtures, "compiler-shape")),
            "2 passed, 0 failed\n");
    }
}

@("a parent with no modules holds library parts and two parts that are programs, each run on both backends")
unittest
{
    auto project = buildPath(fixtures, "compiler-shape");
    foreach (backend; ["interpreter", "llvm"])
    {
        expectRan(planned(["-b", backend, "compiler/source/main.ag"], project), "parsed node 9\n");
        expectRan(planned(["-b", backend, "main.ag"], buildPath(project, "frontend")), "the front end\n");
    }
}

@("a package elsewhere uses one part of another project by the part's directory")
unittest
{
    foreach (backend; ["interpreter", "llvm"])
        expectRan(planned(["-b", backend, "main.ag"], buildPath(fixtures, "uses-part")), "parsed node 7\n");
}

@("silver itself runs a project's program and shows the compiler's command line when asked")
unittest
{
    auto shop = buildPath(fixtures, "uses-path", "shop");
    expectRan(silver(["src/main.ag"], shop), "25\n5\n");
    expectRan(silver(["run", "-b", "llvm", "src/main.ag"], shop), "25\n5\n");
    auto shown = silver(["--show-command", "src/main.ag"], shop);
    assert(shown.status == 0 && shown.output.endsWith("src/main.ag\n25\n5\n"), shown.output);
    assert(shown.output.startsWith(built("silverc") ~ " run --package shop=src --package cards="), shown.output);
    assert(shown.output.canFind(" --uses shop=cards,geometry --uses cards=geometry --package-file shop=silver.toml "),
        shown.output);
}

@("a file with no silver.toml at or above it runs as before")
unittest
{
    auto directory = makeTree("frontend-no-project", ["hello.ag": "import std.math\n\ndef main(): Unit {\n"
        ~ "    printl(\"hello\")\n}\n"]);
    scope (exit) rmdirRecurse(directory);
    auto p = plan("silverc", request(["hello.ag"]), directory);
    assert(p.projectFile is null && p.arguments == ["silverc", "run", "hello.ag"]);
    expectRan(silver(["hello.ag"], directory), "hello\n");
    expectRan(silver(["-b", "llvm", buildPath(directory, "hello.ag")], tempDir), "hello\n");
}

@("a mistake in a package file is one located message, and the compiler isn't started")
unittest
{
    auto broken = buildPath(fixtures, "broken");
    immutable message = "Error F0016: `version` isn't a field of a package file. A package file has `name`, `source`, "
        ~ "`uses`, `[paths]` and `[[part]]`\n";
    expectRan(silver(["main.ag"], broken), "silver.toml(2,1): " ~ message, 1);
    expectRan(silver(["build", "broken/main.ag"], fixtures), buildPath("broken", "silver.toml") ~ "(2,1): " ~ message, 1);
    auto p = plan("silverc", request(["test", "main.ag"]), broken);
    assert(p.mistake == "silver.toml(2,1): " ~ message[0 .. $ - 1] && p.arguments is null);
}

@("a compiler message about a package in a project names its package file and field, not an option")
unittest
{
    auto directory = makeTree("frontend-hints", [
        "silver.toml": "name = \"p\"\n\n[[part]]\nname = \"p.a\"\npath = \"a\"\n\n[[part]]\nname = \"p.b\"\npath = \"b\"\n",
        "a/lib.ag": "module p.a.lib\n\ndef one(): Int => 1\n",
        "b/main.ag": "module p.b.main\n\nimport p.a.lib\n\ndef main(): Unit {\n    printl(one())\n}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto ran = silver([buildPath("b", "main.ag")], directory);
    assert(ran.status == 1, ran.output);
    assert(ran.output.endsWith("\nList 'p.a' among what 'p.b' uses\nThat list is the `uses` of the part 'p.b' in "
        ~ "silver.toml\n"), ran.output);
    assert(!ran.output.canFind("--uses"), ran.output);
}

@("the file is found in the arguments however the options before it are written")
unittest
{
    Plan p = plan("silverc", request(["test", "--filter", "node", "-b", "both", "--format=json", "ast"]),
        buildPath(fixtures, "compiler-shape"));
    assert(p.projectFile == buildPath(fixtures, "compiler-shape", "silver.toml"), p.projectFile);
    assert(p.containing == "tool.ast");
    assert(p.arguments[$ - 6 .. $] == ["--filter", "node", "-b", "both", "--format=json", "ast"]);
    assert(p.arguments[0 .. 4] == ["silverc", "test", "--package", "tool.ast=ast"]);
    p = plan("silverc", request(["--package", "x=y", "main.ag", "after"]), buildPath(fixtures, "uses-part"));
    assert(p.arguments[$ - 4 .. $] == ["--package", "x=y", "main.ag", "after"]);
    assert(p.arguments.canFind("lint=."));
}
