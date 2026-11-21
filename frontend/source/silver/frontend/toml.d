/// Reads the TOML a package file is written in into a tree that keeps where each key and value
/// is, so that a message about one can point at it. It reads what a package file needs: comments,
/// bare, quoted and dotted keys, basic and literal strings, integers, booleans, arrays, inline
/// tables, `[table]` and `[[array of tables]]`. Floats, dates, times and multi-line strings are a
/// located "not supported" mistake.
///
/// Written like the compiler's lexer and parser, so it can move to Silver with them: a token
/// array and an index, and nothing throws. It stops at the first mistake.
module silver.frontend.toml;

/// Where something is: byte offsets into the text, and the line and column of its start, both
/// counted from 1, the column in bytes as the compiler counts it.
struct Span
{
    uint start;
    uint end;
    uint line;
    uint column;
}

enum ValueKind : ubyte
{
    string_,
    integer,
    boolean,
    array,
    table,
}

struct Value
{
    ValueKind kind;
    Span span;
    string text;
    long integer;
    bool boolean;
    Value[] items;
    Table table;
    /// An array made by `[[name]]` headers, which a later one can add to.
    bool ofTables;
}

struct Entry
{
    string key;
    Span keySpan;
    Value value;
}

/// How a table came to be, which decides what may add to it later.
enum Origin : ubyte
{
    /// `[name]`, each table of `[[name]]`, and the top-level table.
    header,
    /// Named on the way to a header's table, as `a` is by `[a.b]`, and given no header of its own yet.
    implied,
    /// Made by a dotted key, as `a` is by `a.b = 1`.
    dotted,
    /// Written `{ ... }`, and closed where it ends.
    inline,
}

/// A table's entries, in the order the text gives them.
final class Table
{
    Entry[] entries;
    Origin origin;

    this(Origin origin) nothrow
    {
        this.origin = origin;
    }

    inout(Entry)* entry(string key) inout nothrow
    {
        foreach (ref e; entries)
        {
            if (e.key == key) return &e;
        }
        return null;
    }

    inout(Value)* get(string key) inout nothrow
    {
        auto e = entry(key);
        return e is null ? null : &e.value;
    }
}

/// A stable ID for each kind of mistake in a package file. The value is what users see.
enum TomlCode : string
{
    NotUtf8 = "F0001",
    /// A character that can't be where it is: a control character, a carriage return with no line
    /// feed, or one that starts no token.
    BadCharacter = "F0002",
    UnterminatedString = "F0003",
    BadEscape = "F0004",
    Unexpected = "F0005",
    BadKey = "F0006",
    /// A bare word where a value should be that isn't one, as `name = geometry`.
    BadValue = "F0007",
    BadInteger = "F0008",
    /// Valid TOML that a package file doesn't need: floats, dates, times and multi-line strings.
    Unsupported = "F0009",
    DuplicateKey = "F0010",
    DuplicateTable = "F0011",
    /// `[[name]]` where `name` is already something other than an array of tables.
    NotAnArrayOfTables = "F0012",
    /// A dotted key or a header that goes through something it can't add keys to.
    NotATable = "F0013",
    NestedTooDeeply = "F0014",
}

struct TomlError
{
    TomlCode code;
    Span span;
    string message;
}

struct TomlDocument
{
    /// The top-level table, or null when the text has a mistake.
    Table root;
    bool failed;
    /// The first mistake, when `failed`.
    TomlError error;
}

TomlDocument readToml(string text) nothrow
{
    auto lexer = Lexer(text);
    lexer.run();
    auto parser = Parser(lexer.tokens, lexer.error);
    if (!parser.document()) return TomlDocument(null, true, parser.error);
    return TomlDocument(parser.root);
}

/// `error` in the shape the compiler gives its diagnostics: `file(line,column): Error code: message`.
string formatTomlError(string file, const TomlError error) nothrow
{
    return file ~ "(" ~ decimal(error.span.line) ~ "," ~ decimal(error.span.column) ~ "): Error "
        ~ cast(string) error.code ~ ": " ~ error.message;
}

private:

enum maxDepth = 100;

enum Tok : ubyte
{
    end,
    newline,
    /// A run of the characters a bare key, an integer, a boolean or a date can hold.
    word,
    basicString,
    literalString,
    equals,
    dot,
    comma,
    leftBracket,
    rightBracket,
    leftBrace,
    rightBrace,
    /// Lexing stopped here; the lexer's `error` says why. Always the last token.
    error,
}

struct Token
{
    Tok kind;
    Span span;
    /// A string's value with its escapes read, or a word's characters.
    string text;
}

struct Lexer
{
nothrow:
    string source;
    size_t i;
    size_t line = 1;
    size_t lineStart;
    Token[] tokens;
    TomlError error;

    void run()
    {
        // A byte order mark, which some Windows editors write.
        if (source.length >= 3 && source[0] == 0xEF && source[1] == 0xBB && source[2] == 0xBF) i = lineStart = 3;
        while (true)
        {
            while (peek == ' ' || peek == '\t') i++;
            if (i >= source.length)
            {
                emit(Tok.end, i, i);
                return;
            }
            bool ok = true;
            switch (source[i])
            {
                case '#':
                    ok = comment();
                    break;
                case '\n':
                    emit(Tok.newline, i, i + 1);
                    i++;
                    newLine();
                    break;
                case '\r':
                    if (peek(1) != '\n')
                    {
                        ok = fail(TomlCode.BadCharacter, i, i + 1, "A carriage return has to be followed by a line feed");
                        break;
                    }
                    emit(Tok.newline, i, i + 2);
                    i += 2;
                    newLine();
                    break;
                case '"':
                    ok = basicString();
                    break;
                case '\'':
                    ok = literalString();
                    break;
                case '=': single(Tok.equals); break;
                case '.': single(Tok.dot); break;
                case ',': single(Tok.comma); break;
                case '[': single(Tok.leftBracket); break;
                case ']': single(Tok.rightBracket); break;
                case '{': single(Tok.leftBrace); break;
                case '}': single(Tok.rightBrace); break;
                default:
                    if (isWordChar(source[i])) word();
                    else ok = badCharacter();
            }
            if (!ok) return;
        }
    }

    char peek(size_t ahead = 0) const => i + ahead < source.length ? source[i + ahead] : '\0';

    void newLine()
    {
        line++;
        lineStart = i;
    }

    Span span(size_t start, size_t end) const
        => Span(cast(uint) start, cast(uint) end, cast(uint) line, cast(uint)(start - lineStart + 1));

    void emit(Tok kind, size_t start, size_t end, string text = null)
    {
        tokens ~= Token(kind, span(start, end), text);
    }

    void single(Tok kind)
    {
        emit(kind, i, i + 1);
        i++;
    }

