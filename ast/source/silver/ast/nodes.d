module silver.ast.nodes;

import std.sumtype;

import silver.ast.span;

import silver.ast.id;

/// The node kinds that get IDs. One NodeIds is shared by every module in a Program.
alias NodeIds = IdSource!(Module, Expr, TypeExpr, VarDecl, Param, FunctionDecl, ImportStmt, TypeDecl, Field, ConstDecl);

struct Module
{
    Id!Module id;
    string name;
    Span span;
    Decl[] declarations;
    /// null when the file has no `module` line, which only a file that's never imported may omit.
    ModuleDeclaration* declaration;
}

/// `module a.b`, the first line of a file. `path` must match the file's path under its root.
struct ModuleDeclaration
{
    string[] path;
    Span span;
}

/// A top-level declaration. Modules hold only these; statements live in function bodies.
struct Decl
{
    Span span;
    DeclKind kind;
}

alias DeclKind = SumType!(ImportStmt, FunctionDecl, TypeDecl, ConstDecl);

/// A type as written in source. Names aren't resolved, so `Int` is a NamedType
/// like any other; the checker's resolved types are a separate representation.
struct TypeExpr
{
    Id!TypeExpr id;
    Span span;
    TypeExprKind kind;
}

/// `T?`.
struct OptionType
{
    TypeExpr* inner;
}

/// `[T]`.
struct ArrayType
{
    TypeExpr* element;
}

/// `Int`, `math.Vector`, `List<Int>`; `path` is the dotted name split into parts.
struct NamedType
{
    string[] path;
    /// Empty when there are no type arguments.
    TypeExpr[] args;
}

/// `(Int, Int) -> Int`.
struct FunctionType
{
    TypeExpr[] params;
    TypeExpr* returnType;
}

/// `()`.
struct UnitType
{
}

alias TypeExprKind = SumType!(OptionType, ArrayType, NamedType, FunctionType, UnitType);

/// Prints a type the way it's written in source.
string printTypeExpr(const TypeExpr t)
{
    import std.algorithm : map;
    import std.array : join;

    return t.kind.match!(
        (const OptionType o) => printOptionInner(*o.inner) ~ "?",
        (const ArrayType a) => "[" ~ printTypeExpr(*a.element) ~ "]",
        (const NamedType n) => n.path.join(".")
            ~ (n.args.length > 0 ? "<" ~ n.args.map!printTypeExpr.join(", ") ~ ">" : ""),
        (const FunctionType f) => "(" ~ f.params.map!printTypeExpr.join(", ") ~ ") -> "
            ~ printTypeExpr(*f.returnType),
        (const UnitType u) => "()",
    );
}

/// `(Int) -> Int?` returns an option and `Int??` doesn't parse, so an optional
/// function or option needs its inner type parenthesized.
private string printOptionInner(const TypeExpr inner)
{
    auto needsParens = inner.kind.match!(
        (const FunctionType _) => true,
        (const OptionType _) => true,
        _ => false,
    );
    return needsParens ? "(" ~ printTypeExpr(inner) ~ ")" : printTypeExpr(inner);
}

struct Expr
{
    Id!Expr id;

    Span span;
    ExprKind kind;
}

alias ExprKind = SumType!(BoolLiteral, IntLiteral, FloatLiteral, StringLiteral, InterpolatedString, Identifier,
    UnaryExpr, BinaryExpr, CallExpr, MemberAccess, WhileExpr, ForExpr, IfExpr, BlockExpr, UnitLiteral,
    SomeExpr, NoneLiteral, PropagateExpr, SafeMemberAccess, ArrayLiteral, MapLiteral, IndexExpr, RangeExpr);

/// `()`, the only value of type Unit.
struct UnitLiteral
{
}

struct BoolLiteral
{
    bool value;
}

/// A sign is a UnaryExpr around this, so the value is a magnitude. Sema checks that it fits the
/// type the literal ends up with.
struct IntLiteral
{
    ulong value;
    /// The text doesn't fit 64 bits, whatever the type.
    bool tooLarge;
}

struct FloatLiteral
{
    double value;
}

/// `"..."`, with escapes already decoded.
struct StringLiteral
{
    string value;
}

/// `"a{x}b"`: each part is the StringLiteral for a run of text or a hole's expression, and the
/// value is every part formatted as `print` would show it, joined. No holes means a StringLiteral.
struct InterpolatedString
{
    Expr[] parts;
}

struct Identifier
{
    string name;
}

