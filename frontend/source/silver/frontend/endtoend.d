/// Runs `silver` and `silverc` on the projects under frontend/tests, and on ones built in the temp
/// directory. Both executables have to be built at the repository's root first, which `dub build`
/// does and `runTests.sh` does before testing.
module silver.frontend.endtoend;

version (unittest):

import silver.frontend : makeTree, plan, Plan, request;
import std.algorithm : canFind, endsWith, startsWith;
import std.array : join, replace;
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
    assert(p.scriptHomes == ["tool.ast"]);
    assert(p.arguments[$ - 6 .. $] == ["--filter", "node", "-b", "both", "--format=json", "ast"]);
    assert(p.arguments[0 .. 4] == ["silverc", "test", "--package", "tool.ast=ast"]);
    p = plan("silverc", request(["--package", "x=y", "main.ag", "after"]), buildPath(fixtures, "uses-part"));
    assert(p.arguments[$ - 4 .. $] == ["--package", "x=y", "main.ag", "after"]);
    assert(p.arguments.canFind("lint=."));
}

@("a library's scripts beside its modules use it and what it uses, on both backends")
unittest
{
    auto scripts = buildPath(fixtures, "scripts");
    auto shapes = buildPath(scripts, "shapes");
    foreach (backend; [["-b", "interpreter"], ["-b", "llvm"]])
    {
        expectRan(planned(backend ~ "demo.ag", shapes), "9\n");
        expectRan(planned(backend ~ "bench.ag", shapes), "17\n");
        expectRan(planned(backend ~ buildPath("shapes", "demo.ag"), scripts), "9\n");
    }
    auto p = plan("silverc", request(["demo.ag"]), shapes);
    assert(p.scriptHomes == ["shapes"] && p.arguments.canFind("shapes=."), p.arguments[2 .. $].join(" "));
}

@("a script started by its path from another directory behaves as it does from its own")
unittest
{
    auto shapes = buildPath(fixtures, "scripts", "shapes");
    expectRan(silver([buildPath(shapes, "demo.ag")], tempDir), "9\n");
    expectRan(silver(["-b", "llvm", buildPath(shapes, "bench.ag")], tempDir), "17\n");
    expectRan(silver([buildPath(fixtures, "scripts", "shop", "tryout.ag")], tempDir), "tryout 2\n");
}

