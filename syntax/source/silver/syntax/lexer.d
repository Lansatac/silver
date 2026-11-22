module silver.syntax.lexer;

enum TokenKind : ubyte
{
    end,
    /// A run of line breaks that separates statements: see `separates`.
    newline,
    semicolon,
    /// Lexing failed here; the lexer's `errors` say why.
    error,

    identifier,
    typeName,
    /// Decimal digits.
    integer,
    hexInteger,
    binaryInteger,
    /// With a fraction, an exponent or both.
    float_,
    /// A whole character literal, quotes included.
    char_,

    stringStart,
    /// A run of a string's text with no escapes.
    stringText,
    stringEscape,
    holeStart,
    holeEnd,
    stringEnd,

    // Reserved words. Keep these together: `isKeyword` relies on it.
    kwAlias,
    kwBreak,
    kwContinue,
    kwDef,
    kwElse,
    kwFail,
    kwFalse,
    kwFor,
    kwIf,
    kwImport,
    kwIn,
    kwInterface,
    kwIntrinsic,
    kwInvariant,
    kwMatch,
    kwModule,
    kwMutable,
    kwNative,
    kwPrivate,
    kwReturn,
    kwTrue,
    kwType,
    kwVal,
    kwWhile,
    kwWith,
    underscore,

    leftParen,
    rightParen,
    leftBracket,
    rightBracket,
    leftBrace,
    rightBrace,
    comma,
    dot,
    dotDot,
    colon,
    question,
    questionDot,
    questionQuestion,
    bang,
    bangEqual,
    assign,
    equalEqual,
    fatArrow,
    thinArrow,
    less,
    lessEqual,
    lessLess,
    /// Always a single `>`, so `List<List<Int>>` closes twice; the parser reads `>=`, `>>` and
    /// `>>=` from adjacent tokens.
    greater,
    plus,
    plusPercent,
    minus,
    minusPercent,
    star,
    starPercent,
    slash,
    percent,
    caret,
    tilde,
    amp,
    ampAmp,
    pipe,
    pipePipe,

    plusAssign,
    minusAssign,
    starAssign,
    slashAssign,
    caretAssign,
    tildeAssign,
    plusPercentAssign,
    minusPercentAssign,
    starPercentAssign,
    ampAssign,
    pipeAssign,
    lessLessAssign,
}

struct Token
{
    TokenKind kind;
    /// Byte offsets into the source.
    uint start;
    uint end;
}

struct LexError
{
    uint start;
    uint end;
    string message;
}

struct Lexed
{
    Token[] tokens;
    /// One for each `error` token, in order.
    LexError[] errors;
}

bool isKeyword(TokenKind kind) => kind >= TokenKind.kwAlias && kind <= TokenKind.underscore;

/// The reserved words. `conform`, `forward`, `library`, `test` and `when` aren't among them: they
/// only mean something where an identifier can't go, so they lex as identifiers.
TokenKind keywordKind(const(char)[] word)
{
    switch (word)
    {
    case "alias": return TokenKind.kwAlias;
    case "break": return TokenKind.kwBreak;
    case "continue": return TokenKind.kwContinue;
    case "def": return TokenKind.kwDef;
    case "else": return TokenKind.kwElse;
    case "fail": return TokenKind.kwFail;
    case "false": return TokenKind.kwFalse;
    case "for": return TokenKind.kwFor;
    case "if": return TokenKind.kwIf;
    case "import": return TokenKind.kwImport;
    case "in": return TokenKind.kwIn;
    case "interface": return TokenKind.kwInterface;
    case "intrinsic": return TokenKind.kwIntrinsic;
    case "invariant": return TokenKind.kwInvariant;
    case "match": return TokenKind.kwMatch;
    case "module": return TokenKind.kwModule;
    case "mutable": return TokenKind.kwMutable;
    case "native": return TokenKind.kwNative;
    case "private": return TokenKind.kwPrivate;
    case "return": return TokenKind.kwReturn;
    case "true": return TokenKind.kwTrue;
    case "type": return TokenKind.kwType;
    case "val": return TokenKind.kwVal;
    case "while": return TokenKind.kwWhile;
    case "with": return TokenKind.kwWith;
    case "_": return TokenKind.underscore;
    default: return TokenKind.identifier;
    }
}