    bool fail(TomlCode code, size_t start, size_t end, string message)
    {
        error = TomlError(code, span(start, end), message);
        emit(Tok.error, start, end);
        return false;
    }

    bool notUtf8() => fail(TomlCode.NotUtf8, i, i + 1, "The file isn't valid UTF-8 here");

    bool badCharacter()
    {
        immutable c = source[i];
        if (c >= 0x80)
        {
            immutable n = utf8Length(source, i);
            if (n == 0) return notUtf8();
            return fail(TomlCode.BadCharacter, i, i + n,
                "`" ~ source[i .. i + n] ~ "` can't be here; only a string or a comment can hold it");
        }
        if (!printable(c))
        {
            return fail(TomlCode.BadCharacter, i, i + 1, "A control character (" ~ hexByte(c) ~ ") can't be here");
        }
        return fail(TomlCode.BadCharacter, i, i + 1, "`" ~ c ~ "` can't be here");
    }

    /// Up to the end of the line, which a comment leaves for the next token.
    bool comment()
    {
        i++;
        while (i < source.length && source[i] != '\n' && source[i] != '\r')
        {
            immutable c = source[i];
            if (c >= 0x80)
            {
                immutable n = utf8Length(source, i);
                if (n == 0) return notUtf8();
                i += n;
            }
            else if (!printable(c))
            {
                return fail(TomlCode.BadCharacter, i, i + 1, "A comment can't hold a control character (" ~ hexByte(c) ~ ")");
            }
            else
            {
                i++;
            }
        }
        return true;
    }

    void word()
    {
        immutable start = i;
        while (i < source.length && isWordChar(source[i])) i++;
        emit(Tok.word, start, i, source[start .. i]);
    }

    bool basicString() => quoted('"', Tok.basicString);

    bool literalString() => quoted('\'', Tok.literalString);

    bool quoted(char quote, Tok kind)
    {
        immutable start = i;
        if (peek(1) == quote && peek(2) == quote)
        {
            return fail(TomlCode.Unsupported, i, i + 3, "A multi-line string isn't supported in a package file");
        }
        i++;
        string text;
        while (true)
        {
            if (peek == '\r' && peek(1) != '\n')
            {
                return fail(TomlCode.BadCharacter, i, i + 1, "A carriage return has to be followed by a line feed");
            }
            if (i >= source.length || source[i] == '\n' || source[i] == '\r')
            {
                return fail(TomlCode.UnterminatedString, start, i,
                    "A string has to end on the line it starts, with `" ~ quote ~ "`");
            }
            immutable c = source[i];
            if (c == quote)
            {
                i++;
                emit(kind, start, i, text);
                return true;
            }
            if (c == '\\' && kind == Tok.basicString)
            {
                if (!escape(text)) return false;
            }
            else if (c >= 0x80)
            {
                immutable n = utf8Length(source, i);
                if (n == 0) return notUtf8();
                text ~= source[i .. i + n];
                i += n;
            }
            else if (!printable(c))
            {
                return fail(TomlCode.BadCharacter, i, i + 1, "A string can't hold a control character (" ~ hexByte(c) ~ ")");
            }
            else
            {
                text ~= c;
                i++;
            }
        }
    }

    bool escape(ref string text)
    {
        immutable e = peek(1);
        char plain;
        switch (e)
        {
            case 'b': plain = '\b'; break;
            case 't': plain = '\t'; break;
            case 'n': plain = '\n'; break;
            case 'f': plain = '\f'; break;
            case 'r': plain = '\r'; break;
            case '"': plain = '"'; break;
            case '\\': plain = '\\'; break;
            case 'u': return unicode(text, 4);
            case 'U': return unicode(text, 8);
            default:
                enum escapes = "a string can use \\b, \\t, \\n, \\f, \\r, \\\", \\\\, \\uXXXX and \\UXXXXXXXX";
                if (e > ' ' && e < 0x7F) return fail(TomlCode.BadEscape, i, i + 2, "`\\" ~ e ~ "` isn't an escape; " ~ escapes);
                return fail(TomlCode.BadEscape, i, i + 1, "A `\\` has to start an escape; " ~ escapes);
        }
        text ~= plain;
        i += 2;
        return true;
    }

    bool unicode(ref string text, size_t digits)
    {
        immutable start = i;
        i += 2;
        uint value = 0;
        foreach (_; 0 .. digits)
        {
            immutable d = hexValue(peek);
            if (d < 0)
            {
                return fail(TomlCode.BadEscape, start, i, digits == 4
                    ? "`\\u` has to be followed by four hexadecimal digits"
                    : "`\\U` has to be followed by eight hexadecimal digits");
            }
            value = value * 16 + d;
            i++;
        }
        if ((value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF)
        {
            return fail(TomlCode.BadEscape, start, i, "`" ~ source[start .. i] ~ "` isn't a Unicode character");
        }
        appendUtf8(text, value);
        return true;
    }
}

struct Segment
{
    string name;
    Span span;
}

struct Parser
{
nothrow:
    Token[] tokens;
    /// What's wrong at the `error` token, when the lexer stopped at one.
    TomlError lexError;
    size_t index;
    bool failed;
    TomlError error;
    Table root;
    /// The table key/value lines go into: the top-level one, then the last header's.
    Table current;
    /// How many arrays and inline tables are open.
    size_t depth;

    ref const(Token) token() const return => tokens[index];

    void advance()
    {
        if (index + 1 < tokens.length) index++;
    }

    bool fail(TomlCode code, Span span, string message)
    {
        if (!failed)
        {
            failed = true;
            error = TomlError(code, span, message);
        }
        return false;
    }

    /// The mistake for finding the current token where `what` should be, or the lexer's, when it
    /// stopped there.
    bool expected(string what)
    {
        if (token.kind == Tok.error) return fail(lexError.code, lexError.span, lexError.message);
        return fail(TomlCode.Unexpected, token.span, "expected " ~ what ~ ", but got " ~ describe(token));
    }

    bool document()
    {
        root = new Table(Origin.header);
        current = root;
        while (true)
        {
            switch (token.kind)
            {
                case Tok.end:
                    return true;
                case Tok.newline:
                    advance();
                    continue;
                case Tok.leftBracket:
                    if (!header()) return false;
                    break;
                case Tok.word, Tok.basicString, Tok.literalString:
                    if (!keyValue(current)) return false;
                    break;
                default:
                    return expected("a key or a table header");
            }
            if (token.kind == Tok.newline) advance();
            else if (token.kind != Tok.end) return expected("a new line");
        }
    }

