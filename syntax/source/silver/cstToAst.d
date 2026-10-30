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
    case "Silver.TopLevelStatement":
        return convertStatement(cst[0], file);
    case "Silver.VariableDeclaration":
    case "Silver.ValueDeclaration":
        // `Variable TypeAnnotation? '=' Expression` once the keywords are discarded.
        // The type isn't recorded yet, so only the last child's position matters.
        auto name = cst[0].matches[0];
        if (cst.children[$ - 1].name != "Silver.Expression")
        {
            // `mutable val x: Int?` with no initializer
            throw new Exception("cstToAst: declaration without an initializer not supported yet");
        }
        auto expr = convertExpression(cst.children[$ - 1], file);
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
    case "Silver.FunctionDeclaration":
        return convertFunctionDeclaration(cst, file);
    case "Silver.ReturnStatement":
        // `RETURN Expression?`; the keyword is kept so a bare `return` still has a node.
        auto value = cst.children.length > 1
            ? convertExpression(cst[1], file)
            : Expr(spanOf(cst, file), ExprKind(UnitLiteral()));
        return Stmt(spanOf(cst, file), StmtKind(ReturnStmt(value)));
    case "Silver.ExpressionStatement":
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
    case "Silver.IfBranch":
    case "Silver.ElseBranch":
        return convertExpression(cst[0], file);
    case "Silver.Block":
        return convertBlock(cst, file);
    case "Silver.UnitLiteral":
        return Expr(spanOf(cst, file), ExprKind(UnitLiteral()));
    case "Silver.IfExpression":
        return convertIfExpression(cst, file);
    case "Silver.RelationalExpression":
    case "Silver.OrExpression":
    case "Silver.AndExpression":
    case "Silver.EqExpression":
    case "Silver.AdditionExpression":
    case "Silver.MultiplyExpression":
    case "Silver.CoalesceExpression":
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

/// `IF Expression IfBranch (ELSE ElseBranch)?`. An else-if is just an
/// ElseBranch whose expression is another IfExpression.
private Expr convertIfExpression(ParseTree cst, string file)
{
    cst.validateNodeIs("Silver.IfExpression");
    auto condition = convertExpression(cst[0], file);
    auto thenBranch = convertExpression(cst[1], file);
    Expr* elseBranch = cst.children.length > 2 ? boxed(convertExpression(cst[2], file)) : null;
    return Expr(spanOf(cst, file), ExprKind(IfExpr(boxed(condition), boxed(thenBranch), elseBranch)));
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

/// `DEF Variable FunctionParamDefs? TypeAnnotation ('=>' Expression / Block)`.
/// FunctionParamDefs is absent rather than empty when there are no params,
/// so children are matched by name.
private Stmt convertFunctionDeclaration(ParseTree cst, string file)
{
    cst.validateNodeIs("Silver.FunctionDeclaration");
    auto name = cst[0].matches[0];

    string[] params;
    Expr* body;
    string returnType;
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
        case "Silver.TypeAnnotation":
            returnType = child.matches[0];
            break;
        case "Silver.Block":
        case "Silver.Expression":
            body = boxed(convertExpression(child, file));
            break;
        default:
            throw new Exception("Unexpected '%s' in function declaration".format(child.name));
        }
    }
    return Stmt(spanOf(cst, file), StmtKind(FunctionDecl(name, params, body, returnType)));
}

/// `{ Statement* }`. When the last statement is an expression it becomes the
/// block's value; otherwise the value is null, meaning ().
private Expr convertBlock(ParseTree cst, string file)
{
    cst.validateNodeIs("Silver.Block");
    auto statements = cst.children;
    BlockExpr block;
    if (statements.length > 0 && statements[$ - 1][0].name == "Silver.ExpressionStatement")
    {
        // Statement -> ExpressionStatement -> Expression
        block.value = boxed(convertExpression(statements[$ - 1][0][0], file));
        statements = statements[0 .. $ - 1];
    }
    foreach (statement; statements)
    {
        block.statements ~= convertStatement(statement, file);
    }
    return Expr(spanOf(cst, file), ExprKind(block));
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
    case "<":
        return BinaryOp.Less;
    case "<=":
        return BinaryOp.LessEqual;
    case ">":
        return BinaryOp.Greater;
    case ">=":
        return BinaryOp.GreaterEqual;
    case "??":
        return BinaryOp.Coalesce;
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
        return parse(source, "test", "test");
    }
}

@("cstToAst: precedence and parentheses")
unittest
{
    auto m = convertSource("val x = (1 + y) * 2");
    m.statements.length.should.equal(1);
    printStmt(m.statements[0]).should.equal("(val x (Multiply (Add 1 y) 2))");
}

@("cstToAst: binary operators are left-associative")
unittest
{
    auto m = convertSource("val x = 1 - 2 - 3\nval y = a == b");
    m.statements.length.should.equal(2);
    printStmt(m.statements[0]).should.equal("(val x (Subtract (Subtract 1 2) 3))");
    printStmt(m.statements[1]).should.equal("(val y (Equal a b))");
}

