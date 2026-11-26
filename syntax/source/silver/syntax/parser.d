/// A recursive-descent parser over the lexer's tokens, building the AST directly.
///
/// The lexer has already applied the newline rule, so a `newline` token is a statement separator
/// unless a rule below skips it, which it does only where the grammar continues past a token that
/// can end a statement into one that can begin one (`def f` / `()`, `if c` / `{`). Speculation
/// saves and restores the token index; nothing throws except the first syntax error.
module silver.syntax.parser;

import std.format : format;
import std.sumtype : match;
import silver.ast;
import silver.syntax.lexer;
import silver.syntax.parse : ParseException;

/// Parses `source` as the module `moduleName`, taking node IDs from `ids`.
/// Throws: ParseException at the first syntax error.
Module parseModule(string source, string moduleName, NodeIds ids, string file)
{
    auto parser = new Parser(source, ids, file);
    return parser.parseModule(moduleName);
}

private enum Assoc
{
    left,
    /// At most one operator at the level, as with `==`, `<` and `..`.
    single,
    right,
}

/// Binary levels, loosest first.
private enum Level : size_t
{
    or, and, equality, relational, range, coalesce, bitOr, bitXor, bitAnd, shift, addition, multiply,
}

private enum size_t levelCount = Level.max + 1;

private Assoc assocOf(size_t level)
{
    switch (level)
    {
    case Level.equality, Level.relational, Level.range: return Assoc.single;
    case Level.coalesce: return Assoc.right;
    default: return Assoc.left;
    }
}

private final class Parser
{
    private string source;
    private string file;
    private NodeIds ids;
    private Token[] tokens;
    private LexError[] lexErrors;
    private size_t pos;
    /// Every error found, the first of which is thrown. Kept as a list so recovery can come later.
    private Diagnostic[] errors;
    /// How many `for` loops so far take their element apart, for naming the element's local.
    private size_t forPatterns;
    private size_t parameterPatterns;
    /// The type of each bare sum member, which declares a marker.
    private bool[Id!TypeExpr] markerMembers;
    /// The tokens the last postfix expression to finish spanned, so an assignment can tell whether
    /// its target was one.
    private size_t lastPostfixStart = size_t.max;
    private size_t lastPostfixEnd;

    this(string source, NodeIds ids, string file)
    {
        this.source = source;
        this.ids = ids;
        this.file = file;
        auto lexed = lex(source);
        tokens = lexed.tokens;
        lexErrors = lexed.errors;
    }

    // Tokens

    private TokenKind kind() const => tokens[pos].kind;

    private TokenKind kindAt(size_t ahead) const
        => pos + ahead < tokens.length ? tokens[pos + ahead].kind : TokenKind.end;

    private bool at(TokenKind k) const => tokens[pos].kind == k;

    private string text(Token t) const => source[t.start .. t.end];

    private string text() const => text(tokens[pos]);

    /// Whether the current token is the identifier `word`, which only means something here.
    private bool atWord(string word, size_t ahead = 0) const
        => kindAt(ahead) == TokenKind.identifier && text(tokens[pos + ahead]) == word;

    private bool accept(TokenKind k)
    {
        if (tokens[pos].kind != k) return false;
        pos++;
        return true;
    }

    private Token expect(TokenKind k, string what)
    {
        if (tokens[pos].kind != k) throw failure(what);
        return tokens[pos++];
    }

    /// Skips a separating newline, where the grammar continues past it.
    private void skipNewline()
    {
        if (at(TokenKind.newline)) pos++;
    }

    /// Skips a newline if `k` follows it.
    private void skipNewlineBefore(TokenKind k)
    {
        if (at(TokenKind.newline) && kindAt(1) == k) pos++;
    }

    private bool atSeparator() const => at(TokenKind.newline) || at(TokenKind.semicolon);

    private void skipSeparators()
    {
        while (atSeparator()) pos++;
    }

    private void requireSeparator()
    {
        if (!atSeparator()) throw failure("a new line or `;`");
        skipSeparators();
    }

    /// Whether token `i` ends where the next one starts.
    private bool touches(size_t i) const => i + 1 < tokens.length && tokens[i].end == tokens[i + 1].start;

    /// Where the current token starts, which is where a node beginning here starts.
    private size_t here() const => tokens[pos].start;

    /// Where the last token taken ends, not counting a newline.
    private size_t lastEnd() const
    {
        size_t i = pos;
        while (i > 0 && tokens[i - 1].kind == TokenKind.newline) i--;
        return i > 0 ? tokens[i - 1].end : 0;
    }

    private Span spanFrom(size_t start) const => Span(file, start, lastEnd());

    private Span spanOf(Token t) const => Span(file, t.start, t.end);

    // Errors

    private ParseException error(Span span, string message)
    {
        auto diagnostic = Diagnostic(DiagnosticCode.ParseError, span, message, Severity.Error);
        errors ~= diagnostic;
        return new ParseException(diagnostic);
    }

    /// The error for finding the current token where `expected` should be.
    private ParseException failure(string expected)
    {
        auto t = tokens[pos];
        if (t.kind == TokenKind.error)
        {
            foreach (e; lexErrors)
            {
                if (e.start == t.start && e.end == t.end) return error(spanOf(t), e.message);
            }
        }
        return error(spanOf(t), "expected %s, but got %s".format(expected, describe(t)));
    }

    private string describe(Token t) const
    {
        switch (t.kind)
        {
        case TokenKind.end: return "the end of the file";
        case TokenKind.newline: return "a new line";
        case TokenKind.stringText, TokenKind.stringEscape: return "text";
        default: return "`" ~ text(t) ~ "`";
        }
    }

    // Module and declarations

    Module parseModule(string moduleName)
    {
        ModuleDeclaration* header;
        NativeLibrary* library;
        Decl[] declarations;

        skipSeparators();
        if (at(TokenKind.kwModule))
        {
            auto start = here;
            pos++;
            auto path = qualifiedName();
            header = new ModuleDeclaration(path, spanFrom(start));
            if (!at(TokenKind.end)) requireSeparator();
        }
        while (!at(TokenKind.end))
        {
            if (at(TokenKind.kwNative) && atWord("library", 1)) library = parseNativeLibrary(library);
            else declarations ~= parseDeclaration();
            if (at(TokenKind.end)) break;
            requireSeparator();
        }
        declarations ~= implicitMarkers(declarations);
        return Module(ids.next!Module, moduleName, Span(file, 0, lastEnd()), declarations, header, library);
    }

    /// `a.b.c`, written with no spaces.
    private string[] qualifiedName()
    {
        if (!isValueWord(kind)) throw failure("a module name");
        string[] parts = [text()];
        pos++;
        while (at(TokenKind.dot) && touches(pos - 1) && touches(pos) && isValueWord(kindAt(1)))
        {
            parts ~= text(tokens[pos + 1]);
            pos += 2;
        }
        return parts;
    }

    /// `native library "name"`. `previous` is the one the module already has, if any.
    private NativeLibrary* parseNativeLibrary(NativeLibrary* previous)
    {
        auto start = here;
        pos += 2;
        skipNewline();
        auto name = plainString(parseStringLiteral(), "A library name");
        auto span = spanFrom(start);
        if (previous !is null) throw error(span, "A module can name only one `native library`");
        return new NativeLibrary(name, span);
    }

    /// One declaration, except that a sum comes with a declaration for each member it defines
    /// inline.
    private Decl[] parseDeclaration()
    {
        if (!at(TokenKind.kwPrivate)) return parseDeclarationBody(false);
        pos++;
        auto declarations = parseDeclarationBody(true);
        foreach (ref declaration; declarations)
        {
            declaration.kind.match!(
                (ref FunctionDecl function_) { function_.isPrivate = true; },
                (ref TypeDecl type) { type.isPrivate = true; },
                (ref ConstDecl constant) { constant.isPrivate = true; },
                (ref AliasDecl alias_) { alias_.isPrivate = true; },
                (ref InterfaceDecl interface_) { interface_.isPrivate = true; },
                (ref ImportStmt _) {},
                (ref ConformDecl _) {
                    throw error(declaration.span,
                        "A conformance is never private: every module sees it, and a private type can conform");
                },
            );
        }
        return declarations;
    }

    private Decl[] parseDeclarationBody(bool afterPrivate)
    {
        auto start = here;
        Decl one(K)(K kind) => Decl(spanFrom(start), DeclKind(kind));

        switch (kind)
        {
        case TokenKind.kwDef:
            return [one(parseFunction(FunctionKind.ordinary))];
        case TokenKind.kwNative:
            if (kindAt(1) == TokenKind.kwType) return [one(parseNativeType())];
            return [one(parseFunction(FunctionKind.native))];
        case TokenKind.kwIntrinsic:
            switch (kindAt(1))
            {
            case TokenKind.kwDef:
                return [one(parseFunction(FunctionKind.intrinsic))];
            case TokenKind.kwAlias:
                pos += 2;
                auto nameToken = expect(TokenKind.typeName, "a type name");
                auto nameSpan = spanOf(nameToken);
                auto placeholder = TypeExpr(ids.next!TypeExpr, nameSpan, TypeExprKind(NamedType([text(nameToken)], null)));
                return [one(AliasDecl(ids.next!AliasDecl, text(nameToken), nameSpan, placeholder, false, true))];
            case TokenKind.kwType:
                pos += 2;
                auto nameToken = expect(TokenKind.typeName, "a type name");
                TypeParam[] typeParams;
                if (at(TokenKind.less)) typeParams = parseTypeParameters();
                skipNewlineBefore(TokenKind.leftParen);
                if (!at(TokenKind.leftParen)) throw failure("`(`");
                bool emptyParens;
                auto fields = parseFields(emptyParens);
                auto intrinsicType = TypeDecl(ids.next!TypeDecl, text(nameToken), spanOf(nameToken), fields, emptyParens);
                intrinsicType.typeParams = typeParams;
                intrinsicType.intrinsic = true;
                return [one(intrinsicType)];
            default:
                pos++;
                throw failure("`def`, `type` or `alias`");
            }
        case TokenKind.kwType:
            return parseTypeDeclaration();
        case TokenKind.kwAlias:
            pos++;
            auto nameToken = expect(TokenKind.typeName, "a type name");
            if (at(TokenKind.less))
            {
                auto paramsStart = here;
                parseTypeParameters();
                throw error(spanFrom(paramsStart),
                    "An alias can't take type parameters yet; declare a generic `type` instead");
            }
            expect(TokenKind.assign, "`=`");
            auto target = parseType();
            return [one(AliasDecl(ids.next!AliasDecl, text(nameToken), spanOf(nameToken), target))];
        case TokenKind.kwInterface:
            return [one(parseInterface())];
        case TokenKind.kwVal:
            pos++;
            auto nameToken = expect(TokenKind.identifier, "a name");
            TypeExpr* type = at(TokenKind.colon) ? boxed(parseTypeAnnotation()) : null;
            expect(TokenKind.assign, "`=`");
            auto value = parseExpression();
            return [one(ConstDecl(ids.next!ConstDecl, text(nameToken), spanOf(nameToken), type, value))];
        case TokenKind.kwImport:
            if (afterPrivate) break;
            return [one(parseImport())];
        case TokenKind.identifier:
            if (atWord("conform")) return [one(parseConform())];
            if (afterPrivate) break;
            if (atWord("forward")) return [one(parseImport())];
            if (atWord("test")) return [one(parseTest())];
            break;
        default:
            break;
        }
        throw failure("a declaration");
    }

