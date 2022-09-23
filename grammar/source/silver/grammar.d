module silver.grammar;

import pegged.grammar;

version(unittest) import fluent.asserts;

mixin(pegged.grammar.grammar(`
Silver:
    Module < Statement+ eoi
    Statement < Declaration / Print / Assignment / Call

    Declaration < 'var' Variable '=' Expression
    
    Assignment < AssignTarget '=' Expression

    AssignTarget < Variable

    Call < Expression '(' (FunctionParam (:',' FunctionParam)*)? ')'
    FunctionParam < Expression

    Print < 'print' Expression
    
    Expression < AdditionExpression / MultiplyExpression / Eval

    AdditionOperator < "+" / "-"
    AdditionExpression < (MultiplyExpression / Eval) (AdditionOperator (MultiplyExpression / Eval))+

    MultiplyOperator < "*" / "/"
    MultiplyExpression < Eval (MultiplyOperator Eval)+
    
    Eval <  :'(' Expression :')'
            / Call
            / Literal
            / Variable

    Literal < BooleanLiteral
            / NumberLiteral

    AssignOp <  "~=" / "+=" / "-=" / "*=" / "^=" / "|=" / "&=" / "/=" / "="

    BooleanLiteral <- "true" / "false"

    NumberLiteral <-  ScientificLiteral
                    / FloatingLiteral
                    / UnsignedLiteral
                    / IntegerLiteral
                    / HexaLiteral
                    / BinaryLiteral

    ScientificLiteral <~ FloatingLiteral ( ('e' / 'E' ) IntegerLiteral )
    FloatingLiteral   <~ IntegerLiteral ('.' UnsignedLiteral )
    UnsignedLiteral   <~ [0-9]+
    IntegerLiteral    <~ SignLiteral? UnsignedLiteral
    HexaLiteral       <~ "0x" [0-9a-fA-F]+
    BinaryLiteral     <~ "0b" [01] [01_]*
    SignLiteral       <- '-' / '+'

    Variable <- identifier
`));

version(unittest)
{
    import std.typecons;

    bool parse(string input)
    {
        import std.stdio : writeln;
        
        auto parseTree = Silver(input);

        if(!parseTree.successful)
        {
            writeln("ParseFailure:\n" ~ parseTree.toString);
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
    parse("a=b").should.equal(true);
}

@("Assignment to literal")
unittest
{
    parse("a=true").should.equal(true);
}

@("Basic Addition")
unittest
{
    Silver.Expression("1+2").successful.should.equal(true);
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
    import std.format;
    import std.conv;
    auto implicit = Silver.decimateTree(Silver.Expression("1+2*3"));
    auto explicit = Silver.decimateTree(Silver.Expression("1+(2*3)"));
    implicit.isEquivilent(explicit).should.equal(true).because("\n"~diff(implicit, explicit));
}

@("Expression Operator Precedence, Complex")
unittest
{
    import std.format;
    import std.conv;
    auto implicit = Silver.decimateTree(Silver.Expression("1 + 2 * 3 + 4"));
    auto explicit = Silver.decimateTree(Silver.Expression("1 + (2 * 3) + 4"));
    implicit.isEquivilent(explicit).should.equal(true).because("\n"~diff(implicit, explicit));
}

@("Expression Operator Precedence, Parenthesis")
unittest
{
    import std.format;
    import std.conv;
    import std.stdio;
    auto expr = Silver.decimateTree(Silver.Expression("(1 + 2) * 3"));
    auto subexpr = Silver.decimateTree(Silver.AdditionExpression("1 + 2"));
    expr[0][0].isEquivilent(subexpr).should.equal(true).because("\n"~diff(expr[0][0], subexpr));
}


@("Repeated Expression Operator")
unittest
{
    Silver.Expression("a=1+2+3").successful.should.equal(true);
}

@("Multi-Line")
unittest
{
    parse(`var a = 0
    print a`).should.equal(true);
}

@("Assign To Function Call")
unittest
{
    parse("a=b()").should.equal(true);
}

@("Function Call - Empty")
unittest
{
    parse("a()").should.equal(true);
}

@("Function Calls - Single Parameter")
unittest
{
    Silver.Expression("a(b)").successful.should.equal(true);
}

@("Function Calls - Multiple Parameters")
unittest
{
    parse("a(b,c)").should.equal(true);
}

@("Nested function Calls")
unittest
{
    parse("a(b())").should.equal(true);
    parse("a(b(),c())").should.equal(true);
}