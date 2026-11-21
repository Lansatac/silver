/// Runs `silver` and `silverc` on the projects under frontend/tests, and on ones built in the temp
/// directory. Both executables have to be built at the repository's root first, which `dub build`
/// does and `runTests.sh` does before testing.
module silver.frontend.endtoend;

version (unittest):

import silver.frontend : makeTree, plan, Plan, request;
import std.algorithm : canFind, count, endsWith, startsWith;
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

@("a program uses libraries listed by their paths, one of which uses the other, on both backends")
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

@("silver test runs a library's tests and a described package's companion tests, on both backends")
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

@("a root with no modules describes libraries and two programs, each run on both backends")
unittest
{
    auto project = buildPath(fixtures, "compiler-shape");
    foreach (backend; ["interpreter", "llvm"])
    {
        expectRan(planned(["-b", backend, "compiler/source/main.ag"], project), "parsed node 9\n");
        expectRan(planned(["-b", backend, "main.ag"], buildPath(project, "frontend")), "the front end\n");
    }
}

@("a package elsewhere uses one package that another project describes, by its directory")
unittest
{
    foreach (backend; ["interpreter", "llvm"])
        expectRan(planned(["-b", backend, "main.ag"], buildPath(fixtures, "uses-described")), "parsed node 7\n");
    // It's given to the compiler with the rest of that project, whose project list names it, and lint is in none.
    auto p = plan("silverc", request(["main.ag"]), buildPath(fixtures, "uses-described"));
    assert(p.arguments.canFind("tool=tool.ast,tool.syntax,tool.compiler,tool.frontend"), p.arguments.join(" "));
    assert(p.arguments.count("--project") == 1, p.arguments.join(" "));
}

@("a root lists a library and a program that have files of their own: each is its own project, and run from its directory")
unittest
{
    auto listing = buildPath(fixtures, "listing");
    foreach (backend; [["-b", "interpreter"], ["-b", "llvm"]])
    {
        expectRan(silver(["run"] ~ backend, buildPath(listing, "app")), "counted 3\n");
        expectRan(silver(["run"] ~ backend ~ "app", listing), "counted 3\n");
        expectRan(silver(backend ~ buildPath("app", "src", "main.ag"), listing), "counted 3\n");
    }
    // The library is used by the described package and by the program, each through its own entry.
    auto p = plan("silverc", request(["run"]), listing);
    assert(p.arguments.canFind("--project") && p.arguments.canFind("listing=listing.report"), p.arguments.join(" "));
    assert(p.arguments.count("--project") == 1 && p.arguments.canFind("words=words"), p.arguments.join(" "));
    assert(!p.arguments.canFind!(a => a.startsWith("app=")), p.arguments.join(" "));
    // The only program here has a file of its own, so it isn't the program of the project here.
    auto ran = silver(["run"], listing);
    assert(ran.status == 1 && ran.output.startsWith("Error L0014: The package 'listing' only describes others, and none "
        ~ "of the packages it describes is a program"), ran.output);
    expectRan(silver(["test", "-b", "both"], buildPath(listing, "words")), "1 passed, 0 failed\n");
}

@("silver itself runs a project's program and shows the compiler's command line when asked")
unittest
{
    auto shop = buildPath(fixtures, "uses-path", "shop");
    expectRan(silver(["src/main.ag"], shop), "25\n5\n");
    expectRan(silver(["run", "-b", "llvm", "src/main.ag"], shop), "25\n5\n");
    auto shown = silver(["--show-command", "src/main.ag"], shop);
    assert(shown.status == 0 && shown.output.endsWith("src/main.ag\n25\n5\n"), shown.output);
    assert(shown.output.startsWith(built("silverc") ~ " run --from-silver --package shop=src --package cards="), shown.output);
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
    assert(p.projectFile is null && p.arguments == ["silverc", "run", "--from-silver", "hello.ag"]);
    expectRan(silver(["hello.ag"], directory), "hello\n");
    expectRan(silver(["-b", "llvm", buildPath(directory, "hello.ag")], tempDir), "hello\n");
}