    /// `import a.b`, `import a.b: c, D`, or either after `forward`.
    private ImportStmt parseImport()
    {
        auto forward = atWord("forward");
        if (forward)
        {
            pos++;
            skipNewline();
        }
        expect(TokenKind.kwImport, "`import`");
        auto path = qualifiedName();
        ImportedName[] names;
        if (accept(TokenKind.colon))
        {
            do
            {
                if (!at(TokenKind.identifier) && !at(TokenKind.typeName)) throw failure("a name to import");
                names ~= ImportedName(text(), spanOf(tokens[pos]));
                pos++;
            }
            while (accept(TokenKind.comma));
        }
        return ImportStmt(ids.next!ImportStmt, path, names, forward);
    }

    /// `native type Name`, a handle to something a library owns, or `native type Name(fields)`, a C structure.
    private TypeDecl parseNativeType()
    {
        pos += 2;
        auto nameToken = expect(TokenKind.typeName, "a type name");
        if (at(TokenKind.less))
        {
            auto paramsStart = here;
            parseTypeParameters();
            throw error(spanFrom(paramsStart), "A native type can't take type parameters, since a C type has one layout");
        }
        Field[] fields;
        if (at(TokenKind.leftParen))
        {
            auto parensStart = here;
            bool emptyParens;
            fields = parseFields(emptyParens);
            if (emptyParens)
            {
                throw error(spanFrom(parensStart),
                    "A native type with no fields is written `native type %s`, with no `()`".format(text(nameToken)));
            }
        }
        auto native = TypeDecl(ids.next!TypeDecl, text(nameToken), spanOf(nameToken), fields, false);
        native.native = true;
        return native;
    }

    /// `def`, `native def`, `intrinsic def`, or a function an interface requires, which has no body.
    private FunctionDecl parseFunction(FunctionKind kind)
    {
        string symbol;
        if (kind == FunctionKind.native)
        {
            pos++;
            if (accept(TokenKind.leftParen))
            {
                symbol = plainString(parseStringLiteral(), "A native's symbol");
                expect(TokenKind.rightParen, "`)`");
                if (at(TokenKind.kwType))
                {
                    throw error(spanOf(tokens[pos]), "A native type is written `native type Name`, with no symbol");
                }
            }
        }
        else if (kind == FunctionKind.intrinsic)
        {
            pos++;
        }
        expect(TokenKind.kwDef, "`def`");
        auto nameToken = expect(TokenKind.identifier, "a function name");
        auto name = text(nameToken);
        if (kind == FunctionKind.native && symbol is null) symbol = name;

        TypeParam[] typeParams;
        if (at(TokenKind.less))
        {
            auto paramsStart = here;
            typeParams = parseTypeParameters();
            if (kind == FunctionKind.native)
            {
                throw error(spanFrom(paramsStart),
                    "A `native def` can't take type parameters, since a C function has one signature");
            }
            if (kind == FunctionKind.required)
            {
                throw error(spanFrom(paramsStart),
                    "A function of an interface can't take type parameters of its own; the interface's are in scope");
            }
        }
        skipNewlineBefore(TokenKind.leftParen);
        expect(TokenKind.leftParen, "`(`");
        Stmt[] unpacks;
        auto params = parseParams(unpacks);
        expect(TokenKind.rightParen, "`)` or `,`");
        auto returnType = parseTypeAnnotation();
        if (unpacks.length > 0 && kind != FunctionKind.ordinary)
        {
            throw error(unpacks[0].span, kind == FunctionKind.required
                ? "A function of an interface says what a type has to have, so its parameters are names, not patterns"
                : "A `native def` or an `intrinsic def` has no body to take a parameter apart in, so its parameters are names");
        }

        Expr* body;
        if (kind == FunctionKind.ordinary)
        {
            body = boxed(takingApart(unpacks, parseBody()));
        }
        else if (kind == FunctionKind.required && (at(TokenKind.fatArrow) || at(TokenKind.leftBrace)))
        {
            auto bodyStart = at(TokenKind.fatArrow) ? tokens[pos + 1].start : here;
            parseBody();
            throw error(spanFrom(bodyStart), "A function of an interface has no body; it says what a type has to have");
        }
        return FunctionDecl(ids.next!FunctionDecl, name, spanOf(nameToken), params, body, returnType, kind, symbol,
            false, typeParams);
    }

    /// `=> expression` or a block, after a function's signature or a test's name.
    private Expr parseBody()
    {
        skipNewlineBefore(TokenKind.leftBrace);
        if (accept(TokenKind.fatArrow)) return parseExpression();
        if (at(TokenKind.leftBrace)) return parseBlock();
        throw failure("`=>` or a block");
    }

    /// A function's parameters. One written as a tuple pattern, as in `(w, h): (Int, Int)`, is a
    /// parameter no name can reach, with a declaration added to `unpacks` that takes it apart.
    private Param[] parseParams(ref Stmt[] unpacks)
    {
        Param[] params;
        if (at(TokenKind.rightParen)) return params;
        do
        {
            auto start = here;
            auto mutable = accept(TokenKind.kwMutable);
            if (at(TokenKind.leftParen))
            {
                params ~= parsePatternParam(start, mutable, true, unpacks);
                continue;
            }
            auto nameToken = expectBindingName();
            auto type = parseTypeAnnotation();
            params ~= Param(ids.next!Param, text(nameToken), spanOf(nameToken), type, mutable);
        }
        while (accept(TokenKind.comma));
        return params;
    }

    /// A parameter written as a tuple pattern, which starts here, with `mutable` before it from
    /// `start` if that was written. A `def`'s has its type after it, and a lambda's may.
    private Param parsePatternParam(size_t start, bool mutable, bool typed, ref Stmt[] unpacks)
    {
        auto patternStart = here;
        if (mutable)
        {
            throw error(spanFrom(start), "A parameter that's taken apart can't be `mutable`: there'd be nothing to write back "
                ~ "to. Take it as a name, and take it apart in the body");
        }
        auto pattern = parseTuplePattern(false);
        auto span = spanFrom(patternStart);
        auto annotated = typed || at(TokenKind.colon);
        auto type = annotated ? parseTypeAnnotation() : TypeExpr.init;
        // With a type on every part and none on the whole, the parts' types are the whole's.
        if (!annotated) annotated = typeOfParts(pattern, type);
        auto name = "parameter.%s".format(parameterPatterns++);
        auto whole = Expr(ids.next!Expr, span, ExprKind(Identifier(name)));
        unpacks ~= Stmt(span, StmtKind(PatternDecl(pattern, whole)));
        return Param(ids.next!Param, name, span, type, false, annotated, true);
    }

    /// The tuple type `pattern`'s annotations spell, when every name in it has one.
    private bool typeOfParts(ref Pattern pattern, out TypeExpr type)
    {
        TypeExpr[] elements;
        bool whole = true;
        bool binding;
        pattern.kind.match!(
            (ref TuplePattern tuple) {
                foreach (ref element; tuple.elements)
                {
                    TypeExpr part;
                    if (typeOfParts(element, part)) elements ~= part;
                    else whole = false;
                }
            },
            (ref VarDecl v) {
                binding = true;
                if (v.type is null) whole = false;
                else type = copyOf(*v.type);
            },
            (ref _) { whole = false; },
        );
        if (!whole) return false;
        if (!binding) type = TypeExpr(ids.next!TypeExpr, pattern.span, TypeExprKind(TupleType(elements)));
        return true;
    }

    /// `type` again, as if it had been written a second time.
    private TypeExpr copyOf(ref TypeExpr type)
    {
        TypeExpr[] all(TypeExpr[] types)
        {
            TypeExpr[] copies;
            foreach (ref t; types) copies ~= copyOf(t);
            return copies;
        }
        auto kind = type.kind.match!(
            (ref OptionType o) => TypeExprKind(OptionType(boxed(copyOf(*o.inner)))),
            (ref ArrayType a) => TypeExprKind(ArrayType(boxed(copyOf(*a.element)))),
            (ref DictionaryType d) => TypeExprKind(DictionaryType(boxed(copyOf(*d.key)), boxed(copyOf(*d.value)))),
            (ref NamedType n) => TypeExprKind(NamedType(n.path, all(n.args))),
            (ref FunctionType f) => TypeExprKind(FunctionType(all(f.params), f.mutableParams, boxed(copyOf(*f.returnType)))),
            (ref UnitType u) => TypeExprKind(u),
            (ref TupleType t) => TypeExprKind(TupleType(all(t.elements))),
            (ref ErrorUnionType u) => TypeExprKind(ErrorUnionType(boxed(copyOf(*u.success)), all(u.errors))),
            (ref JoinedType j) => TypeExprKind(JoinedType(all(j.parts))),
        );
        return TypeExpr(ids.next!TypeExpr, type.span, kind);
    }

    /// `body` with `unpacks` before it, each taking apart a parameter written as a pattern.
    private Expr takingApart(Stmt[] unpacks, Expr body)
    {
        if (unpacks.length == 0) return body;
        auto isBlock = body.kind.match!((ref BlockExpr _) => true, (ref _) => false);
        if (!isBlock) return Expr(ids.next!Expr, body.span, ExprKind(BlockExpr(unpacks, boxed(body))));
        body.kind.match!(
            (ref BlockExpr block) { block.statements = unpacks ~ block.statements; },
            (ref _) {},
        );
        return body;
    }

