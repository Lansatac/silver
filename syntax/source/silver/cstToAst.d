module silver.cstToAst;

import std.format : format;
import pegged.grammar : ParseTree;
import silver.ast;

version(unittest) import fluent.asserts;

/// Lowers a parse tree from silver.parse into an AST Module.
/// `file` is recorded in every node's Span, for error messages.
Module cstToAst(ParseTree tree, string moduleName, string file = "<input>")
{
    return convertModule(tree, moduleName, file);
}

private Module convertModule(ParseTree tree, string moduleName, string file)
{
    tree.validateNodeIs("Silver");
    tree[0].validateNodeIs("Silver.Module");

    // The StatementBlock is optional: an empty module has no children.
    Stmt[] statements;
    if (tree[0].children.length > 0)
    {
        tree[0][0].validateNodeIs("Silver.StatementBlock");
        statements = convertStatementBlock(tree[0][0], file);
    }
    return Module(moduleName, spanOf(tree, file), statements);
}

void validateNodeIs(ParseTree tree, string type)
{
    if (tree.name != type)
    {
        throw new Exception("Expected node of type '%s', got '%s'".format(type, tree.name));
    }
}

private Span spanOf(ParseTree cst, string file)
{
    return Span(file, cst.begin, cst.end);
}

private Stmt[] convertStatementBlock(ParseTree cst, string file)
{
    Stmt[] statements;
    foreach (statement; cst.children)
    {
        statements ~= convertStatement(statement, file);
    }
    return statements;
}

private Stmt convertStatement(ParseTree cst, string file)
{
    switch (cst.name)
    {
    case "Silver.Statement":
        return convertStatement(cst[0], file);
    case "Silver.VariableDeclaration":
    case "Silver.ValueDeclaration":
        // Both are `Variable '=' Expression` once the keyword is discarded.
        auto name = cst[0].matches[0];
        auto expr = convertExpression(cst[1], file);
        auto mutable = cst.name == "Silver.VariableDeclaration";
        return Stmt(spanOf(cst, file), StmtKind(VarDecl(name, expr, mutable)));
    case "Silver.AssignmentStatement":
        // The target is a Postfix, so `a.b = 1` keeps its member access.
        cst[0].validateNodeIs("Silver.AssignTarget");
        auto target = convertExpression(cst[0][0], file);
        auto op = toAssignOp(cst.children[1].matches[0]);
        auto expr = convertExpression(cst[2], file);
        return Stmt(spanOf(cst, file), StmtKind(AssignStmt(target, op, expr)));
    case "Silver.PrintStatement":
        auto expr = convertExpression(cst[1], file);
        if (cst.matches[0] == "print")
        {
            return Stmt(spanOf(cst, file), StmtKind(PrintStmt(expr, false)));
        }
        else
        {
            return Stmt(spanOf(cst, file), StmtKind(PrintStmt(expr, true)));
        }
    case "Silver.IfStatement":
        return convertIfStatement(cst, file);
    case "Silver.FunctionDeclaration":
        return convertFunctionDeclaration(cst, file);
    case "Silver.ReturnStatement":
        return Stmt(spanOf(cst, file), StmtKind(ReturnStmt(convertExpression(cst[0], file))));
    case "Silver.CallStatement":
        return Stmt(spanOf(cst, file), StmtKind(ExprStmt(convertExpression(cst[0], file))));
    case "Silver.ImportStatement":
        import std.algorithm : filter;
        import std.array : array;
        // QualifiedName's matches are the identifiers with the '.'s between them.
        cst[0].validateNodeIs("Silver.QualifiedName");
        auto path = cst[0].matches.filter!(m => m != ".").array;
        return Stmt(spanOf(cst, file), StmtKind(ImportStmt(path)));
    default:
        throw new Exception("cstToAst: statement '%s' not supported yet".format(cst.name));
    }
}