/// Whether a statement can end with a token of this kind.
bool canEnd(TokenKind kind)
{
    switch (kind)
    {
    case TokenKind.identifier, TokenKind.typeName, TokenKind.integer, TokenKind.hexInteger,
        TokenKind.binaryInteger, TokenKind.float_, TokenKind.char_, TokenKind.stringEnd,
        TokenKind.rightParen, TokenKind.rightBracket, TokenKind.rightBrace,
        TokenKind.question, TokenKind.bang, TokenKind.greater,
        TokenKind.kwReturn, TokenKind.kwBreak, TokenKind.kwContinue, TokenKind.kwTrue, TokenKind.kwFalse,
        TokenKind.underscore, TokenKind.error:
        return true;
    default:
        return false;
    }
}

/// Whether a statement can begin with a token of this kind.
bool canBegin(TokenKind kind)
{
    switch (kind)
    {
    case TokenKind.identifier, TokenKind.typeName, TokenKind.integer, TokenKind.hexInteger,
        TokenKind.binaryInteger, TokenKind.float_, TokenKind.char_, TokenKind.stringStart,
        TokenKind.leftParen, TokenKind.leftBracket, TokenKind.leftBrace,
        TokenKind.minus, TokenKind.bang, TokenKind.tilde,
        TokenKind.kwVal, TokenKind.kwMutable, TokenKind.kwDef, TokenKind.kwType, TokenKind.kwNative,
        TokenKind.kwIntrinsic, TokenKind.kwPrivate, TokenKind.kwWhile, TokenKind.kwFor, TokenKind.kwIf,
        TokenKind.kwReturn, TokenKind.kwFail, TokenKind.kwBreak, TokenKind.kwContinue, TokenKind.kwTrue, TokenKind.kwFalse,
        TokenKind.kwImport, TokenKind.kwModule, TokenKind.kwMatch, TokenKind.kwAlias, TokenKind.kwInterface,
        TokenKind.underscore, TokenKind.error:
        return true;
    default:
        return false;
    }
}

/// The newline rule: line breaks between two tokens separate statements only when the first can
/// end one and the second can begin one. Anywhere else they're whitespace.
bool separates(TokenKind before, TokenKind after) => canEnd(before) && canBegin(after);

/// Splits `source` into tokens, ending with an `end` token. Spaces, tabs and comments are
/// dropped, and line breaks become a `newline` token where `separates` says so.
Lexed lex(string source)
{
    auto lexer = Lexer(source);
    lexer.run();
    return Lexed(lexer.tokens, lexer.errors);
}

private struct Lexer
{
    string source;
    size_t i;
    Token[] tokens;
    LexError[] errors;
    /// The brace depth inside each string hole that's open, innermost last.
    int[] holes;
    /// Between a string's quotes, outside any hole.
    bool inString;
    /// Where the first line break since the last token was, if there was one.
    bool sawNewline;
    size_t newlineAt;

    void run()
    {
        // A shebang line, so a script can be run as `./script.ag`.
        if (source.length >= 2 && source[0] == '#' && source[1] == '!')
        {
            while (i < source.length && source[i] != '\n' && source[i] != '\r') i++;
        }
        while (true)
        {
            if (inString)
            {
                lexStringPart();
                continue;
            }
            skipSpace();
            if (i >= source.length)
            {
                if (inString || holes.length > 0) error(i, i, "A string ends on the line it starts");
                emit(TokenKind.end, i, i);
                return;
            }
            lexToken();
        }
    }

    char peek(size_t ahead = 0) => i + ahead < source.length ? source[i + ahead] : '\0';

    void emit(TokenKind kind, size_t start, size_t end)
    {
        if (sawNewline)
        {
            sawNewline = false;
            if (tokens.length > 0 && separates(tokens[$ - 1].kind, kind))
            {
                tokens ~= Token(TokenKind.newline, cast(uint) newlineAt, cast(uint) newlineAt + 1);
            }
        }
        tokens ~= Token(kind, cast(uint) start, cast(uint) end);
    }

    void error(size_t start, size_t end, string message)
    {
        emit(TokenKind.error, start, end);
        errors ~= LexError(cast(uint) start, cast(uint) end, message);
    }