    private Token expectBindingName()
    {
        if (!at(TokenKind.identifier) && !at(TokenKind.underscore)) throw failure("a name");
        return tokens[pos++];
    }

    private TypeParam[] parseTypeParameters()
    {
        expect(TokenKind.less, "`<`");
        TypeParam[] params;
        do params ~= parseTypeParameter();
        while (accept(TokenKind.comma));
        expect(TokenKind.greater, "`>` or `,`");
        return params;
    }

    /// `T`, or `T: A & B`.
    private TypeParam parseTypeParameter()
    {
        auto nameToken = expect(TokenKind.typeName, "a type parameter");
        TypeExpr[] bounds;
        if (accept(TokenKind.colon)) bounds = parseInterfaces();
        return TypeParam(ids.next!TypeParam, text(nameToken), spanOf(nameToken), bounds);
    }

    /// `I & J<T>`, after an interface's name or in a conformance or bound.
    private TypeExpr[] parseInterfaces()
    {
        TypeExpr[] interfaces;
        do interfaces ~= parseNamedType();
        while (accept(TokenKind.amp));
        return interfaces;
    }

    /// `interface Name<T>: Required { def f(value: Self): T }`.
    private InterfaceDecl parseInterface()
    {
        pos++;
        auto nameToken = expect(TokenKind.typeName, "an interface name");
        auto nameSpan = spanOf(nameToken);
        InterfaceDecl decl;
        decl.id = ids.next!InterfaceDecl;
        decl.name = text(nameToken);
        decl.nameSpan = nameSpan;
        decl.self = TypeParam(ids.next!TypeParam, "Self", nameSpan);
        if (at(TokenKind.less)) decl.typeParams = parseTypeParameters();
        if (accept(TokenKind.colon)) decl.requires = parseInterfaces();
        skipNewlineBefore(TokenKind.leftBrace);
        expect(TokenKind.leftBrace, "`{`");
        skipSeparators();
        while (!at(TokenKind.rightBrace))
        {
            if (!at(TokenKind.kwDef)) throw failure("`def` or `}`");
            decl.functions ~= parseFunction(FunctionKind.required);
            if (at(TokenKind.rightBrace)) break;
            requireSeparator();
        }
        pos++;
        return decl;
    }

    /// `conform Type: I & J when T: K, U: L`.
    private ConformDecl parseConform()
    {
        pos++;
        skipNewline();
        auto type = parseOptionalType();
        expect(TokenKind.colon, "`:`");
        auto decl = ConformDecl(ids.next!ConformDecl, type, parseInterfaces());
        if (at(TokenKind.newline) && atWord("when", 1)) pos++;
        if (atWord("when"))
        {
            pos++;
            skipNewline();
            do decl.when ~= parseTypeParameter();
            while (accept(TokenKind.comma));
        }
        return decl;
    }

    /// `test "name" body`: a private function returning Unit, named so nothing can call it.
    private FunctionDecl parseTest()
    {
        pos++;
        skipNewline();
        auto literal = parseStringLiteral();
        auto name = plainString(literal, "A test's name");
        auto nameSpan = literal.span;
        auto body = parseBody();
        auto unit = TypeExpr(ids.next!TypeExpr, nameSpan, TypeExprKind(UnitType()));
        auto f = FunctionDecl(ids.next!FunctionDecl, "test " ~ name, nameSpan, null, boxed(body), unit,
            FunctionKind.ordinary, null, true);
        f.testName = name;
        return f;
    }

    /// The text of a string literal that has to be known as written, with no holes.
    private string plainString(Expr literal, string what)
    {
        auto text = literal.kind.match!((ref StringLiteral s) => s.value, (ref _) => cast(string) null);
        if (text.length == 0)
        {
            throw error(literal.span, what ~ " has to be a string with no holes, and can't be empty");
        }
        return text;
    }

    private Expr parseStringLiteral()
    {
        if (!at(TokenKind.stringStart)) throw failure("a string");
        return parseString();
    }

    /// `type Name`, `type Name()`, `type Name(fields)` or `type Name = members`, and for a sum a
    /// declaration of each member it defines inline, which from here on is a type like any other.
    private Decl[] parseTypeDeclaration()
    {
        auto start = here;
        pos++;
        auto nameToken = expect(TokenKind.typeName, "a type name");
        TypeParam[] typeParams;
        if (at(TokenKind.less)) typeParams = parseTypeParameters();
        if (accept(TokenKind.assign)) return parseSum(start, nameToken, typeParams);

        Field[] fields;
        bool emptyParens;
        if (at(TokenKind.leftParen)) fields = parseFields(emptyParens);
        auto product = TypeDecl(ids.next!TypeDecl, text(nameToken), spanOf(nameToken), fields, emptyParens);
        product.typeParams = typeParams;
        return [Decl(spanFrom(start), DeclKind(product))];
    }

    private Decl[] parseSum(size_t start, Token nameToken, TypeParam[] typeParams)
    {
        Decl[] declarations;
        SumMember[] members;
        do
        {
            if (accept(TokenKind.colon))
            {
                members ~= SumMember(parseSumMemberType(), false);
                continue;
            }
            if (!at(TokenKind.typeName) || kindAt(1) != TokenKind.leftParen)
            {
                members ~= SumMember(markerMember(parseSumMemberType(), typeParams), true);
                markerMembers[members[$ - 1].type.id] = true;
                continue;
            }

            auto memberStart = here;
            auto memberName = tokens[pos++];
            bool emptyParens;
            auto fields = parseFields(emptyParens);
            auto inline = TypeDecl(ids.next!TypeDecl, text(memberName), spanOf(memberName), fields, emptyParens);
            inline.typeParams = mentioned(typeParams, inline.fields);
            inline.inheritsParams = inline.typeParams.length > 0;
            declarations ~= Decl(spanFrom(memberStart), DeclKind(inline));
            TypeExpr[] args;
            foreach (p; inline.typeParams)
            {
                args ~= TypeExpr(ids.next!TypeExpr, inline.nameSpan, TypeExprKind(NamedType([p.name], null)));
            }
            members ~= SumMember(TypeExpr(ids.next!TypeExpr, inline.nameSpan, TypeExprKind(NamedType([inline.name], args))), true);
        }
        while (accept(TokenKind.pipe));

        auto sum = TypeDecl(ids.next!TypeDecl, text(nameToken), spanOf(nameToken), null, false, members);
        sum.typeParams = typeParams;
        return declarations ~ Decl(spanFrom(start), DeclKind(sum));
    }

    /// An unmarked sum member, which declares a marker, so it must be a plain new name.
    private TypeExpr markerMember(TypeExpr type, const TypeParam[] typeParams)
    {
        import std.algorithm : canFind;

        auto name = type.kind.match!(
            (ref NamedType named) => named.path.length == 1 && named.args.length == 0 ? named.path[0] : null,
            (ref _) => cast(string) null,
        );
        string problem;
        if (name is null) problem = "only a new name declares a member; write `:%s` to use an existing type";
        else if ([__traits(allMembers, Builtin)].canFind(name)) problem = "`%s` is a built-in type; write `:%s` to make it a member";
        else if (typeParams.canFind!(p => p.name == name)) problem = "`%s` is a type parameter; write `:%s` to make it a member";
        if (problem is null) return type;
        auto text = printTypeExpr(type);
        throw error(type.span, name is null ? problem.format(text) : problem.format(text, text));
    }

    /// `(a: Int, b: T)`, or `()`, which sets `emptyParens`.
    private Field[] parseFields(out bool emptyParens)
    {
        expect(TokenKind.leftParen, "`(`");
        Field[] fields;
        emptyParens = at(TokenKind.rightParen);
        if (!emptyParens)
        {
            do
            {
                auto nameToken = expect(TokenKind.identifier, "a field name");
                fields ~= Field(ids.next!Field, text(nameToken), spanOf(nameToken), parseTypeAnnotation());
            }
            while (accept(TokenKind.comma));
        }
        expect(TokenKind.rightParen, "`)` or `,`");
        return fields;
    }

