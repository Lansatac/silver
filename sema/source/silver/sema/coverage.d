/// Whether a `match` covers every value of its subject, and which of its arms can never run.
/// This is the usefulness algorithm over a matrix of patterns, one row per arm.
module silver.sema.coverage;

import std.algorithm;
import std.array;
import std.format : format;
import std.range : repeat;
import std.sumtype;

import silver.ast;
import silver.sema.declare;
import silver.sema.type;

/// A pattern as coverage sees it: a head (null for one that matches anything) and what's under it.
package struct CoveragePattern
{
    string head;
    CoveragePattern[] args;
}

/// One of the shapes a type's values come in, and the types of what's inside it.
private struct PatternHead
{
    string key;
    string label;
    const(Type)[] args;
    /// A declared sum an error list names, whose own members are what's written.
    bool transparent;

    string render(const(string)[] parts) const
    {
        if (transparent) return parts[0] == "_" ? "_: " ~ label : parts[0];
        return label ~ (parts.length > 0 ? "(" ~ parts.join(", ") ~ ")" : "");
    }
}
/// Reports each of `match_`'s arms that the ones before it already cover, and the values of
/// `subject` that none of them do. `patterns` are the arms' patterns, in order.
package void checkCoverage(const MatchExpr match_, CoveragePattern[] patterns, Type subject, Span span,
    TypeTable types, Declarer declarer, Collector collector)
{
    Coverage(types, declarer, collector).check(match_, patterns, subject, span);
}

private struct Coverage
{
    private TypeTable _types;
    private Declarer _declarer;
    private Collector _collector;

    /// Every shape `type`'s values come in, or nothing if there are too many to list, as for an integer.
    private PatternHead[] headsOf(Type type)
    {
        if (type == _types.bool_) return [PatternHead("false", "false"), PatternHead("true", "true")];
        return _types[type].match!(
            (const OptionData option) => [PatternHead("none", "None"), PatternHead("some", "Some", [option.inner])],
            (const ErrorUnionData u) => [PatternHead("error", "Error", [u.error]), PatternHead("ok", "Ok", [u.success])],
            (const ErrorListData list) {
                PatternHead[] heads;
                foreach (i, member; list.members)
                {
                    auto key = "member%s".format(i);
                    if (_declarer.isSum(member)) heads ~= PatternHead(key, _types.describe(member), [member], true);
                    else heads ~= PatternHead(key, _types.describe(member), _declarer.fieldsOf(member).map!(f => f.type).array);
                }
                return heads;
            },
            (const TupleData tuple) => [PatternHead("tuple", "", tuple.elements)],
            (const NominalData nominal) {
                auto members = _declarer.membersOf(type);
                if (members.length == 0)
                {
                    return [PatternHead("product", _types.describe(type), _declarer.fieldsOf(type).map!(f => f.type).array)];
                }
                PatternHead[] heads;
                foreach (i, member; members)
                {
                    auto fields = _declarer.fieldsOf(member);
                    heads ~= PatternHead("member%s".format(i), _types.describe(member), fields.map!(f => f.type).array);
                }
                return heads;
            },
            _ => PatternHead[].init,
        );
    }

    private static CoveragePattern[][] specialize(CoveragePattern[][] rows, string key, size_t arity)
    {
        CoveragePattern[][] result;
        foreach (row; rows)
        {
            if (row[0].head is null) result ~= new CoveragePattern[arity] ~ row[1 .. $].dup;
            else if (row[0].head == key) result ~= row[0].args.dup ~ row[1 .. $].dup;
        }
        return result;
    }

    private static CoveragePattern[][] defaults(CoveragePattern[][] rows)
    {
        return rows.filter!(row => row[0].head is null).map!(row => row[1 .. $].dup).array;
    }

    private static bool usesAll(const PatternHead[] heads, CoveragePattern[][] rows)
    {
        return heads.length > 0 && heads.all!(h => rows.any!(row => row[0].head == h.key));
    }

    /// Whether `row` matches a value no row of `rows` does. Each is a list of patterns for values of `types`.
    private bool isUseful(CoveragePattern[][] rows, CoveragePattern[] row, const(Type)[] types)
    {
        if (types.length == 0) return rows.length == 0;

        auto heads = headsOf(types[0]);
        auto rest = types[1 .. $];
        if (row[0].head !is null)
        {
            auto found = heads.find!(h => h.key == row[0].head);
            const(Type)[] inner = found.empty ? null : found.front.args;
            return isUseful(specialize(rows, row[0].head, row[0].args.length), row[0].args ~ row[1 .. $], inner ~ rest);
        }
        if (usesAll(heads, rows))
        {
            foreach (head; heads)
            {
                auto wildcards = new CoveragePattern[head.args.length];
                if (isUseful(specialize(rows, head.key, head.args.length), wildcards ~ row[1 .. $], head.args ~ rest)) return true;
            }
            return false;
        }
        return isUseful(defaults(rows), row[1 .. $], rest);
    }

    /// Finds values of `types` that no row matches, written as patterns in `witness`.
    private bool findUncovered(CoveragePattern[][] rows, const(Type)[] types, out string[] witness)
    {
        if (types.length == 0) return rows.length == 0;

        auto heads = headsOf(types[0]);
        auto rest = types[1 .. $];
        if (usesAll(heads, rows))
        {
            foreach (head; heads)
            {
                string[] parts;
                if (!findUncovered(specialize(rows, head.key, head.args.length), head.args ~ rest, parts)) continue;
                witness = head.render(parts[0 .. head.args.length]) ~ parts[head.args.length .. $];
                return true;
            }
            return false;
        }

        string[] after;
        if (!findUncovered(defaults(rows), rest, after)) return false;
        auto unused = heads.find!(h => !rows.any!(row => row[0].head == h.key));
        auto first = unused.empty || rows.all!(row => row[0].head is null)
            ? "_" : unused.front.render("_".repeat(unused.front.args.length).array);
        witness = first ~ after;
        return true;
    }

    void check(const MatchExpr match_, CoveragePattern[] patterns, Type subject, Span span)
    {
        const(Type)[] types = [subject];
        CoveragePattern[][] rows;
        foreach (i, pattern; patterns)
        {
            if (!isUseful(rows, [pattern], types))
            {
                _collector.reportError(DiagnosticCode.UnreachableArm, match_.arms[i].pattern.span,
                    "This arm can never run, because the arms before it cover everything it matches");
            }
            rows ~= [pattern];
        }

        string[] missing;
        auto heads = headsOf(subject);
        foreach (head; heads)
        {
            string[] parts;
            if (findUncovered(specialize(rows, head.key, head.args.length), head.args, parts)) missing ~= head.render(parts);
        }
        if (heads.length == 0)
        {
            string[] witness;
            if (findUncovered(rows, types, witness)) missing = witness;
        }
        if (missing.length == 0) return;
        _collector.reportError(DiagnosticCode.NonExhaustiveMatch, span,
            "This `match` doesn't cover %-(`%s`%|, %); add %s, or a `_` arm".format(missing, missing.length > 1 ? "them" : "it"));
    }
}