enum BinaryOp
{
    Add = "+",
    Subtract = "-",
    Multiply = "*",
    Divide = "/",
    Modulo = "%",
    BitAnd = "&",
    BitOr = "|",
    BitXor = "^",
    ShiftLeft = "<<",
    ShiftRight = ">>",
    WrappingAdd = "&+",
    WrappingSubtract = "&-",
    WrappingMultiply = "&*",
    Equal = "==",
    NotEqual = "!=",
    And = "&&",
    Or = "||",
    Less = "<",
    LessEqual = "<=",
    Greater = ">",
    GreaterEqual = ">=",
    Coalesce = "??",
    Concat = "~",
    /// `xs ~= ys` lowers to `xs = xs ~= ys`: a `~` that may leave room to grow, and only ever
    /// appears as the value of that assignment.
    Append = "~=",
}

enum UnaryOp
{
    Plus = "+",
    Minus = "-",
    Not = "!",
    BitNot = "~",
}

struct UnaryExpr
{
    UnaryOp op;
    Expr* operand;
}

struct BinaryExpr
{
    BinaryOp op;
    Expr* left;
    Expr* right;
}

/// `callee(args...)`. The callee is any expression, so `f()()` and `m.f()` work.
struct CallExpr
{
    Expr* callee;
    Expr[] args;
}

/// `object.member`, e.g. a function in an imported module.
struct MemberAccess
{
    Expr* object;
    string member;
}

/// `Some(x)`.
struct SomeExpr
{
    Expr* value;
}

/// `None`.
struct NoneLiteral
{
}

/// `x?`: `x`'s payload, or a `None` returned from the enclosing function.
struct PropagateExpr
{
    Expr* operand;
}

/// `object?.member`.
struct SafeMemberAccess
{
    Expr* object;
    string member;
}

/// `[a, b]`.
struct ArrayLiteral
{
    Expr[] elements;
}

/// `[k: v]`, whose entries are `keys[i]: values[i]`. Sema rejects it until generics.
struct MapLiteral
{
    Expr[] keys;
    Expr[] values;
}

/// `object[index]`, or a slice when `index` is a RangeExpr.
struct IndexExpr
{
    Expr* object;
    Expr* index;
}

/// `start..end`, half open. Only a slice or a `for` takes one for now.
struct RangeExpr
{
    Expr* start;
    Expr* end;
}

/// The range `expr` is, or null if it's anything else.
const(RangeExpr)* asRange(const(Expr)* expr)
{
    return (*expr).kind.match!(
        (ref const RangeExpr range) => &range,
        (_) => cast(const(RangeExpr)*) null,
    );
}

/// `if c => a else b` or `if c { ... } else { ... }`.
/// `falseBody` is null when there's no else, and the if's value is then ().
/// `if val x = opt ...` sets `binding` instead of `condition`: its value is the option, and
/// `x` is in scope only in `trueBody`.
struct IfExpr
{
    Expr* condition;
    Expr* trueBody;
    Expr* falseBody;
    VarDecl* binding;
}

/// `while c { ... }`, whose value is `()`.
/// `while val x = opt { ... }` sets `binding` instead of `condition`: its value is evaluated before
/// each iteration, the loop ends on `None`, and `x` is in scope only in `body`.
struct WhileExpr
{
    Expr* condition;
    Expr* body;
    VarDecl* binding;
}

/// `for x in xs { ... }`, whose value is `()`. `binding`'s value is what's looped over, an array or
/// a RangeExpr, evaluated once before the loop, and `x` is in scope only in `body`.
struct ForExpr
{
    VarDecl* binding;
    Expr* body;
}

/// `{ statements }`, which has its own scope. `value` is the last statement when
/// that's an expression, and null otherwise, in which case the block's value is ().
struct BlockExpr
{
    Stmt[] statements;
    Expr* value;
}

