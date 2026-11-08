module silver.syntax.lower;

import std.algorithm : canFind, map;
import std.array : array;
import std.format : format;
import std.sumtype : match;
import pegged.grammar : ParseTree;
import silver.ast;
import silver.syntax.parse : ParseException;

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
        case "Silver.ConstantDeclaration":
            return Decl(spanOf(cst[0], file), DeclKind(convertConstantDeclaration(cst[0])));
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
            TypeExpr* typeExpr = null;
            if (cst[1].name == "Silver.TypeAnnotation")
            {
                typeExpr = boxed(convertTypeExpression(cst[1]));
            }
            Expr expr;
            if (cst.children[$ - 1].name == "Silver.Expression")
            {
                expr = convertExpression(cst.children[$ - 1]);
            }
            else
            {
                // `mutable val x: Int?` with no initializer
                auto isOption = typeExpr.kind.match!((const OptionType _) => true, _ => false);
                if (!isOption)
                {
                    throw new ParseException(Diagnostic(DiagnosticCode.ParseError, spanOf(cst[0], file),
                        "`%s` needs an initializer; only an option type defaults to `None`".format(name), Severity.Error));
                }
                expr = Expr(ids.next!Expr, spanOf(cst, file), ExprKind(NoneLiteral()));
            }
            auto mutable = cst.name == "Silver.VariableDeclaration";
            return Stmt(spanOf(cst, file), StmtKind(VarDecl(ids.next!VarDecl, name, spanOf(cst[0], file), expr, typeExpr, mutable)));
        case "Silver.PatternDeclaration":
            // `MUTABLE? TuplePattern Expression` once `val` and `=` are discarded.
            auto mutablePattern = cst[0].name == "Silver.MUTABLE";
            auto pattern = convertPattern(cst[mutablePattern ? 1 : 0], mutablePattern);
            return Stmt(spanOf(cst, file), StmtKind(PatternDecl(pattern, convertExpression(cst.children[$ - 1]))));
        case "Silver.DiscardStatement":
            auto discarded = convertExpression(cst[0]);
            return Stmt(spanOf(cst, file), StmtKind(VarDecl(ids.next!VarDecl, discardName,
                Span(file, cst.begin, cst.begin + discardName.length), discarded, null, false)));
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
                auto binaryOp = op == "~=" ? BinaryOp.Append : toBinaryOp(op[0 .. $ - 1]);
                auto binary = BinaryExpr(binaryOp, boxed(read), boxed(expr));
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
        case "Silver.BreakStatement":
            return Stmt(spanOf(cst, file), StmtKind(BreakStmt()));
        case "Silver.ContinueStatement":
            return Stmt(spanOf(cst, file), StmtKind(ContinueStmt()));
        case "Silver.ExpressionStatement":
            return Stmt(spanOf(cst, file), StmtKind(ExprStmt(convertExpression(cst[0]))));
        default:
            throw new Exception("lower: statement '%s' not supported yet".format(cst.name));
        }
    }

    /// `TuplePattern`, or a `PatternElement` in one: a nested tuple, or a name with an optional type.
    private Pattern convertPattern(ParseTree cst, bool mutable)
    {
        switch (cst.name)
        {
        case "Silver.PatternElement":
            if (cst[0].name == "Silver.TuplePattern") return convertPattern(cst[0], mutable);
            TypeExpr* type = cst.children.length > 1 ? boxed(convertTypeExpression(cst[1])) : null;
            // A binding in a pattern has no value of its own; see VarDecl.value.
            auto binding = VarDecl(ids.next!VarDecl, cst[0].matches[0], spanOf(cst[0], file), Expr.init, type, mutable);
            return Pattern(spanOf(cst, file), PatternKind(binding));
        case "Silver.TuplePattern":
            Pattern[] elements;
            foreach (element; cst.children)
            {
                elements ~= convertPattern(element, mutable);
            }
            return Pattern(spanOf(cst, file), PatternKind(TuplePattern(elements)));
        default:
            throw new Exception("Unexpected '%s' in pattern".format(cst.name));
        }
    }

    /// `TypeAnnotation`, or any of the rules under `Type`. `BaseType` adds no node of its own,
    /// and neither does a `ParenType` around one type, which is only grouping.
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
        case "Silver.ArrayType":
            return TypeExpr(ids.next!TypeExpr, spanOf(cst, file),
                TypeExprKind(ArrayType(boxed(convertTypeExpression(cst[0])))));
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
            TypeExpr[] params;
            bool[] mutables;
            foreach (param; cst[0 .. $ - 1])
            {
                param.validateNodeIs("Silver.FunctionTypeParam");
                mutables ~= param.children.length == 2;
                params ~= convertTypeExpression(param[$ - 1]);
            }
            if (!mutables.canFind(true)) mutables = null;
            auto returnType = boxed(convertTypeExpression(cst[$ - 1]));
            return TypeExpr(ids.next!TypeExpr, spanOf(cst, file), TypeExprKind(FunctionType(params, mutables, returnType)));
        case "Silver.UnitType":
            return TypeExpr(ids.next!TypeExpr, spanOf(cst, file), TypeExprKind(UnitType()));
        case "Silver.ParenType":
            if (cst.children.length == 1) return convertTypeExpression(cst[0]);
            auto elements = cst.children.map!(e => convertTypeExpression(e)).array;
            return TypeExpr(ids.next!TypeExpr, spanOf(cst, file), TypeExprKind(TupleType(elements)));
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
        case "Silver.CollectionLiteral":
            return convertExpression(cst[0]);
        case "Silver.ListLiteral":
            return convertListLiteral(cst);
        case "Silver.MapLiteral":
            return convertMapLiteral(cst);
        case "Silver.RangeExpression":
            if (cst.children.length == 1) return convertExpression(cst[0]);
            auto rangeStart = convertExpression(cst[0]);
            auto rangeEnd = convertExpression(cst[1]);
            return Expr(ids.next!Expr, Span(file, rangeStart.span.start, rangeEnd.span.end),
                ExprKind(RangeExpr(boxed(rangeStart), boxed(rangeEnd))));
        case "Silver.Block":
            return convertBlock(cst);
        case "Silver.UnitLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(UnitLiteral()));
        case "Silver.ParenExpression":
            if (cst.children.length == 1) return convertExpression(cst[0]);
            Expr[] elements;
            foreach (element; cst.children)
            {
                elements ~= convertExpression(element);
            }
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(TupleLiteral(elements)));
        case "Silver.WhileExpression":
            return convertWhileExpression(cst);
        case "Silver.ForExpression":
            return convertForExpression(cst);
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
            return convertStringLiteral(cst);
        case "Silver.ScientificLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(FloatLiteral(cst.matches[0].to!double)));
        case "Silver.HexaLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(integerLiteral(cst.matches[0][2 .. $], 16)));
        case "Silver.BinaryLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(integerLiteral(cst.matches[0][2 .. $], 2)));
        case "Silver.TypeName":
            if (cst.matches[0] == "None") return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(NoneLiteral()));
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(Identifier(cst.matches[0])));
        default:
            break;
        }
        throw new Exception("lower: expression '%s' not supported yet".format(cst.name));
    }

    /// A StringLiteral with escapes decoded, or an InterpolatedString if the source has holes.
    private Expr convertStringLiteral(ParseTree cst)
    {
        Expr[] parts;
        string text;
        Span textSpan;
        void endText()
        {
            if (text.length == 0) return;
            parts ~= Expr(ids.next!Expr, textSpan, ExprKind(StringLiteral(text)));
            text = null;
        }

        auto hasHoles = false;
        foreach (part; cst.children)
        {
            part.validateNodeIs("Silver.StringPart");
            auto piece = part[0];
            if (piece.name == "Silver.StringHole")
            {
                if (piece.children.length == 0)
                {
                    throw new ParseException(Diagnostic(DiagnosticCode.ParseError, spanOf(piece, file),
                        "A string hole needs an expression; write `\\{` for a literal brace", Severity.Error));
                }
                hasHoles = true;
                endText();
                parts ~= convertExpression(piece[0]);
                continue;
            }
            auto pieceSpan = spanOf(piece, file);
            textSpan = Span(file, text.length == 0 ? pieceSpan.start : textSpan.start, pieceSpan.end);
            switch (piece.name)
            {
            case "Silver.StringText":
                text ~= piece.matches[0];
                break;
            case "Silver.EscapeSequence":
                text ~= decodeEscape(piece.matches[0]);
                break;
            default:
                throw new Exception("Unexpected '%s' in string literal".format(piece.name));
            }
        }

        if (!hasHoles) return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(StringLiteral(text)));
        endText();
        return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(InterpolatedString(parts)));
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

    private Expr convertListLiteral(ParseTree cst)
    {
        Expr[] elements;
        foreach (element; cst.children)
        {
            elements ~= convertExpression(element);
        }
        return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(ArrayLiteral(elements)));
    }

    private Expr convertMapLiteral(ParseTree cst)
    {
        Expr[] keys;
        Expr[] values;
        foreach (entry; cst.children)
        {
            entry.validateNodeIs("Silver.MapEntry");
            keys ~= convertExpression(entry[0]);
            values ~= convertExpression(entry[1]);
        }
        return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(MapLiteral(keys, values)));
    }

    /// `Identifier Expression` once the keyword and `=` are discarded.
    private VarDecl* convertOptionBinding(ParseTree cst)
    {
        cst.validateNodeIs("Silver.OptionBinding");
        return boxed(VarDecl(ids.next!VarDecl, cst[0].matches[0], spanOf(cst[0], file),
            convertExpression(cst[1]), null, false));
    }

    // WhileExpression      < :WHILE (OptionBinding / Expression) Block
    private Expr convertWhileExpression(ParseTree cst)
    {
        cst.validateNodeIs("Silver.WhileExpression");
        Expr* condition = null;
        VarDecl* binding = null;
        if (cst[0].name == "Silver.OptionBinding")
        {
            binding = convertOptionBinding(cst[0]);
        }
        else
        {
            condition = boxed(convertExpression(cst[0]));
        }
        auto body = convertExpression(cst[1]);
        return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(WhileExpr(condition, boxed(body), binding)));
    }

    /// `BindingName Expression Block` once the keywords are discarded.
    private Expr convertForExpression(ParseTree cst)
    {
        cst.validateNodeIs("Silver.ForExpression");
        auto binding = boxed(VarDecl(ids.next!VarDecl, cst[0].matches[0], spanOf(cst[0], file),
            convertExpression(cst[1]), null, false));
        auto body = convertExpression(cst[2]);
        return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(ForExpr(binding, boxed(body))));
    }

    /// `IF Expression IfBranch (ELSE ElseBranch)?`. An else-if is just an
    /// ElseBranch whose expression is another IfExpression.
    private Expr convertIfExpression(ParseTree cst)
    {
        cst.validateNodeIs("Silver.IfExpression");
        Expr* condition = null;
        VarDecl* binding = null;
        if (cst[0].name == "Silver.OptionBinding")
        {
            binding = convertOptionBinding(cst[0]);
        }
        else
        {
            condition = boxed(convertExpression(cst[0]));
        }
        auto thenBranch = convertExpression(cst[1]);
        Expr* elseBranch = cst.children.length > 2 ? boxed(convertExpression(cst[2])) : null;
        return Expr(ids.next!Expr, spanOf(cst, file),
            ExprKind(IfExpr(condition, boxed(thenBranch), elseBranch, binding)));
    }

    /// Applies one postfix operation (a call or member access) to `lhs`.
    private Expr convertPostfixOp(Expr lhs, ParseTree op)
    {
        auto span = Span(file, lhs.span.start, spanOf(op, file).end);
        switch (op.name)
        {
        case "Silver.CallArgs":
            Expr[] args;
            bool[] mutables;
            foreach (argument; op.children)
            {
                argument.validateNodeIs("Silver.Argument");
                mutables ~= argument.children.length == 2;
                args ~= convertExpression(argument[$ - 1]);
            }
            if (!mutables.canFind(true)) mutables = null;
            auto isSome = lhs.kind.match!((const Identifier callee) => callee.name == "Some", _ => false);
            if (isSome && args.length == 1 && mutables is null) return Expr(ids.next!Expr, span, ExprKind(SomeExpr(boxed(args[0]))));
            return Expr(ids.next!Expr, span, ExprKind(CallExpr(boxed(lhs), args, mutables)));
        case "Silver.WithUpdate":
            FieldUpdate[] updates;
            foreach (update; op.children)
            {
                update.validateNodeIs("Silver.FieldUpdate");
                auto path = update[0].matches;
                updates ~= FieldUpdate(path, spanOf(update[0], file), convertExpression(update[1]));
            }
            return Expr(ids.next!Expr, span, ExprKind(WithExpr(boxed(lhs), updates)));
        case "Silver.MemberAccess":
            return Expr(ids.next!Expr, span, ExprKind(MemberAccess(boxed(lhs), op.matches[0])));
        case "Silver.SafeMemberAccess":
            return Expr(ids.next!Expr, span, ExprKind(SafeMemberAccess(boxed(lhs), op.matches[0])));
        case "Silver.PropagateNone":
            return Expr(ids.next!Expr, span, ExprKind(PropagateExpr(boxed(lhs))));
        case "Silver.IndexArgs":
            return Expr(ids.next!Expr, span, ExprKind(IndexExpr(boxed(lhs), boxed(convertExpression(op[0])))));
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
                    auto mutable = param.children.length == 3;
                    auto paramName = param[mutable ? 1 : 0];
                    params ~= Param(ids.next!Param, paramName.matches[0], spanOf(paramName, file),
                        convertTypeExpression(param[$ - 1]), mutable);
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
                params.validateNodeIs("Silver.FieldList");
                foreach (param; params.children)
                {
                    fields ~= Field(ids.next!Field, param.matches[0], spanOf(param[0], file),
                        convertTypeExpression(param[1]));
                }
            }
        }
        return TypeDecl(ids.next!TypeDecl, name, spanOf(cst[0], file), fields, emptyParens);
    }

    /// `Identifier TypeAnnotation? '=' Expression` once the keyword is discarded.
    private ConstDecl convertConstantDeclaration(ParseTree cst)
    {
        cst.validateNodeIs("Silver.ConstantDeclaration");
        TypeExpr* type = cst[1].name == "Silver.TypeAnnotation" ? boxed(convertTypeExpression(cst[1])) : null;
        return ConstDecl(ids.next!ConstDecl, cst[0].matches[0], spanOf(cst[0], file), type,
            convertExpression(cst.children[$ - 1]));
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
        case "~":
            return BinaryOp.Concat;
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

@("only an option type can leave out a mutable val's initializer")
unittest
{
    import std.exception : collectException;
    import silver.syntax.parse : parse;

    auto error = collectException!ParseException(parse("def f(): Unit {\n    mutable val x: Int\n}", "test", new NodeIds));
    assert(error !is null);
    assert(error.diagnostic.code == DiagnosticCode.ParseError);
    assert(collectException!ParseException(parse("def f(): Unit {\n    mutable val x: Int?\n}", "test", new NodeIds)) is null);
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