    /// Spaces, tabs, comments and line breaks. A line break inside a block comment doesn't count.
    void skipSpace()
    {
        while (i < source.length)
        {
            auto c = source[i];
            if (c == ' ' || c == '\t')
            {
                i++;
            }
            else if (c == '\n' || c == '\r')
            {
                if (holes.length > 0)
                {
                    // Taken as an error token, so the hole and its string are reported.
                    return;
                }
                if (!sawNewline)
                {
                    sawNewline = true;
                    newlineAt = i;
                }
                i++;
            }
            else if (c == '/' && peek(1) == '/')
            {
                while (i < source.length && source[i] != '\n' && source[i] != '\r') i++;
            }
            else if (c == '/' && peek(1) == '*')
            {
                skipBlockComment();
            }
            else
            {
                return;
            }
        }
    }

    void skipBlockComment()
    {
        auto start = i;
        size_t depth = 0;
        while (i < source.length)
        {
            if (source[i] == '/' && peek(1) == '*')
            {
                depth++;
                i += 2;
            }
            else if (source[i] == '*' && peek(1) == '/')
            {
                i += 2;
                if (--depth == 0) return;
            }
            else
            {
                i++;
            }
        }
        error(start, i, "A block comment needs a closing `*/`");
    }

    void lexToken()
    {
        auto start = i;
        auto c = source[i];

        if (isLower(c) || c == '_')
        {
            while (i < source.length && isIdentChar(source[i])) i++;
            emit(keywordKind(source[start .. i]), start, i);
            return;
        }
        if (isUpper(c))
        {
            while (i < source.length && isIdentChar(source[i])) i++;
            emit(TokenKind.typeName, start, i);
            return;
        }
        if (isDigit(c))
        {
            lexNumber();
            return;
        }

        switch (c)
        {
        case '\n', '\r':
            // Only reached inside a string hole.
            i++;
            error(start, i, "A string ends on the line it starts");
            holes = null;
            return;
        case '"':
            i++;
            emit(TokenKind.stringStart, start, i);
            inString = true;
            return;
        case '\'':
            lexChar();
            return;
        case '{':
            if (holes.length > 0) holes[$ - 1]++;
            return single(TokenKind.leftBrace);
        case '}':
            if (holes.length > 0)
            {
                if (holes[$ - 1] == 0)
                {
                    holes = holes[0 .. $ - 1];
                    i++;
                    emit(TokenKind.holeEnd, start, i);
                    inString = true;
                    return;
                }
                holes[$ - 1]--;
            }
            return single(TokenKind.rightBrace);
        case '(': return single(TokenKind.leftParen);
        case ')': return single(TokenKind.rightParen);
        case '[': return single(TokenKind.leftBracket);
        case ']': return single(TokenKind.rightBracket);
        case ',': return single(TokenKind.comma);
        case ';': return single(TokenKind.semicolon);
        case ':': return single(TokenKind.colon);
        case '>': return single(TokenKind.greater);
        case '.':
            return peek(1) == '.' ? pair(TokenKind.dotDot) : single(TokenKind.dot);
        case '?':
            if (peek(1) == '?') return pair(TokenKind.questionQuestion);
            // `a?..b` is `a?` and then a range.
            if (peek(1) == '.' && peek(2) != '.') return pair(TokenKind.questionDot);
            return single(TokenKind.question);
        case '!':
            return peek(1) == '=' ? pair(TokenKind.bangEqual) : single(TokenKind.bang);
        case '=':
            if (peek(1) == '=') return pair(TokenKind.equalEqual);
            if (peek(1) == '>') return pair(TokenKind.fatArrow);
            return single(TokenKind.assign);
        case '<':
            if (peek(1) == '<') return peek(2) == '=' ? triple(TokenKind.lessLessAssign) : pair(TokenKind.lessLess);
            return peek(1) == '=' ? pair(TokenKind.lessEqual) : single(TokenKind.less);
        case '-':
            if (peek(1) == '>') return pair(TokenKind.thinArrow);
            if (peek(1) == '%') return peek(2) == '=' ? triple(TokenKind.minusPercentAssign) : pair(TokenKind.minusPercent);
            return peek(1) == '=' ? pair(TokenKind.minusAssign) : single(TokenKind.minus);
        case '+':
            if (peek(1) == '%') return peek(2) == '=' ? triple(TokenKind.plusPercentAssign) : pair(TokenKind.plusPercent);
            return peek(1) == '=' ? pair(TokenKind.plusAssign) : single(TokenKind.plus);
        case '*':
            if (peek(1) == '%') return peek(2) == '=' ? triple(TokenKind.starPercentAssign) : pair(TokenKind.starPercent);
            return peek(1) == '=' ? pair(TokenKind.starAssign) : single(TokenKind.star);
        case '/':
            return peek(1) == '=' ? pair(TokenKind.slashAssign) : single(TokenKind.slash);
        case '%': return single(TokenKind.percent);
        case '^':
            return peek(1) == '=' ? pair(TokenKind.caretAssign) : single(TokenKind.caret);
        case '~':
            return peek(1) == '=' ? pair(TokenKind.tildeAssign) : single(TokenKind.tilde);
        case '&':
            if (peek(1) == '&') return pair(TokenKind.ampAmp);
            return peek(1) == '=' ? pair(TokenKind.ampAssign) : single(TokenKind.amp);
        case '|':
            if (peek(1) == '|') return pair(TokenKind.pipePipe);
            return peek(1) == '=' ? pair(TokenKind.pipeAssign) : single(TokenKind.pipe);
        default:
            i = nextCharacter(i);
            error(start, i, "`" ~ source[start .. i] ~ "` can't appear here");
        }
    }

