/// End-to-end tests of remote packages: bare repositories built in the temp directory from the files
/// here, fetched by path, so no test touches the network. Like `endtoend`, they run the built `silver`.
module silver.frontend.remotes;

version (unittest):

import silver.frontend : makeTree, removeTree;
import silver.frontend.endtoend : built, expectRan, Ran;
import silver.frontend.toml : quotedString;
import std.algorithm : canFind, count, startsWith;
import std.array : replace;
import std.file : exists, readText, write;
import std.path : buildPath;
static import std.process;

/// A repository to fetch from: commits are made in `work` and pushed to the bare `bare` beside it.
struct Repository
{
    string work;
    string bare;

    string git(string[] words)
    {
        auto ran = std.process.execute(["git", "-C", work, "-c", "user.name=t", "-c", "user.email=t@t", "-c",
            "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "core.autocrlf=false"] ~ words);
        assert(ran.status == 0, ran.output);
        return ran.output;
    }

    /// Writes `files` (path to text, null to remove), commits them and pushes, giving the commit.
    string commit(string[string] files)
    {
        import std.file : mkdirRecurse, remove;
        import std.path : dirName;

        foreach (path, text; files)
        {
            auto full = buildPath(work, path);
            if (text is null)
            {
                remove(full);
                continue;
            }
            mkdirRecurse(dirName(full));
            write(full, text);
        }
        git(["add", "-A"]);
        git(["commit", "-q", "--allow-empty", "-m", "c"]);
        push();
        return head();
    }

    string head()
    {
        import std.string : strip;

        return strip(git(["rev-parse", "HEAD"]));
    }

    /// Puts the annotated tag `name` at the current commit, moving it if it's there.
    void tag(string name)
    {
        git(["tag", "-f", "-a", name, "-m", name]);
        push();
    }

    void push()
    {
        git(["push", "-q", "--force", "--tags", bare, "main"]);
    }
}

/// A temporary directory with a cache of its own, removed at the end.
struct Scene
{
    string directory;
    string cache;
    /// Given to every run of silver.
    string[string] env;

    this(string name)
    {
        directory = makeTree("frontend-remote-" ~ name, null);
        cache = buildPath(directory, "cache");
    }

    void remove()
    {
        removeTree(directory);
    }

    Repository repository(string name, string[string] files, string[] format = null)
    {
        import std.file : mkdirRecurse;

        auto r = Repository(buildPath(directory, name), buildPath(directory, name ~ ".git"));
        mkdirRecurse(r.work);
        r.git(["init", "-q", "-b", "main"] ~ format);
        auto bare = std.process.execute(["git", "init", "-q", "--bare", "-b", "main"] ~ format ~ [r.bare]);
        assert(bare.status == 0, bare.output);
        r.commit(files);
        return r;
    }

    /// A program, `app` in the directory `name`, whose silver.toml has `entries` and uses `uses`, and whose main prints `printed`.
    string app(string name, string entries, string[] uses, string printed, string imports)
    {
        import std.file : mkdirRecurse;

        auto at = buildPath(directory, name);
        mkdirRecurse(at);
        write(buildPath(at, "silver.toml"), "name = \"app\"\nuses = [" ~ uses.joinQuoted ~ "]\n" ~ entries);
        write(buildPath(at, "main.ag"), "module app.main\n\n" ~ imports ~ "\ndef main(): Unit {\n    printl(" ~ printed
            ~ ")\n}\n\ntest \"a remote package\" => expect(" ~ printed ~ " != \"\")\n");
        return at;
    }

    Ran silver(string[] words, string workingDirectory, string[string] env = null)
    {
        string[string] all = ["SILVER_CACHE": cache];
        foreach (k, v; this.env) all[k] = v;
        foreach (k, v; env) all[k] = v;
        built("silverc");
        auto result = std.process.execute([built("silver")] ~ words, all, std.process.Config.none, size_t.max,
            workingDirectory);
        return Ran(result.status, result.output.replace("\r\n", "\n"));
    }
}

string joinQuoted(string[] names)
{
    string text;
    foreach (k, n; names) text ~= (k > 0 ? ", " : "") ~ "\"" ~ n ~ "\"";
    return text;
}

/// A `[[package]]` entry for `name` from `repository`, with `more` lines after its `git`.
string entry(string name, const Repository repository, string more = "")
{
    return "\n[[package]]\nname = \"" ~ name ~ "\"\ngit = " ~ quotedString(repository.bare) ~ "\n" ~ more;
}

/// The files of the package `deck`, whose `deckName()` is `label`. Its .gitattributes would have a
/// checkout write CRLF line endings, which the files fetched mustn't have; `raw.txt` is stored with
/// CRLF, which they must keep.
string[string] deckFiles(string label)
{
    return [
        "silver.toml": "name = \"deck\"\n",
        "cards.ag": "module deck.cards\n\ndef deckName(): String => \"" ~ label ~ "\"\n",
        ".gitattributes": "* text eol=crlf\nraw.txt -text\n",
        "raw.txt": "a\r\nb\r\n",
    ];
}

enum importDeck = "import deck.cards\n";

string fetching(string name, const Repository repository, string wanted, string commit)
    => "Fetching " ~ name ~ " from " ~ repository.bare ~ wanted ~ ", commit " ~ commit ~ "\n";

/// The lock's entries, without its header.
string lockOf(string app)
{
    auto text = readText(buildPath(app, "silver.lock"));
    auto start = text.length;
    foreach (k; 0 .. text.length)
    {
        if (text[k .. $].startsWith("[[package]]"))
        {
            start = k;
            break;
        }
    }
    assert(text.startsWith("# silver.lock: written by silver."), text);
    return text[start .. $];
}

string locked(string name, string git, string wanted, string commit, string hash, string path = null)
    => "[[package]]\nname = \"" ~ name ~ "\"\ngit = \"" ~ git ~ "\"\n" ~ (path is null ? "" : "path = \"" ~ path ~ "\"\n")
        ~ wanted ~ "commit = \"" ~ commit ~ "\"\nhash = \"" ~ hash ~ "\"\n";

/// The hash of `deckFiles("v1")`, fixed here so that every platform has to give the same one.
enum deckHash = "sha256-a03eecd35d3772f0cd3b4f778db73650ee4978836e3187da40cc1b3011e739cb";

@("a git entry with a tag is fetched once, with no line ending converted, locked with its commit and hash, and used on both backends; once fetched, git isn't needed")
unittest
{
    import std.datetime : SysTime;
    import std.file : read, timeLastModified;

    auto scene = Scene("tag");
    scope (exit) scene.remove();
    auto deck = scene.repository("deck", deckFiles("v1"));
    deck.tag("v1");
    auto commit = deck.head();
    auto app = scene.app("app", entry("deck", deck, "tag = \"v1\"\n"), ["deck"], "deckName()", importDeck);
    // What an interrupted fetch left a day ago is swept; what one may be writing now isn't.
    import core.time : days;
    import std.datetime.systime : Clock;
    import std.file : mkdirRecurse, setTimes;

    auto stale = buildPath(scene.cache, "tmp", "4f1c2a9e0b7d3c58e6a1f92d4b0c7e3a5d8f1b26-123-456");
    auto fresh = buildPath(scene.cache, "tmp", "fresh");
    mkdirRecurse(stale);
    mkdirRecurse(fresh);
    setTimes(stale, Clock.currTime() - 2.days, Clock.currTime() - 2.days);

    expectRan(scene.silver(["-b", "interpreter", "main.ag"], app), fetching("deck", deck, ", tag = \"v1\"", commit)
        ~ "v1\n");
    assert(lockOf(app) == locked("deck", "../deck.git", "tag = \"v1\"\n", commit, deckHash), lockOf(app));
    immutable written = timeLastModified(buildPath(app, "silver.lock"));

    // The files are git's bytes: LF where a checkout would have written CRLF, and CRLF where git stores it.
    auto files = buildPath(scene.cache, "git", commit, "files");
    assert(read(buildPath(files, "cards.ag")) == "module deck.cards\n\ndef deckName(): String => \"v1\"\n");
    assert(read(buildPath(files, "raw.txt")) == "a\r\nb\r\n");
    assert(readText(buildPath(scene.cache, "git", commit, "hash")) == deckHash ~ "\n");
    version (Posix)
    {
        import std.file : getAttributes;

        assert((getAttributes(buildPath(files, "cards.ag")) & octal!222) == 0, "a fetched file is writable");
    }
    assert(!exists(stale) && exists(fresh));
    removeTree(fresh);
    assert(isEmptyDirectory(buildPath(scene.cache, "tmp")));

    expectRan(scene.silver(["-b", "llvm", "main.ag"], app), "v1\n");
    expectRan(scene.silver(["run"], app), "v1\n");
    expectRan(scene.silver(["test", "-b", "both"], app), "1 passed, 0 failed\n");
    auto output = buildPath(scene.directory, "app-built" ~ exeSuffix);
    expectRan(scene.silver(["build", "-o", output], app), "");
    expectRan(runOutput(output), "v1\n");
    assert(timeLastModified(buildPath(app, "silver.lock")) == written, "the lock was written again");

    // Everything is fetched, so git isn't needed; with a cache that's empty, it is, and the message says so.
    expectRan(scene.silver(["main.ag"], app, ["PATH": ""]), "v1\n");
    auto ran = scene.silver(["main.ag"], app, ["PATH": "", "SILVER_CACHE": buildPath(scene.directory, "empty")]);
    assert(ran.status == 1 && ran.output.canFind("\nsilver.toml(6,7): Error F0046: 'deck' can't be fetched, since git "
        ~ "isn't on the PATH, and silver fetches a remote package with it"), ran.output);
}

bool isEmptyDirectory(string directory)
{
    import std.file : dirEntries, SpanMode;

    foreach (_; dirEntries(directory, SpanMode.shallow)) return false;
    return true;
}

import std.conv : octal;

version (Windows) enum exeSuffix = ".exe";
else enum exeSuffix = "";

Ran runOutput(string program)
{
    auto result = std.process.execute([program]);
    return Ran(result.status, result.output.replace("\r\n", "\n"));
}

@("a locked package stays at its commit when its tag or branch moves, an entry that changes is fetched again alone, one nothing uses stays locked, and one no silver.toml names is dropped")
unittest
{
    import std.file : remove;

    auto scene = Scene("moves");
    scope (exit) scene.remove();
    auto deck = scene.repository("deck", deckFiles("v1"));
    deck.tag("v1");
    auto v1 = deck.head();
    // A package described by the silver.toml above its directory in the repository.
    auto games = scene.repository("cardgames", [
        "silver.toml": "name = \"cardgames\"\n\n[[package]]\nname = \"cardgames.cards\"\npath = \"cards\"\n",
        "cards/suit.ag": "module cardgames.cards.suit\n\ndef suit(): String => \"hearts\"\n",
    ]);
    auto hearts = games.head();
    auto entries = entry("deck", deck, "tag = \"v1\"\n") ~ entry("cardgames.cards", games, "path = \"cards\"\nbranch = \"main\"\n");
    auto app = scene.app("app", entries, ["deck", "cardgames.cards"], "deckName() ~ \" \" ~ suit()",
        importDeck ~ "import cardgames.cards.suit\n");
    auto ran = scene.silver(["main.ag"], app);
    assert(ran.status == 0 && ran.output.canFind(fetching("cardgames.cards", games, ", branch = \"main\"", hearts))
        && ran.output.canFind(fetching("deck", deck, ", tag = \"v1\"", v1)) && ran.output.canFind("\nv1 hearts\n"),
        ran.output);
    auto gamesLocked = locked("cardgames.cards", "../cardgames.git", "branch = \"main\"\n", hearts,
        lockedHash(app, "cardgames.cards"), "cards");
    assert(lockOf(app) == gamesLocked ~ "\n" ~ locked("deck", "../deck.git", "tag = \"v1\"\n", v1, deckHash), lockOf(app));
    auto before = lockOf(app);

    // The tag and the branch move on; the lock keeps what it took.
    deck.commit(["cards.ag": "module deck.cards\n\ndef deckName(): String => \"v1 moved\"\n"]);
    deck.tag("v1");
    auto moved = deck.head();
    games.commit(["cards/suit.ag": "module cardgames.cards.suit\n\ndef suit(): String => \"spades\"\n"]);
    expectRan(scene.silver(["main.ag"], app), "v1 hearts\n");
    assert(lockOf(app) == before);

    // An entry that changes is fetched again, and only it: the branch keeps its commit.
    deck.tag("v2");
    write(buildPath(app, "silver.toml"), readText(buildPath(app, "silver.toml")).replace("tag = \"v1\"", "tag = \"v2\""));
    expectRan(scene.silver(["main.ag"], app), fetching("deck", deck, ", tag = \"v2\"", moved) ~ "v1 moved hearts\n");
    assert(lockOf(app) == gamesLocked ~ "\n" ~ locked("deck", "../deck.git", "tag = \"v2\"\n", moved,
        lockedHash(app, "deck")), lockOf(app));

    // An entry nothing uses is still the file's, so it stays locked.
    auto lockedNow = lockOf(app);
    write(buildPath(app, "silver.toml"), "name = \"app\"\nuses = [\"deck\"]\n" ~ entry("deck", deck, "tag = \"v2\"\n")
        ~ entry("cardgames.cards", games, "path = \"cards\"\nbranch = \"main\"\n"));
    write(buildPath(app, "main.ag"), "module app.main\n\n" ~ importDeck ~ "\ndef main(): Unit {\n    printl(deckName())\n}\n");
    expectRan(scene.silver(["main.ag"], app), "v1 moved\n");
    assert(lockOf(app) == lockedNow, lockOf(app));

    // One no silver.toml names is dropped.
    write(buildPath(app, "silver.toml"), "name = \"app\"\nuses = [\"deck\"]\n" ~ entry("deck", deck, "tag = \"v2\"\n"));
    expectRan(scene.silver(["main.ag"], app), "v1 moved\n");
    assert(lockOf(app) == locked("deck", "../deck.git", "tag = \"v2\"\n", moved, lockedHash(app, "deck")), lockOf(app));

    // With no lock, what the entries name now is taken.
    remove(buildPath(app, "silver.lock"));
    write(buildPath(app, "silver.toml"), readText(buildPath(app, "silver.toml")).replace("tag = \"v2\"", "tag = \"v1\""));
    expectRan(scene.silver(["main.ag"], app), "v1 moved\n");
}

/// The hash the lock of `app` has for `name`.
string lockedHash(string app, string name)
{
    import std.string : indexOf;

    auto text = readText(buildPath(app, "silver.lock"));
    auto at = text.indexOf("name = \"" ~ name ~ "\"");
    assert(at >= 0, text);
    auto hash = text[at .. $].indexOf("hash = \"");
    auto start = at + hash + "hash = \"".length;
    return text[start .. start + text[start .. $].indexOf('"')];
}

@("a rev and the default branch are taken, and a server that won't send a commit it doesn't advertise is fetched from whole")
unittest
{
    auto scene = Scene("revs");
    scope (exit) scene.remove();
    auto deck = scene.repository("deck", deckFiles("one"));
    auto one = deck.head();
    deck.commit(["cards.ag": "module deck.cards\n\ndef deckName(): String => \"two\"\n"]);
    auto two = deck.head();

    auto app = scene.app("app", entry("deck", deck), ["deck"], "deckName()", importDeck);
    expectRan(scene.silver(["main.ag"], app), fetching("deck", deck, "", two) ~ "two\n");
    assert(lockOf(app) == locked("deck", "../deck.git", "", two, lockedHash(app, "deck")), lockOf(app));

    // A SHA-256 repository's commit is fetched into one of its kind.
    auto wide = scene.repository("wide", deckFiles("wide"), ["--object-format=sha256"]);
    auto app3 = scene.app("app3", entry("deck", wide, "rev = \"" ~ wide.head() ~ "\"\n"), ["deck"], "deckName()",
        importDeck);
    assert(wide.head().length == 64);
    expectRan(scene.silver(["main.ag"], app3), fetching("deck", wide, ", rev = \"" ~ wide.head() ~ "\"", wide.head())
        ~ "wide\n");

    // Protocol version 0 refuses a commit that isn't a branch's or a tag's.
    auto app2 = scene.app("app2", entry("deck", deck, "rev = \"" ~ one ~ "\"\n"), ["deck"], "deckName()", importDeck);
    expectRan(scene.silver(["main.ag"], app2, ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.version",
        "GIT_CONFIG_VALUE_0": "0"]), fetching("deck", deck, ", rev = \"" ~ one ~ "\"", one) ~ "one\n");
    assert(lockOf(app2) == locked("deck", "../deck.git", "rev = \"" ~ one ~ "\"\n", one, lockedHash(app2, "deck")));
}

@("a remote package's own remote entries are followed as far as what it uses and locked beside the starting file, its own lock is ignored, and two entries that disagree are refused, naming both")
unittest
{
    import std.array : replace;

    auto scene = Scene("transitive");
    scope (exit) scene.remove();
    auto deck = scene.repository("deck", deckFiles("v1"));
    deck.tag("v1");
    auto v1 = deck.head();
    // A fetched package names its own packages by URL; here git takes this one's from the bare repository.
    enum deckUrl = "https://example.invalid/deck";
    scene.env = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "url." ~ deck.bare.replace("\\", "/") ~ ".insteadOf",
        "GIT_CONFIG_VALUE_0": deckUrl];
    // `spare` is one only its own tests would use: never fetched, since nothing maps its URL anywhere.
    auto table = scene.repository("table", [
        "silver.toml": "name = \"table\"\nuses = [\"deck\"]\n\n[[package]]\nname = \"deck\"\ngit = \"" ~ deckUrl
            ~ "\"\ntag = \"v1\"\n\n[[package]]\nname = \"spare\"\ngit = \"https://example.invalid/spare\"\n",
        "play.ag": "module table.play\n\nimport deck.cards\n\ndef play(): String => \"table of \" ~ deckName()\n",
        "silver.lock": "this isn't a lock",
    ]);
    auto app = scene.app("app", entry("table", table), ["table"], "play()", "import table.play\n");
    auto ran = scene.silver(["main.ag"], app);
    assert(ran.status == 0 && ran.output.canFind("\ntable of v1\n") && ran.output.count("Fetching") == 2
        && ran.output.canFind("Fetching deck from " ~ deckUrl ~ ", tag = \"v1\""), ran.output);
    assert(lockOf(app) == locked("deck", deckUrl, "tag = \"v1\"\n", v1, deckHash) ~ "\n"
        ~ locked("table", "../table.git", "", table.head(), lockedHash(app, "table")), lockOf(app));
    expectRan(scene.silver(["test"], app), "1 passed, 0 failed\n");
    assert(lockOf(app) == locked("deck", deckUrl, "tag = \"v1\"\n", v1, deckHash) ~ "\n"
        ~ locked("table", "../table.git", "", table.head(), lockedHash(app, "table")), lockOf(app));

