module silver.syntax.lower;

import std.format : format;
import pegged.grammar : ParseTree;
import silver.ast;

import std.utf;

/// Lowers a parse tree from silver.syntax.parse into an AST Module.
/// `file` is recorded in every node's Span, for error messages.
Module lower(ParseTree tree, string moduleName, NodeIds ids, string file = "<input>")
{
    auto lowering = new Lowering(ids, file);
    return lowering.convertModule(tree, moduleName);
}

private final class Lowering
{
    private string file;
    private NodeIds ids;

    public this(NodeIds ids, string file)
    {
        this.ids = ids;
        this.file = file;
    }


    private Module convertModule(ParseTree tree, string moduleName)
    {
        tree.validateNodeIs("Silver");
        tree[0].validateNodeIs("Silver.Module");

        // Both the module line and the declarations are optional.
        ModuleDeclaration* header;
        Decl[] declarations;
        foreach (child; tree[0].children)
        {
            switch (child.name)
            {
            case "Silver.ModuleDeclaration":
                header = new ModuleDeclaration(qualifiedName(child[0]), spanOf(child, file));
                break;
            case "Silver.Declarations":
                foreach (declaration; child.children)
                {
                    declarations ~= convertDeclaration(declaration);
                }
                break;
            default:
                throw new Exception("Unexpected '%s' in module".format(child.name));
            }
        }
        return Module(ids.next!Module, moduleName, spanOf(tree, file), declarations, header);
    }

    /// `a.b.c` as ["a", "b", "c"].
    private static string[] qualifiedName(ParseTree cst)
    {
        import std.algorithm : filter;
        import std.array : array;

        // QualifiedName's matches are the identifiers with the '.'s between them.
        cst.validateNodeIs("Silver.QualifiedName");
        return cst.matches.filter!(m => m != ".").array;
    }


    private Decl convertDeclaration(ParseTree cst)
    {
        cst.validateNodeIs("Silver.Declaration");
        switch (cst[0].name)
        {
        case "Silver.ImportStatement":
            auto path = qualifiedName(cst[0][0]);
            return Decl(spanOf(cst[0], file), DeclKind(ImportStmt(ids.next!ImportStmt, path)));
        case "Silver.FunctionDeclaration":
        case "Silver.NativeFunctionDeclaration":
            return Decl(spanOf(cst[0], file), DeclKind(convertFunctionDeclaration(cst[0])));
        case "Silver.TypeDeclaration":
            return Decl(spanOf(cst[0], file), DeclKind(convertTypeDeclaration(cst[0])));
        default:
            throw new Exception("lower: declaration '%s' not supported yet".format(cst[0].name));
        }
    }

    private Stmt convertStatement(ParseTree cst)
    {
        switch (cst.name)
        {
        case "Silver.Statement":
            return convertStatement(cst[0]);
        case "Silver.VariableDeclaration":
        case "Silver.ValueDeclaration":
            // `Identifier TypeAnnotation? '=' Expression` once the keywords are discarded.
            auto name = cst[0].matches[0];
            if (cst.children[$ - 1].name != "Silver.Expression")
            {
                // `mutable val x: Int?` with no initializer
                throw new Exception("lower: declaration without an initializer not supported yet");
            }
            auto expr = convertExpression(cst.children[$ - 1]);
            TypeExpr* typeExpr = null;
            if (cst[1].name == "Silver.TypeAnnotation")
            {
                typeExpr = boxed(convertTypeExpression(cst[1]));
            }
            auto mutable = cst.name == "Silver.VariableDeclaration";
            return Stmt(spanOf(cst, file), StmtKind(VarDecl(ids.next!VarDecl, name, spanOf(cst[0], file), expr, typeExpr, mutable)));
        case "Silver.AssignmentStatement":
            // The target is a Postfix, so `a.b = 1` keeps its member access.
            cst[0].validateNodeIs("Silver.AssignTarget");
            auto target = convertExpression(cst[0][0]);
            auto op = cst[1].matches[0];
            auto expr = convertExpression(cst[2]);
            if (op != "=")
            {
                // `a += 1` becomes `a = a + 1`, so nothing past lowering sees compound assignment.
                // The target is lowered again rather than copied, so the read gets its own IDs.
                auto read = convertExpression(cst[0][0]);
                auto binary = BinaryExpr(toBinaryOp(op[0 .. $ - 1]), boxed(read), boxed(expr));
                expr = Expr(ids.next!Expr, Span(file, target.span.start, expr.span.end), ExprKind(binary));
            }
            return Stmt(spanOf(cst, file), StmtKind(AssignStmt(target, expr)));
        case "Silver.FunctionDeclaration":
        case "Silver.NativeFunctionDeclaration":
            auto decl = convertFunctionDeclaration(cst);
            return Stmt(spanOf(cst, file), StmtKind(decl));
        case "Silver.ReturnStatement":
            // `RETURN Expression?`; the keyword is kept so a bare `return` still has a node.
            auto value = cst.children.length > 1
                ? convertExpression(cst[1]) : Expr(ids.next!Expr, spanOf(cst, file), ExprKind(UnitLiteral()));
            return Stmt(spanOf(cst, file), StmtKind(ReturnStmt(value)));
        case "Silver.ExpressionStatement":
            return Stmt(spanOf(cst, file), StmtKind(ExprStmt(convertExpression(cst[0]))));
        default:
            throw new Exception("lower: statement '%s' not supported yet".format(cst.name));
        }
    }

