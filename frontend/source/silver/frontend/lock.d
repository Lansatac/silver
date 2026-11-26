/// `silver.lock`: the commit and hash taken for each remote package, read and written.
module silver.frontend.lock;

import silver.frontend.git : fullHash, Want, Wanted;
import silver.frontend.toml;

/// The name of the lock, beside the package file a run starts from.
enum lockFileName = "silver.lock";

/// The code of a mistake in what a lock says.
enum lockCode = "F0049";

/// One remote entry as it was written, and what it was taken to be.
struct Locked
{
    string name;
    /// The entry's `git`: as written for a URL, and for a directory on this machine as a path from the
    /// lock's directory, with `/`.
    string git;
    /// The entry's `path` inside the repository, or null.
    string path;
    Wanted wanted;
    string commit;
    string hash;
}

/// Whether `a` and `b` are written the same, so one's commit is the other's.
bool sameEntry(const Locked a, const Locked b)
    => a.name == b.name && a.git == b.git && a.path == b.path && a.wanted == b.wanted;

/// The order a lock lists its entries in: by name, then as written.
bool before(const Locked a, const Locked b)
{
    import std.typecons : tuple;

    return tuple(a.name, a.git, a.path, cast(int) a.wanted.want, a.wanted.name)
        < tuple(b.name, b.git, b.path, cast(int) b.wanted.want, b.wanted.name);
}

/// `entries`, sorted and each once.
Locked[] tidied(const Locked[] entries)
{
    import std.algorithm : sort;

    auto sorted = entries.dup;
    sorted.sort!((a, b) => before(a, b));
    Locked[] once;
    foreach (e; sorted)
    {
        if (once.length == 0 || !sameEntry(once[$ - 1], e)) once ~= e;
    }
    return once;
}

/// The text of a lock holding `entries`, which are tidied.
string lockText(const Locked[] entries)
{
    auto root = new Table(Origin.header);
    auto list = Value(ValueKind.array);
    foreach (e; entries)
    {
        auto table = new Table(Origin.header);
        void add(string key, string value)
        {
            if (value !is null) table.entries ~= Entry(key, Span(), stringValue(value));
        }
        add("name", e.name);
        add("git", e.git);
        add("path", e.path);
        final switch (e.wanted.want)
        {
            case Want.defaultBranch: break;
            case Want.tag: add("tag", e.wanted.name); break;
            case Want.branch: add("branch", e.wanted.name); break;
            case Want.rev: add("rev", e.wanted.name); break;
        }
        add("commit", e.commit);
        add("hash", e.hash);
        auto item = Value(ValueKind.table);
        item.table = table;
        list.items ~= item;
    }
    if (list.items.length > 0) root.entries ~= Entry("package", Span(), list);
    return writeToml(root, "# silver.lock: written by silver. Each remote package is kept at its commit until its\n"
        ~ "# entry in silver.toml changes.\n");
}

/// What the lock `text` holds, or where it's wrong: a code, a place and what's wrong.
bool readLock(string text, out Locked[] entries, out string code, out Span span, out string message)
{
    auto document = readToml(text);
    if (document.failed)
    {
        code = document.error.code;
        span = document.error.span;
        message = document.error.message;
        return false;
    }
    bool fail(Span at, string what)
    {
        code = lockCode;
        span = at;
        message = what ~ "; silver writes this file, and deleting it has every remote package fetched again";
        return false;
    }
    foreach (ref top; document.root.entries)
    {
        if (top.key != "package" || top.value.kind != ValueKind.array)
            return fail(top.keySpan, "A lock holds only `[[package]]` entries, and `" ~ top.key ~ "` isn't one");
        foreach (ref item; top.value.items)
        {
            if (item.kind != ValueKind.table) return fail(item.span, "Each `package` of a lock is a table");
            Locked e;
            int wants;
            foreach (ref field; item.table.entries)
            {
                if (field.value.kind != ValueKind.string_)
                    return fail(field.value.span, "`" ~ field.key ~ "` in a lock is a string");
                auto value = field.value.text;
                switch (field.key)
                {
                    case "name": e.name = value; break;
                    case "git": e.git = value; break;
                    case "path": e.path = value; break;
                    case "tag": e.wanted = Wanted(Want.tag, value); wants++; break;
                    case "branch": e.wanted = Wanted(Want.branch, value); wants++; break;
                    case "rev": e.wanted = Wanted(Want.rev, value); wants++; break;
                    case "commit": e.commit = value; break;
                    case "hash": e.hash = value; break;
                    default: return fail(field.keySpan, "`" ~ field.key ~ "` isn't a field of a lock's entry");
                }
            }
            if (e.name is null || e.git is null || e.commit is null || e.hash is null)
                return fail(item.span, "An entry of a lock has a `name`, `git`, `commit` and `hash`");
            if (wants > 1) return fail(item.span, "An entry of a lock has at most one of `tag`, `branch` and `rev`");
            if (!fullHash(e.commit)) return fail(item.span, "An entry's `commit` is a full hash");
            entries ~= e;
        }
    }
    return true;
}

@("a lock is written sorted, each entry once, and read back the same")
unittest
{
    auto a = Locked("b.pkg", "https://h/b", null, Wanted(Want.tag, "v1"), "4f1c2a9e0b7d3c58e6a1f92d4b0c7e3a5d8f1b26",
        "sha256-00");
    auto b = Locked("a.pkg", "../repo", "cards", Wanted(Want.defaultBranch), "5f1c2a9e0b7d3c58e6a1f92d4b0c7e3a5d8f1b26",
        "sha256-11");
    auto text = lockText(tidied([a, b, a]));
    assert(text == "# silver.lock: written by silver. Each remote package is kept at its commit until its\n"
        ~ "# entry in silver.toml changes.\n\n"
        ~ "[[package]]\nname = \"a.pkg\"\ngit = \"../repo\"\npath = \"cards\"\n"
        ~ "commit = \"5f1c2a9e0b7d3c58e6a1f92d4b0c7e3a5d8f1b26\"\nhash = \"sha256-11\"\n\n"
        ~ "[[package]]\nname = \"b.pkg\"\ngit = \"https://h/b\"\ntag = \"v1\"\n"
        ~ "commit = \"4f1c2a9e0b7d3c58e6a1f92d4b0c7e3a5d8f1b26\"\nhash = \"sha256-00\"\n", text);
    Locked[] read;
    string code, message;
    Span span;
    assert(readLock(text, read, code, span, message), message);
    assert(read == [b, a]);
    assert(readLock("", read, code, span, message) && read.length == 0);
    assert(!readLock("[[package]]\nname = \"a\"\n", read, code, span, message) && code == lockCode && span.line == 1);
    assert(!readLock("name = 1\n", read, code, span, message) && code == lockCode);
    assert(!readLock("[[package]\n", read, code, span, message) && code != lockCode);
}