    // Every run locks what the files name, whatever the command: here a package listed by its path, which
    // nothing the program uses, names a remote package that only its tests would use.
    import std.file : mkdirRecurse;

    auto withTools = buildPath(scene.directory, "withtools");
    mkdirRecurse(buildPath(scene.directory, "tools"));
    mkdirRecurse(withTools);
    write(buildPath(scene.directory, "tools", "silver.toml"), "name = \"tools\"\nuses = [\"table\"]\n" ~ entry("table", table));
    write(buildPath(withTools, "silver.toml"), "name = \"withtools\"\nuses = [\"deck\"]\n" ~ entry("deck", deck,
        "tag = \"v1\"\n") ~ "\n[[package]]\npath = \"../tools\"\n");
    write(buildPath(withTools, "main.ag"), "module withtools.main\n\n" ~ importDeck ~ "\ndef main(): Unit {\n"
        ~ "    printl(deckName())\n}\n");
    expectRan(scene.silver(["run"], withTools), "v1\n");
    auto toolsLock = locked("deck", "../deck.git", "tag = \"v1\"\n", v1, deckHash) ~ "\n"
        ~ locked("deck", deckUrl, "tag = \"v1\"\n", v1, deckHash) ~ "\n"
        ~ locked("table", "../table.git", "", table.head(), lockedHash(app, "table"));
    assert(lockOf(withTools) == toolsLock, lockOf(withTools));
    expectRan(scene.silver(["test"], withTools), "No tests found\n");
    assert(lockOf(withTools) == toolsLock, lockOf(withTools));

