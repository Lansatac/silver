module silver.grammar_tests;

import pegged.grammar : ParseTree;
import silver.grammar;

version(unittest)
{
    import fluent.asserts;
    import fluentasserts.core.operations.registry;
    import std.typecons;



    void shouldParse(string input)
    {
        string failure;
        parse(input, failure).should.equal(true).because(failure);
    }

    bool parse(string input)
    {
        string failure;
        return parse(input, failure);
    }
    bool parse(string input, ref string failure)
    {
        import std.conv : to;
        
        auto parseTree = Silver(input);

        if(!parseTree.successful)
        {
            failure = parseTree.failMsg ~ "\n" ~ parseTree.to!string;
            //writeln("ParseFailure:\n" ~ parseTree.toString);
        }

        return parseTree.successful;
    }

    bool isEquivilent(ParseTree lhs, ParseTree rhs)
    {
        import std.range : zip;
        import std.algorithm: canFind;

        auto skippable = ["Silver.Expression", "Silver.Eval"];

        while(skippable.canFind(lhs.name))
            lhs = lhs[0];
        while(skippable.canFind(rhs.name))
            rhs = rhs[0];

        if((lhs.name == rhs.name)
        && (lhs.successful == rhs.successful)
        && (lhs.matches == rhs.matches)
        && (lhs.children.length == rhs.children.length))
        {
            foreach (children; lhs.children.zip(rhs.children))
            {
                if(children[0].isEquivilent(children[1]))
                {
                    continue;
                }
                return false;
            }
            return true;
        }
        return false;
    }

    string diff(ParseTree lhs, ParseTree rhs)
    {
        import std.array : join;
        import std.conv : to;
        import std.algorithm : map;
        import std.format : format;
        
        return diffTree(lhs, rhs)
            .map!(_ => "%s: %s is not the same as %s: %s".format(_[0].name, _[0].matches, _[1].name, _[1].matches))
            .join("\n--------------------\n");
    }

    Tuple!(ParseTree, ParseTree)[] diffTree(ParseTree lhs, ParseTree rhs)
    {
        import std.range : zip;
        import std.format;

        if((lhs.name == rhs.name)
        && (lhs.successful == rhs.successful)
        && (lhs.matches == rhs.matches)
        && (lhs.children.length == rhs.children.length))
        {
            Tuple!(ParseTree, ParseTree)[] diffs;
            foreach (children; lhs.children.zip(rhs.children))
            {
                if(children[0].isEquivilent(children[1]))
                {
                    continue;
                }
                diffs ~= children[0].diffTree(children[1]);
            }
            return diffs;
        }
        return [tuple(lhs, rhs)];
    }
}

@("Basic Assignment")
unittest
{
    shouldParse("a=b;");
}

@("Assignment to literal")
unittest
{
    shouldParse("a=true;");
}

@("Basic Addition")
unittest
{
    Silver.Expression("1+2").successful.should.equal(true);
}

@("Basic Logical Operator")
unittest
{
    Silver.Expression("true && true").successful.should.equal(true);
}

@("Repeated Addition")
unittest
{
    Silver.Expression("1+2+3").successful.should.equal(true);
}

@("Print Expression")
unittest
{
    Silver.Expression("print a").successful.should.equal(true);
}

@("Parenthesis")
unittest
{
    Silver.Expression("(1)").successful.should.equal(true);
}

@("Parenthesis Add")
unittest
{
    Silver.Expression("1 + (2 * 3) + 4").successful.should.equal(true);
}

@("Expression Operator Precedence, Simple")
unittest
{
    auto implicit = Silver.decimateTree(Silver.Expression("1+2*3"));
    auto explicit = Silver.decimateTree(Silver.Expression("1+(2*3)"));
    implicit.isEquivilent(explicit).should.equal(true).because("\n"~diff(implicit, explicit));
}

@("Expression Operator Precedence, Complex")
unittest
{
    auto implicit = Silver.decimateTree(Silver.Expression("1 + 2 * 3 + 4"));
    auto explicit = Silver.decimateTree(Silver.Expression("1 + (2 * 3) + 4"));
    implicit.isEquivilent(explicit).should.equal(true).because("\n"~diff(implicit, explicit));
}

@("Expression Operator Precedence, Parenthesis")
unittest
{
    auto expr = Silver.decimateTree(Silver.Expression("(1 + 2) * 3"));
    auto subexpr = Silver.decimateTree(Silver.AdditionExpression("1 + 2"));
    expr[0][0].isEquivilent(subexpr).should.equal(true).because("\n"~diff(expr[0][0], subexpr));
}

@("Expression Operator Precedence, Logical")
unittest
{
    auto expr = Silver.decimateTree(Silver.LogicalExpression("1 + 2 == 1 + 2"));
    auto subexpr = Silver.decimateTree(Silver.AdditionExpression("1 + 2"));
    expr[0].isEquivilent(subexpr).should.equal(true).because("\n"~diff(expr[0], subexpr));
    expr[2].isEquivilent(subexpr).should.equal(true).because("\n"~diff(expr[2], subexpr));
}


@("Repeated Expression Operator")
unittest
{
    Silver.Expression("1+2+3").successful.should.equal(true);
}

@("Multi-Line")
unittest
{
    shouldParse(`var a = 0;
    print a;`);
}

@("Assign To Function Call")
unittest
{
    shouldParse("a=b();");
}

@("Function Call - Empty")
unittest
{
    shouldParse("a();");
}

@("Function Calls - Single Parameter")
unittest
{
    Silver.Expression("a(b);").successful.should.equal(true);
}

@("Function Calls - Multiple Parameters")
unittest
{
    shouldParse("a(b,c);");
}

@("Nested function Calls")
unittest
{
    shouldParse("a(b());");
    shouldParse("a(b(),c());");
}

@("If Statement")
unittest
{
       `if true then
            print 1;
        end`.shouldParse;
}

@("If-Else Statement")
unittest
{
    shouldParse(
        r"if true then
            print 1;
        else
            print 2;
        end");
}

@("If-Else-If Statement")
unittest
{
    shouldParse(
        r"if true then
            print 1;
        else if true then
            print 2;
        end",
        );
}


@("If-Else-If-Else Statement")
unittest
{
    shouldParse(
        r"if true then
            print 1;
        else if true then
            print 2;
        else
            print 3;
        end");
}