    bool key(ref Segment[] path)
    {
        while (true)
        {
            auto t = token;
            if (t.kind == Tok.word)
            {
                foreach (c; t.text)
                {
                    if (!isBareKeyChar(c))
                    {
                        return fail(TomlCode.BadKey, t.span, "`" ~ t.text ~ "` isn't a bare key, which holds only letters, "
                            ~ "digits, `_` and `-`; a key with other characters is quoted, as \"" ~ t.text ~ "\"");
                    }
                }
            }
            else if (t.kind != Tok.basicString && t.kind != Tok.literalString)
            {
                return expected("a key");
            }
            path ~= Segment(t.text, t.span);
            advance();
            if (token.kind != Tok.dot) return true;
            advance();
        }
    }

    bool header()
    {
        immutable open = token.span;
        advance();
        immutable array = token.kind == Tok.leftBracket && token.span.start == open.end;
        if (array) advance();
        Segment[] path;
        if (!key(path)) return false;
        if (token.kind != Tok.rightBracket) return expected(array ? "`]]`" : "`]`");
        Span close = token.span;
        advance();
        if (array)
        {
            if (token.kind != Tok.rightBracket || token.span.start != close.end) return expected("`]]`");
            close = token.span;
            advance();
        }
        immutable whole = Span(open.start, close.end, open.line, open.column);
        return array ? defineArrayOfTables(path, whole) : defineTable(path, whole);
    }

    /// The table `path[k]` names in `table`, made when there's none. A header can go through an
    /// array of tables, to its last table; a dotted key only through tables dotted keys made.
    bool descend(Table table, const Segment[] path, size_t k, bool forHeader, ref Table next)
    {
        auto segment = path[k];
        auto found = table.entry(segment.name);
        if (found is null)
        {
            next = new Table(forHeader ? Origin.implied : Origin.dotted);
            table.entries ~= Entry(segment.name, segment.span, tableValue(segment.span, next));
            return true;
        }
        immutable name = "`" ~ pathName(path[0 .. k + 1]) ~ "`";
        immutable at = ", at line " ~ decimal(found.keySpan.line);
        auto value = &found.value;
        if (value.kind == ValueKind.table)
        {
            auto inner = value.table;
            if (inner.origin == Origin.inline)
            {
                return fail(TomlCode.NotATable, segment.span, name ~ " is an inline table" ~ at ~ ", which can't be added to");
            }
            if (!forHeader && inner.origin != Origin.dotted)
            {
                return fail(TomlCode.NotATable, segment.span, name ~ " is a table with a header" ~ at
                    ~ ", which a dotted key can't add to");
            }
            next = inner;
            return true;
        }
        if (forHeader && value.kind == ValueKind.array && value.ofTables)
        {
            next = value.items[$ - 1].table;
            return true;
        }
        return fail(TomlCode.NotATable, segment.span, name ~ " is already " ~ kindName(*value) ~ at ~ ", so it can't hold keys");
    }

    /// The table that holds the last of `path`, made as a header makes it.
    bool headerParent(const Segment[] path, ref Table table)
    {
        table = root;
        foreach (k; 0 .. path.length - 1)
        {
            Table next;
            if (!descend(table, path, k, true, next)) return false;
            table = next;
        }
        return true;
    }

    bool defineTable(const Segment[] path, Span span)
    {
        Table parent;
        if (!headerParent(path, parent)) return false;
        immutable last = path[$ - 1];
        auto found = parent.entry(last.name);
        if (found is null)
        {
            current = new Table(Origin.header);
            parent.entries ~= Entry(last.name, last.span, tableValue(span, current));
            return true;
        }
        if (found.value.kind == ValueKind.table && found.value.table.origin == Origin.implied)
        {
            current = found.value.table;
            current.origin = Origin.header;
            found.keySpan = last.span;
            found.value.span = span;
            return true;
        }
        immutable plainTable = found.value.kind == ValueKind.table;
        return fail(TomlCode.DuplicateTable, last.span, "`" ~ pathName(path) ~ "` is already defined, at line "
            ~ decimal(found.keySpan.line) ~ (plainTable ? "" : ", as " ~ kindName(found.value)));
    }

    bool defineArrayOfTables(const Segment[] path, Span span)
    {
        Table parent;
        if (!headerParent(path, parent)) return false;
        immutable last = path[$ - 1];
        auto found = parent.entry(last.name);
        auto table = new Table(Origin.header);
        if (found is null)
        {
            Value array;
            array.kind = ValueKind.array;
            array.span = span;
            array.ofTables = true;
            array.items = [tableValue(span, table)];
            parent.entries ~= Entry(last.name, last.span, array);
        }
        else if (found.value.kind == ValueKind.array && found.value.ofTables)
        {
            found.value.items ~= tableValue(span, table);
        }
        else
        {
            immutable name = pathName(path);
            return fail(TomlCode.NotAnArrayOfTables, last.span, "`" ~ name ~ "` is already defined, at line "
                ~ decimal(found.keySpan.line) ~ ", as " ~ kindName(found.value) ~ ", so `[[" ~ name ~ "]]` can't add to it");
        }
        current = table;
        return true;
    }

    bool keyValue(Table into)
    {
        Segment[] path;
        if (!key(path)) return false;
        auto target = into;
        foreach (k; 0 .. path.length - 1)
        {
            Table next;
            if (!descend(target, path, k, false, next)) return false;
            target = next;
        }
        immutable last = path[$ - 1];
        if (auto found = target.entry(last.name))
        {
            return fail(TomlCode.DuplicateKey, last.span, "`" ~ pathName(path) ~ "` is already defined, at line "
                ~ decimal(found.keySpan.line));
        }
        if (token.kind != Tok.equals) return expected("`=`");
        advance();
        Value v;
        if (!value(v)) return false;
        target.entries ~= Entry(last.name, last.span, v);
        return true;
    }

    bool value(ref Value v)
    {
        auto t = token;
        switch (t.kind)
        {
            case Tok.basicString, Tok.literalString:
                v.kind = ValueKind.string_;
                v.span = t.span;
                v.text = t.text;
                advance();
                return true;
            case Tok.word:
                return wordValue(v);
            case Tok.leftBracket:
                return nested(v, false);
            case Tok.leftBrace:
                return nested(v, true);
            default:
                return expected("a value");
        }
    }

    bool nested(ref Value v, bool table)
    {
        if (depth == maxDepth)
        {
            return fail(TomlCode.NestedTooDeeply, token.span, "Arrays and inline tables can be nested only "
                ~ decimal(maxDepth) ~ " deep");
        }
        depth++;
        immutable ok = table ? inlineTable(v) : array(v);
        depth--;
        return ok;
    }

