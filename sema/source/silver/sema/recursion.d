/// Finding generic declarations that need themselves at ever larger type arguments. Each
/// instance is compiled for its own types, so they would need endlessly many.
module silver.sema.recursion;

import std.algorithm;
import std.array;
import std.format : format;
import std.sumtype;

import silver.ast;
import silver.sema.type;

/// A use, inside the generic declaration `from`, of the generic declaration `to`, with `args` for
/// `to`'s type parameters in terms of `from`'s.
package struct Use(Decl)
{
    Decl from;
    Decl to;
    const(Type)[] args;
    Span span;
}

/// The uses around a cycle through which a type argument grows, starting with the one where
/// it grows, or null if there's none.
///
/// Each type parameter is a node, and each use gives an edge from a parameter of `from` to the
/// parameter of `to` whose argument mentions it. An edge grows when that argument isn't the
/// parameter itself. With no cycle that has an edge that grows, the instances are finite, since
/// around any cycle the arguments only pass parameters along or swap them.
package const(Use!Decl)[] growingCycle(Decl)(const(Use!Decl)[] uses, const(TypeParam)[] delegate(Decl) paramsOf,
    const TypeTable types)
{
    static struct Edge
    {
        Id!TypeParam to;
        size_t use;
        bool grows;
    }

    Edge[][Id!TypeParam] edges;
    Edge[] growing;
    Id!TypeParam[] sources;
    foreach (i, use; uses)
    {
        auto targets = paramsOf(use.to);
        foreach (k, arg; use.args)
        {
            if (k >= targets.length) break;
            foreach (param; paramsOf(use.from).filter!(p => types.mentionsParameter(arg, p.id)))
            {
                auto edge = Edge(targets[k].id, i, !isParameter(types, arg, param.id));
                edges[param.id] ~= edge;
                if (edge.grows)
                {
                    growing ~= edge;
                    sources ~= param.id;
                }
            }
        }
    }

    foreach (n, start; growing)
    {
        // Breadth first from where the growing edge leads, back to where it starts.
        auto goal = sources[n];
        size_t[Id!TypeParam] reachedBy;
        Id!TypeParam[Id!TypeParam] previous;
        auto frontier = [start.to];
        bool found = start.to == goal;
        bool[Id!TypeParam] seen = [start.to: true];
        while (!found && frontier.length > 0)
        {
            Id!TypeParam[] next;
            foreach (node; frontier)
            {
                foreach (edge; edges.get(node, null))
                {
                    if (edge.to in seen) continue;
                    seen[edge.to] = true;
                    reachedBy[edge.to] = edge.use;
                    previous[edge.to] = node;
                    if (edge.to == goal) found = true;
                    next ~= edge.to;
                }
            }
            frontier = next;
        }
        if (!found) continue;
        const(Use!Decl)[] path;
        for (auto at = goal; at != start.to; at = previous[at]) path = uses[reachedBy[at]] ~ path;
        return uses[start.use] ~ path;
    }
    return null;
}

/// The instances that following `cycle` from its first declaration leads to: the first one at its
/// own type parameters, then those it needs in turn, around the cycle twice, or once when it's long.
package string[] instancesAround(Decl)(const(Use!Decl)[] cycle, const(TypeParam)[] delegate(Decl) paramsOf,
    TypeTable types, string delegate(Decl, const(Type)[]) describe)
{
    auto first = cycle[0].from;
    auto shown = [describe(first, paramsOf(first).map!(p => types.parameter(p.id, p.name)).array)];
    Substitution current;
    foreach (lap; 0 .. cycle.length > 2 ? 1 : 2)
    {
        foreach (use; cycle)
        {
            auto args = use.args.map!(a => types.substitute(a, current)).array;
            shown ~= describe(use.to, args);
            current = null;
            foreach (k, param; paramsOf(use.to)) if (k < args.length) current[param.id] = args[k];
        }
    }
    return shown;
}

/// Every declared type that occurs in `type`, outermost first, as `visit` is given them.
package void eachNominal(const TypeTable types, Type type, void delegate(Type, const NominalData) visit)
{
    void each(const(Type)[] inner)
    {
        foreach (t; inner) eachNominal(types, t, visit);
    }

    types[type].match!(
        (const OptionData o) => each([o.inner]),
        (const ErrorUnionData u) => each([u.success, u.error]),
        (const ErrorListData l) => each(l.members),
        (const FailureData f) => each([f.error]),
        (const ArrayData a) => each([a.element]),
        (const FunctionData f) => each(f.params ~ f.ret),
        (const TupleData tuple) => each(tuple.elements),
        (const NominalData nominal) {
            visit(type, nominal);
            each(nominal.args);
        },
        (_) {},
    );
}

private bool isParameter(const TypeTable types, Type type, Id!TypeParam param)
{
    return types[type].match!((const TypeParamData p) => p.param == param, _ => false);
}