private Expr convertExpression(ParseTree cst, string file)
{
    import std.conv : to;
    import std.range : chunks, drop;

    switch (cst.name)
    {
    case "Silver.Expression":
    case "Silver.Eval":
    case "Silver.Literal":
    case "Silver.NumberLiteral":
        return convertExpression(cst[0], file);
    case "Silver.OrExpression":
    case "Silver.AndExpression":
    case "Silver.EqExpression":
    case "Silver.AdditionExpression":
    case "Silver.MultiplyExpression":
        // `X (Op X)*`, folded left so `1 - 2 - 3` is `(1 - 2) - 3`.
        auto lhs = convertExpression(cst[0], file);
        foreach (pair; cst.children.drop(1).chunks(2))
        {
            auto op = toBinaryOp(pair[0].matches[0]);
            auto rhs = convertExpression(pair[1], file);
            auto span = Span(file, lhs.span.start, rhs.span.end);
            lhs = Expr(span, ExprKind(BinaryExpr(op, boxed(lhs), boxed(rhs))));
        }
        return lhs;
    case "Silver.Unary":
        if (cst.children.length == 1)
        {
            return convertExpression(cst[0], file);
        }
            auto op = toUnaryOp(cst[0].matches[0]);
            auto operand = convertExpression(cst[1], file);
            auto span = Span(file, cst.begin, operand.span.end);
            return Expr(span, ExprKind(UnaryExpr(op, boxed(operand))));
        break;
    case "Silver.PowerExpression":
        // `Postfix (^ Unary)?` - the exponent recurses, so `2 ^ 3 ^ 2` is `2 ^ (3 ^ 2)`.
        {
            auto base = convertExpression(cst[0], file);
            if (cst.children.length == 1)
            {
                return base;
            }
            auto exponent = convertExpression(cst[2], file);
            auto span = Span(file, base.span.start, exponent.span.end);
            return Expr(span, ExprKind(BinaryExpr(BinaryOp.Power, boxed(base), boxed(exponent))));
        }
    case "Silver.Postfix":
        // `Eval PostfixOp*`, folded left so `m.f(1)` is `call (m.f) 1`.
        {
            auto lhs = convertExpression(cst[0], file);
            foreach (postfixOp; cst.children.drop(1))
            {
                postfixOp.validateNodeIs("Silver.PostfixOp");
                lhs = convertPostfixOp(lhs, postfixOp[0], file);
            }
            return lhs;
        }
    case "Silver.ReadExpression":
        return Expr(spanOf(cst, file), ExprKind(ReadExpr()));
    case "Silver.BooleanLiteral":
        return Expr(spanOf(cst, file), ExprKind(BoolLiteral(cst.matches[0].to!bool)));
    case "Silver.UnsignedLiteral":
    case "Silver.IntegerLiteral":
        return Expr(spanOf(cst, file), ExprKind(IntLiteral(cst.matches[0].to!long)));
    case "Silver.FloatingLiteral":
        return Expr(spanOf(cst, file), ExprKind(FloatLiteral(cst.matches[0].to!double)));
    case "Silver.Variable":
        return Expr(spanOf(cst, file), ExprKind(VariableRef(cst.matches[0])));
    case "Silver.ScientificLiteral":
        return Expr(spanOf(cst, file), ExprKind(FloatLiteral(cst.matches[0].to!double)));
    case "Silver.HexaLiteral":
        return Expr(spanOf(cst, file), ExprKind(IntLiteral(cst.matches[0].to!long)));
    case "Silver.BinaryLiteral":
        return Expr(spanOf(cst, file), ExprKind(IntLiteral(cst.matches[0].to!long)));
    default:
        break;
    }
    throw new Exception("cstToAst: expression '%s' not supported yet".format(cst.name));
}

/// Applies one postfix operation (a call or member access) to `lhs`.
private Expr convertPostfixOp(Expr lhs, ParseTree op, string file)
{
    auto span = Span(file, lhs.span.start, op.end);
    switch (op.name)
    {
    case "Silver.CallArgs":
        Expr[] args;
        foreach (param; op.children)
        {
            param.validateNodeIs("Silver.FunctionParam");
            args ~= convertExpression(param[0], file);
        }
        return Expr(span, ExprKind(CallExpr(boxed(lhs), args)));
    case "Silver.MemberAccess":
        return Expr(span, ExprKind(MemberAccess(boxed(lhs), op.matches[0])));
    default:
        throw new Exception("Expected call or member access, got '%s'".format(op.name));
    }
}