    bool wordValue(ref Value v)
    {
        auto t = token;
        immutable w = t.text;
        if (w == "true" || w == "false")
        {
            v.kind = ValueKind.boolean;
            v.span = t.span;
            v.boolean = w == "true";
            advance();
            return true;
        }
        immutable numeric = isDigit(w[0]) || ((w[0] == '+' || w[0] == '-') && w.length > 1 && isDigit(w[1]));
        immutable fraction = index + 1 < tokens.length && tokens[index + 1].kind == Tok.dot
            && tokens[index + 1].span.start == t.span.end;
        if (isDateWord(w))
        {
            return fail(TomlCode.Unsupported, t.span, "A date or a time isn't supported in a package file");
        }
        if ((numeric && fraction) || isFloatWord(w))
        {
            string text;
            immutable run = adjacentRun(text);
            return fail(TomlCode.Unsupported, run, "A float isn't supported in a package file; "
                ~ "text such as a version is written in quotes, as \"" ~ text ~ "\"");
        }
        if (isDigit(w[0]) || w[0] == '+' || w[0] == '-')
        {
            long n;
            immutable problem = parseInteger(w, n);
            if (problem !is null) return fail(TomlCode.BadInteger, t.span, problem);
            v.kind = ValueKind.integer;
            v.span = t.span;
            v.integer = n;
            advance();
            return true;
        }
        return fail(TomlCode.BadValue, t.span,
            "`" ~ w ~ "` isn't a value; a string is written in quotes, as \"" ~ w ~ "\"");
    }

    /// The current token and those touching it, as `1.5e3` is three, and their text.
    Span adjacentRun(ref string text) const
    {
        Span run = token.span;
        text = token.text;
        for (auto k = index + 1; k < tokens.length; k++)
        {
            auto t = tokens[k];
            if ((t.kind != Tok.word && t.kind != Tok.dot) || t.span.start != run.end) break;
            run.end = t.span.end;
            text ~= t.kind == Tok.dot ? "." : t.text;
        }
        return run;
    }

    void skipNewlines()
    {
        while (token.kind == Tok.newline) advance();
    }

    bool array(ref Value v)
    {
        immutable open = token.span;
        advance();
        Value[] items;
        while (true)
        {
            skipNewlines();
            if (token.kind == Tok.rightBracket) break;
            if (token.kind == Tok.end) return unclosed("array", open, "]");
            Value item;
            if (!value(item)) return false;
            items ~= item;
            skipNewlines();
            if (token.kind == Tok.comma)
            {
                advance();
                continue;
            }
            if (token.kind == Tok.rightBracket) break;
            if (token.kind == Tok.end) return unclosed("array", open, "]");
            return expected("`,` or `]`");
        }
        v.kind = ValueKind.array;
        v.span = Span(open.start, token.span.end, open.line, open.column);
        v.items = items;
        advance();
        return true;
    }

    bool inlineTable(ref Value v)
    {
        immutable open = token.span;
        advance();
        auto table = new Table(Origin.inline);
        if (token.kind != Tok.rightBrace)
        {
            while (true)
            {
                if (token.kind == Tok.newline) return oneLine();
                if (token.kind == Tok.end) return unclosed("inline table", open, "}");
                if (!keyValue(table)) return false;
                if (token.kind == Tok.rightBrace) break;
                if (token.kind == Tok.newline) return oneLine();
                if (token.kind == Tok.end) return unclosed("inline table", open, "}");
                if (token.kind != Tok.comma) return expected("`,` or `}`");
                advance();
                if (token.kind == Tok.rightBrace)
                {
                    return fail(TomlCode.Unexpected, token.span, "An inline table can't have a `,` after its last key");
                }
            }
        }
        v.kind = ValueKind.table;
        v.span = Span(open.start, token.span.end, open.line, open.column);
        v.table = table;
        advance();
        return true;
    }

    /// Located at the end of the file, where reading stopped, naming the line the bracket opened on.
    bool unclosed(string what, Span open, string closer) => fail(TomlCode.Unexpected, token.span,
        "The " ~ what ~ " opened at line " ~ decimal(open.line) ~ " has no closing `" ~ closer ~ "`");

    bool oneLine() => fail(TomlCode.Unexpected, token.span, "An inline table has to be on one line; a table with "
        ~ "keys on several lines is written with a `[header]`");
}

Value tableValue(Span span, Table table) nothrow
{
    Value v;
    v.kind = ValueKind.table;
    v.span = span;
    v.table = table;
    return v;
}

string describe(const Token t) nothrow
{
    final switch (t.kind)
    {
        case Tok.end: return "the end of the file";
        case Tok.newline: return "a new line";
        case Tok.word: return "`" ~ t.text ~ "`";
        case Tok.basicString, Tok.literalString: return "a string";
        case Tok.equals: return "`=`";
        case Tok.dot: return "`.`";
        case Tok.comma: return "`,`";
        case Tok.leftBracket: return "`[`";
        case Tok.rightBracket: return "`]`";
        case Tok.leftBrace: return "`{`";
        case Tok.rightBrace: return "`}`";
        case Tok.error: return "a mistake";
    }
}

string kindName(const Value v) nothrow
{
    final switch (v.kind)
    {
        case ValueKind.string_: return "a string";
        case ValueKind.integer: return "an integer";
        case ValueKind.boolean: return "a boolean";
        case ValueKind.array: return v.ofTables ? "an array of tables" : "an array";
        case ValueKind.table: return "a table";
    }
}

/// A key as it would be written, quoting the parts that aren't bare.
string pathName(const Segment[] path) nothrow
{
    string name;
    foreach (k, segment; path)
    {
        if (k > 0) name ~= '.';
        bool bare = segment.name.length > 0;
        foreach (c; segment.name) bare = bare && isBareKeyChar(c);
        name ~= bare ? segment.name : "\"" ~ segment.name ~ "\"";
    }
    return name;
}

/// Null when `word` is an integer, which goes in `result`; otherwise why it isn't.
string parseInteger(string word, ref long result) nothrow
{
    immutable what = "`" ~ word ~ "` isn't an integer: ";
    size_t i = 0;
    bool negative = false;
    if (word[0] == '+' || word[0] == '-')
    {
        negative = word[0] == '-';
        i = 1;
    }
    if (word.length >= i + 2 && word[i] == '0' && (word[i + 1] == 'X' || word[i + 1] == 'O' || word[i + 1] == 'B'))
    {
        return what ~ "its prefix is written in lowercase, as `0" ~ cast(char)(word[i + 1] + 32) ~ "`";
    }
    uint radix = 10;
    string radixName = "decimal";
    if (word.length >= i + 2 && word[i] == '0' && (word[i + 1] == 'x' || word[i + 1] == 'o' || word[i + 1] == 'b'))
    {
        if (i == 1) return what ~ "one with a prefix can't have a sign";
        switch (word[i + 1])
        {
            case 'x': radix = 16; radixName = "hexadecimal"; break;
            case 'o': radix = 8; radixName = "octal"; break;
            default: radix = 2; radixName = "binary"; break;
        }
        i += 2;
    }
    immutable digits = word[i .. $];
    if (digits.length == 0) return what ~ "it has no digits";
    if (radix == 10 && digits.length > 1 && digits[0] == '0') return what ~ "a decimal integer can't start with 0";
    immutable ulong limit = negative ? 9_223_372_036_854_775_808UL : long.max;
    ulong total = 0;
    bool afterUnderscore = true;
    foreach (c; digits)
    {
        if (c == '_')
        {
            if (afterUnderscore) return what ~ "an underscore has to be between digits";
            afterUnderscore = true;
            continue;
        }
        immutable d = hexValue(c);
        if (d < 0 || d >= radix) return what ~ "`" ~ c ~ "` isn't a " ~ radixName ~ " digit";
        if (total > (limit - d) / radix) return "`" ~ word ~ "` is too large for an integer, which has 64 bits";
        total = total * radix + d;
        afterUnderscore = false;
    }
    if (afterUnderscore) return what ~ "an underscore has to be between digits";
    result = negative ? cast(long)(0UL - total) : cast(long) total;
    return null;
}

bool isFloatWord(string w) nothrow
{
    auto rest = w.length > 0 && (w[0] == '+' || w[0] == '-') ? w[1 .. $] : w;
    if (rest == "inf" || rest == "nan") return true;
    if (rest.length == 0 || !isDigit(rest[0])) return false;
    if (rest.length >= 2 && rest[0] == '0' && (rest[1] == 'x' || rest[1] == 'o' || rest[1] == 'b')) return false;
    foreach (c; rest)
    {
        if (c == 'e' || c == 'E') return true;
    }
    return false;
}

/// Starts as a date (`1979-05-27`) or a time (`07:32`) does.
bool isDateWord(string w) nothrow
{
    bool shaped(string pattern)
    {
        if (w.length < pattern.length) return false;
        foreach (k, c; pattern)
        {
            if (c == 'd' ? !isDigit(w[k]) : w[k] != c) return false;
        }
        return true;
    }
    return shaped("dddd-dd-dd") || shaped("dd:dd");
}

bool isDigit(char c) nothrow => c >= '0' && c <= '9';

bool isBareKeyChar(char c) nothrow
    => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c) || c == '_' || c == '-';