    /// `TypeAnnotation`, or any of the rules under `Type`.
    /// `BaseType` and the parenthesized `( Type )` add no node of their own.
    private TypeExpr convertTypeExpression(ParseTree cst)
    {
        import std.algorithm : map;
        import std.array : array;

        switch (cst.name)
        {
        case "Silver.TypeAnnotation":
        case "Silver.BaseType":
            return convertTypeExpression(cst[0]);
        case "Silver.Type":
            // `BaseType OptionMark?`
            auto base = convertTypeExpression(cst[0]);
            if (cst.children.length == 1)
            {
                return base;
            }
            return TypeExpr(ids.next!TypeExpr, spanOf(cst, file), TypeExprKind(OptionType(boxed(base))));
        case "Silver.NamedType":
            // `TypePath TypeArguments?`. TypePath's children are just the names, without the '.'s.
            cst[0].validateNodeIs("Silver.TypePath");
            auto path = cst[0].children.map!(part => part.matches[0]).array;
            TypeExpr[] args;
            if (cst.children.length > 1)
            {
                args = cst[1].children.map!(a => convertTypeExpression(a)).array;
            }
            return TypeExpr(ids.next!TypeExpr, spanOf(cst, file), TypeExprKind(NamedType(path, args)));
        case "Silver.FunctionType":
            // The parameter types, then the return type.
            auto params = cst[0 .. $ - 1].map!(p => convertTypeExpression(p)).array;
            auto returnType = boxed(convertTypeExpression(cst[$ - 1]));
            return TypeExpr(ids.next!TypeExpr, spanOf(cst, file), TypeExprKind(FunctionType(params, returnType)));
        case "Silver.UnitType":
            return TypeExpr(ids.next!TypeExpr, spanOf(cst, file), TypeExprKind(UnitType()));
        default:
            throw new Exception("lower: type expression '%s' not supported yet".format(cst.name));
        }
    }

