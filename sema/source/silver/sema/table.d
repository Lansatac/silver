/// Where sema keeps what it learns about nodes: a table per module, found from each node's ID.
module silver.sema.table;

import std.algorithm : joiner, map;
import std.sumtype : match;

import silver.ast : Id, ModuleKey;

/// What sema knows about each of a kind of node, by the node's ID, kept apart for each module the
/// nodes belong to. It's used as an associative array is.
struct SideTable(K, V)
{
    private V[K][ModuleKey] byModule;

    ref inout(V) opIndex(const K key) inout
    {
        return byModule[moduleOf(key)][key];
    }

    void opIndexAssign(V value, const K key)
    {
        byModule.require(moduleOf(key))[key] = value;
    }

    void opIndexOpAssign(string op, T)(T value, const K key)
    {
        mixin("byModule.require(moduleOf(key))[key] " ~ op ~ "= value;");
    }

    inout(V)* opBinaryRight(string op : "in")(const K key) inout
    {
        if (auto table = moduleOf(key) in byModule) return key in *table;
        return null;
    }

    inout(V) get(const K key, lazy inout(V) fallback) inout
    {
        if (auto value = key in this) return *value;
        return fallback;
    }

    ref V require(const K key, lazy V value = V.init)
    {
        return byModule.require(moduleOf(key)).require(key, value);
    }

    bool remove(const K key)
    {
        if (auto table = moduleOf(key) in byModule) return (*table).remove(key);
        return false;
    }

    size_t length() const
    {
        size_t total;
        foreach (table; byModule.byValue) total += table.length;
        return total;
    }

    auto byKey() inout => byModule.byValue.map!(table => table.byKey).joiner;
    auto byValue() inout => byModule.byValue.map!(table => table.byValue).joiner;
}

/// The module whose node `key` names.
ModuleKey moduleOf(K)(const K key)
{
    static if (is(K : Id!N, N)) return key.moduleKey;
    else return key.match!(id => id.moduleKey);
}

@("a side table keeps entries of different modules apart and finds each by its ID")
unittest
{
    import silver.ast : Expr, NodeIds;

    auto a = new NodeIds(ModuleKey.of("a", "x"));
    auto b = new NodeIds(ModuleKey.of("b", "x"));
    auto inA = a.next!Expr, inB = b.next!Expr;
    SideTable!(Id!Expr, int) table;
    table[inA] = 1;
    table[inB] = 2;
    table[inB] += 1;
    assert(table[inA] == 1 && *(inB in table) == 3);
    assert(table.byModule.length == 2 && table.length == 2);
    assert(table.get(a.next!Expr, 7) == 7);
    assert(table.remove(inA) && inA !in table);
}