bool isWordChar(char c) nothrow => isBareKeyChar(c) || c == '+' || c == ':';

/// Allowed in a string or a comment as itself: anything but a control character other than tab.
bool printable(char c) nothrow => c == '\t' || (c >= 0x20 && c != 0x7F);

int hexValue(char c) nothrow
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// The length of the UTF-8 sequence at `source[i]`, or 0 when it isn't a valid one.
size_t utf8Length(string source, size_t i) nothrow
{
    immutable b0 = cast(ubyte) source[i];
    if (b0 < 0x80) return 1;
    size_t n;
    if (b0 < 0xC2) return 0;
    else if (b0 < 0xE0) n = 2;
    else if (b0 < 0xF0) n = 3;
    else if (b0 < 0xF5) n = 4;
    else return 0;
    if (i + n > source.length) return 0;
    foreach (k; 1 .. n)
    {
        if ((cast(ubyte) source[i + k] & 0xC0) != 0x80) return 0;
    }
    immutable b1 = cast(ubyte) source[i + 1];
    if (b0 == 0xE0 && b1 < 0xA0) return 0;
    if (b0 == 0xED && b1 >= 0xA0) return 0;
    if (b0 == 0xF0 && b1 < 0x90) return 0;
    if (b0 == 0xF4 && b1 >= 0x90) return 0;
    return n;
}

void appendUtf8(ref string text, uint c) nothrow
{
    if (c < 0x80)
    {
        text ~= cast(char) c;
    }
    else if (c < 0x800)
    {
        text ~= cast(char)(0xC0 | (c >> 6));
        text ~= cast(char)(0x80 | (c & 0x3F));
    }
    else if (c < 0x10000)
    {
        text ~= cast(char)(0xE0 | (c >> 12));
        text ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
        text ~= cast(char)(0x80 | (c & 0x3F));
    }
    else
    {
        text ~= cast(char)(0xF0 | (c >> 18));
        text ~= cast(char)(0x80 | ((c >> 12) & 0x3F));
        text ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
        text ~= cast(char)(0x80 | (c & 0x3F));
    }
}

string decimal(ulong n) nothrow
{
    char[20] buffer;
    size_t at = buffer.length;
    do
    {
        buffer[--at] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n > 0);
    return buffer[at .. $].idup;
}

string hexByte(char c) nothrow
{
    enum digits = "0123456789ABCDEF";
    return "0x" ~ digits[(c >> 4) & 0xF] ~ digits[c & 0xF];
}

version (unittest)
{
    Table read(string text)
    {
        auto document = readToml(text);
        assert(!document.failed, formatTomlError("test.toml", document.error));
        return document.root;
    }

    /// Asserts that `text` has one mistake, with `code`, starting at `line` and `column`.
    TomlError mistake(string text, TomlCode code, uint line, uint column)
    {
        auto document = readToml(text);
        assert(document.failed, "read without a mistake: " ~ text);
        auto e = document.error;
        assert(e.code == code && e.span.line == line && e.span.column == column,
            "for " ~ text ~ " got " ~ formatTomlError("test.toml", e));
        return e;
    }

    const(Value) at(const Table table, string key)
    {
        auto v = table.get(key);
        assert(v !is null, "no key " ~ key);
        return *v;
    }

    string slice(string text, Span span) => text[span.start .. span.end];
}

@("strings, integers and booleans, with comments and blank lines")
unittest
{
    auto t = read("# a package\n\nname = \"geometry\" # its name\nlimit = 1_000\nnegative = -42\n"
        ~ "hex = 0xFF\noctal = 0o17\nbinary = 0b101\nzero = +0\nyes = true\nno = false\npath = 'C:\\dir'\n");
    assert(at(t, "name").kind == ValueKind.string_ && at(t, "name").text == "geometry");
    assert(at(t, "limit").integer == 1000);
    assert(at(t, "negative").integer == -42);
    assert(at(t, "hex").integer == 255 && at(t, "octal").integer == 15 && at(t, "binary").integer == 5);
    assert(at(t, "zero").integer == 0);
    assert(at(t, "yes").boolean && !at(t, "no").boolean && at(t, "no").kind == ValueKind.boolean);
    assert(at(t, "path").text == "C:\\dir");
    assert(t.entries.length == 10 && t.entries[0].key == "name" && t.entries[$ - 1].key == "path");
    assert(read("").entries.length == 0);
    assert(read("\n# only a comment").entries.length == 0);
    assert(read("a = 1").get("a").integer == 1);
    assert(read("a=1\r\nb=2\r\n").get("b").integer == 2);
    assert(read("\xEF\xBB\xBFa = 1").get("a").integer == 1);
    assert(read("max = 9223372036854775807\nmin = -9223372036854775808").get("min").integer == long.min);
}