    private Expr convertExpression(ParseTree cst)
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
            return convertExpression(cst[0]);
        case "Silver.Block":
            return convertBlock(cst);
        case "Silver.UnitLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(UnitLiteral()));
        case "Silver.WhileExpression":
            return convertWhileExpression(cst);
        case "Silver.IfExpression":
            return convertIfExpression(cst);
        case "Silver.RelationalExpression":
        case "Silver.OrExpression":
        case "Silver.AndExpression":
        case "Silver.EqExpression":
        case "Silver.AdditionExpression":
        case "Silver.MultiplyExpression":
        case "Silver.CoalesceExpression":
        case "Silver.BitOrExpression":
        case "Silver.BitXorExpression":
        case "Silver.BitAndExpression":
        case "Silver.ShiftExpression":
            // `X (Op X)*`, folded left so `1 - 2 - 3` is `(1 - 2) - 3`.
            auto lhs = convertExpression(cst[0]);
            foreach (pair; cst.children.drop(1).chunks(2))
            {
                auto op = toBinaryOp(pair[0].matches[0]);
                auto rhs = convertExpression(pair[1]);
                auto span = Span(file, lhs.span.start, rhs.span.end);
                lhs = Expr(ids.next!Expr, span, ExprKind(BinaryExpr(op, boxed(lhs), boxed(rhs))));
            }
            return lhs;
        case "Silver.Unary":
            if (cst.children.length == 1)
            {
                return convertExpression(cst[0]);
            }
            auto op = toUnaryOp(cst[0].matches[0]);
            auto operand = convertExpression(cst[1]);
            auto span = Span(file, cst.begin, operand.span.end);
            return Expr(ids.next!Expr, span, ExprKind(UnaryExpr(op, boxed(operand))));
            break;
        case "Silver.Postfix":
            // `Eval PostfixOp*`, folded left so `m.f(1)` is `call (m.f) 1`.
            {
                auto lhs = convertExpression(cst[0]);
                foreach (postfixOp; cst.children.drop(1))
                {
                    postfixOp.validateNodeIs("Silver.PostfixOp");
                    lhs = convertPostfixOp(lhs, postfixOp[0]);
                }
                return lhs;
            }
        case "Silver.BooleanLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(BoolLiteral(cst.matches[0].to!bool)));
        case "Silver.UnsignedLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(integerLiteral(cst.matches[0], 10)));
        case "Silver.IntegerLiteral":
            // The sign is only here when a unary operator didn't take it first, as in `--5`.
            {
                auto text = cst.matches[0];
                auto signed = text[0] == '-' || text[0] == '+';
                auto literal = Expr(ids.next!Expr, spanOf(cst, file),
                    ExprKind(integerLiteral(signed ? text[1 .. $] : text, 10)));
                if (text[0] != '-') return literal;
                return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(UnaryExpr(UnaryOp.Minus, boxed(literal))));
            }
        case "Silver.FloatingLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(FloatLiteral(cst.matches[0].to!double)));
        case "Silver.Identifier":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(Identifier(cst.matches[0])));
        case "Silver.StringLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(StringLiteral(stringValue(cst))));
        case "Silver.ScientificLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(FloatLiteral(cst.matches[0].to!double)));
        case "Silver.HexaLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(integerLiteral(cst.matches[0][2 .. $], 16)));
        case "Silver.BinaryLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(integerLiteral(cst.matches[0][2 .. $], 2)));
        case "Silver.TypeName":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(Identifier(cst.matches[0])));
        default:
            break;
        }
        throw new Exception("lower: expression '%s' not supported yet".format(cst.name));
    }

    /// The text of a StringLiteral, with escapes decoded.
    private static string stringValue(ParseTree cst)
    {
        string value;
        foreach (part; cst.children)
        {
            part.validateNodeIs("Silver.StringPart");
            auto piece = part[0];
            switch (piece.name)
            {
            case "Silver.StringText":
                value ~= piece.matches[0];
                break;
            case "Silver.EscapeSequence":
                value ~= decodeEscape(piece.matches[0]);
                break;
            default:
                throw new Exception("Unexpected '%s' in string literal".format(piece.name));
            }
        }
        return value;
    }

    private static char decodeEscape(string escape)
    {
        switch (escape[1])
        {
        case 'n':
            return '\n';
        case 'r':
            return '\r';
        case 't':
            return '\t';
        case '0':
            return '\0';
        default:
            // `\"` and `\\` stand for the character itself.
            return escape[1];
        }
    }

    // WhileExpression      < :WHILE Expression Block
    private Expr convertWhileExpression(ParseTree cst)
    {
        cst.validateNodeIs("Silver.WhileExpression");
        auto condition = convertExpression(cst[0]);
        auto body = convertExpression(cst[1]);
        return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(WhileExpr(boxed(condition), boxed(body))));
    }

    /// `IF Expression IfBranch (ELSE ElseBranch)?`. An else-if is just an
    /// ElseBranch whose expression is another IfExpression.
    private Expr convertIfExpression(ParseTree cst)
    {
        cst.validateNodeIs("Silver.IfExpression");
        auto condition = convertExpression(cst[0]);
        auto thenBranch = convertExpression(cst[1]);
        Expr* elseBranch = cst.children.length > 2 ? boxed(convertExpression(cst[2])) : null;
        return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(IfExpr(boxed(condition), boxed(thenBranch), elseBranch)));
    }

    /// Applies one postfix operation (a call or member access) to `lhs`.
    private Expr convertPostfixOp(Expr lhs, ParseTree op)
    {
        auto span = Span(file, lhs.span.start, spanOf(op, file).end);
        switch (op.name)
        {
        case "Silver.CallArgs":
            Expr[] args;
            foreach (argument; op.children)
            {
                argument.validateNodeIs("Silver.Argument");
                args ~= convertExpression(argument[0]);
            }
            return Expr(ids.next!Expr, span, ExprKind(CallExpr(boxed(lhs), args)));
        case "Silver.MemberAccess":
            return Expr(ids.next!Expr, span, ExprKind(MemberAccess(boxed(lhs), op.matches[0])));
        default:
            throw new Exception("Expected call or member access, got '%s'".format(op.name));
        }
    }

    /// `DEF Identifier Params? TypeAnnotation ('=>' Expression / Block)`,
    /// or `NATIVE DEF Identifier Params? TypeAnnotation` with no body.
    /// Params is absent rather than empty when there are no params,
    /// so children are matched by name.
    private FunctionDecl convertFunctionDeclaration(ParseTree cst)
    {
        auto native = cst.name == "Silver.NativeFunctionDeclaration";
        if (!native)
        {
            cst.validateNodeIs("Silver.FunctionDeclaration");
        }
        auto name = cst[0].matches[0];

        Param[] params;
        Expr* body;
        TypeExpr returnType;
        foreach (child; cst.children[1 .. $])
        {
            switch (child.name)
            {
            case "Silver.Params":
                foreach (param; child.children)
                {
                    params ~= Param(ids.next!Param, param.matches[0], spanOf(param[0], file), convertTypeExpression(param[1]));
                }
                break;
            case "Silver.TypeAnnotation":
                returnType = convertTypeExpression(child);
                break;
            case "Silver.Block":
            case "Silver.Expression":
                body = boxed(convertExpression(child));
                break;
            default:
                throw new Exception("Unexpected '%s' in function declaration".format(child.name));
            }
        }
        return FunctionDecl(ids.next!FunctionDecl, name, spanOf(cst[0], file), params, body, returnType, native);
    }

    /// `type Name`, `type Name()` or `type Name(fields)`. Fields has no Params child when the parens are empty.
    private TypeDecl convertTypeDeclaration(ParseTree cst)
    {
        cst.validateNodeIs("Silver.TypeDeclaration");
        auto name = cst[0].matches[0];

        Field[] fields;
        bool emptyParens;
        if (cst.children.length > 1)
        {
            auto fieldList = cst[1];
            fieldList.validateNodeIs("Silver.Fields");
            emptyParens = fieldList.children.length == 0;
            foreach (params; fieldList.children)
            {
                params.validateNodeIs("Silver.Params");
                foreach (param; params.children)
                {
                    fields ~= Field(ids.next!Field, param.matches[0], spanOf(param[0], file),
                        convertTypeExpression(param[1]));
                }
            }
        }
        return TypeDecl(ids.next!TypeDecl, name, spanOf(cst[0], file), fields, emptyParens);
    }

    /// `{ Statement* }`. When the last statement is an expression it becomes the
    /// block's value; otherwise the value is null, meaning ().
    private Expr convertBlock(ParseTree cst)
    {
        cst.validateNodeIs("Silver.Block");
        auto statements = cst.children;
        BlockExpr block;
        if (statements.length > 0 && statements[$ - 1][0].name == "Silver.ExpressionStatement")
        {
            // Statement -> ExpressionStatement -> Expression
            block.value = boxed(convertExpression(statements[$ - 1][0][0]));
            statements = statements[0 .. $ - 1];
        }
        foreach (statement; statements)
        {
            block.statements ~= convertStatement(statement);
        }
        return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(block));
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
        case "~":
            return UnaryOp.BitNot;
        default:
            throw new Exception("Unknown unary operator '%s'".format(op));
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
        case "&":
            return BinaryOp.BitAnd;
        case "|":
            return BinaryOp.BitOr;
        case "^":
            return BinaryOp.BitXor;
        case "<<":
            return BinaryOp.ShiftLeft;
        case ">>":
            return BinaryOp.ShiftRight;
        case "&+":
            return BinaryOp.WrappingAdd;
        case "&-":
            return BinaryOp.WrappingSubtract;
        case "&*":
            return BinaryOp.WrappingMultiply;
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

    /// Copies `node` to the heap, for nodes that hold their children by pointer.
    private T* boxed(T)(T node)
    {
        auto p = new T;
        *p = node;
        return p;
    }
}


