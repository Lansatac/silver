/// Checks that the hand-written parser and Pegged's agree on every Silver file in the repository:
/// the same AST, field by field and span by span, or both rejecting it.
module silver.syntax.differential;

version (unittest):

import std.array : Appender;
import std.format : format;
import silver.ast;
import silver.syntax.parse : parseWith, ParseException, ParserChoice;

/// Every node and value in `m`, with every span, but not the IDs, which needn't be numbered alike.
string dump(const Module m)
{
    Appender!string output;
    dumpValue(output, m);
    return output[];
}

private void dumpValue(T)(ref Appender!string output, auto ref const T value)
{
    import std.sumtype : isSumType, match;
    import std.traits : isArray, isPointer, isSomeString;

    static if (is(T == Span))
    {
        output.put(format("@%s-%s", value.start, value.end));
    }
    else static if (is(T == Id!N, N))
    {
        output.put(value.isValid ? "id" : "noid");
    }
    else static if (is(T == InterpolatedString))
    {
        // Pegged's spans for a run of text leave out the spaces it ends with, so only its value is compared.
        output.put("InterpolatedString(");
        foreach (ref part; value.parts)
        {
            part.kind.match!(
                (ref const StringLiteral text) => dumpValue(output, text),
                (ref const _) => dumpValue(output, part),
            );
            output.put(",");
        }
        output.put(")");
    }
    else static if (is(T == Module))
    {
        // Pegged ends a module's span wrongly after a `'"'` character literal, and nothing reads it.
        dumpValue(output, value.declarations);
        dumpValue(output, value.declaration);
        dumpValue(output, value.library);
    }
    else static if (isSumType!T)
    {
        value.match!((ref const v) => dumpValue(output, v));
    }
    else static if (is(T == struct))
    {
        output.put(T.stringof ~ "(");
        foreach (i, ref field; value.tupleof)
        {
            output.put(__traits(identifier, T.tupleof[i]) ~ "=");
            dumpValue(output, field);
            output.put(" ");
        }
        output.put(")");
    }
    else static if (isPointer!T)
    {
        if (value is null) output.put("null");
        else dumpValue(output, *value);
    }
    else static if (isSomeString!T)
    {
        // The lowering of Pegged's tree numbers the local a `for` takes apart differently, and nothing can name it.
        import std.algorithm.searching : startsWith;
        if (value.startsWith("for.")) return output.put("for.N");
        output.put(format("%(%s%)", [value]));
    }
    else static if (isArray!T)
    {
        output.put("[");
        foreach (ref element; value)
        {
            dumpValue(output, element);
            output.put(",");
        }
        output.put("]");
    }
    else static if (is(T == double))
    {
        output.put(format("%a", value));
    }
    else
    {
        output.put(format("%s", value));
    }
}

/// The dump of what `parser` makes of `source`, or what it says when it rejects it.
string outcome(ParserChoice parser, string source, out bool rejected)
{
    rejected = false;
    try
    {
        return dump(parseWith(parser, source, "m", new NodeIds, "f"));
    }
    catch (ParseException e)
    {
        rejected = true;
        return "rejected: " ~ e.msg;
    }
}

/// Where the two dumps first differ, with some context.
string firstDifference(string a, string b)
{
    import std.algorithm : min;

    size_t i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) i++;
    auto from = i > 200 ? i - 200 : 0;
    return format("\n  pegged:       ...%s\n  hand-written: ...%s", a[from .. min(i + 200, $)], b[from .. min(i + 200, $)]);
}

/// The Silver files to compare: the repository's, and those under any directory listed in
/// `SILVER_PARSER_CORPUS`, separated by `:`.
string[] corpus()
{
    import std.algorithm : filter, map, sort, splitter;
    import std.array : array;
    import std.file : dirEntries, exists, SpanMode;
    import std.path : buildNormalizedPath, dirName;
    import std.process : environment;

    auto root = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..");
    auto directories = ["conformance", "stdlib", "exploration"].map!(d => buildNormalizedPath(root, d)).array;
    foreach (extra; environment.get("SILVER_PARSER_CORPUS", "").splitter(':'))
    {
        if (extra.length > 0) directories ~= extra;
    }
    string[] files;
    foreach (directory; directories.filter!exists)
    {
        foreach (entry; dirEntries(directory, "*.ag", SpanMode.depth)) files ~= entry.name;
    }
    files.sort();
    return files;
}

@("the hand-written parser and Pegged's agree on every Silver file in the repository")
unittest
{
    import std.file : readText;

    string[] problems;
    auto files = corpus();
    foreach (path; files)
    {
        auto source = readText(path);
        bool peggedRejected, handRejected;
        auto pegged = outcome(ParserChoice.pegged, source, peggedRejected);
        auto hand = outcome(ParserChoice.handWritten, source, handRejected);
        if (peggedRejected && handRejected) continue;
        if (pegged != hand) problems ~= path ~ firstDifference(pegged, hand);
    }
    assert(files.length > 100, "found only %s files".format(files.length));
    assert(problems.length == 0, format("%s of %s files differ:\n%-(%s\n%)", problems.length, files.length, problems));
}

@("the parsers agree when a space becomes a line break or a line break a space, if SILVER_PARSER_MUTATIONS is set")
unittest
{
    import std.conv : to;
    import std.file : readText;
    import std.process : environment;

    auto perFile = environment.get("SILVER_PARSER_MUTATIONS", "0").to!size_t;
    if (perFile == 0) return;
    string[] problems;
    size_t tried;
    foreach (path; corpus())
    {
        auto source = readText(path);
        size_t[] sites;
        foreach (i, c; source)
        {
            if (c == ' ' || c == '\n') sites ~= i;
        }
        auto stride = sites.length / perFile + 1;
        for (size_t s = 0; s < sites.length; s += stride)
        {
            auto i = sites[s];
            auto mutated = source[0 .. i] ~ (source[i] == ' ' ? "\n" : " ") ~ source[i + 1 .. $];
            tried++;
            bool peggedRejected, handRejected;
            auto pegged = outcome(ParserChoice.pegged, mutated, peggedRejected);
            auto hand = outcome(ParserChoice.handWritten, mutated, handRejected);
            if (peggedRejected && handRejected) continue;
            if (pegged != hand)
            {
                auto line = mutated[i > 60 ? i - 60 : 0 .. i + 40 < $ ? i + 40 : $];
                problems ~= format("%s at %s (%s):\n%s\n%s", path, i, source[i] == ' ' ? "line break" : "space", line,
                    peggedRejected || handRejected ? (peggedRejected ? "pegged: " ~ pegged : "hand-written: " ~ hand)[0 .. $ < 300 ? $ : 300]
                        : firstDifference(pegged, hand));
            }
        }
    }
    assert(problems.length == 0, format("%s of %s mutations differ:\n%-(%s\n\n%)", problems.length, tried, problems));
}
