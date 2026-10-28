module silver.parse_result;

debug import std.stdio;

version(unittest)
{
    import pegged.grammar : ParseTree;
    import silver.grammar;
    import fluent.asserts;
    import fluentasserts.operations.registry : Registry;
    import fluentasserts.core.evaluation.eval : Evaluation;

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

    void parseResult(ref Evaluation evaluation) @safe nothrow
    {
        string program = evaluation.currentValue.strValue[].idup;
        ParseTree tree;
        try{
            tree = safeSilver(program);
        }
        catch(Exception e)
        {
            evaluation.result.expected.put("program to parse");
            evaluation.result.actual.put("Failed to parse with this exception: " ~ e.msg);
            return;
        }
        if(tree.successful)
        {
            return;
        }
        evaluation.result.expected.put("program to parse");
        evaluation.result.actual.put(
            tree.safeFailMsg ~ "\n" ~ program ~ "\n" ~ tree.safeToString);
    }
}