void validateNodeIs(ParseTree tree, string type)
{
    if (tree.name != type)
    {
        throw new Exception("Expected node of type '%s', got '%s'".format(type, tree.name));
    }
}

/// `digits` without any prefix or sign.
private IntLiteral integerLiteral(string digits, uint radix)
{
    import std.array : replace;
    import std.conv : ConvOverflowException, to;

    try
    {
        return IntLiteral(digits.replace("_", "").to!ulong(radix));
    }
    catch (ConvOverflowException)
    {
        return IntLiteral(0, true);
    }
}

private Span spanOf(ParseTree cst, string file)
{
    return Span(file, cst.begin, contentEnd(cst.input, cst.begin, cst.end));
}

/// Pegged's `<` rules count the spacing after their last element as part of the match,
/// so this finds the end of the last token in `input[begin .. end]` instead.
private size_t contentEnd(string input, size_t begin, size_t end)
{
    import std.algorithm.searching : startsWith;

    size_t last = begin;
    size_t i = begin;
    while (i < end)
    {
        auto rest = input[i .. end];
        if (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r')
        {
            i++;
        }
        else if (rest.startsWith("//"))
        {
            while (i < end && input[i] != '\n' && input[i] != '\r')
                i++;
        }
        else if (rest.startsWith("/*"))
        {
            i = blockCommentEnd(input, i, end);
        }
        else if (rest[0] == '"')
        {
            // Skipped whole, so a `//` inside a string isn't taken for a comment.
            i++;
            while (i < end && input[i] != '"')
                i += input[i] == '\\' ? 2 : 1;
            i = i < end ? i + 1 : end;
            last = i;
        }
        else
        {
            last = ++i;
        }
    }
    return last;
}

private size_t blockCommentEnd(string input, size_t i, size_t end)
{
    import std.algorithm.searching : startsWith;

    size_t depth = 0;
    while (i < end)
    {
        if (input[i .. end].startsWith("/*"))
        {
            depth++;
            i += 2;
        }
        else if (input[i .. end].startsWith("*/"))
        {
            i += 2;
            if (--depth == 0)
                return i;
        }
        else
        {
            i++;
        }
    }
    return end;
}
@("contentEnd stops before trailing spacing")
unittest
{
    size_t endOf(string s) => contentEnd(s, 0, s.length);

    assert(endOf("x") == 1);
    assert(endOf("x  \t") == 1);
    assert(endOf("x // note") == 1);
    assert(endOf("x /* a /* nested */ b */ ") == 1);
    assert(endOf("a /* c */ b ") == 11);
    assert(endOf(`"a // b" `) == 8);
    assert(endOf(`"a \" b" `) == 8);
    assert(endOf("{\n  x\n}\n") == 7);
}

@("node spans exclude the spacing after them")
unittest
{
    import std.sumtype : match;
    import silver.syntax.parse : parse;

    auto source = "def f(): Int => if c /* why */ { 1 } // one\n else { 2 }";
    auto m = parse(source, "test", new NodeIds);
    auto body = m.declarations[0].kind.match!(
        (const FunctionDecl f) => f.body,
        _ => null,
    );
    auto ifExpr = (*body).kind.match!(
        (const IfExpr i) => i,
        _ => IfExpr.init,
    );
    string text(Span s) => source[s.start .. s.end];

    assert(text(ifExpr.condition.span) == "c");
    assert(text(ifExpr.trueBody.span) == "{ 1 }");
    assert(text((*body).span) == "if c /* why */ { 1 } // one\n else { 2 }");
}
