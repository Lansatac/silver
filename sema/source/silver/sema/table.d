/// Where sema keeps what it learns about nodes: a table per module, found from each node's ID.
module silver.sema.table;

import std.algorithm : joiner, map;
import std.sumtype : match;

import silver.ast : Id, ModuleKey;

/// One write to a side table, which can be taken back.
interface Change
{
    /// Puts the key back as it was, without the journal noting it.
    void undo();
    /// Puts the key back as it was by writing to the table, which the journal notes like any write.
    void revert();
}

/// The writes made to side tables while something is being tried, so they can be taken back.
/// Nothing is kept while `recording` is off.
struct Journal
{
    Change[] changes;
    bool recording;

    /// Takes back every write since there were `mark` changes.
    void rollBack(size_t mark)
    {
        auto was = recording;
        recording = false;
        while (changes.length > mark)
        {
            changes[$ - 1].undo();
            changes.length--;
        }
        changes.assumeSafeAppend();
        recording = was;
    }
}

Journal journal;

/// What sema knows about each of a kind of node, by the node's ID, kept apart for each module the
/// nodes belong to. It's used as an associative array is.
struct SideTable(K, V)
{
    private V[K][ModuleKey] byModule;

    ref inout(V) opIndex(const K key) inout
    {
        return byModule[moduleOf(key)][key];
    }

    private static final class Written : Change
    {
        SideTable* table;
        K key;
        bool had;
        V was;

        this(SideTable* table, const K key, bool had, V was)
        {
            this.table = table;
            this.key = cast() key;
            this.had = had;
            this.was = was;
        }

        void undo()
        {
            auto home = moduleOf(key);
            if (had) table.byModule[home][key] = was;
            else if (auto entries = home in table.byModule) (*entries).remove(key);
        }

        void revert()
        {
            if (had) (*table)[key] = was;
            else table.remove(key);
        }
    }

    /// Notes how `key` stands, for the journal to put back.
    private void note(const K key)
    {
        if (!journal.recording) return;
        auto old = key in this;
        journal.changes ~= old is null ? new Written(&this, key, false, V.init) : new Written(&this, key, true, *old);
    }

    void opIndexAssign(V value, const K key)
    {
        note(key);
        byModule.require(moduleOf(key))[key] = value;
    }

    void opIndexOpAssign(string op, T)(T value, const K key)
    {
        note(key);
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
        note(key);
        return byModule.require(moduleOf(key)).require(key, value);
    }

    bool remove(const K key)
    {
        note(key);
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

@("a journal takes back the writes to a side table made while it records")
unittest
{
    import silver.ast : Expr, NodeIds;

    auto ids = new NodeIds(ModuleKey.of("a", "x"));
    auto kept = ids.next!Expr, changed = ids.next!Expr, added = ids.next!Expr;
    SideTable!(Id!Expr, int[]) table;
    table[kept] = [1];
    table[changed] = [2];
    journal.recording = true;
    auto mark = journal.changes.length;
    table[changed] ~= 3;
    table[added] = [4];
    table.require(kept) ~= 5;
    table.remove(changed);
    auto made = journal.changes[mark .. $].dup;
    journal.rollBack(mark);
    assert(table[kept] == [1] && table[changed] == [2] && added !in table);

    // A revert is a write like any other, so it can be taken back too.
    table[added] = [4];
    table[kept] = [6];
    mark = journal.changes.length;
    foreach_reverse (change; made) change.revert();
    assert(table[kept] == [1] && added !in table);
    journal.rollBack(mark);
    journal.recording = false;
    assert(table[kept] == [6] && table[added] == [4]);
}
