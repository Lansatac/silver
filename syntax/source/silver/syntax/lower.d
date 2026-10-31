module silver.syntax.lower;

import std.format : format;
import pegged.grammar : ParseTree;
import silver.ast;

import std.utf;

/// Lowers a parse tree from silver.syntax.parse into an AST Module.
/// `file` is recorded in every node's Span, for error messages.
Module lower(ParseTree tree, string moduleName, string file = "<input>")
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
            throw new Exception("lower: declaration without an initializer not supported yet");
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
    case "Silver.FunctionDeclaration":
    case "Silver.NativeFunctionDeclaration":
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
        throw new Exception("lower: statement '%s' not supported yet".format(cst.name));
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
    case "Silver.WhileExpression":
        return convertWhileExpression(cst, file);
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
    throw new Exception("lower: expression '%s' not supported yet".format(cst.name));
}

// WhileExpression      < :WHILE Expression Block
private Expr convertWhileExpression(ParseTree cst, string file)
{
    cst.validateNodeIs("Silver.WhileExpression");
    auto condition = convertExpression(cst[0], file);
    auto body = convertExpression(cst[1], file);
    return Expr(spanOf(cst, file), ExprKind(WhileExpr(boxed(condition), boxed(body))));
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

/// `DEF Variable FunctionParamDefs? TypeAnnotation ('=>' Expression / Block)`,
/// or `NATIVE DEF Variable FunctionParamDefs? TypeAnnotation` with no body.
/// FunctionParamDefs is absent rather than empty when there are no params,
/// so children are matched by name.
private Stmt convertFunctionDeclaration(ParseTree cst, string file)
{
    auto native = cst.name == "Silver.NativeFunctionDeclaration";
    if (!native)
    {
        cst.validateNodeIs("Silver.FunctionDeclaration");
    }
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
    return Stmt(spanOf(cst, file), StmtKind(FunctionDecl(name, params, body, returnType, native)));
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