@("a mistake in a package file is one located message, and the compiler isn't started")
unittest
{
    auto broken = buildPath(fixtures, "broken");
    immutable message = "Error F0016: `version` isn't a field of a package file. A package file has `name`, `source`, "
        ~ "`uses` and `[[package]]`\n";
    expectRan(silver(["main.ag"], broken), "silver.toml(2,1): " ~ message, 1);
    expectRan(silver(["build", "broken/main.ag"], fixtures), buildPath("broken", "silver.toml") ~ "(2,1): " ~ message, 1);
    auto p = plan("silverc", request(["test", "main.ag"]), broken);
    assert(p.mistake == "silver.toml(2,1): " ~ message[0 .. $ - 1] && p.arguments is null);
}

@("a package named with a capital letter is refused at its name in silver.toml, and the compiler isn't started")
unittest
{
    auto directory = makeTree("frontend-capital-name", ["silver.toml": "name = \"Geo\"\n",
        "main.ag": "module Geo.main\n\ndef main(): Unit {\n    printl(1)\n}\n"]);
    scope (exit) rmdirRecurse(directory);
    expectRan(silver(["main.ag"], directory), "silver.toml(1,8): Error F0019: \"Geo\" isn't a package name: it's one or "
        ~ "more segments joined by `.`, as \"silver.core\", each a lowercase letter or `_` followed by letters, digits "
        ~ "and `_`, as in a module's name\n", 1);
}