@("cstToAst: power binds tighter than multiply and unary, and is right-associative")
unittest
{
    auto m = convertSource("val a = 2 * 3 ^ 2\nval b = 2 ^ 3 ^ 2\nval c = -2 ^ 2\nval d = 2 ^ -1");
    m.statements.length.should.equal(4);
    printStmt(m.statements[0]).should.equal("(val a (Multiply 2 (Power 3 2)))");
    printStmt(m.statements[1]).should.equal("(val b (Power 2 (Power 3 2)))");
    printStmt(m.statements[2]).should.equal("(val c (Minus (Power 2 2)))");
    printStmt(m.statements[3]).should.equal("(val d (Power 2 (Minus 1)))");
}



@("cstToAst: unary operators")
unittest
{
    auto m = convertSource("val x = -1\nval y = !a");
    m.statements.length.should.equal(2);
    printStmt(m.statements[0]).should.equal("(val x (Minus 1))");
    printStmt(m.statements[1]).should.equal("(val y (Not a))");
}

@("cstToAst: if with else-if chain and else")
unittest
{
    auto m = convertSource("if a => 1 else if b => 2 else if c { val x = 3 } else { 4 }");
    m.statements.length.should.equal(1);
    printStmt(m.statements[0]).should.equal(
        "(if a 1 (if b 2 (if c (block (val x 3)) (block => 4))))");
}

@("cstToAst: if without else, and empty blocks")
unittest
{
    auto m = convertSource("if a {}\nif a => b");
    printStmt(m.statements[0]).should.equal("(if a (block))");
    printStmt(m.statements[1]).should.equal("(if a b)");
}

@("cstToAst: a block's value is its last statement only if that's an expression")
unittest
{
    auto m = convertSource("val a = { val x = 1\nx }\nval b = { x = 1 }\nval c = { f()\ng() }");
    printStmt(m.statements[0]).should.equal("(val a (block (val x 1) => x))");
    printStmt(m.statements[1]).should.equal("(val b (block (assign x Assign 1)))");
    printStmt(m.statements[2]).should.equal("(val c (block (call f) => (call g)))");
}

@("cstToAst: return")
unittest
{
    auto m = convertSource("def f(): Int {\nreturn 1\n}\ndef g(): Unit {\nreturn\n}");
    printStmt(m.statements[0]).should.equal("(def f () : Int (block (return 1)))");
    printStmt(m.statements[1]).should.equal("(def g () : Unit (block (return ())))");
}

@("cstToAst: typed declarations")
unittest
{
    auto m = convertSource("val x: Int = 1\nmutable val y: Int? = 2");
    printStmt(m.statements[0]).should.equal("(val x 1)");
    printStmt(m.statements[1]).should.equal("(mutable val y 2)");
}
@("cstToAst: calls and member access fold left")
unittest
{
    auto m = convertSource("f(1, x)()\nval y = m.x.f(2) + 1\nval r = read");
    m.statements.length.should.equal(3);
    printStmt(m.statements[0]).should.equal("(call (call f 1 x))");
    printStmt(m.statements[1]).should.equal("(val y (Add (call (. (. m x) f) 2) 1))");
    printStmt(m.statements[2]).should.equal("(val r read)");
}

@("cstToAst: val declarations")
unittest
{
    auto m = convertSource("val x = 1\nval y = x\nval value = 2");
    m.statements.length.should.equal(3);
    printStmt(m.statements[0]).should.equal("(val x 1)");
    printStmt(m.statements[1]).should.equal("(val y x)");
    printStmt(m.statements[2]).should.equal("(val value 2)");
}

@("cstToAst: mutable val")
unittest
{
    auto m = convertSource("mutable val x = 1");
    printStmt(m.statements[0]).should.equal("(mutable val x 1)");
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
    auto m1 = convertSource("def f() : Int => 1");
    m1.statements.length.should.equal(1);
    printStmt(m1.statements[0]).should.equal("(def f () : Int 1)");

    auto m2 = convertSource("def h(p : Int, q:Int) : Int {\nval z = p\nz + q\n}\ndef k() : Int =>\n    1");
    m2.statements.length.should.equal(2);
    printStmt(m2.statements[0]).should.equal("(def h (p q) : Int (block (val z p) => (Add z q)))");
    printStmt(m2.statements[1]).should.equal("(def k () : Int 1)");
}

@("cstToAst: if expressions")
unittest
{
    auto m1 = convertSource("val a = if b => 1 else 2");
    m1.statements.length.should.equal(1);
    printStmt(m1.statements[0]).should.equal("(val a (if b 1 2))");

    auto m2 = convertSource("val a = if b {
        val a = 1
        a
    }
    else 2");
    m2.statements.length.should.equal(1);
    printStmt(m2.statements[0]).should.equal("(val a (if b (block (val a 1) => a) 2))");
}