    // The same package at the same commit, written another way, agrees.
    auto agreeing = scene.app("agreeing", entry("table", table) ~ entry("deck", deck, "rev = \"" ~ v1 ~ "\"\n"), ["table", "deck"],
        "play() ~ deckName()", "import table.play\n" ~ importDeck);
    expectRan(scene.silver(["main.ag"], agreeing), "table of v1v1\n");

    // At another commit, it doesn't.
    deck.commit(["cards.ag": "module deck.cards\n\ndef deckName(): String => \"v2\"\n"]);
    deck.tag("v2");
    auto conflict = scene.app("conflict", entry("deck", deck, "tag = \"v2\"\n") ~ entry("table", table), ["deck", "table"],
        "play() ~ deckName()", "import table.play\n" ~ importDeck);
    ran = scene.silver(["main.ag"], conflict);
    auto cached = buildPath(scene.cache, "git", table.head(), "files", "silver.toml");
    assert(ran.status == 1 && ran.output.canFind("Error F0045: 'deck' is reached by the entry at line 4 of " ~ cached
        ~ ", git = \"" ~ deckUrl ~ "\", tag = \"v1\", which is commit " ~ v1 ~ ", and already by the entry "
        ~ "at line 4 of " ~ buildPath(conflict, "silver.toml") ~ ", git = " ~ quotedString(deck.bare) ~ ", tag = \"v2\", "
        ~ "which is commit " ~ deck.head() ~ "; a program holds one package of a name, from one source at one commit"),
        ran.output);
}

