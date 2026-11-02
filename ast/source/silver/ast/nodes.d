module silver.ast.nodes;

import std.sumtype;

import silver.ast.span;

import silver.ast.id;

/// The node kinds that get IDs. One NodeIds is shared by every module in a Program.
alias NodeIds = IdSource!(Module, Expr, TypeExpr, VarDecl, Param, FunctionDecl, ImportStmt);

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

alias DeclKind = SumType!(ImportStmt, FunctionDecl);

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

alias TypeExprKind = SumType!(OptionType, NamedType, FunctionType, UnitType);

/// Prints a type the way it's written in source.
string printTypeExpr(const TypeExpr t)
{
    import std.algorithm : map;
    import std.array : join;

    return t.kind.match!(
        (const OptionType o) => printOptionInner(*o.inner) ~ "?",
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

alias ExprKind = SumType!(BoolLiteral, IntLiteral, FloatLiteral, StringLiteral, Identifier, UnaryExpr, BinaryExpr,
    CallExpr, MemberAccess, WhileExpr, IfExpr, BlockExpr, UnitLiteral);

/// `()`, the only value of type Unit.
struct UnitLiteral
{
}

struct BoolLiteral
{
    bool value;
}

struct IntLiteral
{
    long value;
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

struct Identifier
{
    string name;
}

enum BinaryOp
{
    Add,
    Subtract,
    Multiply,
    Divide,
    Modulo,
    Power,
    Equal,
    NotEqual,
    And,
    Or,
    Less,
    LessEqual,
    Greater,
    GreaterEqual,
    Coalesce,
}

enum UnaryOp
{
    Plus,
    Minus,
    Not,
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

/// `if c => a else b` or `if c { ... } else { ... }`.
/// `falseBody` is null when there's no else, and the if's value is then ().
struct IfExpr
{
    Expr* condition;
    Expr* trueBody;
    Expr* falseBody;
}

/// `while c => b` or `while c { ... }`.
struct WhileExpr
{
    Expr* condition;
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
        (const Identifier i) => i.name,
        (const BinaryExpr b) => format("(%s %s %s)", b.op, printExpr(*b.left), printExpr(*b.right)),
        (const UnaryExpr u) => format("(%s %s)", u.op, printExpr(*u.operand)),
        (const CallExpr c) => format("(call %s%s)", printExpr(*c.callee), c.args.map!(a => " " ~ printExpr(a)).join),
        (const MemberAccess m) => format("(. %s %s)", printExpr(*m.object), m.member),
        (const WhileExpr w) => format("(while %s %s)", printExpr(*w.condition), printExpr(*w.body)),
        (const IfExpr i) => i.falseBody is null
            ? format("(if %s %s)", printExpr(*i.condition), printExpr(*i.trueBody))
            : format("(if %s %s %s)", printExpr(*i.condition), printExpr(*i.trueBody), printExpr(*i.falseBody)),
        (const BlockExpr b) => format("(block%s%s)", b.statements.map!(s => " " ~ printStmt(s)).join,
            b.value is null ? "" : " => " ~ printExpr(*b.value)),
        (const UnitLiteral u) => "()",
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

alias StmtKind = SumType!(VarDecl, AssignStmt, ExprStmt, FunctionDecl, ReturnStmt);

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

/// `return value`. A bare `return` has a UnitLiteral value.
struct ReturnStmt
{
    Expr value;
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