@("a compiler message about a package in a project names its package file and field, not an option")
unittest
{
    auto directory = makeTree("frontend-hints", [
        "silver.toml": "name = \"p\"\n\n[[package]]\nname = \"p.a\"\npath = \"a\"\n\n[[package]]\nname = \"p.b\"\npath = \"b\"\n",
        "a/lib.ag": "module p.a.lib\n\ndef one(): Int => 1\n",
        "b/main.ag": "module p.b.main\n\nimport p.a.lib\n\ndef main(): Unit {\n    printl(one())\n}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto ran = silver([buildPath("b", "main.ag")], directory);
    assert(ran.status == 1, ran.output);
    assert(ran.output.endsWith("\nList 'p.a' among what 'p.b' uses\nThat list is the `uses` of the package 'p.b' in "
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
    assert(p.arguments[0 .. 5] == ["silverc", "test", "--from-silver", "--package", "tool.ast=ast"]);
    p = plan("silverc", request(["-b", "llvm", "main.ag", "after"]), buildPath(fixtures, "uses-described"));
    assert(p.arguments[$ - 4 .. $] == ["-b", "llvm", "main.ag", "after"]);
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
    assert(plan("silverc", request(["scratch.ag"]), group).scriptHomes == ["group"]);

    auto directory = makeTree("frontend-script-homeless", [
        "silver.toml": "name = \"g\"\n\n[[package]]\nname = \"g.lib\"\npath = \"lib\"\n",
        "lib/words.ag": "module g.lib.words\n\ndef word(): String => \"w\"\n",
        "scratch.ag": "import g.lib.words\n\ndef main(): Unit {}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto ran = silver(["scratch.ag"], directory);
    assert(ran.status == 1 && ran.output.endsWith("\nA file with no `module` line under the directory of 'g', a "
        ~ "package that only describes others, uses only the standard library, so one that needs 'g.lib' belongs under "
        ~ "the directory of one of the packages it describes, 'g.lib', or of a package that uses it\n"), ran.output);
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
        ~ "'geo' uses what 'geo' uses\nList it in `uses` in silver.toml, with a `[[package]]` entry whose `path` is its "
        ~ "directory there\n"),
        ran.output);
}

@("silver test runs the tests of every script in a directory, each beside its own package, on both backends")
unittest
{
    auto scripts = buildPath(fixtures, "scripts");
    foreach (backend; ["interpreter", "llvm"])
    {
        expectRan(planned(["test", "-b", backend, "shapes"], scripts), "2 passed, 0 failed\n");
        // The root only describes another: scratch.ag uses std alone and lib/try.ag uses the package it's in.
        expectRan(planned(["test", "-b", backend, "group"], scripts), "2 passed, 0 failed\n");
        expectRan(planned(["test", "-b", backend, "."], buildPath(scripts, "group")), "2 passed, 0 failed\n");
    }
    assert(plan("silverc", request(["test", "group"]), scripts).scriptHomes == ["group", "group.lib"]);
}

@("with no file, silver run runs the program of the package started in, from its root, a subdirectory or a described package, on both backends")
unittest
{
    auto shop = buildPath(fixtures, "uses-path", "shop");
    auto tool = buildPath(fixtures, "compiler-shape");
    foreach (backend; [["-b", "interpreter"], ["-b", "llvm"]])
    {
        expectRan(silver(["run"] ~ backend, shop), "25\n5\n");
        expectRan(silver(["run"] ~ backend, buildPath(shop, "src")), "25\n5\n");
        expectRan(silver(["run"] ~ backend, buildPath(tool, "compiler")), "parsed node 9\n");
        expectRan(silver(["run"] ~ backend, buildPath(tool, "compiler", "source")), "parsed node 9\n");
        expectRan(silver(["run"] ~ backend, buildPath(tool, "frontend")), "the front end\n");
    }
    auto p = plan("silverc", request(["run", "-b", "llvm"]), buildPath(shop, "src"));
    assert(p.program == "shop" && p.arguments[$ - 4 .. $] == ["--program", "shop", "-b", "llvm"], p.arguments.join(" "));
    assert(p.arguments.canFind("--scripts-in"), p.arguments.join(" "));
}

@("several programs are listed with their directories, and one is chosen by its directory")
unittest
{
    auto tool = buildPath(fixtures, "compiler-shape");
    expectRan(silver(["run"], tool), "Error L0015: The package 'tool' holds more than one program, so which to run has to "
        ~ "be said:\n  'tool.compiler', at compiler, whose `main` is in " ~ buildPath("compiler", "source", "main.ag")
        ~ "\n  'tool.frontend', at frontend, whose `main` is in " ~ buildPath("frontend", "main.ag") ~ "\nChoose one by "
        ~ "its directory, as `silver run compiler`\n", 1);
    assert(silver(["build"], tool).output.canFind("so which to build has to be said"));
    foreach (backend; [["-b", "interpreter"], ["-b", "llvm"]])
    {
        expectRan(silver(["run"] ~ backend ~ "compiler", tool), "parsed node 9\n");
        expectRan(silver(["run"] ~ backend ~ buildPath(tool, "frontend"), tempDir), "the front end\n");
    }
    expectRan(silver(["run", "compiler/source"], tool), "Error F0034: " ~ buildPath("compiler", "source")
        ~ " is a directory, and no package that silver.toml describes is there, so it has no program to run. Its packages "
        ~ "are 'tool' at ., 'tool.ast' at ast, 'tool.syntax' at syntax, 'tool.compiler' at compiler, 'tool.frontend' at "
        ~ "frontend; name one of those directories, or a file\n", 1);
    expectRan(silver(["run", "compiler", "x"], tool), "`x` follows the directory compiler, and what follows it is for the "
        ~ "program, which can't be given arguments yet.\n", 1);
}

@("a package with a main of its own that describes a program lists its own as chosen by its file, and the other by its directory")
unittest
{
    auto directory = makeTree("frontend-root-and-described-programs", [
        "silver.toml": "name = \"par\"\nsource = \"src\"\n\n[[package]]\nname = \"par.tool\"\npath = \"tool\"\n",
        "src/main.ag": "module par.main\n\ndef main(): Unit {\n    printl(\"par\")\n}\n",
        "tool/main.ag": "module par.tool.main\n\ndef main(): Unit {\n    printl(\"tool\")\n}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    expectRan(silver(["run"], directory), "Error L0015: The package 'par' holds more than one program, so which to run "
        ~ "has to be said:\n  'par' itself, whose `main` is in " ~ buildPath("src", "main.ag") ~ ", chosen by naming that "
        ~ "file\n  'par.tool', at tool, whose `main` is in " ~ buildPath("tool", "main.ag") ~ "\nChoose one by its "
        ~ "directory, as `silver run tool`, or the program of 'par' itself by its file, as `silver run "
        ~ buildPath("src", "main.ag") ~ "`\n", 1);
    expectRan(silver(["run", "tool"], directory), "tool\n");
    expectRan(silver(["run", buildPath("src", "main.ag")], directory), "par\n");
}

@("a library given to run says it's a library, and that its tests are run with silver test")
unittest
{
    immutable message = "Error L0014: The package 'tool.ast' is a library: none of its modules declares `main`, so it "
        ~ "has no program to run\nIts tests are run with `silver test`\nA file with no `module` line is a program of its own, "
        ~ "and is run by naming it, as `silver run demo.ag`\n";
    expectRan(silver(["run"], buildPath(fixtures, "compiler-shape", "ast")), message, 1);
    expectRan(silver(["run", "ast"], buildPath(fixtures, "compiler-shape")), message, 1);
    // A library's scripts beside it are programs of their own, not the library's.
    assert(silver(["run"], buildPath(fixtures, "scripts", "shapes")).output.canFind("'shapes' is a library"));
}

@("silver build with no file names the executable after the package, and -o still says where")
unittest
{
    import std.file : remove;

    auto shop = buildPath(fixtures, "uses-path", "shop");
    auto built = buildPath(shop, "shop" ~ exe);
    if (exists(built)) remove(built);
    expectRan(silver(["build"], shop), "");
    scope (exit) remove(built);
    expectRan(runIn([built], tempDir), "25\n5\n");

    auto directory = makeTree("frontend-build-no-file", null);
    scope (exit) rmdirRecurse(directory);
    auto output = buildPath(directory, "front" ~ exe);
    expectRan(silver(["build", "-o", output, "frontend"], buildPath(fixtures, "compiler-shape")), "");
    expectRan(runIn([output], directory), "the front end\n");
    // A described package's executable is named after the last segment of its name, in the working directory.
    expectRan(silver(["build", buildPath(fixtures, "compiler-shape", "frontend")], directory), "");
    expectRan(runIn([buildPath(directory, "frontend" ~ exe)], directory), "the front end\n");
    version (Posix)
    {
        // The default name is the package's directory, which isn't written over.
        expectRan(silver(["build", "frontend"], buildPath(fixtures, "compiler-shape")), "The executable would be "
            ~ "written to frontend, which is a directory: give where to write it with -o.\n", 1);
    }
}

@("with no path, silver test runs the tests of the package started in and of those it describes, on both backends")
unittest
{
    auto tool = buildPath(fixtures, "compiler-shape");
    foreach (backend; ["interpreter", "llvm", "both"])
    {
        expectRan(silver(["test", "-b", backend], tool), "2 passed, 0 failed\n");
        expectRan(silver(["test", "-b", backend], buildPath(tool, "ast")), "2 passed, 0 failed\n");
        expectRan(silver(["test", "-b", backend], buildPath(fixtures, "uses-path", "geometry")), "1 passed, 0 failed\n");
        expectRan(silver(["test", "-b", backend], buildPath(fixtures, "scripts", "shapes")), "2 passed, 0 failed\n");
    }
    // From inside a described package, only its tests.
    expectRan(silver(["test"], buildPath(tool, "compiler", "source")), "No tests found\n");
    auto p = plan("silverc", request(["test", "--filter", "node"]), buildPath(tool, "compiler", "source"));
    assert(p.arguments[$ - 3 .. $] == ["--filter", "node", buildPath(tool, "compiler")], p.arguments.join(" "));
    assert(p.scriptHomes == ["tool.compiler"]);
    assert(plan("silverc", request(["test"]), tool).arguments[$ - 1] == ".");
}

@("silver test --format json with no path is one JSON document")
unittest
{
    import std.json : parseJSON;

    auto ran = silver(["test", "--format", "json", "-b", "both"], buildPath(fixtures, "compiler-shape"));
    assert(ran.status == 0, ran.output);
    auto report = parseJSON(ran.output);
    assert(report["summary"]["passed"].integer == 2, ran.output);
}

@("with no file and no project, silver says there's nothing here and runs nothing")
unittest
{
    auto directory = makeTree("frontend-no-file-no-project", null);
    scope (exit) rmdirRecurse(directory);
    expectRan(silver(["run"], directory), "Error F0033: There's no silver.toml in " ~ directory ~ " or any directory "
        ~ "above it, so there's no project here to run: name a file, as `silver run hello.ag`\n", 1);
    assert(silver(["test", "-b", "llvm"], directory).output.startsWith("Error F0033: "));
    auto help = silver(["build", "--help"], directory);
    assert(help.status == 0 && help.output.startsWith("Usage: silver build"), help.output);
}

@("silver test over a directory leaves out a project of its own inside it, and still tests one the project uses")
unittest
{
    auto directory = makeTree("frontend-script-nested-project", [
        "outer/silver.toml": "name = \"outer\"
source = \"src\"
uses = [\"used\"]
[[package]]
path = \"used\"
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

/// Whether `message` names no command-line option, as `--uses`.
bool mentionsNoOption(string message)
{
    import std.regex : matchFirst, regex;

    return message.matchFirst(regex(`--[a-z]`)).empty;
}

@("silver run from inside a package tells a file whose module line names no package the name its path gives it")
unittest
{
    auto directory = makeTree("frontend-module-line", [
        "geometry/silver.toml": "name = \"geometry\"",
        "geometry/w.ag": "module w\n\ndef main(): Unit {}\n",
        "geometry/shapes/c.ag": "module c\n\ndef main(): Unit {}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto geometry = buildPath(directory, "geometry");
    immutable w = "w.ag(1,1): Error L0003: Module 'w' is in no package: no package is named 'w', or by any longer start "
        ~ "of 'w'\nw.ag is in the package 'geometry', at ., so its `module` line is `module geometry.w`\n";
    expectRan(silver(["w.ag"], geometry), w, 1);
    auto c = silver([buildPath("shapes", "c.ag")], geometry);
    assert(c.status == 1 && c.output.endsWith("so its `module` line is `module geometry.shapes.c`\n"), c.output);
    auto up = silver([buildPath("..", "w.ag")], buildPath(geometry, "shapes"));
    assert(up.status == 1 && up.output.endsWith("so its `module` line is `module geometry.w`\n"), up.output);
}

@("a file in no project that imports a package is told what to write in a silver.toml, and no option is named")
unittest
{
    auto directory = makeTree("frontend-lone-import", [
        "app.ag": "import geometry.area\n\ndef main(): Unit {}\n",
        "other.ag": "import geometry.area\n\ndef main(): Unit {}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    expectRan(silver(["app.ag"], directory), "app.ag(1,1): Error L0001: Module 'geometry.area' not found: no package is "
        ~ "named 'geometry', or by any longer start of 'geometry.area'\nA file in no project uses only the standard "
        ~ "library. To use 'geometry', put a `silver.toml` at or above it that names a package of its own, with "
        ~ "'geometry' in its `uses` and a `[[package]]` entry whose `path` is the directory of 'geometry', whose own "
        ~ "`silver.toml` names it\n", 1);
    auto tested = silver(["test", "."], directory);
    assert(tested.status == 1 && tested.output.canFind("To use 'geometry'") && mentionsNoOption(tested.output),
        tested.output);
}

@("a package listed from inside the directory of a package with no source is refused at its entry")
unittest
{
    auto directory = makeTree("frontend-nested-used", [
        "outer/silver.toml": "name = \"outer\"\nuses = [\"inner\"]\n\n[[package]]\npath = \"inner\"\n",
        "outer/main.ag": "def main(): Unit {}\n",
        "outer/inner/silver.toml": "name = \"inner\"\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto outer = buildPath(directory, "outer");
    expectRan(silver(["main.ag"], outer), "silver.toml(5,8): Error F0035: 'inner' is at " ~ buildPath(outer, "inner")
        ~ ", inside the directory of 'outer', at " ~ outer ~ ", whose modules are that whole directory, so a file of "
        ~ "'inner' would be a module of both; giving 'outer' a `source` directory below it avoids it\n", 1);
}

@("a syntax error in a module of a script's package is printed once, and a package option by hand in a project is refused")
unittest
{
    auto directory = makeTree("frontend-broken-helper", [
        "kit/silver.toml": "name = \"kit\"\n",
        "kit/good.ag": "module kit.good\n\ndef one(): Int => 1\n",
        "kit/bad.ag": "module kit.bad\n\ndef = broken\n",
        "kit/s.ag": "def main(): Unit {}\n",
        "kit/t.ag": "import kit.bad\n\ndef main(): Unit {}\n",
    ]);
    scope (exit) rmdirRecurse(directory);
    auto kit = buildPath(directory, "kit");
    foreach (script; ["s.ag", "t.ag"])
    {
        auto ran = silver([script], kit);
        assert(ran.status == 1 && ran.output.canFind("Error P0001") && ran.output.count("Error") == 1, ran.output);
    }
    expectRan(silver(["--uses", "kit", "s.ag"], kit), "Error F0036: --uses is given by hand, and inside a project "
        ~ "packages are described in its package file, silver.toml: what a package uses is its `uses`, and each "
        ~ "package it uses or describes is a `[[package]]` entry\n", 1);
}