@("escapes in basic strings, and none in literal strings")
unittest
{
    auto t = read(`a = "tab\tquote\" slash\\ \b\f\n\r"` ~ "\n" ~ `b = "\u00e9\U0001F600"` ~ "\n" ~ `c = 'a\tb'`
        ~ "\nd = \"\"\ne = ''\nf = \"caf\xC3\xA9\"");
    assert(at(t, "a").text == "tab\tquote\" slash\\ \b\f\n\r");
    assert(at(t, "b").text == "\u00e9\U0001F600");
    assert(at(t, "c").text == `a\tb`);
    assert(at(t, "d").text == "" && at(t, "e").text == "");
    assert(at(t, "f").text == "caf\u00e9");
}

@("bare, quoted and dotted keys")
unittest
{
    auto t = read("bare-key_1 = 1\n\"quoted key\" = 2\n'literal' = 3\n\"silver.core\" = 4\n"
        ~ "a.b.c = 5\na.b.d = 6\na . \"e.f\" = 7\n1234 = 8\ntrue = 9\n");
    assert(at(t, "bare-key_1").integer == 1);
    assert(at(t, "quoted key").integer == 2);
    assert(at(t, "literal").integer == 3);
    assert(at(t, "silver.core").integer == 4);
    auto a = at(t, "a").table;
    assert(at(a, "b").table.get("c").integer == 5 && at(a, "b").table.get("d").integer == 6);
    assert(at(a, "e.f").integer == 7);
    assert(at(t, "1234").integer == 8 && at(t, "true").integer == 9);
}

@("arrays, over several lines and with a trailing comma")
unittest
{
    auto t = read("uses = [\"a\", 'b']\nempty = []\nnested = [[1, 2], [true]]\n"
        ~ "long = [\n  \"x\", # first\n\n  \"y\",\n]\nmixed = [1, \"two\", { three = 3 }]");
    auto uses = at(t, "uses");
    assert(uses.kind == ValueKind.array && uses.items.length == 2 && uses.items[1].text == "b");
    assert(at(t, "empty").items.length == 0);
    assert(at(t, "nested").items[0].items[1].integer == 2 && at(t, "nested").items[1].items[0].boolean);
    assert(at(t, "long").items.length == 2 && at(t, "long").items[1].text == "y");
    assert(at(t, "mixed").items[2].table.get("three").integer == 3);
    assert(!at(t, "uses").ofTables);
}

@("inline tables")
unittest
{
    auto t = read("geometry = { path = \"../geometry\", deep.er = true }\nempty = {}");
    auto g = at(t, "geometry");
    assert(g.kind == ValueKind.table && at(g.table, "path").text == "../geometry");
    assert(at(at(g.table, "deep").table, "er").boolean);
    assert(at(t, "empty").table.entries.length == 0);
}

@("table headers, implied tables and arrays of tables")
unittest
{
    auto t = read("top = 1\n[places]\ngeometry = \"../geometry\"\n\"silver.core\" = \"../silver/core\"\n"
        ~ "[a.b]\nx = 1\n[a]\ny = 2\n[[package]]\nname = \"one\"\n[[package]]\nname = \"two\"\n[package.extra]\nz = 3\n"
        ~ "[x]\nd.e = 1\n[x.d.f]\ng = 2\n");
    assert(at(t, "top").integer == 1);
    auto places = at(t, "places").table;
    assert(at(places, "geometry").text == "../geometry" && at(places, "silver.core").text == "../silver/core");
    auto a = at(t, "a").table;
    assert(at(a, "y").integer == 2 && at(at(a, "b").table, "x").integer == 1);
    auto packages = at(t, "package");
    assert(packages.kind == ValueKind.array && packages.ofTables && packages.items.length == 2);
    assert(at(packages.items[0].table, "name").text == "one");
    assert(at(packages.items[1].table, "name").text == "two");
    assert(at(at(packages.items[1].table, "extra").table, "z").integer == 3);
    assert(packages.items[0].table.get("extra") is null);
    auto d = at(at(t, "x").table, "d").table;
    assert(at(d, "e").integer == 1 && at(at(d, "f").table, "g").integer == 2);
    assert(read("[ spaced . key ]\na = 1").get("spaced").table.get("key").table.get("a").integer == 1);
}

@("every key and value has its span")
unittest
{
    immutable text = "name = \"geometry\"\nuses = [\"a\", 'b']\n\n[places]\n\"silver.core\" = \"../silver/core\"\n"
        ~ "n = 42\nflag = true\ninline = { k = 1 }\n[[package]]\n";
    auto t = read(text);
    auto name = t.entry("name");
    assert(name.keySpan == Span(0, 4, 1, 1));
    assert(name.value.span == Span(7, 17, 1, 8) && slice(text, name.value.span) == "\"geometry\"");
    auto uses = t.entry("uses");
    assert(uses.keySpan.line == 2 && uses.keySpan.column == 1);
    assert(slice(text, uses.value.span) == "[\"a\", 'b']" && uses.value.span.column == 8);
    assert(slice(text, uses.value.items[1].span) == "'b'" && uses.value.items[1].span.column == 14);
    auto places = t.entry("places");
    assert(slice(text, places.keySpan) == "places" && places.keySpan.line == 4 && places.keySpan.column == 2);
    assert(slice(text, places.value.span) == "[places]");
    auto core = places.value.table.entry("silver.core");
    assert(slice(text, core.keySpan) == "\"silver.core\"" && core.keySpan.line == 5 && core.keySpan.column == 1);
    assert(slice(text, core.value.span) == "\"../silver/core\"" && core.value.span.line == 5 && core.value.span.column == 17);
    auto n = places.value.table.entry("n");
    assert(slice(text, n.value.span) == "42" && n.value.span.line == 6 && n.value.span.column == 5);
    assert(slice(text, places.value.table.entry("flag").value.span) == "true");
    auto inline = places.value.table.entry("inline");
    assert(slice(text, inline.value.span) == "{ k = 1 }");
    assert(slice(text, inline.value.table.entry("k").keySpan) == "k");
    assert(places.value.table.get("package") is null);
    auto packages = t.entry("package");
    assert(slice(text, packages.keySpan) == "package" && slice(text, packages.value.items[0].span) == "[[package]]");
    auto dotted = read("a.b = 1").entry("a");
    assert(dotted.keySpan == Span(0, 1, 1, 1) && dotted.value.table.entry("b").keySpan == Span(2, 3, 1, 3));
}