@("a script beside a program's package file uses what the program uses, and is told it can't use the program")
unittest
{
    auto shop = buildPath(fixtures, "scripts", "shop");
    foreach (backend; ["interpreter", "llvm"])
        expectRan(planned(["-b", backend, "tryout.ag"], shop), "tryout 2\n");
    expectRan(planned([buildPath("src", "main.ag")], shop), "shop 1\n");

    auto directory = makeTree("frontend-script-program", [
        "silver.toml": "name = \"app\"\nsource = \"src\"\n",
        "src/main.ag": "module app.main\n\ndef main(): Unit {}\n",
        "tryout.ag": "import app.main\n\ndef main(): Unit {}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    expectRan(silver(["tryout.ag"], directory), "tryout.ag(1,1): Error L0010: 'tryout' is a file with no `module` line "
        ~ "under the directory of the package 'app', and it can't import 'app.main': 'app.main' declares `main`, so 'app' "
        ~ "is a program, and nothing can use a program, not even a file beside it\nA file beside a program uses only what "
        ~ "the program uses: move what both need to a library they use\n", 1);
}

@("a script in a project under none of its packages uses the standard library alone, and is told where one that needs more goes")
unittest
{
    auto group = buildPath(fixtures, "scripts", "group");
    foreach (backend; ["interpreter", "llvm"])
    {
        expectRan(planned(["-b", backend, "scratch.ag"], group), "8\n");
        expectRan(planned(["-b", backend, buildPath("lib", "try.ag")], group), "hello\n");
    }
    assert(plan("silverc", request(["scratch.ag"]), group).scriptHomes.length == 0);

    auto directory = makeTree("frontend-script-homeless", [
        "silver.toml": "name = \"g\"\n\n[[part]]\nname = \"g.lib\"\npath = \"lib\"\n",
        "lib/words.ag": "module g.lib.words\n\ndef word(): String => \"w\"\n",
        "scratch.ag": "import g.lib.words\n\ndef main(): Unit {}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto ran = silver(["scratch.ag"], directory);
    assert(ran.status == 1 && ran.output.endsWith("\nA file with no `module` line that's under no package's directory "
        ~ "uses only the standard library, so one that needs 'g.lib' belongs under the directory of that package or of "
        ~ "one that uses it\n"), ran.output);
    assert(!ran.output.canFind("--uses"), ran.output);
}

@("a script that imports what its library doesn't use is told to list it in the library's uses")
unittest
{
    auto directory = makeTree("frontend-script-hint", [
        "geo/silver.toml": "name = \"geo\"\n",
        "geo/shapes.ag": "module geo.shapes\n\ndef sides(): Int => 4\n",
        "units/silver.toml": "name = \"units\"\n",
        "units/length.ag": "module units.length\n\ndef metre(): Int => 1\n",
        "geo/demo.ag": "import geo.shapes\nimport units.length\n\ndef main(): Unit {}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto ran = silver(["demo.ag"], buildPath(directory, "geo"));
    assert(ran.status == 1 && ran.output.endsWith("\nA file with no `module` line under the directory of the package "
        ~ "'geo' uses what 'geo' uses\nList it in `uses` in silver.toml, with its directory under `[paths]` there\n"),
        ran.output);
}

@("silver test runs the tests of every script in a directory, each beside its own package, on both backends")
unittest
{
    auto scripts = buildPath(fixtures, "scripts");
    foreach (backend; ["interpreter", "llvm"])
    {
        expectRan(planned(["test", "-b", backend, "shapes"], scripts), "2 passed, 0 failed\n");
        // The root holds only its parts: scratch.ag uses std alone and lib/try.ag uses its part.
        expectRan(planned(["test", "-b", backend, "group"], scripts), "2 passed, 0 failed\n");
        expectRan(planned(["test", "-b", backend, "."], buildPath(scripts, "group")), "2 passed, 0 failed\n");
    }
    assert(plan("silverc", request(["test", "group"]), scripts).scriptHomes == ["group.lib"]);
}

@("silver test over a directory leaves out a project of its own inside it, and still tests one the project uses")
unittest
{
    auto directory = makeTree("frontend-script-nested-project", [
        "outer/silver.toml": "name = \"outer\"
source = \"src\"
uses = [\"used\"]
[paths]
used = \"used\"
",
        "outer/src/k.ag": "module outer.k

import used.u

def k(): Int => u()

test \"k\" => expect(k() == 4)
",
        "outer/used/silver.toml": "name = \"used\"
",
        "outer/used/u.ag": "module used.u

def u(): Int => 4

test \"u\" => expect(u() == 4)
",
        "outer/nested/silver.toml": "name = \"nested\"
",
        "outer/nested/x.ag": "import outer.k

def main(): Unit {}

test \"k\" => expect(k() == 4)
",
        "outer/nested/deeper/silver.toml": "name = \"deeper\"
",
    ]);
    scope (exit) rmdirRecurse(directory);
    // Run by itself, or tested from its own directory, x.ag can't import outer.k: it's under 'nested'.
    assert(silver([buildPath("outer", "nested", "x.ag")], directory).status == 1);
    assert(silver(["test", buildPath("outer", "nested")], directory).status == 1);
    // From the directory above, nested is another project and isn't tested, and used, which outer uses, is.
    foreach (backend; ["interpreter", "llvm", "both"])
        expectRan(silver(["test", "-b", backend, "outer"], directory), "2 passed, 0 failed
");
    auto json = silver(["test", "--format", "json", "outer"], directory);
    assert(json.status == 0 && !json.output.canFind("x.ag"), json.output);
    auto p = plan("silverc", request(["test", "outer"]), directory);
    assert(p.arguments.canFind("--skip") && p.arguments.canFind(buildPath("outer", "nested")), p.arguments.join(" "));
    assert(!p.arguments.canFind(buildPath("outer", "nested", "deeper")) && !p.arguments.canFind(buildPath("outer", "used")));
    // A file is tested as it is, with nothing skipped.
    assert(!plan("silverc", request(["test", buildPath("outer", "src", "k.ag")]), directory).arguments.canFind("--skip"));
}