    /// A TypeDecl for each bare name in a sum. They come last, so a clash with a declaration
    /// elsewhere in the module is reported on the member, where the `:` would go.
    private Decl[] implicitMarkers(Decl[] declarations)
    {
        Decl[] markers;
        foreach (ref declaration; declarations)
        {
            declaration.kind.match!(
                (ref TypeDecl sum) {
                    bool[string] inThisSum;
                    foreach (ref member; sum.members)
                    {
                        if (member.type.id !in markerMembers) continue;
                        auto name = member.type.kind.match!((ref NamedType named) => named.path[0], (ref _) => "");
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

    // Statements

    /// `{ statements }`. When the last statement is an expression it becomes the block's value;
    /// otherwise the value is null, meaning ().
    private Expr parseBlock()
    {
        auto start = here;
        expect(TokenKind.leftBrace, "`{`");
        skipSeparators();
        Stmt[] statements;
        while (!at(TokenKind.rightBrace))
        {
            statements ~= parseStatement();
            if (at(TokenKind.rightBrace)) break;
            requireSeparator();
        }
        pos++;
        BlockExpr block;
        if (statements.length > 0)
        {
            statements[$ - 1].kind.match!(
                (ref ExprStmt last) {
                    block.value = boxed(last.expr);
                    statements = statements[0 .. $ - 1];
                },
                (ref _) {},
            );
        }
        block.statements = statements;
        return Expr(ids.next!Expr, spanFrom(start), ExprKind(block));
    }

    private Stmt parseStatement()
    {
        auto start = here;
        switch (kind)
        {
        case TokenKind.kwVal:
            if (kindAt(1) == TokenKind.leftParen) return parsePatternDeclaration(false);
            return parseValueDeclaration(false);
        case TokenKind.kwMutable:
            if (kindAt(1) != TokenKind.kwVal)
            {
                pos++;
                throw failure("`val`");
            }
            if (kindAt(2) == TokenKind.leftParen) return parsePatternDeclaration(true);
            return parseValueDeclaration(true);
        case TokenKind.kwDef:
            return parseNestedFunction(FunctionKind.ordinary);
        case TokenKind.kwNative:
            return parseNestedFunction(FunctionKind.native);
        case TokenKind.kwIntrinsic:
            if (kindAt(1) != TokenKind.kwDef)
            {
                pos++;
                throw failure("`def`");
            }
            return parseNestedFunction(FunctionKind.intrinsic);
        case TokenKind.underscore:
            if (kindAt(1) != TokenKind.assign) break;
            pos += 2;
            auto discarded = parseExpression();
            return Stmt(spanFrom(start), StmtKind(VarDecl(ids.next!VarDecl, discardName,
                Span(file, start, start + discardName.length), discarded, null, false)));
        case TokenKind.leftParen:
            if (assignTupleAhead()) return parseTupleAssignment();
            break;
        default:
            break;
        }
        return parseExpressionOrAssignment();
    }

    /// `val name: Type = value`, or `mutable val`, whose initializer an option type can leave out.
    private Stmt parseValueDeclaration(bool mutable)
    {
        auto start = here;
        pos += mutable ? 2 : 1;
        auto nameToken = mutable ? expect(TokenKind.identifier, "a name") : expectBindingName();
        auto name = text(nameToken);
        TypeExpr* type = at(TokenKind.colon) ? boxed(parseTypeAnnotation()) : null;
        Expr value;
        if (accept(TokenKind.assign))
        {
            value = parseExpression();
        }
        else if (mutable && type !is null)
        {
            auto isOption = type.kind.match!((ref OptionType _) => true, (ref _) => false);
            if (!isOption)
            {
                throw error(spanOf(nameToken),
                    "`%s` needs an initializer; only an option type defaults to `None`".format(name));
            }
            value = Expr(ids.next!Expr, spanFrom(start), ExprKind(NoneLiteral()));
        }
        else
        {
            throw failure("`=`");
        }
        return Stmt(spanFrom(start), StmtKind(VarDecl(ids.next!VarDecl, name, spanOf(nameToken), value, type, mutable)));
    }

    /// `val (a, b) = value`, or `mutable val`.
    private Stmt parsePatternDeclaration(bool mutable)
    {
        auto start = here;
        pos += mutable ? 2 : 1;
        auto pattern = parseTuplePattern(mutable);
        expect(TokenKind.assign, "`=`");
        auto value = parseExpression();
        return Stmt(spanFrom(start), StmtKind(PatternDecl(pattern, value)));
    }

    /// `(a, (b, c: Int))`, with at least two elements.
    private Pattern parseTuplePattern(bool mutable)
    {
        auto start = here;
        expect(TokenKind.leftParen, "`(`");
        Pattern[] elements = [parsePatternElement(mutable)];
        if (!at(TokenKind.comma)) throw failure("`,`");
        while (accept(TokenKind.comma)) elements ~= parsePatternElement(mutable);
        expect(TokenKind.rightParen, "`)` or `,`");
        return Pattern(ids.next!Pattern, spanFrom(start), PatternKind(TuplePattern(elements)));
    }

    private Pattern parsePatternElement(bool mutable)
    {
        if (at(TokenKind.leftParen)) return parseTuplePattern(mutable);
        auto start = here;
        auto nameToken = expectBindingName();
        TypeExpr* type = at(TokenKind.colon) ? boxed(parseTypeAnnotation()) : null;
        // A binding in a pattern has no value of its own; see VarDecl.value.
        auto binding = VarDecl(ids.next!VarDecl, text(nameToken), spanOf(nameToken), Expr.init, type, mutable);
        return Pattern(ids.next!Pattern, spanFrom(start), PatternKind(binding));
    }

    /// A `def` in a block, which is a lambda bound to a local; a native or intrinsic stays a declaration.
    private Stmt parseNestedFunction(FunctionKind kind)
    {
        auto start = here;
        auto decl = parseFunction(kind);
        if (decl.kind != FunctionKind.ordinary) return Stmt(spanFrom(start), StmtKind(decl));
        if (decl.typeParams.length > 0)
        {
            throw error(decl.typeParams[0].span,
                "A nested `def` can't take type parameters, but it can use those of the function around it");
        }
        auto binding = ids.next!VarDecl;
        auto nested = Expr(ids.next!Expr, spanFrom(start),
            ExprKind(Lambda(decl.params, boxed(decl.returnType), decl.body, decl.name, binding)));
        return Stmt(spanFrom(start), StmtKind(VarDecl(binding, decl.name, decl.nameSpan, nested, null, false)));
    }

    /// An expression, or an assignment to one when an assignment operator follows it, which is
    /// only allowed when the expression is a postfix one: a name, a member, an element or a call.
    private Stmt parseExpressionOrAssignment()
    {
        auto start = here;
        auto targetAt = pos;
        auto expr = parseExpression();
        size_t opLength;
        auto op = assignOpAt(opLength);
        if (op is null) return Stmt(spanFrom(start), StmtKind(ExprStmt(expr)));
        if (lastPostfixStart != targetAt || lastPostfixEnd != pos)
        {
            throw error(spanFrom(start), "Only a name, a field, an element or a tuple of them can be assigned to");
        }
        pos += opLength;
        auto value = parseExpression();
        if (op != "=")
        {
            // `a += 1` becomes `a = a + 1`, so nothing past parsing sees compound assignment.
            // The target is parsed again rather than copied, so the read gets its own IDs.
            auto saved = pos;
            pos = targetAt;
            auto read = parsePostfix();
            pos = saved;
            auto binaryOp = op == "~=" ? BinaryOp.Append : toBinaryOp(op[0 .. $ - 1]);
            value = Expr(ids.next!Expr, Span(file, expr.span.start, value.span.end),
                ExprKind(BinaryExpr(binaryOp, boxed(read), boxed(value))));
        }
        return Stmt(spanFrom(start), StmtKind(AssignStmt(expr, value, op != "=")));
    }

    /// The assignment operator at the current token, if there is one, and how many tokens it takes.
    private string assignOpAt(out size_t length)
    {
        length = 1;
        switch (kind)
        {
        case TokenKind.assign: return "=";
        case TokenKind.plusAssign: return "+=";
        case TokenKind.minusAssign: return "-=";
        case TokenKind.starAssign: return "*=";
        case TokenKind.slashAssign: return "/=";
        case TokenKind.caretAssign: return "^=";
        case TokenKind.tildeAssign: return "~=";
        case TokenKind.plusPercentAssign: return "+%=";
        case TokenKind.minusPercentAssign: return "-%=";
        case TokenKind.starPercentAssign: return "*%=";
        case TokenKind.ampAssign: return "&=";
        case TokenKind.pipeAssign: return "|=";
        case TokenKind.lessLessAssign: return "<<=";
        case TokenKind.greater:
            if (kindAt(1) == TokenKind.greater && kindAt(2) == TokenKind.assign && touches(pos) && touches(pos + 1))
            {
                length = 3;
                return ">>=";
            }
            return null;
        default:
            return null;
        }
    }

    /// Whether a tuple of targets starts here: parentheses holding a comma, then an assignment operator.
    private bool assignTupleAhead()
    {
        size_t close;
        if (!bracketHoldsComma(pos, close)) return false;
        auto saved = pos;
        pos = close + 1;
        size_t length;
        auto isAssignment = assignOpAt(length) !is null;
        pos = saved;
        return isAssignment;
    }

    /// Whether the brackets opening at token `open` hold a comma of their own, and where they close.
    private bool bracketHoldsComma(size_t open, out size_t close)
    {
        int depth = 0;
        bool comma = false;
        for (size_t i = open; i < tokens.length; i++)
        {
            switch (tokens[i].kind)
            {
            case TokenKind.leftParen, TokenKind.leftBracket, TokenKind.leftBrace, TokenKind.holeStart:
                depth++;
                break;
            case TokenKind.rightParen, TokenKind.rightBracket, TokenKind.rightBrace, TokenKind.holeEnd:
                if (--depth == 0)
                {
                    close = i;
                    return comma;
                }
                break;
            case TokenKind.comma:
                if (depth == 1) comma = true;
                break;
            case TokenKind.end:
                return false;
            default:
                break;
            }
        }
        return false;
    }

    /// `(a, _) = v`, whose target is a TupleLiteral, with each `_` an Identifier named
    /// `discardName`, which no expression can otherwise be.
    private Stmt parseTupleAssignment()
    {
        auto start = here;
        auto target = parseAssignTuple();
        size_t opLength;
        auto opStart = here;
        auto op = assignOpAt(opLength);
        pos += opLength;
        if (op != "=")
        {
            throw error(spanFrom(opStart), "`%s` needs one target; only `=` assigns to several at once".format(op));
        }
        auto value = parseExpression();
        return Stmt(spanFrom(start), StmtKind(AssignStmt(target, value, false)));
    }

    private Expr parseAssignTuple()
    {
        auto start = here;
        expect(TokenKind.leftParen, "`(`");
        Expr[] elements;
        do
        {
            size_t close;
            if (at(TokenKind.leftParen) && bracketHoldsComma(pos, close))
            {
                elements ~= parseAssignTuple();
            }
            else if (at(TokenKind.underscore))
            {
                elements ~= Expr(ids.next!Expr, spanOf(tokens[pos]), ExprKind(Identifier(discardName)));
                pos++;
            }
            else
            {
                elements ~= parsePostfix();
            }
        }
        while (accept(TokenKind.comma));
        expect(TokenKind.rightParen, "`)` or `,`");
        return Expr(ids.next!Expr, spanFrom(start), ExprKind(TupleLiteral(elements)));
    }

    // Types

    private TypeExpr parseTypeAnnotation()
    {
        expect(TokenKind.colon, "`:`");
        return parseType();
    }

    /// An optional type, the interfaces joined to it, and then the errors it can be after `!`.
    private TypeExpr parseType()
    {
        auto start = here;
        auto success = parseOptionalType();
        if (at(TokenKind.amp))
        {
            TypeExpr[] parts = [success];
            while (accept(TokenKind.amp)) parts ~= parseOptionalType();
            auto joined = Span(file, success.span.start, parts[$ - 1].span.end);
            success = TypeExpr(ids.next!TypeExpr, joined, TypeExprKind(JoinedType(parts)));
        }
        if (!accept(TokenKind.bang)) return success;
        // `!` can end a statement, so a newline after it is a continuation only by this rule.
        skipNewline();
        TypeExpr[] errors = [parseOptionalType()];
        while (accept(TokenKind.pipe)) errors ~= parseOptionalType();
        return TypeExpr(ids.next!TypeExpr, spanFrom(start), TypeExprKind(ErrorUnionType(boxed(success), errors)));
    }

    /// A sum member's type, whose error side is one type: a list would run into the sum's own `|`.
    private TypeExpr parseSumMemberType()
    {
        auto start = here;
        auto success = parseOptionalType();
        if (!accept(TokenKind.bang)) return success;
        skipNewline();
        auto errorType = parseOptionalType();
        return TypeExpr(ids.next!TypeExpr, spanFrom(start), TypeExprKind(ErrorUnionType(boxed(success), [errorType])));
    }

    /// A type with an optional `?` written right after it.
    private TypeExpr parseOptionalType()
    {
        auto start = here;
        auto base = parseBaseType();
        if (!at(TokenKind.question) || !touches(pos - 1)) return base;
        pos++;
        return TypeExpr(ids.next!TypeExpr, spanFrom(start), TypeExprKind(OptionType(boxed(base))));
    }

    private TypeExpr parseBaseType()
    {
        import std.algorithm : canFind;

        auto start = here;
        if (accept(TokenKind.leftBracket))
        {
            auto element = parseType();
            if (accept(TokenKind.colon))
            {
                auto value = parseType();
                expect(TokenKind.rightBracket, "`]`");
                return TypeExpr(ids.next!TypeExpr, spanFrom(start), TypeExprKind(DictionaryType(boxed(element), boxed(value))));
            }
            expect(TokenKind.rightBracket, "`]`");
            return TypeExpr(ids.next!TypeExpr, spanFrom(start), TypeExprKind(ArrayType(boxed(element))));
        }
        if (!accept(TokenKind.leftParen)) return parseNamedType();

        TypeExpr[] elements;
        bool[] mutables;
        if (!at(TokenKind.rightParen))
        {
            do
            {
                mutables ~= accept(TokenKind.kwMutable);
                elements ~= parseType();
            }
            while (accept(TokenKind.comma));
        }
        expect(TokenKind.rightParen, "`)` or `,`");
        if (accept(TokenKind.thinArrow))
        {
            auto returnType = parseType();
            if (!mutables.canFind(true)) mutables = null;
            return TypeExpr(ids.next!TypeExpr, spanFrom(start), TypeExprKind(FunctionType(elements, mutables, boxed(returnType))));
        }
        if (mutables.canFind(true)) throw failure("`->`, since only a function type's parameters are `mutable`");
        if (elements.length == 0) return TypeExpr(ids.next!TypeExpr, spanFrom(start), TypeExprKind(UnitType()));
        // One element is grouping and more are a tuple.
        if (elements.length == 1) return elements[0];
        return TypeExpr(ids.next!TypeExpr, spanFrom(start), TypeExprKind(TupleType(elements)));
    }

    private TypeExpr parseNamedType()
    {
        auto start = here;
        auto path = parseTypePath();
        TypeExpr[] args;
        if (at(TokenKind.less)) args = parseTypeArguments();
        return TypeExpr(ids.next!TypeExpr, spanFrom(start), TypeExprKind(NamedType(path, args)));
    }

    /// `Name` or `module.path.Name`, written with no spaces.
    private string[] parseTypePath()
    {
        string[] path;
        while (isValueWord(kind))
        {
            if (kindAt(1) != TokenKind.dot || !touches(pos) || !touches(pos + 1)) throw failure("a type");
            path ~= text();
            pos += 2;
        }
        if (!at(TokenKind.typeName)) throw failure("a type");
        path ~= text();
        pos++;
        return path;
    }

    private TypeExpr[] parseTypeArguments()
    {
        expect(TokenKind.less, "`<`");
        TypeExpr[] args;
        do args ~= parseType();
        while (accept(TokenKind.comma));
        expect(TokenKind.greater, "`>` or `,`");
        return args;
    }

    // Recognizers for speculation: each moves `i` past what `parseType` and the rest would take,
    // and says whether they would succeed, without building anything.

    private TokenKind kindOf(size_t i) const => i < tokens.length ? tokens[i].kind : TokenKind.end;

    private bool scanType(ref size_t i)
    {
        if (!scanOptionalType(i)) return false;
        while (kindOf(i) == TokenKind.amp)
        {
            i++;
            if (!scanOptionalType(i)) return false;
        }
        if (kindOf(i) != TokenKind.bang) return true;
        i++;
        if (kindOf(i) == TokenKind.newline) i++;
        if (!scanOptionalType(i)) return false;
        while (kindOf(i) == TokenKind.pipe)
        {
            i++;
            if (!scanOptionalType(i)) return false;
        }
        return true;
    }

    private bool scanOptionalType(ref size_t i)
    {
        if (!scanBaseType(i)) return false;
        if (kindOf(i) == TokenKind.question && touches(i - 1)) i++;
        return true;
    }

    private bool scanBaseType(ref size_t i)
    {
        if (kindOf(i) == TokenKind.leftBracket)
        {
            i++;
            if (!scanType(i) || kindOf(i) != TokenKind.rightBracket) return false;
            i++;
            return true;
        }
        if (kindOf(i) != TokenKind.leftParen) return scanNamedType(i);
        i++;
        if (kindOf(i) != TokenKind.rightParen)
        {
            while (true)
            {
                if (kindOf(i) == TokenKind.kwMutable) i++;
                if (!scanType(i)) return false;
                if (kindOf(i) != TokenKind.comma) break;
                i++;
            }
        }
        if (kindOf(i) != TokenKind.rightParen) return false;
        i++;
        if (kindOf(i) != TokenKind.thinArrow) return true;
        i++;
        return scanType(i);
    }

    private bool scanNamedType(ref size_t i)
    {
        while (isValueWord(kindOf(i)))
        {
            if (kindOf(i + 1) != TokenKind.dot || !touches(i) || !touches(i + 1)) return false;
            i += 2;
        }
        if (kindOf(i) != TokenKind.typeName) return false;
        i++;
        return kindOf(i) != TokenKind.less || scanTypeArguments(i);
    }

    private bool scanTypeArguments(ref size_t i)
    {
        i++;
        while (true)
        {
            if (!scanType(i)) return false;
            if (kindOf(i) != TokenKind.comma) break;
            i++;
        }
        if (kindOf(i) != TokenKind.greater) return false;
        i++;
        return true;
    }

    // Expressions

    private Expr parseExpression() => parseExpressionAt(true);

    /// An expression with no lambda at its top, or `if done => 1 else 2` would read the condition as one.
    private Expr parseCondition() => parseExpressionAt(false);

    private Expr parseExpressionAt(bool lambdas)
    {
        switch (kind)
        {
        case TokenKind.kwMatch: return parseMatch();
        case TokenKind.kwFor: return parseFor();
        case TokenKind.kwWhile: return parseWhile();
        case TokenKind.kwIf: return parseIf();
        default: break;
        }
        if (lambdas && lambdaAhead()) return parseLambda();
        return parseBinary(0);
    }

    private Expr parseBinary(size_t level)
    {
        if (level == levelCount) return parseUnary();
        auto start = here;
        return continueBinary(level, parseBinary(level + 1), start);
    }

    /// The operators at `level` that follow `lhs`, which starts at `start`.
    private Expr continueBinary(size_t level, Expr lhs, size_t start)
    {
        auto assoc = assocOf(level);
        while (true)
        {
            BinaryOp op;
            size_t length;
            if (!binaryOpAt(level, op, length)) return lhs;
            pos += length;
            skipNewline();
            auto rhs = parseBinary(assoc == Assoc.right ? level : level + 1);
            if (level == Level.range)
            {
                lhs = Expr(ids.next!Expr, Span(file, lhs.span.start, rhs.span.end),
                    ExprKind(RangeExpr(boxed(lhs), boxed(rhs))));
            }
            else
            {
                // An operand's own span leaves out its parentheses, so the span runs from the
                // first token instead.
                lhs = Expr(ids.next!Expr, spanFrom(start), ExprKind(BinaryExpr(op, boxed(lhs), boxed(rhs))));
            }
            if (assoc != Assoc.left) return lhs;
        }
    }

    /// The operator at `level` at the current token, and how many tokens it takes.
    private bool binaryOpAt(size_t level, out BinaryOp op, out size_t length)
    {
        length = 1;
        auto k = kind;
        bool pick(TokenKind want, BinaryOp result)
        {
            if (k != want) return false;
            op = result;
            return true;
        }

        switch (level)
        {
        case Level.or: return pick(TokenKind.pipePipe, BinaryOp.Or);
        case Level.and: return pick(TokenKind.ampAmp, BinaryOp.And);
        case Level.equality: return pick(TokenKind.equalEqual, BinaryOp.Equal) || pick(TokenKind.bangEqual, BinaryOp.NotEqual);
        case Level.relational:
            if (pick(TokenKind.lessEqual, BinaryOp.LessEqual) || pick(TokenKind.less, BinaryOp.Less)) return true;
            if (k != TokenKind.greater) return false;
            if (kindAt(1) == TokenKind.assign && touches(pos))
            {
                op = BinaryOp.GreaterEqual;
                length = 2;
                return true;
            }
            if (kindAt(1) == TokenKind.greater && touches(pos)) return false;
            op = BinaryOp.Greater;
            return true;
        case Level.range: return pick(TokenKind.dotDot, BinaryOp.Add);
        case Level.coalesce: return pick(TokenKind.questionQuestion, BinaryOp.Coalesce);
        case Level.bitOr: return pick(TokenKind.pipe, BinaryOp.BitOr);
        case Level.bitXor: return pick(TokenKind.caret, BinaryOp.BitXor);
        case Level.bitAnd: return pick(TokenKind.amp, BinaryOp.BitAnd);
        case Level.shift:
            if (pick(TokenKind.lessLess, BinaryOp.ShiftLeft)) return true;
            // `a >>= b` is an assignment.
            if (k == TokenKind.greater && kindAt(1) == TokenKind.greater && touches(pos)
                && !(kindAt(2) == TokenKind.assign && touches(pos + 1)))
            {
                op = BinaryOp.ShiftRight;
                length = 2;
                return true;
            }
            return false;
        case Level.addition:
            return pick(TokenKind.plusPercent, BinaryOp.WrappingAdd) || pick(TokenKind.minusPercent, BinaryOp.WrappingSubtract)
                || pick(TokenKind.plus, BinaryOp.Add) || pick(TokenKind.minus, BinaryOp.Subtract) || pick(TokenKind.tilde, BinaryOp.Concat);
        case Level.multiply:
            return pick(TokenKind.starPercent, BinaryOp.WrappingMultiply) || pick(TokenKind.star, BinaryOp.Multiply)
                || pick(TokenKind.slash, BinaryOp.Divide) || pick(TokenKind.percent, BinaryOp.Modulo);
        default:
            return false;
        }
    }

    /// One prefix operator at most, then a postfix expression.
    private Expr parseUnary()
    {
        UnaryOp op;
        switch (kind)
        {
        case TokenKind.minus: op = UnaryOp.Minus; break;
        case TokenKind.bang: op = UnaryOp.Not; break;
        case TokenKind.tilde: op = UnaryOp.BitNot; break;
        default: return parsePostfix();
        }
        auto start = here;
        pos++;
        skipNewline();
        auto operand = parsePostfix();
        return Expr(ids.next!Expr, Span(file, start, operand.span.end), ExprKind(UnaryExpr(op, boxed(operand))));
    }

    /// A primary expression and the calls, indexes, members and other postfix operations after it,
    /// folded left so `m.f(1)` is `call (m.f) 1`.
    private Expr parsePostfix()
    {
        if (kind == TokenKind.kwReturn || kind == TokenKind.kwFail || kind == TokenKind.kwBreak || kind == TokenKind.kwContinue)
            return parseJump();
        auto startAt = pos;
        auto lhs = parsePrimary();
        loop: while (true)
        {
            auto opStart = here;
            Span through() => Span(file, lhs.span.start, lastEnd());
            switch (kind)
            {
            case TokenKind.leftParen:
                lhs = parseCall(lhs);
                break;
            case TokenKind.leftBracket:
                lhs = parseIndex(lhs);
                break;
            case TokenKind.bang:
                pos++;
                lhs = Expr(ids.next!Expr, through(), ExprKind(AssertExpr(boxed(lhs))));
                break;
            case TokenKind.question:
                pos++;
                lhs = Expr(ids.next!Expr, through(), ExprKind(PropagateExpr(boxed(lhs))));
                break;
            case TokenKind.dot:
                if (!isMemberName(kindAt(1))) break loop;
                auto member = text(tokens[pos + 1]);
                pos += 2;
                lhs = Expr(ids.next!Expr, through(), ExprKind(MemberAccess(boxed(lhs), member)));
                break;
            case TokenKind.questionDot:
                if (!isMemberName(kindAt(1))) break loop;
                auto safeMember = text(tokens[pos + 1]);
                pos += 2;
                lhs = Expr(ids.next!Expr, through(), ExprKind(SafeMemberAccess(boxed(lhs), safeMember)));
                break;
            case TokenKind.kwWith:
                lhs = parseWith(lhs);
                break;
            case TokenKind.less:
                size_t i = pos;
                if (!scanTypeArguments(i)) break loop;
                auto typeArgs = parseTypeArguments();
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
                if (!named) throw error(spanFrom(opStart), "Type arguments can only follow the name of a function or a type");
                lhs.span = through();
                break;
            default:
                break loop;
            }
        }
        lastPostfixStart = startAt;
        lastPostfixEnd = pos;
        return lhs;
    }

    private Expr parseCall(Expr callee)
    {
        import std.algorithm : canFind;

        pos++;
        Expr[] args;
        bool[] mutables;
        if (!at(TokenKind.rightParen))
        {
            do
            {
                mutables ~= accept(TokenKind.kwMutable);
                args ~= parseExpression();
            }
            while (accept(TokenKind.comma));
        }
        expect(TokenKind.rightParen, "`)` or `,`");
        auto span = Span(file, callee.span.start, lastEnd());
        if (!mutables.canFind(true)) mutables = null;
        auto reserved = callee.kind.match!((ref Identifier id) => id.typeArgs.length == 0 ? id.name : null, (ref _) => null);
        if (args.length == 1 && mutables is null)
        {
            if (reserved == "Some") return Expr(ids.next!Expr, span, ExprKind(SomeExpr(boxed(args[0]))));
            if (reserved == "Ok") return Expr(ids.next!Expr, span, ExprKind(OkExpr(boxed(args[0]))));
            if (reserved == "Error") return Expr(ids.next!Expr, span, ExprKind(ErrorExpr(boxed(args[0]))));
        }
        return Expr(ids.next!Expr, span, ExprKind(CallExpr(boxed(callee), args, mutables)));
    }

    /// `xs[i]`, or a slice: `xs[a..b]`, and `xs[a..]` and `xs[..b]`, ranges with a bound left out,
    /// which only a slice allows.
    private Expr parseIndex(Expr object)
    {
        pos++;
        Expr index;
        auto start = here;
        if (accept(TokenKind.dotDot))
        {
            auto end = parseBinary(Level.coalesce);
            index = Expr(ids.next!Expr, spanFrom(start), ExprKind(RangeExpr(null, boxed(end))));
        }
        else if (at(TokenKind.kwMatch) || at(TokenKind.kwFor) || at(TokenKind.kwWhile) || at(TokenKind.kwIf) || lambdaAhead())
        {
            index = parseExpression();
        }
        else
        {
            auto first = parseBinary(Level.coalesce);
            if (at(TokenKind.dotDot) && kindAt(1) == TokenKind.rightBracket)
            {
                pos++;
                index = Expr(ids.next!Expr, spanFrom(start), ExprKind(RangeExpr(boxed(first), null)));
            }
            else
            {
                foreach_reverse (level; 0 .. Level.coalesce)
                {
                    first = continueBinary(level, first, start);
                }
                index = first;
            }
        }
        expect(TokenKind.rightBracket, "`]`");
        return Expr(ids.next!Expr, Span(file, object.span.start, lastEnd()), ExprKind(IndexExpr(boxed(object), boxed(index))));
    }

    /// `object with (a = 1, b.c = 2)`.
    private Expr parseWith(Expr object)
    {
        pos++;
        expect(TokenKind.leftParen, "`(`");
        FieldUpdate[] updates;
        do
        {
            auto pathStart = here;
            string[] path;
            do
            {
                if (!isMemberName(kind)) throw failure("a field name");
                path ~= text();
                pos++;
            }
            while (accept(TokenKind.dot));
            auto pathSpan = spanFrom(pathStart);
            expect(TokenKind.assign, "`=`");
            updates ~= FieldUpdate(path, pathSpan, parseExpression());
        }
        while (accept(TokenKind.comma));
        expect(TokenKind.rightParen, "`)` or `,`");
        return Expr(ids.next!Expr, Span(file, object.span.start, lastEnd()), ExprKind(WithExpr(boxed(object), updates)));
    }

    /// A jump's value takes the rest of the expression, so `x ?? return a ?? b` returns `a ?? b`.
    /// `fail e` is `return Error(e)`.
    private Expr parseJump()
    {
        auto start = here;
        auto keyword = kind;
        pos++;
        ExprKind jump;
        if (keyword == TokenKind.kwBreak) jump = ExprKind(BreakExpr());
        else if (keyword == TokenKind.kwContinue) jump = ExprKind(ContinueExpr());
        else if (keyword == TokenKind.kwFail)
        {
            if (!canBeginExpression(kind)) throw failure("an error after `fail`");
            auto error = parseExpression();
            auto wrapped = Expr(ids.next!Expr, spanFrom(start), ExprKind(ErrorExpr(boxed(error))));
            jump = ExprKind(ReturnExpr(boxed(wrapped)));
        }
        else if (canBeginExpression(kind)) jump = ExprKind(ReturnExpr(boxed(parseExpression())));
        else jump = ExprKind(ReturnExpr(boxed(Expr(ids.next!Expr, spanFrom(start), ExprKind(UnitLiteral())))));
        return Expr(ids.next!Expr, spanFrom(start), jump);
    }

    private Expr parsePrimary()
    {
        auto start = here;
        switch (kind)
        {
        case TokenKind.leftParen:
            pos++;
            if (accept(TokenKind.rightParen)) return Expr(ids.next!Expr, spanFrom(start), ExprKind(UnitLiteral()));
            Expr[] elements = [parseExpression()];
            while (accept(TokenKind.comma)) elements ~= parseExpression();
            expect(TokenKind.rightParen, "`)` or `,`");
            // One element is grouping and more are a tuple.
            if (elements.length == 1) return elements[0];
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(TupleLiteral(elements)));
        case TokenKind.leftBrace:
            return parseBlock();
        case TokenKind.leftBracket:
            return parseCollection();
        case TokenKind.identifier:
            pos++;
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(Identifier(text(tokens[pos - 1]))));
        case TokenKind.typeName:
            pos++;
            auto name = text(tokens[pos - 1]);
            if (name == "None") return Expr(ids.next!Expr, spanFrom(start), ExprKind(NoneLiteral()));
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(Identifier(name)));
        default:
            if (atLiteral()) return parseLiteral();
            throw failure("an expression");
        }
    }

    /// Whether a literal starts here. A sign written right before a decimal number is part of it,
    /// which is only reached after a prefix operator has taken the first, as in `--5`, or for `+`.
    private bool atLiteral() const
    {
        switch (kind)
        {
        case TokenKind.kwTrue, TokenKind.kwFalse, TokenKind.integer, TokenKind.hexInteger, TokenKind.binaryInteger,
            TokenKind.float_, TokenKind.stringStart, TokenKind.char_:
            return true;
        case TokenKind.plus, TokenKind.minus:
            return (kindAt(1) == TokenKind.integer || kindAt(1) == TokenKind.float_) && touches(pos);
        default:
            return false;
        }
    }

    private Expr parseLiteral()
    {
        auto start = here;
        auto token = tokens[pos];
        switch (token.kind)
        {
        case TokenKind.kwTrue, TokenKind.kwFalse:
            pos++;
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(BoolLiteral(token.kind == TokenKind.kwTrue)));
        case TokenKind.integer:
            pos++;
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(integerLiteral(text(token), 10)));
        case TokenKind.hexInteger:
            pos++;
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(integerLiteral(text(token)[2 .. $], 16)));
        case TokenKind.binaryInteger:
            pos++;
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(integerLiteral(text(token)[2 .. $], 2)));
        case TokenKind.float_:
            pos++;
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(FloatLiteral(parseFloat(text(token)), text(token))));
        case TokenKind.stringStart:
            return parseString();
        case TokenKind.char_:
            pos++;
            return parseChar(token);
        default:
            // A sign and the number right after it.
            auto number = tokens[pos + 1];
            pos += 2;
            auto span = spanFrom(start);
            if (number.kind == TokenKind.float_)
            {
                return Expr(ids.next!Expr, span, ExprKind(FloatLiteral(parseFloat(source[token.start .. number.end]), source[token.start .. number.end])));
            }
            auto literal = Expr(ids.next!Expr, span, ExprKind(integerLiteral(text(number), 10)));
            if (token.kind == TokenKind.plus) return literal;
            return Expr(ids.next!Expr, span, ExprKind(UnaryExpr(UnaryOp.Minus, boxed(literal))));
        }
    }

    /// A StringLiteral with escapes decoded, or an InterpolatedString if the source has holes.
    private Expr parseString()
    {
        auto start = here;
        pos++;
        Expr[] parts;
        string text;
        Span textSpan;
        void endText()
        {
            if (text.length == 0) return;
            parts ~= Expr(ids.next!Expr, textSpan, ExprKind(StringLiteral(text)));
            text = null;
        }
        void addText(string piece, Span pieceSpan)
        {
            textSpan = Span(file, text.length == 0 ? pieceSpan.start : textSpan.start, pieceSpan.end);
            text ~= piece;
        }

        auto hasHoles = false;
        while (true)
        {
            auto token = tokens[pos];
            switch (token.kind)
            {
            case TokenKind.stringText:
                pos++;
                addText(this.text(token), spanOf(token));
                break;
            case TokenKind.stringEscape:
                pos++;
                addText(decodeEscape(this.text(token), spanOf(token)), spanOf(token));
                break;
            case TokenKind.holeStart:
                pos++;
                if (at(TokenKind.holeEnd))
                {
                    pos++;
                    throw error(spanFrom(token.start), "A string hole needs an expression; write `\\{` for a literal brace");
                }
                hasHoles = true;
                endText();
                parts ~= parseExpression();
                expect(TokenKind.holeEnd, "`}`");
                break;
            case TokenKind.stringEnd:
                pos++;
                if (!hasHoles) return Expr(ids.next!Expr, spanFrom(start), ExprKind(StringLiteral(text)));
                endText();
                return Expr(ids.next!Expr, spanFrom(start), ExprKind(InterpolatedString(parts)));
            default:
                throw failure("the rest of the string");
            }
        }
    }

    private Expr parseChar(Token token)
    {
        import std.range : walkLength;
        import std.utf : decodeFront;

        auto span = spanOf(token);
        auto inner = this.text(token)[1 .. $ - 1];
        auto offset = token.start + 1;
        string text;
        size_t i = 0;
        while (i < inner.length)
        {
            if (inner[i] != '\\')
            {
                text ~= inner[i];
                i++;
                continue;
            }
            auto length = inner[i + 1] == 'u' ? inner[i .. $].indexOfBrace + 1 : 2;
            text ~= decodeEscape(inner[i .. i + length], Span(file, offset + i, offset + i + length));
            i += length;
        }
        if (text.walkLength != 1)
        {
            throw error(span, "A character literal holds exactly one character; a String is written with `\"`");
        }
        return Expr(ids.next!Expr, span, ExprKind(CharLiteral(text.decodeFront)));
    }

    private string decodeEscape(string escape, Span span)
    {
        import std.utf : encode;

        switch (escape[1])
        {
        case 'u':
            import std.conv : to;
            auto scalar = escape[3 .. $ - 1].to!uint(16);
            if (scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF))
            {
                throw error(span, "`%s` isn't a Unicode scalar value, which is at most 10FFFF and not in D800 to DFFF"
                    .format(escape));
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
            // A quote, a backslash or a brace stands for itself.
            return escape[1 .. 2];
        }
    }

    /// `[a, b]`, `[k: v]`, or the empty map `[:]`. Either can end with a comma.
    private Expr parseCollection()
    {
        auto start = here;
        pos++;
        if (at(TokenKind.colon) && kindAt(1) == TokenKind.rightBracket)
        {
            pos += 2;
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(MapLiteral(null, null)));
        }
        Expr[] elements;
        if (accept(TokenKind.rightBracket)) return Expr(ids.next!Expr, spanFrom(start), ExprKind(ArrayLiteral(elements)));

        elements ~= parseExpression();
        if (accept(TokenKind.colon))
        {
            Expr[] keys = elements;
            Expr[] values = [parseExpression()];
            while (accept(TokenKind.comma) && !at(TokenKind.rightBracket))
            {
                keys ~= parseExpression();
                expect(TokenKind.colon, "`:`");
                values ~= parseExpression();
            }
            expect(TokenKind.rightBracket, "`]` or `,`");
            return Expr(ids.next!Expr, spanFrom(start), ExprKind(MapLiteral(keys, values)));
        }
        while (accept(TokenKind.comma) && !at(TokenKind.rightBracket)) elements ~= parseExpression();
        expect(TokenKind.rightBracket, "`]` or `,`");
        return Expr(ids.next!Expr, spanFrom(start), ExprKind(ArrayLiteral(elements)));
    }

    /// Whether a lambda starts here: a name and `=>`, or parameters in parentheses, an optional
    /// return type and `=>`.
    private bool lambdaAhead()
    {
        if ((at(TokenKind.identifier) || at(TokenKind.underscore)) && kindAt(1) == TokenKind.fatArrow) return true;
        if (!at(TokenKind.leftParen)) return false;
        size_t i = pos + 1;
        if (kindOf(i) != TokenKind.rightParen)
        {
            while (true)
            {
                if (kindOf(i) == TokenKind.kwMutable) i++;
                if (kindOf(i) == TokenKind.leftParen)
                {
                    if (!scanPattern(i)) return false;
                }
                else
                {
                    if (kindOf(i) != TokenKind.identifier && kindOf(i) != TokenKind.underscore) return false;
                    i++;
                }
                if (kindOf(i) == TokenKind.colon)
                {
                    i++;
                    if (!scanType(i)) return false;
                }
                if (kindOf(i) != TokenKind.comma) break;
                i++;
            }
            if (kindOf(i) != TokenKind.rightParen) return false;
        }
        i++;
        if (kindOf(i) == TokenKind.colon)
        {
            i++;
            if (!scanType(i)) return false;
        }
        return kindOf(i) == TokenKind.fatArrow;
    }

    /// Whether a tuple pattern starts at `i`, which is moved past it: names, `_` and patterns, each
    /// with an optional type, at least two of them.
    private bool scanPattern(ref size_t i)
    {
        if (kindOf(i) != TokenKind.leftParen) return false;
        i++;
        size_t count;
        while (true)
        {
            if (kindOf(i) == TokenKind.leftParen)
            {
                if (!scanPattern(i)) return false;
            }
            else
            {
                if (kindOf(i) != TokenKind.identifier && kindOf(i) != TokenKind.underscore) return false;
                i++;
                if (kindOf(i) == TokenKind.colon)
                {
                    i++;
                    if (!scanType(i)) return false;
                }
            }
            count++;
            if (kindOf(i) != TokenKind.comma) break;
            i++;
        }
        if (kindOf(i) != TokenKind.rightParen || count < 2) return false;
        i++;
        return true;
    }

    private Expr parseLambda()
    {
        auto start = here;
        Param[] params;
        Stmt[] unpacks;
        TypeExpr* returnType;
        if (!at(TokenKind.leftParen))
        {
            params ~= Param(ids.next!Param, text(), spanOf(tokens[pos]), TypeExpr.init, false, false);
            pos++;
        }
        else
        {
            pos++;
            if (!at(TokenKind.rightParen))
            {
                do
                {
                    auto paramStart = here;
                    auto mutable = accept(TokenKind.kwMutable);
                    if (at(TokenKind.leftParen))
                    {
                        params ~= parsePatternParam(paramStart, mutable, false, unpacks);
                        continue;
                    }
                    auto nameToken = expectBindingName();
                    auto annotated = at(TokenKind.colon);
                    auto type = annotated ? parseTypeAnnotation() : TypeExpr.init;
                    params ~= Param(ids.next!Param, text(nameToken), spanOf(nameToken), type, mutable, annotated);
                }
                while (accept(TokenKind.comma));
            }
            expect(TokenKind.rightParen, "`)` or `,`");
            if (at(TokenKind.colon)) returnType = boxed(parseTypeAnnotation());
        }
        expect(TokenKind.fatArrow, "`=>`");
        auto body = takingApart(unpacks, parseExpression());
        return Expr(ids.next!Expr, spanFrom(start), ExprKind(Lambda(params, returnType, boxed(body))));
    }

    private Expr parseMatch()
    {
        auto start = here;
        pos++;
        auto subject = parseCondition();
        skipNewlineBefore(TokenKind.leftBrace);
        expect(TokenKind.leftBrace, "`{`");
        skipSeparators();
        MatchArm[] arms;
        while (!at(TokenKind.rightBrace))
        {
            auto armStart = here;
            auto pattern = parseMatchPattern();
            expect(TokenKind.fatArrow, "`=>`");
            auto body = parseExpression();
            arms ~= MatchArm(spanFrom(armStart), pattern, body);
            if (at(TokenKind.rightBrace)) break;
            requireSeparator();
        }
        pos++;
        return Expr(ids.next!Expr, spanFrom(start), ExprKind(MatchExpr(boxed(subject), arms, MatchOrigin.Match)));
    }

    private Pattern parseMatchPattern()
    {
        auto start = here;
        Pattern pattern(K)(K kind) => Pattern(ids.next!Pattern, spanFrom(start), PatternKind(kind));

        if (accept(TokenKind.leftParen))
        {
            Pattern[] elements = [parseMatchPattern()];
            if (!at(TokenKind.comma)) throw failure("`,`");
            while (accept(TokenKind.comma)) elements ~= parseMatchPattern();
            expect(TokenKind.rightParen, "`)` or `,`");
            return pattern(TuplePattern(elements));
        }
        if (atTypePath()) return parseConstructorPattern();
        if (atLiteral())
        {
            auto literal = parseLiteral();
            if (literal.kind.match!((ref InterpolatedString _) => true, (ref _) => false))
            {
                throw error(spanFrom(start), "A string in a pattern can't have holes; write `\\{` for a literal brace");
            }
            return pattern(LiteralPattern(boxed(literal)));
        }
        auto nameToken = expectBindingName();
        TypeExpr* type = at(TokenKind.colon) ? boxed(parseTypeAnnotation()) : null;
        return pattern(VarDecl(ids.next!VarDecl, text(nameToken), spanOf(nameToken), Expr.init, type, false));
    }

    /// Whether a type's name starts here: a TypeName, or a lowercase name with a `.` right after it.
    private bool atTypePath() const
        => at(TokenKind.typeName) || (isValueWord(kind) && kindAt(1) == TokenKind.dot && touches(pos));

    /// `Literal(text)` or `Red`, with type arguments if they're written. `Some`, `None`, `Ok` and
    /// `Error` are written like constructors, as in expressions.
    private Pattern parseConstructorPattern()
    {
        auto start = here;
        auto path = parseTypePath();
        auto pathSpan = spanFrom(start);
        TypeExpr[] typeArgs;
        auto typed = at(TokenKind.less);
        if (typed) typeArgs = parseTypeArguments();
        auto typeSpan = spanFrom(start);
        Pattern[] arguments;
        if (accept(TokenKind.leftParen))
        {
            do arguments ~= parseMatchPattern();
            while (accept(TokenKind.comma));
            expect(TokenKind.rightParen, "`)` or `,`");
        }
        auto span = spanFrom(start);
        Pattern pattern(K)(K kind) => Pattern(ids.next!Pattern, span, PatternKind(kind));

        if (typed)
        {
            auto type = TypeExpr(ids.next!TypeExpr, typeSpan, TypeExprKind(NamedType(path, typeArgs)));
            return pattern(ConstructorPattern(type, arguments));
        }
        if (path == ["None"] && arguments.length == 0) return pattern(NonePattern());
        if (arguments.length == 1)
        {
            if (path == ["Some"]) return pattern(SomePattern(boxed(arguments[0])));
            if (path == ["Ok"]) return pattern(OkPattern(boxed(arguments[0])));
            if (path == ["Error"]) return pattern(ErrorPattern(boxed(arguments[0])));
        }
        auto type = TypeExpr(ids.next!TypeExpr, pathSpan, TypeExprKind(NamedType(path, null)));
        return pattern(ConstructorPattern(type, arguments));
    }

    /// `for x in xs { ... }`. `for (a, b) in xs { ... }` becomes `for t in xs { val (a, b) = t; ... }`,
    /// where no source can name `t`.
    private Expr parseFor()
    {
        auto start = here;
        pos++;
        auto destructured = at(TokenKind.leftParen);
        auto nameStart = here;
        string name;
        Pattern pattern;
        if (destructured)
        {
            name = "for.%s".format(forPatterns++);
            pattern = parseTuplePattern(false);
        }
        else
        {
            name = text(expectBindingName());
        }
        auto nameSpan = spanFrom(nameStart);
        expect(TokenKind.kwIn, "`in`");
        auto binding = boxed(VarDecl(ids.next!VarDecl, name, nameSpan, parseCondition(), null, false));
        skipNewlineBefore(TokenKind.leftBrace);
        auto body = parseBlock();
        if (destructured)
        {
            auto element = Expr(ids.next!Expr, nameSpan, ExprKind(Identifier(name)));
            auto unpack = Stmt(nameSpan, StmtKind(PatternDecl(pattern, element)));
            body.kind.match!(
                (ref BlockExpr block) { block.statements = unpack ~ block.statements; },
                (ref _) { assert(0, "a `for` body is always a block"); },
            );
        }
        return Expr(ids.next!Expr, spanFrom(start), ExprKind(ForExpr(binding, boxed(body))));
    }

    private Expr parseWhile()
    {
        auto start = here;
        pos++;
        Expr* condition;
        VarDecl* binding;
        if (at(TokenKind.kwVal)) binding = parseOptionBinding();
        else condition = boxed(parseCondition());
        skipNewlineBefore(TokenKind.leftBrace);
        auto body = parseBlock();
        return Expr(ids.next!Expr, spanFrom(start), ExprKind(WhileExpr(condition, boxed(body), binding)));
    }

    /// `val x = option`, after `if` or `while`.
    private VarDecl* parseOptionBinding()
    {
        pos++;
        auto nameToken = expectBindingName();
        expect(TokenKind.assign, "`=`");
        return boxed(VarDecl(ids.next!VarDecl, text(nameToken), spanOf(nameToken), parseCondition(), null, false));
    }

    /// `if c => a else b`, `if c { ... } else { ... }`, and the same with `val x = option`,
    /// `val Pattern(x) = value` or `type T: I` in place of the condition. An else-if is just an
    /// else branch that's another if.
    private Expr parseIf()
    {
        auto start = here;
        pos++;
        Expr* condition;
        VarDecl* binding;
        TypeTest* test;
        if (at(TokenKind.kwType))
        {
            pos++;
            auto nameToken = expect(TokenKind.typeName, "a type parameter");
            expect(TokenKind.colon, "`:`");
            test = new TypeTest(text(nameToken), spanOf(nameToken), parseInterfaces());
        }
        else if (at(TokenKind.kwVal))
        {
            pos++;
            if (atTypePath()) return parsePatternIf(start);
            pos--;
            binding = parseOptionBinding();
        }
        else
        {
            condition = boxed(parseCondition());
        }
        skipNewlineBefore(TokenKind.leftBrace);
        auto thenBranch = parseIfBranch();
        Expr* elseBranch;
        if (accept(TokenKind.kwElse)) elseBranch = boxed(parseElseBranch());
        return Expr(ids.next!Expr, spanFrom(start), ExprKind(IfExpr(condition, boxed(thenBranch), elseBranch, binding, test)));
    }

    private Expr parseIfBranch()
    {
        if (accept(TokenKind.fatArrow)) return parseExpression();
        if (at(TokenKind.leftBrace)) return parseBlock();
        throw failure("`=>` or a block");
    }

    private Expr parseElseBranch() => at(TokenKind.leftBrace) ? parseBlock() : parseExpression();

    /// `if val Literal(text) = p => a else b`, as a match of that pattern and `_`.
    private Expr parsePatternIf(size_t start)
    {
        auto pattern = parseConstructorPattern();
        expect(TokenKind.assign, "`=`");
        auto subject = parseCondition();
        skipNewlineBefore(TokenKind.leftBrace);
        auto thenBranch = parseIfBranch();
        auto hasElse = accept(TokenKind.kwElse);
        Expr otherwise;
        if (hasElse) otherwise = parseElseBranch();
        auto span = spanFrom(start);
        if (!hasElse) otherwise = Expr(ids.next!Expr, span, ExprKind(UnitLiteral()));
        auto discard = VarDecl(ids.next!VarDecl, discardName, span, Expr.init, null, false);
        auto arms = [
            MatchArm(pattern.span, pattern, thenBranch),
            MatchArm(span, Pattern(ids.next!Pattern, span, PatternKind(discard)), otherwise),
        ];
        return Expr(ids.next!Expr, span, ExprKind(MatchExpr(boxed(subject), arms,
            hasElse ? MatchOrigin.IfValElse : MatchOrigin.IfVal)));
    }

    /// Copies `node` to the heap, for nodes that hold their children by pointer.
    private T* boxed(T)(T node)
    {
        auto p = new T;
        *p = node;
        return p;
    }
}