@("each mistake has its code and position")
unittest
{
    mistake("a = \"\xFF\"", TomlCode.NotUtf8, 1, 6);
    mistake("# caf\xC3", TomlCode.NotUtf8, 1, 6);
    mistake("a = \"\xED\xA0\x80\"", TomlCode.NotUtf8, 1, 6);
    mistake("\xC3\xA9 = 1", TomlCode.BadCharacter, 1, 1);
    mistake("a = 1\nb @ 2", TomlCode.BadCharacter, 2, 3);
    mistake("a = \"x\ty\x01\"", TomlCode.BadCharacter, 1, 9);
    mistake("# a\x7F", TomlCode.BadCharacter, 1, 4);
    mistake("a = 1\rb = 2", TomlCode.BadCharacter, 1, 6);
    mistake("a = \"x\ry\"", TomlCode.BadCharacter, 1, 7);
    mistake("a = 'x\ry'", TomlCode.BadCharacter, 1, 7);
    mistake("a = \"abc\nb = 1", TomlCode.UnterminatedString, 1, 5);
    mistake("a = 'abc", TomlCode.UnterminatedString, 1, 5);
    mistake("a = \"", TomlCode.UnterminatedString, 1, 5);
    mistake(`a = "x\qy"`, TomlCode.BadEscape, 1, 7);
    mistake(`a = "\u12"`, TomlCode.BadEscape, 1, 6);
    mistake(`a = "\UD8000000"`, TomlCode.BadEscape, 1, 6);
    mistake(`a = "\uD800"`, TomlCode.BadEscape, 1, 6);
    mistake("a = \"\\", TomlCode.BadEscape, 1, 6);
    mistake("a 1", TomlCode.Unexpected, 1, 3);
    mistake("a =", TomlCode.Unexpected, 1, 4);
    mistake("a = \n", TomlCode.Unexpected, 1, 5);
    mistake("a = 1 b = 2", TomlCode.Unexpected, 1, 7);
    mistake("a. = 1", TomlCode.Unexpected, 1, 4);
    mistake("= 1", TomlCode.Unexpected, 1, 1);
    mistake("[a\nb = 1", TomlCode.Unexpected, 1, 3);
    mistake("[[a]\n", TomlCode.Unexpected, 1, 5);
    mistake("[[a] ]\n", TomlCode.Unexpected, 1, 6);
    mistake("[]", TomlCode.Unexpected, 1, 2);
    mistake("a = [1 2]", TomlCode.Unexpected, 1, 8);
    mistake("a = [1,,]", TomlCode.Unexpected, 1, 8);
    mistake("a = [1", TomlCode.Unexpected, 1, 7);
    mistake("a = {b = 1,}", TomlCode.Unexpected, 1, 12);
    mistake("a = {b = 1\n}", TomlCode.Unexpected, 1, 11);
    mistake("a = {\nb = 1}", TomlCode.Unexpected, 1, 6);
    mistake("a = {b = 1 c = 2}", TomlCode.Unexpected, 1, 12);
    mistake("a+b = 1", TomlCode.BadKey, 1, 1);
    mistake("[x]\nt:1 = 1", TomlCode.BadKey, 2, 1);
    mistake("name = geometry", TomlCode.BadValue, 1, 8);
    mistake("a = [yes]", TomlCode.BadValue, 1, 6);
    mistake("a = 012", TomlCode.BadInteger, 1, 5);
    mistake("a = 1__0", TomlCode.BadInteger, 1, 5);
    mistake("a = 10_", TomlCode.BadInteger, 1, 5);
    mistake("a = 0x", TomlCode.BadInteger, 1, 5);
    mistake("a = 0b102", TomlCode.BadInteger, 1, 5);
    mistake("a = +0x1", TomlCode.BadInteger, 1, 5);
    mistake("a = 12a", TomlCode.BadInteger, 1, 5);
    mistake("a = 9223372036854775808", TomlCode.BadInteger, 1, 5);
    mistake("a = -9223372036854775809", TomlCode.BadInteger, 1, 5);
    mistake("a = -", TomlCode.BadInteger, 1, 5);
    mistake("a = 1.5", TomlCode.Unsupported, 1, 5);
    mistake("a = -1.5e3", TomlCode.Unsupported, 1, 5);
    mistake("a = 1e5", TomlCode.Unsupported, 1, 5);
    mistake("a = inf", TomlCode.Unsupported, 1, 5);
    mistake("a = -nan", TomlCode.Unsupported, 1, 5);
    mistake("a = 1979-05-27", TomlCode.Unsupported, 1, 5);
    mistake("a = 1979-05-27T07:32:00Z", TomlCode.Unsupported, 1, 5);
    mistake("a = 07:32:00", TomlCode.Unsupported, 1, 5);
    auto time = mistake("a = 07:32:00.5", TomlCode.Unsupported, 1, 5);
    assert(time.message == "A date or a time isn't supported in a package file", time.message);
    mistake("a = \"\"\"x\"\"\"", TomlCode.Unsupported, 1, 5);
    mistake("a = '''x'''", TomlCode.Unsupported, 1, 5);
    mistake("a = 1\na = 2", TomlCode.DuplicateKey, 2, 1);
    mistake("a = 1\n\"a\" = 2", TomlCode.DuplicateKey, 2, 1);
    mistake("[t]\na.b = 1\na.b = 2", TomlCode.DuplicateKey, 3, 3);
    mistake("a = {b = 1, b = 2}", TomlCode.DuplicateKey, 1, 13);
    mistake("[a]\n[b]\n[a]", TomlCode.DuplicateTable, 3, 2);
    mistake("[a.b]\n[a.b]", TomlCode.DuplicateTable, 2, 4);
    mistake("a = 1\n[a]", TomlCode.DuplicateTable, 2, 2);
    mistake("a.b = 1\n[a]", TomlCode.DuplicateTable, 2, 2);
    mistake("[x]\na.b = 1\n[x.a]", TomlCode.DuplicateTable, 3, 4);
    mistake("[[a]]\n[a]", TomlCode.DuplicateTable, 2, 2);
    mistake("[a]\n[[a]]", TomlCode.NotAnArrayOfTables, 2, 3);
    mistake("a = 1\n[[a]]", TomlCode.NotAnArrayOfTables, 2, 3);
    mistake("a = [{b = 1}]\n[[a]]", TomlCode.NotAnArrayOfTables, 2, 3);
    mistake("a = 1\na.b = 2", TomlCode.NotATable, 2, 1);
    mistake("a = 1\n[a.b]", TomlCode.NotATable, 2, 2);
    mistake("a = {b = 1}\n[a.c]", TomlCode.NotATable, 2, 2);
    mistake("a = {b = 1}\na.c = 2", TomlCode.NotATable, 2, 1);
    mistake("[a.b]\n[a]\nb.c = 1", TomlCode.NotATable, 3, 1);
    mistake("a = [1]\n[a.b]", TomlCode.NotATable, 2, 2);
    mistake("[[a]]\nb = 1\n[a.b.c]", TomlCode.NotATable, 3, 4);
    mistake("x = 1\n[[x.y]]", TomlCode.NotATable, 2, 3);
    mistake("a = " ~ repeat('[', 101), TomlCode.NestedTooDeeply, 1, 105);
    assert(!readToml("a = " ~ repeat('[', 100) ~ repeat(']', 100)).failed);
}

