/// What the suite generators share: reading a checkout's files as committed, writing a Silver
/// string literal, and writing the generated file.
module suites;

import core.thread : Thread;
import std.algorithm : map;
import std.array : appender, array, join, split;
import std.conv : to;
import std.format : format;
import std.path : buildNormalizedPath, dirName;
import std.process : execute, pipeProcess, Redirect, wait;
import std.stdio : File, writeln;
import std.string : strip;
import std.utf : toUTF32, validate, UTFException;

/// A checkout's HEAD commit and its files' bytes by path, as committed: read as raw blobs, which no
/// line-ending conversion (core.autocrlf) or other filter touches, as it would a working tree or
/// `git archive`.
struct Committed
{
    string commit;
    immutable(ubyte)[][string] files;
}

Committed committed(string checkout)
{
    string git(string[] args...)
    {
        auto result = execute(["git", "-C", checkout] ~ args);
        if (result.status != 0) throw new Exception("git " ~ args.join(" ") ~ " failed: " ~ result.output);
        return result.output;
    }

    Committed c;
    c.commit = git("rev-parse", "HEAD").strip;
    string[][string] paths;
    foreach (entry; git("ls-tree", "-r", "-z", c.commit).split('\0'))
    {
        if (entry.length == 0) continue;
        auto tab = entry.split('\t');
        auto info = tab[0].split(' ');
        if (info[1] == "blob") paths[info[2]] ~= tab[1 .. $].join("\t");
    }
    auto blobs = paths.keys;
    auto git_ = pipeProcess(["git", "-C", checkout, "cat-file", "--batch"], Redirect.stdin | Redirect.stdout);
    // Written from another thread, since cat-file answers as it reads and would fill the pipe back.
    auto writer = new Thread({
        foreach (blob; blobs) git_.stdin.write(blob, "\n");
        git_.stdin.close();
    }).start();
    auto output = appender!(ubyte[]);
    foreach (chunk; git_.stdout.byChunk(1 << 16)) output ~= chunk;
    writer.join();
    if (wait(git_.pid) != 0) throw new Exception("git cat-file failed");
    auto data = output[];
    size_t at = 0;
    while (at < data.length)
    {
        size_t headerEnd = at;
        while (data[headerEnd] != '\n') headerEnd++;
        auto header = (cast(string) data[at .. headerEnd]).split(' ');
        immutable size = header[2].to!size_t;
        immutable blob = data[headerEnd + 1 .. headerEnd + 1 + size].idup;
        foreach (path; paths[header[0]]) c.files[path] = blob;
        at = headerEnd + 1 + size + 1;
    }
    return c;
}

/// `data` as text, or null when it isn't valid UTF-8.
string utf8(immutable(ubyte)[] data)
{
    auto text = cast(string) data;
    try
    {
        validate(text);
    }
    catch (UTFException)
    {
        return null;
    }
    return text.length == 0 ? "" : text;
}

/// A Silver string literal for `text`, with long runs of a short unit written with `repeat`.
string silverString(string text)
{
    dstring chars = text.toUTF32;
    string[] pieces;
    dchar[] literal;
    size_t i = 0;
    while (i < chars.length)
    {
        size_t bestPeriod, bestCount;
        foreach (period; 1 .. 9)
        {
            if (i + period > chars.length) break;
            auto unit = chars[i .. i + period];
            size_t count = 1;
            while (i + (count + 1) * period <= chars.length && chars[i + count * period .. i + (count + 1) * period] == unit)
                count++;
            if (period * count >= 64 && (bestPeriod == 0 || period * count > bestPeriod * bestCount))
            {
                bestPeriod = period;
                bestCount = count;
            }
        }
        if (bestPeriod)
        {
            if (literal.length)
            {
                pieces ~= quote(literal);
                literal = null;
            }
            pieces ~= format!`%s.repeat().take(%s).join("")`(quote(chars[i .. i + bestPeriod]), bestCount);
            i += bestPeriod * bestCount;
        }
        else
        {
            literal ~= chars[i];
            i++;
        }
    }
    if (literal.length || pieces.length == 0) pieces ~= quote(literal);
    return pieces.join(" ~ ");
}

private string quote(const(dchar)[] text)
{
    auto out_ = appender!string;
    out_ ~= '"';
    foreach (c; text)
    {
        switch (c)
        {
            case '"': out_ ~= `\"`; break;
            case '\\': out_ ~= `\\`; break;
            case '{': out_ ~= `\{`; break;
            case '}': out_ ~= `\}`; break;
            default:
                if (c >= ' ' && c <= '~') out_ ~= c;
                else out_ ~= format!`\u{%x}`(cast(uint) c);
        }
    }
    out_ ~= '"';
    return out_[];
}

/// `data` as Silver's array of bytes.
string byteList(immutable(ubyte)[] data) => data.map!(b => format!"0x%02x"(b)).join(", ");

/// The license as comment lines.
string[] licenseComment(immutable(ubyte)[] license)
{
    string[] lines;
    foreach (line; (cast(string) license).strip.split('\n'))
    {
        line = line.strip("\r");
        lines ~= line.length ? "// " ~ line : "//";
    }
    return lines;
}

/// Writes `lines` to `conformance/stdlib/<name>`, beside this file's folder.
void writeSuite(string thisFile, string name, string[] lines, size_t cases)
{
    auto target = buildNormalizedPath(dirName(thisFile), "..", "stdlib", name);
    auto text = lines.join("\n");
    while (text.length && text[$ - 1] == '\n') text = text[0 .. $ - 1];
    auto file = File(target, "wb");
    file.write(text, "\n");
    file.close();
    writeln("wrote ", cases, " cases to ", target);
}