    void single(TokenKind kind) => length(kind, 1);
    void pair(TokenKind kind) => length(kind, 2);
    void triple(TokenKind kind) => length(kind, 3);

    void length(TokenKind kind, size_t n)
    {
        auto start = i;
        i += n;
        emit(kind, start, i);
    }

    /// The offset after the UTF-8 sequence that starts at `at`.
    size_t nextCharacter(size_t at)
    {
        auto next = at + 1;
        while (next < source.length && (source[next] & 0xC0) == 0x80) next++;
        return next;
    }

    void lexNumber()
    {
        auto start = i;
        if (source[i] == '0' && peek(1) == 'x' && isHexDigit(peek(2)))
        {
            i += 2;
            while (i < source.length && isHexDigit(source[i])) i++;
            emit(TokenKind.hexInteger, start, i);
            return;
        }
        if (source[i] == '0' && peek(1) == 'b' && (peek(2) == '0' || peek(2) == '1'))
        {
            i += 2;
            while (i < source.length && (source[i] == '0' || source[i] == '1' || source[i] == '_')) i++;
            emit(TokenKind.binaryInteger, start, i);
            return;
        }
        auto kind = TokenKind.integer;
        while (i < source.length && isDigit(source[i])) i++;
        if (peek() == '.' && isDigit(peek(1)))
        {
            kind = TokenKind.float_;
            i++;
            while (i < source.length && isDigit(source[i])) i++;
        }
        if (peek() == 'e' || peek() == 'E')
        {
            auto sign = peek(1) == '+' || peek(1) == '-' ? 1 : 0;
            if (isDigit(peek(1 + sign)))
            {
                kind = TokenKind.float_;
                i += 1 + sign;
                while (i < source.length && isDigit(source[i])) i++;
            }
        }
        emit(kind, start, i);
    }

    /// From a string's opening quote, or the end of a hole, to its closing quote or the next hole.
    void lexStringPart()
    {
        auto start = i;
        if (i >= source.length || source[i] == '\n' || source[i] == '\r')
        {
            inString = false;
            holes = null;
            error(start, start, "A string ends on the line it starts; this one has no closing `\"`");
            return;
        }
        switch (source[i])
        {
        case '"':
            i++;
            inString = false;
            emit(TokenKind.stringEnd, start, i);
            return;
        case '{':
            i++;
            inString = false;
            holes ~= 0;
            emit(TokenKind.holeStart, start, i);
            return;
        case '\\':
            if (!skipEscape(true))
            {
                inString = false;
                holes = null;
                error(start, i, "`" ~ source[start .. i] ~ "` isn't an escape; write `\\\\` for a backslash");
                skipToLineEnd();
                return;
            }
            emit(TokenKind.stringEscape, start, i);
            return;
        default:
            while (i < source.length && source[i] != '"' && source[i] != '\\' && source[i] != '{'
                && source[i] != '\n' && source[i] != '\r')
            {
                i++;
            }
            emit(TokenKind.stringText, start, i);
        }
    }