/// `def name(FunctionParamDefs?) StatementBlock? ReturnStatement end`.
/// FunctionParamDefs and StatementBlock are absent rather than empty when
/// there are no params or statements, so children are matched by name.
private Stmt convertFunctionDeclaration(ParseTree cst, string file)
{
    cst.validateNodeIs("Silver.FunctionDeclaration");
    auto name = cst[0].matches[0];

    string[] params;
    Stmt[] body;
    foreach (child; cst.children[1 .. $])
    {
        switch (child.name)
        {
        case "Silver.FunctionParamDefs":
            foreach (param; child.children)
            {
                params ~= param.matches[0];
            }
            break;
        case "Silver.StatementBlock":
            body ~= convertStatementBlock(child, file);
            break;
        case "Silver.ReturnStatement":
            body ~= convertStatement(child, file);
            break;
        default:
            throw new Exception("Unexpected '%s' in function declaration".format(child.name));
        }
    }
    return Stmt(spanOf(cst, file), StmtKind(FunctionDecl(name, params, body)));
}

private UnaryOp toUnaryOp(string op)
{
    switch (op)
    {
    case "+":
        return UnaryOp.Plus;
    case "-":
        return UnaryOp.Minus;
    case "!":
        return UnaryOp.Not;
    default:
        throw new Exception("Unknown unary operator '%s'".format(op));
    }
}

private AssignOp toAssignOp(string op)
{
    switch (op)
    {
    case "=":
        return AssignOp.Assign;
    case "+=":
        return AssignOp.AddAssign;
    case "-=":
        return AssignOp.SubtractAssign;
    case "*=":
        return AssignOp.MultiplyAssign;
    case "/=":
        return AssignOp.DivideAssign;
    case "%=":
        return AssignOp.ModuloAssign;
    case "^=":
        return AssignOp.PowerAssign;
    default:
        throw new Exception("Unknown assignment operator '%s'".format(op));
    }
}

private BinaryOp toBinaryOp(string op)
{
    switch (op)
    {
    case "+":
        return BinaryOp.Add;
    case "-":
        return BinaryOp.Subtract;
    case "*":
        return BinaryOp.Multiply;
    case "/":
        return BinaryOp.Divide;
    case "%":
        return BinaryOp.Modulo;
    case "^":
        return BinaryOp.Power;
    case "==":
        return BinaryOp.Equal;
    case "!=":
        return BinaryOp.NotEqual;
    case "&&":
        return BinaryOp.And;
    case "||":
        return BinaryOp.Or;
    default:
        throw new Exception("Unknown binary operator '%s'".format(op));
    }
}

/// Copies `e` to the heap, for nodes that hold child expressions by pointer.
private Expr* boxed(Expr e)
{
    auto p = new Expr;
    *p = e;
    return p;
}

version(unittest)
{
    import silver.parse : parse;

    private Module convertSource(string source)
    {
        return cstToAst(parse(source), "test");
    }
}

@("cstToAst: precedence and parentheses")
unittest
{
    auto m = convertSource("var x = (1 + y) * 2");
    m.statements.length.should.equal(1);
    printStmt(m.statements[0]).should.equal("(var x (Multiply (Add 1 y) 2))");
}

@("cstToAst: binary operators are left-associative")
unittest
{
    auto m = convertSource("var x = 1 - 2 - 3\nvar y = a == b");
    m.statements.length.should.equal(2);
    printStmt(m.statements[0]).should.equal("(var x (Subtract (Subtract 1 2) 3))");
    printStmt(m.statements[1]).should.equal("(var y (Equal a b))");
}

@("cstToAst: power binds tighter than multiply and unary, and is right-associative")
unittest
{
    auto m = convertSource("var a = 2 * 3 ^ 2\nvar b = 2 ^ 3 ^ 2\nvar c = -2 ^ 2\nvar d = 2 ^ -1");
    m.statements.length.should.equal(4);
    printStmt(m.statements[0]).should.equal("(var a (Multiply 2 (Power 3 2)))");
    printStmt(m.statements[1]).should.equal("(var b (Power 2 (Power 3 2)))");
    printStmt(m.statements[2]).should.equal("(var c (Minus (Power 2 2)))");
    printStmt(m.statements[3]).should.equal("(var d (Power 2 (Minus 1)))");
}



@("cstToAst: unary operators")
unittest
{
    auto m = convertSource("var x = -1\nvar y = !a");
    m.statements.length.should.equal(2);
    printStmt(m.statements[0]).should.equal("(var x (Minus 1))");
    printStmt(m.statements[1]).should.equal("(var y (Not a))");
}