string printExpr(const Expr e)
{
    import std.algorithm : map;
    import std.array : join;
    import std.conv : to;
    import std.format : format;
    return e.kind.match!(
        (const BoolLiteral b) => b.value.to!string,
        (const IntLiteral l) => l.value.to!string,
        (const FloatLiteral f) => f.value.to!string,
        // %(%s%) writes a one-element array's string quoted and escaped.
        (const StringLiteral s) => format("%(%s%)", [s.value]),
        (const InterpolatedString s) => format("(interpolate%s)", s.parts.map!(p => " " ~ printExpr(p)).join),
        (const Identifier i) => i.name,
        (const BinaryExpr b) => format("(%s %s %s)", b.op, printExpr(*b.left), printExpr(*b.right)),
        (const UnaryExpr u) => format("(%s %s)", u.op, printExpr(*u.operand)),
        (const CallExpr c) => format("(call %s%s)", printExpr(*c.callee), c.args.map!(a => " " ~ printExpr(a)).join),
        (const MemberAccess m) => format("(. %s %s)", printExpr(*m.object), m.member),
        (const WhileExpr w) => format("(while %s %s)", w.binding is null
            ? printExpr(*w.condition)
            : format("(val %s %s)", w.binding.name, printExpr(w.binding.value)), printExpr(*w.body)),
        (const ForExpr f) => format("(for %s %s %s)", f.binding.name, printExpr(f.binding.value), printExpr(*f.body)),
        (const IfExpr i) {
            auto head = i.binding is null
                ? printExpr(*i.condition)
                : format("(val %s %s)", i.binding.name, printExpr(i.binding.value));
            return i.falseBody is null
                ? format("(if %s %s)", head, printExpr(*i.trueBody))
                : format("(if %s %s %s)", head, printExpr(*i.trueBody), printExpr(*i.falseBody));
        },
        (const BlockExpr b) => format("(block%s%s)", b.statements.map!(s => " " ~ printStmt(s)).join,
            b.value is null ? "" : " => " ~ printExpr(*b.value)),
        (const UnitLiteral u) => "()",
        (const SomeExpr s) => format("(Some %s)", printExpr(*s.value)),
        (const NoneLiteral _) => "None",
        (const PropagateExpr p) => format("(? %s)", printExpr(*p.operand)),
        (const SafeMemberAccess m) => format("(?. %s %s)", printExpr(*m.object), m.member),
        (const ArrayLiteral a) => format("(array%s)", a.elements.map!(e => " " ~ printExpr(e)).join),
        (const MapLiteral m) {
            string entries;
            foreach (i, key; m.keys)
            {
                entries ~= format(" (%s %s)", printExpr(key), printExpr(m.values[i]));
            }
            return "(map" ~ entries ~ ")";
        },
        (const IndexExpr i) => format("(index %s %s)", printExpr(*i.object), printExpr(*i.index)),
        (const RangeExpr r) => format("(.. %s %s)", printExpr(*r.start), printExpr(*r.end)),
    );
}

@("Build and match an expression")
unittest
{
    // a + b * 2
    Span span;
    auto ids = new NodeIds;
    auto a = new Expr(ids.next!Expr, span, ExprKind(Identifier("a")));
    auto b = new Expr(ids.next!Expr, span, ExprKind(Identifier("b")));
    auto two = new Expr(ids.next!Expr, span, ExprKind(IntLiteral(2)));
    auto product = new Expr(ids.next!Expr, span, ExprKind(BinaryExpr(BinaryOp.Multiply, b, two)));
    auto sum = Expr(ids.next!Expr, span, ExprKind(BinaryExpr(BinaryOp.Add, a, product)));

    assert(printExpr(sum) == "(Add a (Multiply b 2))");
}

struct Stmt
{
    Span span;
    StmtKind kind;
}

alias StmtKind = SumType!(VarDecl, AssignStmt, ExprStmt, FunctionDecl, ReturnStmt, BreakStmt, ContinueStmt);

/// The name of a VarDecl that binds nothing: its value is evaluated and dropped, and no name is
/// declared, so any number of them can share a scope.
enum discardName = "_";

struct VarDecl
{
    Id!VarDecl id;
    string name;
    Span nameSpan;
    Expr value;
    /// null when the type isn't annotated.
    TypeExpr* type;
    bool mutable;
}

/// `target = value`. Lowering rewrites `a += 1` to `a = a + 1`.
struct AssignStmt
{
    Expr target;
    Expr value;
}

/// An expression evaluated for its effect, e.g. a call or an if.
struct ExprStmt
{
    Expr expr;
}

/// `import a.b`; `path` is the dotted name split into parts, e.g. ["a", "b"].
struct ImportStmt
{
    Id!ImportStmt id;
    string[] path;
}

/// `name: Type` in a function declaration.
struct Param
{
    Id!Param id;
    string name;
    Span nameSpan;
    TypeExpr type;
}

/// `def name(params): Type => expr` or `def name(params): Type { ... }`.
/// A block body is a BlockExpr, so either way the body is one expression.
/// `native def name(params): Type` has no body; the runtime binds it by name.
struct FunctionDecl
{
    Id!FunctionDecl id;
    string name;
    Span nameSpan;
    Param[] params;
    /// null when `native` is set.
    Expr* body;
    TypeExpr returnType;
    bool native;
}

