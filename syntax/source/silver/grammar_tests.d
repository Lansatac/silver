module silver.grammar_tests;

import pegged.grammar : ParseTree;
import silver.grammar;

version (unittest)
{
    import fluent.asserts;
    import std.typecons;

    immutable skippable = [
        "Silver.Expression",
        "Silver.OrExpression",
        "Silver.AndExpression",
        "Silver.EqExpression",
        "Silver.RelationalExpression",
        "Silver.CoalesceExpression",
        "Silver.AdditionExpression",
        "Silver.MultiplyExpression",
        "Silver.Unary",
        "Silver.PowerExpression",
        "Silver.Postfix",
        "Silver.Eval",
    ];

    // Steps down through expression levels that matched no operator
    ParseTree unwrap(ParseTree tree)
    {
        import std.algorithm : canFind;

        while (skippable.canFind(tree.name) && tree.children.length == 1)
            tree = tree[0];
        return tree;
    }

    void shouldParse(string input, string file = __FILE__, size_t line = __LINE__)
    {
        string failure;
        should(parse(input, failure), file, line).equal(true).because(failure);
    }

    void shouldNotParse(string input, string file = __FILE__, size_t line = __LINE__)
    {
        string failure;
        should(parse(input, failure), file, line).equal(false);
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

        if (!parseTree.successful)
        {
            failure = parseTree.failMsg ~ "\n" ~ parseTree.to!string;
            //writeln("ParseFailure:\n" ~ parseTree.toString);
        }

        return parseTree.successful;
    }

    bool isEquivilent(ParseTree lhs, ParseTree rhs)
    {
        import std.range : zip;
        import std.algorithm : canFind;

        lhs = lhs.unwrap;
        rhs = rhs.unwrap;

        if ((lhs.name == rhs.name)
            && (lhs.successful == rhs.successful)
            && (lhs.matches == rhs.matches)
            && (lhs.children.length == rhs.children.length))
        {
            foreach (children; lhs.children.zip(rhs.children))
            {
                if (children[0].isEquivilent(children[1]))
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
            .map!(_ => "%s: %s is not the same as %s: %s".format(_[0].name, _[0].matches, _[1].name, _[1]
                    .matches))
            .join("\n--------------------\n");
    }

    Tuple!(ParseTree, ParseTree)[] diffTree(ParseTree lhs, ParseTree rhs)
    {
        import std.range : zip;
        import std.format;

        if ((lhs.name == rhs.name)
            && (lhs.successful == rhs.successful)
            && (lhs.matches == rhs.matches)
            && (lhs.children.length == rhs.children.length))
        {
            Tuple!(ParseTree, ParseTree)[] diffs;
            foreach (children; lhs.children.zip(rhs.children))
            {
                if (children[0].isEquivilent(children[1]))
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
    shouldParse("a=b");
}

@("Assignment to literal")
unittest
{
    shouldParse("a=true");
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

@("Print Statement")
unittest
{
    Silver.Statement("print a").successful.should.equal(true);
}

@("Keyword-like Variable")
unittest
{
    auto tree = Silver("variable = 1");
    tree.successful.should.equal(true);

    // Silver -> Module -> StatementBlock -> Statement -> <kind>
    auto statement = tree[0][0][0][0];
    statement.name.should.equal("Silver.AssignmentStatement");
    statement[0].matches.should.equal(["variable"]);
}

@("Keyword-prefixed Variables")
unittest
{
    shouldParse("printer = 1"); // read as `print er`, then ` = 1` is left over
    shouldParse("x = reader"); // read as `read`, then `er` is left over
    shouldParse("printl a"); // 'print' matches first; `l` becomes the expression
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
    implicit.isEquivilent(explicit).should.equal(true).because("\n" ~ diff(implicit, explicit));
}

@("Expression Operator Precedence, Complex")
unittest
{
    auto implicit = Silver.decimateTree(Silver.Expression("1 + 2 * 3 + 4"));
    auto explicit = Silver.decimateTree(Silver.Expression("1 + (2 * 3) + 4"));
    implicit.isEquivilent(explicit).should.equal(true).because("\n" ~ diff(implicit, explicit));
}

@("Expression Operator Precedence, Parenthesis")
unittest
{
    auto expr = Silver.decimateTree(Silver.Expression("(1 + 2) * 3")).unwrap;
    auto subexpr = Silver.decimateTree(Silver.AdditionExpression("1 + 2"));
    expr.name.should.equal("Silver.MultiplyExpression");
    expr[0].isEquivilent(subexpr).should.equal(true).because("\n" ~ diff(expr[0], subexpr));
}

@("Expression Operator Precedence, Logical")
unittest
{
    auto expr = Silver.decimateTree(Silver.Expression("1 + 2 == 1 + 2")).unwrap;
    auto subexpr = Silver.decimateTree(Silver.AdditionExpression("1 + 2"));
    expr.name.should.equal("Silver.EqExpression");
    expr[0].isEquivilent(subexpr).should.equal(true).because("\n" ~ diff(expr[0], subexpr));
    expr[2].isEquivilent(subexpr).should.equal(true).because("\n" ~ diff(expr[2], subexpr));
}

@("Repeated Expression Operator")
unittest
{
    Silver.Expression("1+2+3").successful.should.equal(true);
}

@("Single-Line")
unittest
{
    shouldParse(`print a`);
}

@("Multi-Line")
unittest
{
    shouldParse(`mutable val a = 0
    print a`);
}

@("Two Statements Single-Line")
unittest
{
    shouldNotParse(`mutable val a = 0 print a`);
}

@("Assign To Function Call")
unittest
{
    shouldParse("a=b()");
}

@("Function Call - Empty")
unittest
{
    shouldParse("a()");
}

@("Function Calls - Single Parameter")
unittest
{
    Silver.Expression("a(b)").successful.should.equal(true);
}

@("Function Calls - Multiple Parameters")
unittest
{
    shouldParse("a(b,c)");
}

@("Nested function Calls")
unittest
{
    shouldParse("a(b())");
    shouldParse("a(b(),c())");
}

@("If Statement")
unittest
{
    `if true then
            print 1
        end`.shouldParse;
}

@("If-Else Statement")
unittest
{
    shouldParse(
        r"if true then
            print 1
        else
            print 2
        end");
}

@("If-Else-If Statement")
unittest
{
    shouldParse(
        r"if true then
            print 1
        else if true then
            print 2
        end",
    );
}

@("If-Else-If-Else Statement")
unittest
{
    shouldParse(
        r"if true then
            print 1
        else if true then
            print 2
        else
            print 3
        end");
}

@("Single-Line If Statement")
unittest
{
    `if true then print 1 end`.shouldParse;
    `if true then print 1 else print 2 end`.shouldParse;
}

@("Semicolon Separators")
unittest
{
    `mutable val a = 1; print a`.shouldParse;
    `if true then a = 1; print a end`.shouldParse;
}

@("Missing Separator")
unittest
{
    `mutable val a = 1 print a`.shouldNotParse;
}

@("Empty Blocks")
unittest
{
    `if true then end`.shouldParse;
}

@("Trailing Newline")
unittest
{
    shouldParse(
        r"mutable val a = 1

");
}

@("Blank Lines Between Statements")
unittest
{
    shouldParse("mutable val a = 1\n\nprint a");
    shouldParse("mutable val a = 1\n\n\nprint a");
}

@("Leading Newline")
unittest
{
    shouldParse("\nmutable val a = 1");
}

@("Trailing Whitespace After Then")
unittest
{
    // Escaped so editors don't strip the trailing spaces
    shouldParse("if true then  \n    print 1\nend");
}

@("Trailing Whitespace After Else")
unittest
{
    shouldParse("if true then\n    print 1\nelse  \n    print 2\nend");
}

@("Hexadecimal Literal")
unittest
{
    shouldParse("a = 0x1F");
    shouldParse("a = 0xff");
}

@("Binary Literal")
unittest
{
    shouldParse("a = 0b101");
    shouldParse("a = 0b1010_0101");
}

@("Scientific Literal Without Decimal")
unittest
{
    shouldParse("a = 1e5");
    shouldParse("a = 1E-5");
}

@("Unary Minus")
unittest
{
    shouldParse("a = -b");
    shouldParse("a = -(1 + 2)");
}

@("Expression Operator Precedence, Equality Before And")
unittest
{
    auto implicit = Silver.decimateTree(Silver.Expression("a == b && c == d"));
    auto explicit = Silver.decimateTree(Silver.Expression("(a == b) && (c == d)"));
    implicit.isEquivilent(explicit).should.equal(true).because("\n" ~ diff(implicit, explicit));
}

@("Expression Operator Precedence, And Before Or")
unittest
{
    auto implicit = Silver.decimateTree(Silver.Expression("a || b && c"));
    auto explicit = Silver.decimateTree(Silver.Expression("a || (b && c)"));
    implicit.isEquivilent(explicit).should.equal(true).because("\n" ~ diff(implicit, explicit));
}

@("Function Definition")
unittest
{
    shouldParse("def a() : Int => 1");
    Silver.FunctionDeclaration("def a() : Int => 1").successful.should.equal(true);
    Silver.FunctionDeclaration("def a() : Int { 1 }").successful.should.equal(true);
    Silver.FunctionDeclaration("def a(a : Int, b : Int) : Int => 1").successful.should.equal(true);
}

@("Import")
unittest
{
    shouldParse("import module");
    Silver.ImportStatement("import module").successful.should.equal(true);
}

@("Qualified names")
unittest
{
    shouldParse("a.b.c");
    Silver.QualifiedName("a.b.c").successful.should.equal(true);
}


@("Function Call On Function Return Value")
unittest
{
    shouldParse("f()()");
    Silver.Postfix("f()()").successful.should.equal(true);
}
@("Line Comments")
unittest
{
    shouldParse("// leading comment\na = 1");
    shouldParse("a = 1 // trailing comment\nb = 2");
    shouldParse("a = 1\n// between statements\nb = 2");
    shouldParse("a = 1 // comment at end of input");
    shouldParse("// only a comment");
    shouldParse("a = 4 / 2 // division is not a comment");
}

@("Line Comment Does Not Hide Separator")
unittest
{
    // The comment ends at the newline, so `b = 2` must still be its own statement
    auto tree = Silver("a = 1 // comment\nb = 2");
    tree.successful.should.equal(true);
    tree[0][0].children.length.should.equal(2);
}

@("Block Comments")
unittest
{
    shouldParse("a = /* inline */ 1");
    shouldParse("/* leading */ a = 1");
    shouldParse("a = 1\n/* spans\n   lines */\nb = 2");
    shouldParse("/* only a comment */");
}

@("Nested Block Comments")
unittest
{
    shouldParse("a = 1 /* outer /* inner */ still outer */");
    shouldNotParse("a = 1 /* outer /* inner */");
}

@("Block Comment Newlines Are Not Separators")
unittest
{
    shouldNotParse("a = 1 /*\n*/ b = 2");
}

@("Value Declarations")
unittest
{
    shouldParse("val a = 1");
    shouldParse("val a: Int = 1");
    shouldNotParse("val a");
    shouldNotParse("val a: Int");
}

@("Mutable Declarations")
unittest
{
    shouldParse("mutable val a = 1");
    shouldParse("mutable val a: Int = 1");
    shouldParse("mutable val a: Int?"); // defaults to None
    shouldNotParse("mutable val a");
    shouldNotParse("mutable a = 1");
}

@("Case-Sensitive Names")
unittest
{
    shouldParse("val point: Point = origin");
    shouldNotParse("val Point = 1");
    shouldNotParse("val a: point = 1");
    shouldParse("val _unused = 1");
}

@("Type Annotations")
unittest
{
    shouldParse("val a: Int? = 1");
    shouldParse("val a: Int?? = 1");
    shouldParse("val a: math.Vector = v");
    shouldParse("val a: List<Int> = []");
    shouldParse("val a: Map<String, List<Int?>> = [:]");
    shouldParse("val a: () = ()");
    shouldParse("val a: () -> Int = f");
    shouldParse("val a: (Int, Int) -> Int = f");
    shouldParse("val a: (Int) -> (Int) -> Int = f");
    shouldParse("val a: ((Int) -> Int)? = None");
    shouldNotParse("val a: List<> = []");
}

@("Optional Binds Tighter Than Function Arrow")
unittest
{
    auto type = Silver.decimateTree(Silver.Type("(Int) -> Int?"));
    type.successful.should.equal(true);
    // Type -> BaseType -> FunctionType; the `?` belongs to the return type
    type[0][0].name.should.equal("Silver.FunctionType");
    type.children.length.should.equal(1);
}

@("Relational Operators")
unittest
{
    shouldParse("a = b < c");
    shouldParse("a = b <= c");
    shouldParse("a = b > c");
    shouldParse("a = b >= c");
    shouldParse("a = b + 1 < c == true");
    shouldNotParse("a = b < c < d");
}

@("Expression Operator Precedence, Relational Before Equality")
unittest
{
    auto implicit = Silver.decimateTree(Silver.Expression("a < b == c > d"));
    auto explicit = Silver.decimateTree(Silver.Expression("(a < b) == (c > d)"));
    implicit.isEquivilent(explicit).should.equal(true).because("\n" ~ diff(implicit, explicit));
}

@("Coalesce Operator")
unittest
{
    shouldParse("a = b ?? 0");
    shouldParse("a = b ?? c ?? 0");
}

@("Expression Operator Precedence, Coalesce")
unittest
{
    // Between addition and comparison, and right-associative
    auto implicit = Silver.decimateTree(Silver.Expression("a ?? b + 1 < c ?? d ?? e"));
    auto explicit = Silver.decimateTree(Silver.Expression("(a ?? (b + 1)) < (c ?? (d ?? e))"));
    implicit.isEquivilent(explicit).should.equal(true).because("\n" ~ diff(implicit, explicit));
}

@("Optional Chaining")
unittest
{
    shouldParse("a = b?.c");
    shouldParse("a = b?.c?.d ?? 0");
    shouldParse("a = b?.c()");
}

@("Propagate None")
unittest
{
    shouldParse("a = b?");
    shouldParse("a = b?.c? + 1");
    shouldParse("a = f()? ?? 0");

    auto postfix = Silver.decimateTree(Silver.Postfix("b?"));
    postfix[1].name.should.equal("Silver.PostfixOp");
    postfix[1][0].name.should.equal("Silver.PropagateNone");
}

@("Constructors")
unittest
{
    shouldParse("a = None");
    shouldParse("a = Some(1)");
    shouldParse("a = Some(Some(1))");
}

@("Unit Literal")
unittest
{
    shouldParse("a = ()");
    shouldParse("f(())");
}

@("List Literals")
unittest
{
    shouldParse("a = []");
    shouldParse("a = [1]");
    shouldParse("a = [1, 2, 3]");
    shouldParse("a = [1, 2, 3,]");
    shouldParse("a = [[1, 2], [3]]");
    shouldParse("a = [f(1), b + c]");
    shouldNotParse("a = [,]");
    shouldNotParse("a = [1 2]");
}

@("Map Literals")
unittest
{
    shouldParse("a = [:]");
    shouldParse("a = [1: 2]");
    shouldParse("a = [1: 2, 3: 4]");
    shouldParse("a = [1: 2, 3: 4,]");
    shouldParse("a = [k: [1, 2], j: []]");
    shouldNotParse("a = [1: 2, 3]");
    shouldNotParse("a = [:,]");
}

@("Empty Map Is Not An Empty List")
unittest
{
    Silver.decimateTree(Silver.CollectionLiteral("[]"))[0].name.should.equal("Silver.ListLiteral");
    Silver.decimateTree(Silver.CollectionLiteral("[:]"))[0].name.should.equal("Silver.MapLiteral");
}

@("Indexing")
unittest
{
    shouldParse("a = xs[0]");
    shouldParse("a = xs[i + 1][j]");
    shouldParse("a = m[k] ?? 0");
    shouldParse("xs[0] = 1");
    shouldParse("a = [1, 2][0]");
}