/// A word a module path or a type's module can be made of: any lowercase name, reserved or not.
private bool isValueWord(TokenKind kind) => kind == TokenKind.identifier || isKeyword(kind);

/// What can follow `.`: any name at all.
private bool isMemberName(TokenKind kind) => kind == TokenKind.identifier || kind == TokenKind.typeName || isKeyword(kind);

/// Whether an expression can start with a token of this kind.
private bool canBeginExpression(TokenKind kind)
{
    switch (kind)
    {
    case TokenKind.identifier, TokenKind.typeName, TokenKind.integer, TokenKind.hexInteger, TokenKind.binaryInteger,
        TokenKind.float_, TokenKind.char_, TokenKind.stringStart, TokenKind.leftParen, TokenKind.leftBracket,
        TokenKind.leftBrace, TokenKind.minus, TokenKind.plus, TokenKind.bang, TokenKind.tilde, TokenKind.kwTrue,
        TokenKind.kwFalse, TokenKind.underscore, TokenKind.kwMatch, TokenKind.kwFor, TokenKind.kwWhile, TokenKind.kwIf,
        TokenKind.kwReturn, TokenKind.kwFail, TokenKind.kwBreak, TokenKind.kwContinue:
        return true;
    default:
        return false;
    }
}

/// The length of a `\u{...}` escape up to its closing brace.
private size_t indexOfBrace(string text)
{
    foreach (i, c; text)
    {
        if (c == '}') return i;
    }
    return text.length - 1;
}