    void skipToLineEnd()
    {
        while (i < source.length && source[i] != '\n' && source[i] != '\r') i++;
    }

    /// Moves past the escape at `i`, if it's one. Only a string's can be `\{` or `\}`, and only a
    /// character's `\'`.
    bool skipEscape(bool inStringLiteral)
    {
        auto c = peek(1);
        if (c == '\\' || c == 'n' || c == 'r' || c == 't' || c == '0'
            || (inStringLiteral ? (c == '"' || c == '{' || c == '}') : c == '\''))
        {
            i += 2;
            return true;
        }
        if (c == 'u' && peek(2) == '{')
        {
            size_t digits = 0;
            while (isHexDigit(peek(3 + digits)) && digits < 6) digits++;
            if (digits > 0 && peek(3 + digits) == '}')
            {
                i += 4 + digits;
                return true;
            }
        }
        i = nextCharacter(i + 1 < source.length ? i + 1 : i);
        return false;
    }

    void lexChar()
    {
        auto start = i;
        i++;
        while (i < source.length && source[i] != '\'' && source[i] != '\n' && source[i] != '\r')
        {
            if (source[i] == '\\')
            {
                auto escapeStart = i;
                if (!skipEscape(false))
                {
                    error(start, i, "`" ~ source[escapeStart .. i] ~ "` isn't an escape; write `\\\\` for a backslash");
                    skipToLineEnd();
                    return;
                }
                continue;
            }
            i++;
        }
        if (peek() != '\'')
        {
            error(start, i, "A character literal needs a closing `'`");
            return;
        }
        i++;
        emit(TokenKind.char_, start, i);
    }
}

bool isLower(char c) => c >= 'a' && c <= 'z';
bool isUpper(char c) => c >= 'A' && c <= 'Z';
bool isDigit(char c) => c >= '0' && c <= '9';
bool isHexDigit(char c) => isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
bool isIdentChar(char c) => isLower(c) || isUpper(c) || isDigit(c) || c == '_';

version (unittest)
{
    private TokenKind[] kinds(string source)
    {
        TokenKind[] result;
        foreach (token; lex(source).tokens) result ~= token.kind;
        return result;
    }

    /// Whether lexing `source` gives a newline token, for sources of two lines.
    private bool separated(string source)
    {
        foreach (token; lex(source).tokens)
        {
            if (token.kind == TokenKind.newline) return true;
        }
        return false;
    }
}

@("a line break separates only where the token before can end a statement and the one after can begin one")
unittest
{
    // Both can end and begin a statement.
    assert(separated("a\nb"));
    assert(separated("a = b\n- 1"));
    assert(separated("a = b\n!c"));
    assert(separated("a = b\n~c"));
    assert(separated("a = b\n(c)"));
    assert(separated("a = b\n[c]"));
    assert(separated("return\na"));
    assert(separated("val w = Box<Int>\n(1)"));
    assert(separated("if a\n{ 1 }"));
    assert(separated("def f\n(): Int => 1"));
    assert(separated("def f(): A\n! E"));

    // The token before can't end one.
    assert(!separated("a = 1 +\n    2"));
    assert(!separated("a =\n    1"));
    assert(!separated("mutable\nval\na = 1"));
    assert(!separated("a = b.\n    c"));
    assert(!separated("val f: (Int) ->\n    Int = g"));
    assert(!separated("for\n    x in xs { 1 }"));
    assert(!separated("a = [\n    1]"));

    // The token after can't begin one.
    assert(!separated("a = b\n    .c"));
    assert(!separated("a = b\n    ?.c"));
    assert(!separated("a = b\n    ?"));
    assert(!separated("a = b\n    ?? c"));
    assert(!separated("a = b\n    && c"));
    assert(!separated("a = 1\n    + 2"));
    assert(!separated("a = 1\n    == 2"));
    assert(!separated("a = 1\n    << 2"));
    assert(!separated("a = 1\n    | 2"));
    assert(!separated("a = xs[1\n    .. 2]"));
    assert(!separated("a\n    = 1"));
    assert(!separated("a\n    ~= b"));
    assert(!separated("val a\n    : Int = 1"));
    assert(!separated("val f: (Int)\n    -> Int = g"));
    assert(!separated("if a { 1 }\nelse { 2 }"));
    assert(!separated("f(\n    1\n)"));

    // Comments between the lines don't change it, and a line break in a block comment isn't one.
    assert(!separated("a = b ||\n\n    // why\n    c"));
    assert(separated("a = 1\n// between\nb = 2"));
    assert(!separated("a = 1 /*\n*/ b = 2"));
}

