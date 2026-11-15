module silver.ast.id;

/// The module a node belongs to: a hash of the module's name and text, so a module's IDs depend
/// only on the module and its AST can be shared by every program that loads it.
struct ModuleKey
{
    ulong value;

    static ModuleKey of(string moduleName, string text) @safe pure nothrow
    {
        return ModuleKey(hashOf(text, hashOf(moduleName)));
    }

    /// The key of the nodes sema creates, which belong to no module's source.
    enum ModuleKey analysis = ModuleKey(ulong.max);
}

struct Id(Node)
{
    ModuleKey moduleKey;
    private uint local;   // 0 = invalid
    bool isValid() const { return local != 0; }

    string toString() const
    {
        import std.conv : to;
        return isValid() ? local.to!string : "invalid";
    }
}

final class IdSource(Nodes...)
{
    import std.meta : staticIndexOf;
    private ModuleKey key;
    private uint[Nodes.length] last;

    this(ModuleKey key = ModuleKey.init)
    {
        this.key = key;
    }

    Id!N next(N)()
    {
        enum i = staticIndexOf!(N, Nodes);
        static assert(i >= 0, N.stringof ~ " doesn't get IDs");
        return Id!N(key, ++last[i]);
    }
}

@("IDs from different modules differ even when their numbers match")
unittest
{
    struct Node {}
    auto a = new IdSource!Node(ModuleKey.of("a", "x"));
    auto b = new IdSource!Node(ModuleKey.of("b", "x"));
    assert(a.next!Node != b.next!Node);
    assert(ModuleKey.of("a", "x") == ModuleKey.of("a", "x"));
}