/// `name: Type` in a type declaration.
struct Field
{
    Id!Field id;
    string name;
    Span nameSpan;
    TypeExpr type;
}

/// `type Name(fields)`, or `type Name` for a marker type, whose only value is `Name`.
struct TypeDecl
{
    Id!TypeDecl id;
    string name;
    Span nameSpan;
    Field[] fields;
    /// `type Name()`, which must be written `type Name`.
    bool emptyParens;
}

/// `val name: Type = value` at the top level of a module. Sema evaluates `value`, so it never runs.
struct ConstDecl
{
    Id!ConstDecl id;
    string name;
    Span nameSpan;
    /// null when the type isn't annotated, which sema reports.
    TypeExpr* type;
    Expr value;
}

/// `return value`. A bare `return` has a UnitLiteral value.
struct ReturnStmt
{
    Expr value;
}

/// `break`, which ends the innermost loop whose body holds it.
struct BreakStmt
{
}

/// `continue`, which starts the next iteration of the innermost loop whose body holds it.
struct ContinueStmt
{
}

string printModule(const Module m)
{
    import std.format : format;
    import std.algorithm : map;
    import std.array : join;
    auto declarations = m.declarations.map!(printDecl).join("\n");
    if (m.declaration is null)
    {
        return declarations;
    }
    auto header = printModuleDeclaration(*m.declaration);
    return declarations.length == 0 ? header : header ~ "\n" ~ declarations;
}

string printModuleDeclaration(const ModuleDeclaration d)
{
    import std.array : join;

    return "(module " ~ d.path.join(".") ~ ")";
}

string printDecl(const Decl d)
{
    return d.kind.match!(
        (const ImportStmt i) => printImport(i),
        (const FunctionDecl f) => printFunctionDecl(f),
        (const TypeDecl t) => printTypeDecl(t),
        (const ConstDecl c) => printConstDecl(c),
    );
}

string printStmt(const Stmt s)
{
    import std.algorithm : map;
    import std.array : join;
    import std.format : format;
    return s.kind.match!(
        (const VarDecl v) => format("(%s %s%s %s)", v.mutable ? "mutable val" : "val", v.name,
            v.type is null ? "" : ": " ~ printTypeExpr(*v.type), printExpr(v.value)),
        (const ExprStmt e) => printExpr(e.expr),
        (const AssignStmt a) => format("(assign %s %s)", printExpr(a.target), printExpr(a.value)),
        (const FunctionDecl f) => printFunctionDecl(f),
        (const ReturnStmt r) => format("(return %s)", printExpr(r.value)),
        (const BreakStmt _) => "(break)",
        (const ContinueStmt _) => "(continue)",
    );
}

private string printImport(const ImportStmt i)
{
    import std.array : join;
    import std.format : format;

    return format("(import %s)", i.path.join("."));
}

private string printFunctionDecl(const FunctionDecl f)
{
    import std.format : format;

    return f.native
        ? format("(native def %s %s)", f.name, printSignature(f))
        : format("(def %s %s %s)", f.name, printSignature(f), printExpr(*f.body));
}

private string printTypeDecl(const TypeDecl t)
{
    import std.algorithm : map;
    import std.array : join;

    if (t.fields.length == 0)
    {
        return t.emptyParens ? "(type " ~ t.name ~ " ())" : "(type " ~ t.name ~ ")";
    }
    return "(type " ~ t.name ~ " (" ~ t.fields.map!(f => f.name ~ ": " ~ printTypeExpr(f.type)).join(", ") ~ "))";
}

private string printConstDecl(const ConstDecl c)
{
    import std.format : format;

    return format("(val %s%s %s)", c.name, c.type is null ? "" : ": " ~ printTypeExpr(*c.type), printExpr(c.value));
}

/// `(a: Int, b: Int): Int`, as written in source.
private string printSignature(const FunctionDecl f)
{
    import std.algorithm : map;
    import std.array : join;

    return "(" ~ f.params.map!(p => p.name ~ ": " ~ printTypeExpr(p.type)).join(", ") ~ "): "
        ~ printTypeExpr(f.returnType);
}

@("Build and match a statement")
unittest
{
    Span span;
    auto ids = new NodeIds;
    auto one = Expr(ids.next!Expr, span, ExprKind(IntLiteral(1)));
    auto decl = Stmt(span, StmtKind(VarDecl(ids.next!VarDecl, "x", span, one, null, false)));

    assert(printStmt(decl) == "(val x 1)");
}
