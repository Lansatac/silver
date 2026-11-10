/// What the compiler knows about the platform a program is compiled for, and the intrinsics,
/// some of which depend on it.
module silver.sema.target;

import silver.ast : Builtin;

/// The platform a program is compiled for, as far as sema needs to know it.
struct Target
{
    /// The width of C's `long`.
    uint cLongBits;

    /// The platform the compiler is running on.
    static Target host()
    {
        version (Windows) return Target(32);
        else return Target(64);
    }
}

/// The operations an `intrinsic def` can name, each a member named as the function is.
enum Intrinsic
{
    print,
    printl,
    read,
    length,
    panic,
}

/// The intrinsic named `name`, or null if the compiler doesn't implement one.
const(Intrinsic)* intrinsicNamed(string name)
{
    import std.conv : to;
    import std.traits : EnumMembers;

    static immutable all = [EnumMembers!Intrinsic];
    foreach (ref intrinsic; all)
    {
        if (intrinsic.to!string == name) return &intrinsic;
    }
    return null;
}

/// The type an `intrinsic alias` named `name` stands for on `target`, or null if there's no such alias.
const(Builtin)* intrinsicAlias(string name, Target target)
{
    static immutable Builtin[2] longs = [Builtin.Int32, Builtin.Int64];
    static immutable Builtin[2] unsignedLongs = [Builtin.UInt32, Builtin.UInt64];
    auto wide = target.cLongBits == 64;
    switch (name)
    {
        case "CLong": return &longs[wide];
        case "CULong": return &unsignedLongs[wide];
        default: return null;
    }
}

@("intrinsics are found by their names, and only those")
unittest
{
    assert(*intrinsicNamed("length") == Intrinsic.length);
    assert(*intrinsicNamed("printl") == Intrinsic.printl);
    assert(intrinsicNamed("sqrt") is null);
}

@("C's long is the target's width")
unittest
{
    assert(*intrinsicAlias("CLong", Target(32)) == Builtin.Int32);
    assert(*intrinsicAlias("CULong", Target(64)) == Builtin.UInt64);
    assert(intrinsicAlias("CInt", Target(64)) is null);
}
