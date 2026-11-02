/// TypeTable tests: interning (equal structure gives an equal handle) and what a handle reads back as.
module silver.sema.type_tests;

version (unittest):

import std.sumtype : match;

import fluent.asserts;
import silver.sema.type;

private Type[] builtins(TypeTable table)
{
    with (table)
    {
        return [error, never, unit, bool_, int_, float_, string_, any];
    }
}

/// What `type` reads back as, in a form that's easy to compare.
private string shape(TypeTable table, Type type)
{
    import std.conv : to;

    return table[type].match!(
        (const Primitive p) => p.kind.to!string,
        (const OptionData _) => "Option",
        (const FunctionData f) => "Function/" ~ f.params.length.to!string,
        (const ErrorType _) => "Error",
    );
}

@("TypeTable gives every built-in its own handle")
unittest
{
    auto all = builtins(new TypeTable);
    foreach (i, a; all)
    {
        foreach (b; all[i + 1 .. $])
        {
            assert(a != b);
        }
    }
}

@("TypeTable built-ins read back as what they are")
unittest
{
    auto table = new TypeTable;
    shape(table, table.error).should.equal("Error");
    shape(table, table.never).should.equal("Never");
    shape(table, table.unit).should.equal("Unit");
    shape(table, table.bool_).should.equal("Bool");
    shape(table, table.int_).should.equal("Integer");
    shape(table, table.float_).should.equal("Float");
    shape(table, table.string_).should.equal("String");
    shape(table, table.any).should.equal("Any");
}

@("TypeTable never hands out the uninitialized handle")
unittest
{
    auto table = new TypeTable;
    foreach (t; builtins(table) ~ [table.option(table.int_), table.function_([], table.unit)])
    {
        assert(t != Type.init);
    }
}

@("TypeTable interns an option: the same inner type gives the same handle")
unittest
{
    auto table = new TypeTable;
    assert(table.option(table.int_) == table.option(table.int_));
    assert(table.option(table.int_) != table.option(table.string_));
}

@("TypeTable keeps a nested option distinct from its inner option")
unittest
{
    auto table = new TypeTable;
    auto maybeInt = table.option(table.int_);
    auto nested = table.option(maybeInt);
    assert(nested != maybeInt);
    assert(nested == table.option(table.option(table.int_)));
}

@("TypeTable option reads back its inner type")
unittest
{
    auto table = new TypeTable;
    auto inner = table[table.option(table.bool_)].match!(
        (const OptionData o) => o.inner,
        _ => Type.init,
    );
    assert(inner == table.bool_);
}

@("TypeTable interns a function type by its params and return type")
unittest
{
    auto table = new TypeTable;
    auto f = table.function_([table.int_, table.string_], table.bool_);
    assert(f == table.function_([table.int_, table.string_], table.bool_));

    assert(f != table.function_([table.string_, table.int_], table.bool_));
    assert(f != table.function_([table.int_, table.string_], table.unit));
    assert(f != table.function_([table.int_], table.bool_));
    assert(table.function_([], table.unit) != table.function_([table.unit], table.unit));
}

@("TypeTable function types nest: a function returning a function, or an option of one")
unittest
{
    auto table = new TypeTable;
    auto intToInt = table.function_([table.int_], table.int_);
    auto curried = table.function_([table.int_], intToInt);
    assert(curried == table.function_([table.int_], table.function_([table.int_], table.int_)));
    assert(curried != intToInt);
    assert(table.option(intToInt) == table.option(table.function_([table.int_], table.int_)));
}

@("TypeTable function reads back its params and return type")
unittest
{
    auto table = new TypeTable;
    auto f = table.function_([table.float_, table.any], table.never);
    table[f].match!(
        (const FunctionData data) {
            assert(data.params == [table.float_, table.any]);
            assert(data.ret == table.never);
        },
        (_) { assert(false, "expected a function type"); },
    );
}

@("TypeTable copies a function's params, so changing the caller's array afterwards changes nothing")
unittest
{
    auto table = new TypeTable;
    auto params = [table.int_, table.int_];
    auto f = table.function_(params, table.unit);
    params[0] = table.string_;

    assert(f == table.function_([table.int_, table.int_], table.unit));
    assert(f != table.function_(params, table.unit));
    table[f].match!(
        (const FunctionData data) { assert(data.params == [table.int_, table.int_]); },
        (_) { assert(false, "expected a function type"); },
    );
}