@("a mistake says how to write what was probably meant")
unittest
{
    auto e = mistake("version = 1.2.0", TomlCode.Unsupported, 1, 11);
    assert(e.message == "A float isn't supported in a package file; text such as a version is written in quotes, "
        ~ "as \"1.2.0\"", e.message);
    assert(e.span.end == 15);
    e = mistake("a = 0X10", TomlCode.BadInteger, 1, 5);
    assert(e.message == "`0X10` isn't an integer: its prefix is written in lowercase, as `0x`", e.message);
    assert(mistake("a = 0B1", TomlCode.BadInteger, 1, 5).message.length > 0);
    e = mistake("a = 1234-5", TomlCode.BadInteger, 1, 5);
    assert(e.message == "`1234-5` isn't an integer: `-` isn't a decimal digit", e.message);
    e = mistake("a = [\n  1,\n  2,\n", TomlCode.Unexpected, 4, 1);
    assert(e.message == "The array opened at line 1 has no closing `]`", e.message);
    e = mistake("x = 1\na = [1, 2", TomlCode.Unexpected, 2, 10);
    assert(e.message == "The array opened at line 2 has no closing `]`", e.message);
    e = mistake("a = {b = 1", TomlCode.Unexpected, 1, 11);
    assert(e.message == "The inline table opened at line 1 has no closing `}`", e.message);
    e = mistake("a = {", TomlCode.Unexpected, 1, 6);
    assert(e.message == "The inline table opened at line 1 has no closing `}`", e.message);
}

version (unittest) private string repeat(char c, size_t n)
{
    string s;
    foreach (_; 0 .. n) s ~= c;
    return s;
}

@("a mistake is formatted as the compiler formats a diagnostic")
unittest
{
    auto e = mistake("name = \"cards\"\nuses = [geometry]", TomlCode.BadValue, 2, 9);
    assert(formatTomlError("cards/silver.toml", e) == "cards/silver.toml(2,9): Error F0007: "
        ~ "`geometry` isn't a value; a string is written in quotes, as \"geometry\"");
    e = mistake("a = 1\na = 2", TomlCode.DuplicateKey, 2, 1);
    assert(formatTomlError("silver.toml", e) == "silver.toml(2,1): Error F0010: `a` is already defined, at line 1");
    e = mistake("[x]\n\"a.b\".c = 1\n\"a.b\".c = 2", TomlCode.DuplicateKey, 3, 7);
    assert(e.message == "`\"a.b\".c` is already defined, at line 2");
}

version (unittest)
{
    immutable geometryFile = "# geometry/silver.toml\nname = \"geometry\"\n";

    immutable cardsFile = "# cards/silver.toml\nname = \"cards\"\nuses = [\"geometry\"]\n\n[[package]]\n"
        ~ "path = \"../geometry\"\n";

    immutable compilerFile = "# silver.toml\nname = \"silver\"\n\n"
        ~ "[[package]]\nname = \"silver.ast\"\npath = \"ast\"\n\n"
        ~ "[[package]]\nname = \"silver.syntax\"\npath = \"syntax\"\nuses = [\"silver.ast\"]\n\n"
        ~ "[[package]]\nname = \"silver.sema\"\npath = \"sema\"\nuses = [\"silver.ast\", \"silver.loader\"]\n\n"
        ~ "[[package]]\nname = \"silver.compiler\"\npath = \"compiler\"\n"
        ~ "uses = [\"silver.sema\", \"silver.core\", \"silver.interpreter\", \"silver.codegen\"]\n\n"
        ~ "[[package]]\nname = \"silver.frontend\"\npath = \"frontend\"\n";

    string[] strings(const Value v)
    {
        assert(v.kind == ValueKind.array);
        string[] result;
        foreach (item; v.items)
        {
            assert(item.kind == ValueKind.string_);
            result ~= item.text;
        }
        return result;
    }
}

@("the package files in docs/silver.md")
unittest
{
    auto geometry = read(geometryFile);
    assert(geometry.entries.length == 1 && at(geometry, "name").text == "geometry");

    auto cards = read(cardsFile);
    assert(cards.entries.length == 3);
    assert(at(cards, "name").text == "cards");
    assert(strings(at(cards, "uses")) == ["geometry"]);
    auto listed = at(cards, "package");
    assert(listed.ofTables && listed.items.length == 1 && at(listed.items[0].table, "path").text == "../geometry");
    assert(slice(cardsFile, listed.items[0].table.entry("path").value.span) == "\"../geometry\"");
    assert(listed.items[0].table.entry("path").value.span.line == 6);

    auto compiler = read(compilerFile);
    assert(compiler.entries.length == 2 && at(compiler, "name").text == "silver");
    auto described = at(compiler, "package");
    assert(described.ofTables && described.items.length == 5);
    string[] names, directories;
    foreach (entry; described.items)
    {
        names ~= at(entry.table, "name").text;
        directories ~= at(entry.table, "path").text;
    }
    assert(names == ["silver.ast", "silver.syntax", "silver.sema", "silver.compiler", "silver.frontend"]);
    assert(directories == ["ast", "syntax", "sema", "compiler", "frontend"]);
    assert(described.items[0].table.get("uses") is null);
    assert(strings(at(described.items[2].table, "uses")) == ["silver.ast", "silver.loader"]);
    assert(strings(at(described.items[3].table, "uses")).length == 4);
    assert(described.items[4].span.line == 23 && slice(compilerFile, described.items[4].span) == "[[package]]");
}

@("any text, cut short or with a byte changed, is read or is one mistake")
unittest
{
    immutable bytes = "\"'[]{}\\.=,#\n\r\t\0\xFF\xC3 a1";
    foreach (text; [geometryFile, cardsFile, compilerFile, "a = {b = [1, {c = 'd'}], e.f = \"\\u00e9\"}\n[[x.y]]\n"])
    {
        foreach (n; 0 .. text.length + 1)
        {
            auto document = readToml(text[0 .. n]);
            assert(document.failed == (document.root is null));
            if (document.failed) assert(document.error.message.length > 0 && document.error.span.line > 0);
        }
        foreach (i; 0 .. text.length)
        {
            foreach (b; bytes)
            {
                auto changed = text.dup;
                changed[i] = b;
                auto document = readToml(cast(string) changed);
                if (document.failed) assert(document.error.span.end >= document.error.span.start);
            }
        }
    }
}