@("a first line starting with #! is skipped, and #! anywhere else is an error")
unittest
{
    with (TokenKind)
    {
        assert(kinds("#!/usr/bin/env silver\na") == [identifier, end]);
        assert(kinds("#!/usr/bin/env silver\r\na\nb") == [identifier, newline, identifier, end]);
        assert(kinds("#!/usr/bin/env silver") == [end]);
        assert(lex("a\n#!/usr/bin/env silver").errors.length > 0);
        assert(lex(" #!/usr/bin/env silver\na").errors.length > 0);
    }
}

@("operators lex by the longest match, except that `>` is always one token")
unittest
{
    with (TokenKind)
    {
        assert(kinds("a >>= b") == [identifier, greater, greater, assign, identifier, end]);
        assert(kinds("List<List<Int>>") == [typeName, less, typeName, less, typeName, greater, greater, end]);
        assert(kinds("a <<= b <= c") == [identifier, lessLessAssign, identifier, lessEqual, identifier, end]);
        assert(kinds("a?.b?..c??d") == [identifier, questionDot, identifier, question, dotDot, identifier,
            questionQuestion, identifier, end]);
        assert(kinds("b!=c!") == [identifier, bangEqual, identifier, bang, end]);
        assert(kinds("a -%= b -% c -> d") == [identifier, minusPercentAssign, identifier, minusPercent, identifier,
            thinArrow, identifier, end]);
        assert(kinds("x => y == z") == [identifier, fatArrow, identifier, equalEqual, identifier, end]);
    }
}

@("keywords are reserved, and contextual words are identifiers")
unittest
{
    with (TokenKind)
    {
        assert(kinds("val interface in _ _a") == [kwVal, kwInterface, kwIn, underscore, identifier, end]);
        assert(kinds("conform test when forward library") == [identifier, identifier, identifier, identifier, identifier, end]);
        assert(kinds("value Int") == [identifier, typeName, end]);
    }
}

@("numbers lex as integers, radix integers and floats")
unittest
{
    with (TokenKind)
    {
        assert(kinds("1 0x1F 0b1_0 1.5 1e5 1.5E-3") == [integer, hexInteger, binaryInteger, float_, float_, float_, end]);
        assert(kinds("1..2") == [integer, dotDot, integer, end]);
        assert(kinds("1.b") == [integer, dot, identifier, end]);
        assert(kinds("1else") == [integer, kwElse, end]);
    }
}

@("a string's holes hold tokens, and strings nest in them")
unittest
{
    with (TokenKind)
    {
        assert(kinds(`"a{x}b{"c{y}"}"`) == [stringStart, stringText, holeStart, identifier, holeEnd, stringText,
            holeStart, stringStart, stringText, holeStart, identifier, holeEnd, stringEnd, holeEnd, stringEnd, end]);
        assert(kinds(`"{ {a} }"`) == [stringStart, holeStart, leftBrace, identifier, rightBrace, holeEnd, stringEnd, end]);
        assert(kinds(`"a\n\{\u{1F600}"`) == [stringStart, stringText, stringEscape, stringEscape, stringEscape, stringEnd, end]);
    }
}

@("lexing reports unterminated strings and comments, unknown escapes and stray characters")
unittest
{
    assert(lex("\"abc\nd").errors.length == 1);
    assert(lex("\"a{b\nc}\"").errors.length >= 1);
    assert(lex(`"\q"`).errors.length == 1);
    assert(lex(`'\{'`).errors.length == 1);
    assert(lex("a /* b").errors.length == 1);
    assert(lex("a @ b").errors.length == 1);
    assert(lex("'ab'").errors.length == 0);
}
