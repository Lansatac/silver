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
    
    Expression <   (     Eval (Op Expression)?     )
                 / (:'(' Eval (Op Expression)? :')')
    
    Eval <   Call
            / Variable
            / Literal

    Literal < BooleanLiteral
            / NumberLiteral

    Op       < '+' / "-" / '*' / '/'
             / AssignOp

    AssignOp <  "~=" / "+=" / "-=" / "*=" / "^=" / "|=" / "&=" / "/="
        / "="

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
    HexaLiteral       <~ [0-9a-fA-F]+
    BinaryLiteral     <~ "0b" [01] [01_]*
    SignLiteral       <- '-' / '+'

    Variable <- identifier
`));

version(unittest)
{
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

@("Basic Expression")
unittest
{
    Silver.Expression("1+2").successful.should.equal(true);
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

@("Expression Operator Precedence")
unittest
{
    Silver("a=1+2*3").isEquivilent(Silver("a=1+(2*3)")).should.equal(true);
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