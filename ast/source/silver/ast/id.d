module silver.ast.id;

struct Id(Node)
{
    private uint value;   // 0 = invalid
    bool isValid() const { return value != 0; }

    string toString() const
    {
        import std.conv : to;
        return isValid() ? value.to!string : "invalid";
    }
}

final class IdSource(Nodes...)
{
    import std.meta : staticIndexOf;
    private uint[Nodes.length] last;

    Id!N next(N)()
    {
        enum i = staticIndexOf!(N, Nodes);
        static assert(i >= 0, N.stringof ~ " doesn't get IDs");
        return Id!N(++last[i]);
    }
}