@("what's wrong with a package fetched is located at its entry: another name, a symbolic link, no such directory, a path outside the repository, a hash that isn't the lock's")
unittest
{
    auto scene = Scene("mistakes");
    scope (exit) scene.remove();
    auto deck = scene.repository("deck", deckFiles("v1"));
    auto commit = deck.head();

    auto app = scene.app("app", entry("dek", deck), ["dek"], "deckName()", importDeck);
    auto ran = scene.silver(["main.ag"], app);
    assert(ran.status == 1 && ran.output.canFind("silver.toml(5,8): Error F0044: This entry names the package 'dek', and "
        ~ buildPath(scene.cache, "git", commit, "files", "silver.toml") ~ ", which describes the package at the root of "
        ~ deck.bare ~ " at commit " ~ commit ~ ", names it 'deck'"), ran.output);
    assert(!exists(buildPath(app, "silver.lock")), "a run that failed wrote the lock");

    app = scene.app("app", entry("deck", deck, "path = \"nowhere\"\n"), ["deck"], "deckName()", importDeck);
    ran = scene.silver(["main.ag"], app);
    assert(ran.status == 1 && ran.output.canFind("silver.toml(7,8): Error F0021: The repository " ~ deck.bare
        ~ " at commit " ~ commit ~ " has no directory nowhere, the entry's `path`"), ran.output);

    // A symbolic link, made in the index so that it's one on every platform.
    auto linked = scene.repository("linked", deckFiles("v1"));
    import std.string : strip;

    auto target = buildPath(scene.directory, "link-target");
    write(target, "cards.ag");
    auto blob = strip(linked.git(["hash-object", "-w", target]));
    linked.git(["update-index", "--add", "--cacheinfo", "120000," ~ blob ~ ",link"]);
    linked.git(["commit", "-q", "-m", "link"]);
    linked.push();
    app = scene.app("app", entry("deck", linked), ["deck"], "deckName()", importDeck);
    ran = scene.silver(["main.ag"], app);
    assert(ran.status == 1 && ran.output.canFind("silver.toml(6,7): Error F0043: 'deck' can't be fetched: The repository "
        ~ "holds a symbolic link, link, at commit " ~ linked.head()), ran.output);

    auto leaky = scene.repository("leaky", [
        "silver.toml": "name = \"leaky\"\nuses = [\"near\"]\n\n[[package]]\npath = \"..\"\n",
        "leak.ag": "module leaky.leak\n\ndef leak(): String => \"x\"\n",
    ]);
    app = scene.app("app", entry("leaky", leaky), ["leaky"], "leak()", "import leaky.leak\n");
    ran = scene.silver(["main.ag"], app);
    assert(ran.status == 1 && ran.output.canFind("silver.toml(5,8): Error F0048: This package was fetched, and its "
        ~ "entries stay in its repository") && ran.output.canFind("\nIt was fetched for the entry at line 4 of "
        ~ buildPath(app, "silver.toml")), ran.output);

    // A fetched package's remote entry can't name a directory, which is one on its author's machine.
    auto local = scene.repository("local", [
        "silver.toml": "name = \"local\"\nuses = [\"deck\"]\n" ~ entry("deck", deck),
        "near.ag": "module local.near\n\nimport deck.cards\n\ndef near(): String => deckName()\n",
    ]);
    app = scene.app("app", entry("local", local), ["local"], "near()", "import local.near\n");
    ran = scene.silver(["main.ag"], app);
    assert(ran.status == 1 && ran.output.canFind("silver.toml(6,7): Error F0048: This package was fetched, and its "
        ~ "remote entries name repositories by URL") && ran.output.canFind("\nIt was fetched for the entry at line 4 of "
        ~ buildPath(app, "silver.toml")), ran.output);

    // A hash in the lock that isn't the files' is refused.
    app = scene.app("app", entry("deck", deck), ["deck"], "deckName()", importDeck);
    expectRan(scene.silver(["main.ag"], app), "v1\n");
    auto lock = buildPath(app, "silver.lock");
    write(lock, readText(lock).replace(deckHash, "sha256-0000"));
    ran = scene.silver(["main.ag"], app);
    assert(ran.status == 1 && ran.output.canFind("silver.toml(6,7): Error F0047: The files of 'deck' at commit " ~ commit
        ~ ", in " ~ buildPath(scene.cache, "git", commit) ~ ", have the hash " ~ deckHash ~ ", and "), ran.output);
}
