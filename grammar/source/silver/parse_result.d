module silver.parse_result;

debug import std.stdio;

version(unittest)
{
    import pegged.grammar : ParseTree;
    import silver.grammar;
    import fluent.asserts;
    import fluentasserts.core.operations.registry;

    static this() {
        Registry.instance.register!(string, bool)("parse", &parseResult);
    }

    @trusted
    ParseTree safeSilver(string input)
    {
        return Silver(input);
    }
    @trusted
    string safeFailMsg(ParseTree tree) nothrow
    {
        string failMsg;
        try{
            failMsg = tree.failMsg;
        }
        catch(Exception e)
        {
            failMsg = e.msg;
        }
        return failMsg;
    }
    @trusted
    string safeToString(ParseTree tree) nothrow
    {
        import std.conv;
        string asString = "";
        try
        {
            asString = tree.to!string;
        }
        catch(Exception){}
        return asString;
    }

    IResult[] parseResult(ref Evaluation evaluation) @safe nothrow
    {
        import std.typecons : rebindable;

        string program = evaluation.currentValue.strValue;
        ParseTree tree;
        try{
            tree = safeSilver(program);
        }
        catch(Exception e)
        {
            return [new MessageResult("Failed to parse with this exception: " ~ e.msg)];
        }
        if(tree.successful)
        {
            return null;
        }
        return [
            new MessageResult(tree.safeFailMsg),
            new MessageResult(program),
            new MessageResult(tree.safeToString)
        ];
    }
}