/// `to!double` rounds through x87 reals, so its result depends on the calling thread's FPU precision.
private double parseFloat(string text)
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;

    return strtod(text.toStringz, null);
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

private BinaryOp toBinaryOp(string op)
{
    switch (op)
    {
    case "+": return BinaryOp.Add;
    case "-": return BinaryOp.Subtract;
    case "*": return BinaryOp.Multiply;
    case "/": return BinaryOp.Divide;
    case "&": return BinaryOp.BitAnd;
    case "|": return BinaryOp.BitOr;
    case "^": return BinaryOp.BitXor;
    case "<<": return BinaryOp.ShiftLeft;
    case ">>": return BinaryOp.ShiftRight;
    case "+%": return BinaryOp.WrappingAdd;
    case "-%": return BinaryOp.WrappingSubtract;
    case "*%": return BinaryOp.WrappingMultiply;
    default: assert(0, "not a compound assignment's operator: " ~ op);
    }
}

/// The parameters in `params` that a field in `fields` names, in their order. A field can only
/// mean one of them by a bare name, since no type can share a parameter's name.
private TypeParam[] mentioned(TypeParam[] params, const(Field)[] fields)
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
            (const DictionaryType d) {
                visit(*d.key);
                visit(*d.value);
            },
            (const FunctionType f) {
                foreach (p; f.params) visit(p);
                visit(*f.returnType);
            },
            (const UnitType _) {},
            (const TupleType t) {
                foreach (e; t.elements) visit(e);
            },
            (const JoinedType j) {
                foreach (part; j.parts) visit(part);
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

@("parse throws, naming the source, on invalid source")
unittest
{
    import std.exception : collectException;
    import silver.syntax.parse : parse;

    auto error = collectException!ParseException(parse("val = 1", "test", new NodeIds, "math.ag"));
    assert(error !is null);
    assert(error.diagnostic.span.file == "math.ag");
    assert(collectException!ParseException(parse("def f(a", "test", new NodeIds)) !is null);
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

@("an `if type`'s span for its type is the type's name")
unittest
{
    import std.sumtype : match;
    import silver.syntax.parse : parse;

    auto source = "def f<R>(r: R): Int => if type  R: Sized => 1 else 2";
    auto m = parse(source, "test", new NodeIds);
    auto body = m.declarations[0].kind.match!(
        (const FunctionDecl f) => f.body,
        _ => null,
    );
    auto test = (*body).kind.match!(
        (const IfExpr i) => i.test,
        _ => null,
    );
    assert(test !is null);
    assert(source[test.span.start .. test.span.end] == "R");
    assert(test.name == "R");
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