/// `IfBlock ElseIfBlock* ElseBlock? END`. Each `else if` becomes an IfStmt
/// nested in the previous one's elseBody.
private Stmt convertIfStatement(ParseTree cst, string file)
{
    cst.validateNodeIs("Silver.IfStatement");
    auto ifBlock = cst[0];
    ifBlock.validateNodeIs("Silver.IfBlock");

    auto condition = convertExpression(ifBlock[0], file);
    auto body = convertOptionalBlock(ifBlock, 1, file);
    auto elseBody = convertElseChain(cst.children[1 .. $], cst, file);
    return Stmt(spanOf(cst, file), StmtKind(IfStmt(condition, body, elseBody)));
}

/// Converts the blocks after the IfBlock (`ElseIfBlock* ElseBlock?`) into an
/// elseBody, building from the end so each IfStmt is complete when created.
/// `ifStatement` is the enclosing IfStatement, which every nested if's span
/// runs to the end of.
private Stmt[] convertElseChain(ParseTree[] blocks, ParseTree ifStatement, string file)
{
    if (blocks.length == 0)
    {
        return [];
    }

    auto block = blocks[0];
    switch (block.name)
    {
    case "Silver.ElseBlock":
        return convertOptionalBlock(block, 0, file);
    case "Silver.ElseIfBlock":
        auto condition = convertExpression(block[0], file);
        auto body = convertOptionalBlock(block, 1, file);
        auto elseBody = convertElseChain(blocks[1 .. $], ifStatement, file);
        auto span = Span(file, block.begin, ifStatement.end);
        return [Stmt(span, StmtKind(IfStmt(condition, body, elseBody)))];
    default:
        throw new Exception("Expected else or else-if block, got '%s'".format(block.name));
    }
}

/// Converts `cst[index]` as a StatementBlock, or returns [] if the optional
/// block is absent (e.g. `if x then end`).
private Stmt[] convertOptionalBlock(ParseTree cst, size_t index, string file)
{
    if (cst.children.length <= index)
    {
        return [];
    }
    return convertStatementBlock(cst[index], file);
}

@("cstToAst: if with else-if chain and else")
unittest
{
    auto source = "if a then\nvar x = 1\nelse if b then\nvar x = 2\n"
        ~ "else if c then\nvar x = 3\nelse\nvar x = 4\nend";
    auto m = convertSource(source);
    m.statements.length.should.equal(1);
    printStmt(m.statements[0]).should.equal(
        "(if a ((var x 1)) ((if b ((var x 2)) ((if c ((var x 3)) ((var x 4)))))))");
}

@("cstToAst: if with empty body and no else")
unittest
{
    auto m = convertSource("if a then end");
    printStmt(m.statements[0]).should.equal("(if a () ())");
}

@("cstToAst: calls and member access fold left")
unittest
{
    auto m = convertSource("f(1, x)()\nvar y = m.x.f(2) + 1\nvar r = read");
    m.statements.length.should.equal(3);
    printStmt(m.statements[0]).should.equal("(call (call f 1 x))");
    printStmt(m.statements[1]).should.equal("(var y (Add (call (. (. m x) f) 2) 1))");
    printStmt(m.statements[2]).should.equal("(var r read)");
}

@("cstToAst: val and var declarations")
unittest
{
    auto m = convertSource("val x = 1\nvar y = x\nval value = 2");
    m.statements.length.should.equal(3);
    printStmt(m.statements[0]).should.equal("(val x 1)");
    printStmt(m.statements[1]).should.equal("(var y x)");
    printStmt(m.statements[2]).should.equal("(val value 2)");
}

@("cstToAst: assignment to a member")
unittest
{
    auto m = convertSource("a.b += 3");
    printStmt(m.statements[0]).should.equal("(assign (. a b) AddAssign 3)");
}

@("cstToAst: import")
unittest
{
    auto m = convertSource("import io\nimport a.b.c");
    m.statements.length.should.equal(2);
    printStmt(m.statements[0]).should.equal("(import io)");
    printStmt(m.statements[1]).should.equal("(import a.b.c)");
}

@("cstToAst: function declarations")
unittest
{
    auto m = convertSource("def h(p, q)\nvar z = p\nreturn z + q\nend\ndef k() return 1 end");
    m.statements.length.should.equal(2);
    printStmt(m.statements[0]).should.equal("(def h (p q) ((var z p) (return (Add z q))))");
    printStmt(m.statements[1]).should.equal("(def k () ((return 1)))");
}