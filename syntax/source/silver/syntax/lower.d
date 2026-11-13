module silver.syntax.lower;

import std.algorithm : canFind, filter, map;
import std.array : array;
import std.format : format;
import std.sumtype : match;
import pegged.grammar : ParseTree;
import silver.ast;
import silver.syntax.parse : ParseException;

/// `to!double` rounds through x87 reals, so its result depends on the calling thread's FPU precision.
private double parseFloat(string text)
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;

    return strtod(text.toStringz, null);
}

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
    /// How many `for` loops so far take their element apart, for naming the element's local.
    private size_t _forPatterns;

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
        NativeLibrary* library;
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
                    if (declaration[0].name == "Silver.NativeLibrary")
                    {
                        library = convertNativeLibrary(declaration[0], library);
                        continue;
                    }
                    declarations ~= convertDeclaration(declaration);
                }
                declarations ~= implicitMarkers(declarations);
                break;
            default:
                throw new Exception("Unexpected '%s' in module".format(child.name));
            }
        }
        return Module(ids.next!Module, moduleName, spanOf(tree, file), declarations, header, library);
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


    /// A TypeDecl for each bare name in a sum that nothing in the module declares, and which
    /// isn't built in. Its members are marked as owned here, once every declaration is known.
    private Decl[] implicitMarkers(Decl[] declarations)
    {
        import std.traits : EnumMembers;

        bool[string] declared;
        foreach (ref declaration; declarations)
        {
            declaration.kind.match!(
                (ref TypeDecl type) { declared[type.name] = true; },
                (ref AliasDecl alias_) { declared[alias_.name] = true; },
                (ref _) {},
            );
        }

        Decl[] markers;
        foreach (ref declaration; declarations)
        {
            declaration.kind.match!(
                (ref TypeDecl sum) {
                    bool[string] inThisSum;
                    foreach (ref member; sum.members)
                    {
                        auto name = member.type.kind.match!(
                            (ref NamedType named) => named.path.length == 1 && named.args.length == 0 ? named.path[0] : null,
                            (ref _) => cast(string) null,
                        );
                        if (name is null || name in declared || [__traits(allMembers, Builtin)].canFind(name)) continue;
                        if (sum.typeParams.canFind!(p => p.name == name)) continue;

                        member.owned = true;
                        // Named twice in one sum is reported as a repeated member, not a redeclaration.
                        if (name in inThisSum) continue;
                        inThisSum[name] = true;
                        auto marker = TypeDecl(ids.next!TypeDecl, name, member.type.span, null, false, null, true, sum.isPrivate);
                        markers ~= Decl(member.type.span, DeclKind(marker));
                    }
                },
                (ref _) {},
            );
        }
        return markers;
    }

    /// One declaration, except that a sum comes with a declaration for each member it defines inline.
    private Decl[] convertDeclaration(ParseTree cst)
    {
        cst.validateNodeIs("Silver.Declaration");
        if (cst[0].name != "Silver.PrivateDeclaration") return convertDeclarationBody(cst[0]);

        auto declarations = convertDeclarationBody(cst[0][0]);
        foreach (ref declaration; declarations)
        {
            declaration.kind.match!(
                (ref FunctionDecl function_) { function_.isPrivate = true; },
                (ref TypeDecl type) { type.isPrivate = true; },
                (ref ConstDecl constant) { constant.isPrivate = true; },
                (ref AliasDecl alias_) { alias_.isPrivate = true; },
                (ref InterfaceDecl interface_) { interface_.isPrivate = true; },
                (ref ImportStmt _) {},
            );
        }
        return declarations;
    }

    private Decl[] convertDeclarationBody(ParseTree cst)
    {
        switch (cst.name)
        {
        case "Silver.ImportStatement":
            auto names = cst.children[1 .. $].map!(n => ImportedName(n.matches[0], spanOf(n, file))).array;
            return [Decl(spanOf(cst, file), DeclKind(ImportStmt(ids.next!ImportStmt, qualifiedName(cst[0]), names)))];
        case "Silver.FunctionDeclaration":
        case "Silver.NativeFunctionDeclaration":
        case "Silver.IntrinsicFunctionDeclaration":
            return [Decl(spanOf(cst, file), DeclKind(convertFunctionDeclaration(cst)))];
        case "Silver.TypeDeclaration":
            return convertTypeDeclaration(cst);
        case "Silver.AliasDeclaration":
            if (cst[1].name == "Silver.TypeParameters")
            {
                throw new ParseException(Diagnostic(DiagnosticCode.ParseError, spanOf(cst[1], file),
                    "An alias can't take type parameters yet; declare a generic `type` instead", Severity.Error));
            }
            auto alias_ =AliasDecl(ids.next!AliasDecl, cst[0].matches[0], spanOf(cst[0], file), convertTypeExpression(cst[1]));
            return [Decl(spanOf(cst, file), DeclKind(alias_))];
        case "Silver.InterfaceDeclaration":
            return [Decl(spanOf(cst, file), DeclKind(convertInterfaceDeclaration(cst)))];
        case "Silver.ConstantDeclaration":
            return [Decl(spanOf(cst, file), DeclKind(convertConstantDeclaration(cst)))];
        case "Silver.TestDeclaration":
            return [Decl(spanOf(cst, file), DeclKind(convertTest(cst)))];
        case "Silver.IntrinsicType":
            auto intrinsicType = convertProduct(cst[0], cst.children[$ - 1]);
            if (cst.children.length > 2) intrinsicType.typeParams = convertTypeParameters(cst[1]);
            intrinsicType.intrinsic = true;
            return [Decl(spanOf(cst, file), DeclKind(intrinsicType))];
        case "Silver.IntrinsicAlias":
            auto nameSpan = spanOf(cst[0], file);
            auto placeholder = TypeExpr(ids.next!TypeExpr, nameSpan, TypeExprKind(NamedType([cst[0].matches[0]], null)));
            auto intrinsic = AliasDecl(ids.next!AliasDecl, cst[0].matches[0], nameSpan, placeholder, false, true);
            return [Decl(spanOf(cst, file), DeclKind(intrinsic))];
        default:
            throw new Exception("lower: declaration '%s' not supported yet".format(cst.name));
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
            cst[0].validateNodeIs("Silver.AssignTarget");
            auto target = convertAssignTarget(cst[0][0]);
            auto op = cst[1].matches[0];
            auto expr = convertExpression(cst[2]);
            if (op != "=" && cst[0][0].name == "Silver.AssignTuple")
            {
                throw new ParseException(Diagnostic(DiagnosticCode.ParseError, spanOf(cst[1], file),
                    "`%s` needs one target; only `=` assigns to several at once".format(op), Severity.Error));
            }
            if (op != "=")
            {
                // `a += 1` becomes `a = a + 1`, so nothing past lowering sees compound assignment.
                // The target is lowered again rather than copied, so the read gets its own IDs.
                auto read = convertExpression(cst[0][0]);
                auto binaryOp = op == "~=" ? BinaryOp.Append : toBinaryOp(op[0 .. $ - 1]);
                auto binary = BinaryExpr(binaryOp, boxed(read), boxed(expr));
                expr = Expr(ids.next!Expr, Span(file, target.span.start, expr.span.end), ExprKind(binary));
            }
            return Stmt(spanOf(cst, file), StmtKind(AssignStmt(target, expr, op != "=")));
        case "Silver.FunctionDeclaration":
        case "Silver.NativeFunctionDeclaration":
        case "Silver.IntrinsicFunctionDeclaration":
            auto decl = convertFunctionDeclaration(cst);
            if (decl.kind != FunctionKind.ordinary) return Stmt(spanOf(cst, file), StmtKind(decl));
            if (decl.typeParams.length > 0)
            {
                throw new ParseException(Diagnostic(DiagnosticCode.ParseError, decl.typeParams[0].span,
                    "A nested `def` can't take type parameters, but it can use those of the function around it",
                    Severity.Error));
            }
            auto binding = ids.next!VarDecl;
            auto nested = Expr(ids.next!Expr, spanOf(cst, file),
                ExprKind(Lambda(decl.params, boxed(decl.returnType), decl.body, decl.name, binding)));
            return Stmt(spanOf(cst, file), StmtKind(VarDecl(binding, decl.name, decl.nameSpan, nested, null, false)));
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

    /// An assignment's target. `(a, _) = v` becomes a TupleLiteral target, with each `_` an
    /// Identifier named `discardName`, which no expression can otherwise be.
    private Expr convertAssignTarget(ParseTree cst)
    {
        switch (cst.name)
        {
        case "Silver.AssignTuple":
            return Expr(ids.next!Expr, spanOf(cst, file),
                ExprKind(TupleLiteral(cst.children.map!(e => convertAssignTarget(e)).array)));
        case "Silver.AssignElement":
            return convertAssignTarget(cst[0]);
        case "Silver.UNDERSCORE":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(Identifier(discardName)));
        default:
            // The target is a Postfix, so `a.b = 1` keeps its member access.
            return convertExpression(cst);
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
            return Pattern(ids.next!Pattern, spanOf(cst, file), PatternKind(binding));
        case "Silver.TuplePattern":
            Pattern[] elements;
            foreach (element; cst.children)
            {
                elements ~= convertPattern(element, mutable);
            }
            return Pattern(ids.next!Pattern, spanOf(cst, file), PatternKind(TuplePattern(elements)));
        default:
            throw new Exception("Unexpected '%s' in pattern".format(cst.name));
        }
    }

    private Pattern convertMatchPattern(ParseTree cst)
    {
        auto span = spanOf(cst, file);
        Pattern pattern(K)(K kind) => Pattern(ids.next!Pattern, span, PatternKind(kind));
        VarDecl binding(ParseTree name, TypeExpr* type) =>
            VarDecl(ids.next!VarDecl, name.matches[0], spanOf(name, file), Expr.init, type, false);

        switch (cst.name)
        {
        case "Silver.MatchPattern":
            return convertMatchPattern(cst[0]);
        case "Silver.BindingName":
            return pattern(binding(cst, null));
        case "Silver.TypedBinding":
            return pattern(binding(cst[0], boxed(convertTypeExpression(cst[1]))));
        case "Silver.MatchTuplePattern":
            return pattern(TuplePattern(cst.children.map!(e => convertMatchPattern(e)).array));
        case "Silver.Literal":
            auto literal = convertExpression(cst);
            if (literal.kind.match!((ref InterpolatedString _) => true, (ref _) => false))
            {
                throw new ParseException(Diagnostic(DiagnosticCode.ParseError, span,
                    "A string in a pattern can't have holes; write `\\{` for a literal brace", Severity.Error));
            }
            return pattern(LiteralPattern(boxed(literal)));
        case "Silver.ConstructorPattern":
            return convertConstructorPattern(cst);
        default:
            throw new Exception("Unexpected '%s' in pattern".format(cst.name));
        }
    }

    /// `TypePath MatchPattern*`. `Some` and `None` are written like constructors, as in expressions.
    private Pattern convertConstructorPattern(ParseTree cst)
    {
        auto span = spanOf(cst, file);
        auto path = cst[0].children.map!(part => part.matches[0]).array;
        auto arguments = cst.children[1 .. $].map!(a => convertMatchPattern(a)).array;
        if (path == ["None"] && arguments.length == 0)
        {
            return Pattern(ids.next!Pattern, span, PatternKind(NonePattern()));
        }
        if (path == ["Some"] && arguments.length == 1)
        {
            return Pattern(ids.next!Pattern, span, PatternKind(SomePattern(boxed(arguments[0]))));
        }
        if (path == ["Ok"] && arguments.length == 1)
        {
            return Pattern(ids.next!Pattern, span, PatternKind(OkPattern(boxed(arguments[0]))));
        }
        if (path == ["Error"] && arguments.length == 1)
        {
            return Pattern(ids.next!Pattern, span, PatternKind(ErrorPattern(boxed(arguments[0]))));
        }
        auto type = TypeExpr(ids.next!TypeExpr, spanOf(cst[0], file), TypeExprKind(NamedType(path, null)));
        return Pattern(ids.next!Pattern, span, PatternKind(ConstructorPattern(type, arguments)));
    }

    private Expr convertMatchExpression(ParseTree cst)
    {
        cst.validateNodeIs("Silver.MatchExpression");
        MatchArm[] arms;
        foreach (arm; cst.children[1 .. $])
        {
            arm.validateNodeIs("Silver.MatchArm");
            arms ~= MatchArm(spanOf(arm, file), convertMatchPattern(arm[0]), convertExpression(arm[1]));
        }
        return Expr(ids.next!Expr, spanOf(cst, file),
            ExprKind(MatchExpr(boxed(convertExpression(cst[0])), arms, MatchOrigin.Match)));
    }

    /// `if val Literal(text) = p => a else b`, as a match of that pattern and `_`.
    private Expr convertPatternIf(ParseTree cst)
    {
        auto head = cst[0];
        head.validateNodeIs("Silver.PatternBinding");
        auto span = spanOf(cst, file);
        auto hasElse = cst.children.length > 2;
        auto otherwise = hasElse ? convertExpression(cst[2]) : Expr(ids.next!Expr, span, ExprKind(UnitLiteral()));
        auto discard = VarDecl(ids.next!VarDecl, discardName, span, Expr.init, null, false);
        auto arms = [
            MatchArm(spanOf(head[0], file), convertConstructorPattern(head[0]), convertExpression(cst[1])),
            MatchArm(span, Pattern(ids.next!Pattern, span, PatternKind(discard)), otherwise),
        ];
        return Expr(ids.next!Expr, span, ExprKind(MatchExpr(boxed(convertExpression(head[1])), arms,
            hasElse ? MatchOrigin.IfValElse : MatchOrigin.IfVal)));
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
        case "Silver.SumMemberType":
            // `OptionalType`, then `ErrorTypes` or a single `OptionalType` after `!`.
            auto success = convertTypeExpression(cst[0]);
            if (cst.children.length == 1) return success;
            auto listed = cst[1].name == "Silver.ErrorTypes" ? cst[1].children : cst.children[1 .. $];
            auto errors = listed.map!(e => convertTypeExpression(e)).array;
            return TypeExpr(ids.next!TypeExpr, spanOf(cst, file), TypeExprKind(ErrorUnionType(boxed(success), errors)));
        case "Silver.OptionalType":
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
        case "Silver.Lambda":
            return convertLambda(cst);
        case "Silver.Expression":
        case "Silver.Condition":
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
            if (cst[0].name == "Silver.PatternBinding") return convertPatternIf(cst);
            return convertIfExpression(cst);
        case "Silver.MatchExpression":
            return convertMatchExpression(cst);
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
            // Spans come from the CST, since an operand's own leaves out its parentheses.
            auto lhs = convertExpression(cst[0]);
            auto start = spanOf(cst[0], file).start;
            foreach (pair; cst.children.drop(1).chunks(2))
            {
                auto op = toBinaryOp(pair[0].matches[0]);
                auto rhs = convertExpression(pair[1]);
                auto span = Span(file, start, spanOf(pair[1], file).end);
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
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(FloatLiteral(parseFloat(cst.matches[0]))));
        case "Silver.Identifier":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(Identifier(cst.matches[0])));
        case "Silver.StringLiteral":
            return convertStringLiteral(cst);
        case "Silver.CharLiteral":
            return convertCharLiteral(cst);
        case "Silver.ScientificLiteral":
            return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(FloatLiteral(parseFloat(cst.matches[0]))));
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
                text ~= decodeEscape(piece.matches[0], pieceSpan);
                break;
            default:
                throw new Exception("Unexpected '%s' in string literal".format(piece.name));
            }
        }

        if (!hasHoles) return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(StringLiteral(text)));
        endText();
        return Expr(ids.next!Expr, spanOf(cst, file), ExprKind(InterpolatedString(parts)));
    }

    private Expr convertCharLiteral(ParseTree cst)
    {
        import std.range : walkLength;
        import std.utf : decodeFront;

        auto span = spanOf(cst, file);
        string text;
        foreach (part; cst.children)
        {
            auto piece = part[0];
            text ~= piece.name == "Silver.CharEscape" ? decodeEscape(piece.matches[0], spanOf(piece, file)) : piece.matches[0];
        }
        if (text.walkLength != 1)
        {
            throw new ParseException(Diagnostic(DiagnosticCode.ParseError, span,
                "A character literal holds exactly one character; a String is written with `\"`", Severity.Error));
        }
        return Expr(ids.next!Expr, span, ExprKind(CharLiteral(text.decodeFront)));
    }

    private string decodeEscape(string escape, Span span)
    {
        switch (escape[1])
        {
        case 'u':
            import std.conv : to;
            auto scalar = escape[3 .. $ - 1].to!uint(16);
            if (scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF))
            {
                throw new ParseException(Diagnostic(DiagnosticCode.ParseError, span,
                    "`%s` isn't a Unicode scalar value, which is at most 10FFFF and not in D800 to DFFF"
                        .format(escape), Severity.Error));
            }
            char[] encoded;
            encode(encoded, cast(dchar) scalar);
            return encoded.idup;
        case 'n':
            return "\n";
        case 'r':
            return "\r";
        case 't':
            return "\t";
        case '0':
            return "\0";
        default:
            // A quote or a backslash stands for itself.
            return escape[1 .. 2];
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

    /// `(TuplePattern / BindingName) Expression Block` once the keywords are discarded.
    /// `for (a, b) in xs { ... }` becomes `for t in xs { val (a, b) = t; ... }`, where no source
    /// can name `t`.
    private Expr convertForExpression(ParseTree cst)
    {
        cst.validateNodeIs("Silver.ForExpression");
        auto destructured = cst[0].name == "Silver.TuplePattern";
        auto name = destructured ? "for.%s".format(_forPatterns++) : cst[0].matches[0];
        auto nameSpan = spanOf(cst[0], file);
        auto binding = boxed(VarDecl(ids.next!VarDecl, name, nameSpan, convertExpression(cst[1]), null, false));
        auto body = convertExpression(cst[2]);
        if (destructured)
        {
            auto element = Expr(ids.next!Expr, nameSpan, ExprKind(Identifier(name)));
            auto unpack = Stmt(nameSpan, StmtKind(PatternDecl(convertPattern(cst[0], false), element)));
            body.kind.match!(
                (ref BlockExpr block) { block.statements = unpack ~ block.statements; },
                (_) { assert(0, "the grammar only allows a block as a `for` body"); },
            );
        }
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
            auto isSome = lhs.kind.match!((const Identifier callee) => callee.name == "Some" && callee.typeArgs.length == 0, _ => false);
            if (isSome && args.length == 1 && mutables is null) return Expr(ids.next!Expr, span, ExprKind(SomeExpr(boxed(args[0]))));
            auto reserved = lhs.kind.match!((const Identifier callee) => callee.typeArgs.length == 0 ? callee.name : null, _ => null);
            if (reserved == "Ok" && args.length == 1 && mutables is null) return Expr(ids.next!Expr, span, ExprKind(OkExpr(boxed(args[0]))));
            if (reserved == "Error" && args.length == 1 && mutables is null) return Expr(ids.next!Expr, span, ExprKind(ErrorExpr(boxed(args[0]))));
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
        case "Silver.AssertSuccess":
            return Expr(ids.next!Expr, span, ExprKind(AssertExpr(boxed(lhs))));
        case "Silver.IndexArgs":
            // `xs[a..]` and `xs[..b]` are ranges with a bound left out, which only a slice allows.
            auto index = op[0];
            Expr bounds;
            if (index.name == "Silver.SliceFrom")
            {
                bounds = Expr(ids.next!Expr, spanOf(index, file), ExprKind(RangeExpr(boxed(convertExpression(index[0])), null)));
            }
            else if (index.name == "Silver.SliceTo")
            {
                bounds = Expr(ids.next!Expr, spanOf(index, file), ExprKind(RangeExpr(null, boxed(convertExpression(index[0])))));
            }
            else
            {
                bounds = convertExpression(index);
            }
            return Expr(ids.next!Expr, span, ExprKind(IndexExpr(boxed(lhs), boxed(bounds))));
        case "Silver.TypeArguments":
            auto typeArgs = op.children.map!(a => convertTypeExpression(a)).array;
            auto named = lhs.kind.match!(
                (ref Identifier id) {
                    if (id.typeArgs.length > 0) return false;
                    id.typeArgs = typeArgs;
                    return true;
                },
                (ref MemberAccess access) {
                    if (access.typeArgs.length > 0) return false;
                    access.typeArgs = typeArgs;
                    return true;
                },
                (ref _) => false,
            );
            if (!named)
            {
                throw new ParseException(Diagnostic(DiagnosticCode.ParseError, spanOf(op, file),
                    "Type arguments can only follow the name of a function or a type", Severity.Error));
            }
            lhs.span = span;
            return lhs;
        default:
            throw new Exception("Expected call or member access, got '%s'".format(op.name));
        }
    }

    /// `DEF Identifier Params? TypeAnnotation ('=>' Expression / Block)`,
    /// or a native or intrinsic declaration, which has no body.
    /// Params is absent rather than empty when there are no params,
    /// so children are matched by name.
    private Expr convertLambda(ParseTree cst)
    {
        cst.validateNodeIs("Silver.Lambda");
        Param[] params;
        if (cst[0].name == "Silver.BindingName")
        {
            params ~= Param(ids.next!Param, cst[0].matches[0], spanOf(cst[0], file), TypeExpr.init, false, false);
        }
        else
        {
            foreach (param; cst[0].children)
            {
                auto mutable = param[0].name == "Silver.MUTABLE";
                auto name = param[mutable ? 1 : 0];
                auto annotated = param.children.length > (mutable ? 2 : 1);
                params ~= Param(ids.next!Param, name.matches[0], spanOf(name, file),
                    annotated ? convertTypeExpression(param[$ - 1]) : TypeExpr.init, mutable, annotated);
            }
        }
        auto returnType = cst.children.length == 3 ? boxed(convertTypeExpression(cst[1])) : null;
        return Expr(ids.next!Expr, spanOf(cst, file),
            ExprKind(Lambda(params, returnType, boxed(convertExpression(cst.children[$ - 1])))));
    }

    private FunctionDecl convertFunctionDeclaration(ParseTree cst)
    {
        FunctionKind kind;
        switch (cst.name)
        {
        case "Silver.NativeFunctionDeclaration":
            kind = FunctionKind.native;
            break;
        case "Silver.IntrinsicFunctionDeclaration":
            kind = FunctionKind.intrinsic;
            break;
        case "Silver.InterfaceFunction":
            kind = FunctionKind.required;
            break;
        default:
            cst.validateNodeIs("Silver.FunctionDeclaration");
        }
        string symbol;
        if (cst[0].name == "Silver.NativeSymbol")
        {
            symbol = plainString(cst[0][0], "A native's symbol");
            cst.children = cst.children[1 .. $];
        }
        auto name = cst[0].matches[0];
        if (kind == FunctionKind.native && symbol is null) symbol = name;

        Param[] params;
        Expr* body;
        TypeExpr returnType;
        TypeParam[] typeParams;
        foreach (child; cst.children[1 .. $])
        {
            switch (child.name)
            {
            case "Silver.TypeParameters":
                if (kind == FunctionKind.native)
                {
                    throw new ParseException(Diagnostic(DiagnosticCode.ParseError, spanOf(child, file),
                        "A `native def` can't take type parameters, since a C function has one signature", Severity.Error));
                }
                if (kind == FunctionKind.required)
                {
                    throw new ParseException(Diagnostic(DiagnosticCode.ParseError, spanOf(child, file),
                        "A function of an interface can't take type parameters of its own; the interface's are in scope",
                        Severity.Error));
                }
                typeParams = convertTypeParameters(child);
                break;
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
                if (kind == FunctionKind.required)
                {
                    throw new ParseException(Diagnostic(DiagnosticCode.ParseError, spanOf(child, file),
                        "A function of an interface has no body; it says what a type has to have", Severity.Error));
                }
                body = boxed(convertExpression(child));
                break;
            default:
                throw new Exception("Unexpected '%s' in function declaration".format(child.name));
            }
        }
        return FunctionDecl(ids.next!FunctionDecl, name, spanOf(cst[0], file), params, body, returnType, kind, symbol, false,
            typeParams);
    }

    private TypeParam[] convertTypeParameters(ParseTree cst)
    {
        cst.validateNodeIs("Silver.TypeParameters");
        TypeParam[] params;
        foreach (p; cst.children)
        {
            auto bounds = p.children.filter!(c => c.name == "Silver.NamedType").map!(b => convertTypeExpression(b)).array;
            params ~= TypeParam(ids.next!TypeParam, p.matches[0], Span(file, p.begin, p.begin + p.matches[0].length), bounds);
        }
        return params;
    }

    /// `interface Name<T> { def f(value: Self): T }`.
    private InterfaceDecl convertInterfaceDeclaration(ParseTree cst)
    {
        cst.validateNodeIs("Silver.InterfaceDeclaration");
        auto nameSpan = spanOf(cst[0], file);
        InterfaceDecl decl;
        decl.id = ids.next!InterfaceDecl;
        decl.name = cst[0].matches[0];
        decl.nameSpan = nameSpan;
        decl.self = TypeParam(ids.next!TypeParam, "Self", nameSpan);
        foreach (child; cst.children[1 .. $])
        {
            if (child.name == "Silver.TypeParameters") decl.typeParams = convertTypeParameters(child);
            else decl.functions ~= convertFunctionDeclaration(child);
        }
        return decl;
    }

    /// `NATIVE LIBRARY StringLiteral`. `previous` is the one the module already has, if any.
    private NativeLibrary* convertNativeLibrary(ParseTree cst, NativeLibrary* previous)
    {
        auto span = spanOf(cst, file);
        if (previous !is null)
        {
            throw new ParseException(Diagnostic(DiagnosticCode.ParseError, span,
                "A module can name only one `native library`", Severity.Error));
        }
        return new NativeLibrary(plainString(cst[0], "A library name"), span);
    }

    /// `test "name" body`: a private function returning Unit, named so nothing can call it.
    private FunctionDecl convertTest(ParseTree cst)
    {
        auto name = plainString(cst[0], "A test's name");
        auto nameSpan = spanOf(cst[0], file);
        auto unit = TypeExpr(ids.next!TypeExpr, nameSpan, TypeExprKind(UnitType()));
        auto f = FunctionDecl(ids.next!FunctionDecl, "test " ~ name, nameSpan, null, boxed(convertExpression(cst[1])),
            unit, FunctionKind.ordinary, null, true);
        f.testName = name;
        return f;
    }

    /// The text of a string literal that has to be known as written, with no holes.
    private string plainString(ParseTree cst, string what)
    {
        auto literal = convertStringLiteral(cst);
        auto text = literal.kind.match!((ref StringLiteral s) => s.value, (ref _) => cast(string) null);
        if (text.length == 0)
        {
            throw new ParseException(Diagnostic(DiagnosticCode.ParseError, literal.span,
                what ~ " has to be a string with no holes, and can't be empty", Severity.Error));
        }
        return text;
    }

    /// `type Name`, `type Name()`, `type Name(fields)` or `type Name = members`, and for a sum a
    /// declaration of each member it defines inline, which from here on is a type like any other,
    /// and for a product with an invariant, the function holding it.
    private Decl[] convertTypeDeclaration(ParseTree cst)
    {
        cst.validateNodeIs("Silver.TypeDeclaration");
        auto span = spanOf(cst, file);
        auto name = cst[0];
        auto rest = cst.children[1 .. $];
        TypeParam[] typeParams;
        ParseTree typeParamsCst;
        if (rest.length > 0 && rest[0].name == "Silver.TypeParameters")
        {
            typeParamsCst = rest[0];
            typeParams = convertTypeParameters(rest[0]);
            rest = rest[1 .. $];
        }
        Decl[] declarations;
        SumMember[] members;
        if (rest.length > 0 && rest[0].name == "Silver.SumMembers")
        {
            foreach (member; rest[0].children)
            {
                member.validateNodeIs("Silver.SumMember");
                if (member[0].name != "Silver.InlineMember")
                {
                    members ~= SumMember(convertTypeExpression(member[0]), false);
                    continue;
                }
                auto inline = convertProduct(member[0][0], member[0][1]);
                inline.typeParams = mentioned(typeParams, inline.fields);
                inline.inheritsParams = inline.typeParams.length > 0;
                Decl[] check;
                if (member[0].children.length > 2)
                {
                    auto invariant_ = member[0][2];
                    auto f = invariantFunction(inline, member[0][1], invariant_[0], mentioned(freshTypeParams(typeParamsCst), inline.fields));
                    auto e = invariantErrorFunction(inline, member[0][1], invariant_, mentioned(freshTypeParams(typeParamsCst), inline.fields));
                    inline.invariantFunction = f.id;
                    inline.invariantError = e.id;
                    check = [Decl(spanOf(invariant_, file), DeclKind(f)), Decl(spanOf(invariant_, file), DeclKind(e))];
                }
                declarations ~= Decl(spanOf(member[0], file), DeclKind(inline)) ~ check;
                auto args = inline.typeParams.map!(p => TypeExpr(ids.next!TypeExpr, inline.nameSpan,
                    TypeExprKind(NamedType([p.name], null)))).array;
                members ~= SumMember(TypeExpr(ids.next!TypeExpr, inline.nameSpan, TypeExprKind(NamedType([inline.name], args))), true);
            }
            auto sum = TypeDecl(ids.next!TypeDecl, name.matches[0], spanOf(name, file), null, false, members);
            sum.typeParams = typeParams;
            return declarations ~ Decl(span, DeclKind(sum));
        }
        auto product = convertProduct(name, rest.length > 0 ? rest[0] : ParseTree.init);
        product.typeParams = typeParams;
        if (rest.length > 1)
        {
            auto f = invariantFunction(product, rest[0], rest[1][0], freshTypeParams(typeParamsCst));
            auto e = invariantErrorFunction(product, rest[0], rest[1], freshTypeParams(typeParamsCst));
            product.invariantFunction = f.id;
            product.invariantError = e.id;
            declarations = [Decl(spanOf(rest[1], file), DeclKind(f)), Decl(spanOf(rest[1], file), DeclKind(e))];
        }
        return Decl(span, DeclKind(product)) ~ declarations;
    }

    /// The type parameters `cst` declares, as nodes of their own, or none for an empty tree.
    private TypeParam[] freshTypeParams(ParseTree cst)
    {
        return cst.name.length > 0 ? convertTypeParameters(cst) : null;
    }

    /// The function holding `type`'s invariant `condition`, whose parameters are the `fields` and
    /// whose type parameters, `typeParams`, match the type's. Its nodes are its own, so sema checks
    /// it as any other function.
    private FunctionDecl invariantFunction(const TypeDecl type, ParseTree fields, ParseTree condition,
        TypeParam[] typeParams)
    {
        auto span = spanOf(condition, file);
        auto bool_ = TypeExpr(ids.next!TypeExpr, span, TypeExprKind(NamedType(["Bool"], null)));
        auto f = FunctionDecl(ids.next!FunctionDecl, "invariant " ~ type.name, type.nameSpan, fieldParams(fields),
            boxed(convertExpression(condition)), bool_, FunctionKind.ordinary, null, true, typeParams);
        f.invariantOf = type.id;
        return f;
    }

    /// The function holding the `else` of `type`'s invariant, declared as `invariantFunction` is.
    /// Sema infers its return type, so the one written here is a placeholder.
    private FunctionDecl invariantErrorFunction(const TypeDecl type, ParseTree fields, ParseTree invariant_,
        TypeParam[] typeParams)
    {
        if (invariant_.children.length < 2)
        {
            throw new ParseException(Diagnostic(DiagnosticCode.ParseError, spanOf(invariant_, file),
                "An invariant needs `else` and the error a value that breaks it gives, as in `invariant low <= high else Reversed(low, high)`",
                Severity.Error));
        }
        auto error = invariant_[1];
        auto placeholder = TypeExpr(ids.next!TypeExpr, spanOf(error, file), TypeExprKind(UnitType()));
        auto f = FunctionDecl(ids.next!FunctionDecl, "invariant error " ~ type.name, type.nameSpan, fieldParams(fields),
            boxed(convertExpression(error)), placeholder, FunctionKind.ordinary, null, true, typeParams);
        f.invariantOf = type.id;
        f.invariantErrorOf = type.id;
        return f;
    }

    /// A parameter for each of `fields`, with nodes of its own.
    private Param[] fieldParams(ParseTree fields)
    {
        Param[] params;
        foreach (list; fields.children)
        {
            foreach (field; list.children)
            {
                params ~= Param(ids.next!Param, field.matches[0], spanOf(field[0], file), convertTypeExpression(field[1]));
            }
        }
        return params;
    }

    /// The parameters in `params` that a field in `fields` names, in their order. A field can only
    /// mean one of them by a bare name, since no type can share a parameter's name.
    private static TypeParam[] mentioned(TypeParam[] params, const(Field)[] fields)
    {
        bool[string] named;
        void visit(const TypeExpr type)
        {
            type.kind.match!(
                (const NamedType n) {
                    if (n.path.length == 1) named[n.path[0]] = true;
                    foreach (arg; n.args) visit(arg);
                },
                (const OptionType o) => visit(*o.inner),
                (const ErrorUnionType u) {
                    visit(*u.success);
                    foreach (e; u.errors) visit(e);
                },
                (const ArrayType a) => visit(*a.element),
                (const FunctionType f) {
                    foreach (p; f.params) visit(p);
                    visit(*f.returnType);
                },
                (const UnitType _) {},
                (const TupleType t) {
                    foreach (e; t.elements) visit(e);
                },
            );
        }
        foreach (field; fields) visit(field.type);
        TypeParam[] result;
        foreach (param; params)
        {
            if (param.name in named) result ~= param;
        }
        return result;
    }

    /// A type named by `name` with the given `Fields`, which is an empty tree for a marker.
    /// Fields has no FieldList child when the parens are empty.
    private TypeDecl convertProduct(ParseTree name, ParseTree fieldList)
    {
        Field[] fields;
        bool emptyParens;
        if (fieldList.name.length > 0)
        {
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
        return TypeDecl(ids.next!TypeDecl, name.matches[0], spanOf(name, file), fields, emptyParens);
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
        case "+%":
            return BinaryOp.WrappingAdd;
        case "-%":
            return BinaryOp.WrappingSubtract;
        case "*%":
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

@("a binary expression's span includes parentheses around its operands")
unittest
{
    import std.sumtype : match;
    import silver.syntax.parse : parse;

    auto source = "def f(): Int => (a) * (b + c) - d";
    auto m = parse(source, "test", new NodeIds);
    auto body = m.declarations[0].kind.match!(
        (const FunctionDecl f) => f.body,
        _ => null,
    );
    auto left = (*body).kind.match!(
        (const BinaryExpr b) => b.left,
        _ => null,
    );
    string text(Span s) => source[s.start .. s.end];

    assert(text((*body).span) == "(a) * (b + c) - d");
    assert(text(left.span) == "(a) * (b + c)");
}

@("a module names at most one native library, and a native's symbol and library and a test's name are plain strings")
unittest
{
    import std.exception : collectException;
    import silver.syntax.parse : parse;

    void rejected(string source)
    {
        auto error = collectException!ParseException(parse(source, "test", new NodeIds));
        assert(error !is null, source);
        assert(error.diagnostic.code == DiagnosticCode.ParseError, source);
    }

    rejected("native library \"a\"\nnative library \"b\"");
    rejected("native library \"{name}\"");
    rejected("native library \"\"");
    rejected("native(\"\") def f(): Int");
    rejected("native(\"f{x}\") def f(): Int");
    rejected("test \"\" {}");
    rejected("test \"a{1}\" {}");
    assert(collectException!ParseException(parse("native library \"a\"\nnative(\"b\") def f(): Int", "test", new NodeIds)) is null);
}

@("a character literal holds one character")
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectException;
    import silver.syntax.parse : parse;

    ParseException error(string literal) =>
        collectException!ParseException(parse("val a: Char = " ~ literal, "test", new NodeIds));

    assert(error(`'a'`) is null);
    assert(error(`'\u{1F600}'`) is null);
    assert(error(`''`).diagnostic.message.canFind("exactly one character"));
    assert(error(`'ab'`).diagnostic.message.canFind("exactly one character"));
    assert(error(`'\u{D800}'`).diagnostic.message.canFind("scalar value"));
}

@("a \\u{...} escape names a Unicode scalar value")
unittest
{
    import std.exception : collectException;
    import silver.syntax.parse : parse;

    ParseException error(string literal) =>
        collectException!ParseException(parse("val a: String = " ~ literal, "test", new NodeIds));

    assert(error(`"\u{10FFFF}\u{D7FF}\u{E000}"`) is null);
    assert(error(`"\u{110000}"`).diagnostic.code == DiagnosticCode.ParseError);
    assert(error(`"\u{D800}"`).diagnostic.code == DiagnosticCode.ParseError);
    assert(error(`"\u{dfff}"`).diagnostic.code == DiagnosticCode.ParseError);
}

@("only `=` assigns to a tuple of targets")
unittest
{
    import std.exception : collectException;
    import silver.syntax.parse : parse;

    ParseException error(string statement) =>
        collectException!ParseException(parse("def f(): Unit {\n    " ~ statement ~ "\n}", "test", new NodeIds));

    assert(error("(a, b) = (1, 2)") is null);
    assert(error("(a, b) += (1, 2)").diagnostic.code == DiagnosticCode.ParseError);
    assert(error("(a, _) ~= ([1], [2])").diagnostic.code == DiagnosticCode.ParseError);
}
