module silver.ast.nodes;

import std.sumtype;

import silver.ast.span;

struct Module
{
    string name;
    Span span;
    Stmt[] statements;
}

struct Expr
{
    Span span;
    ExprKind kind;
}

alias ExprKind = SumType!(BoolLiteral, IntLiteral, FloatLiteral, VariableRef, UnaryExpr, BinaryExpr,
    CallExpr, MemberAccess, ReadExpr, IfExpr, BlockExpr);

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

struct VariableRef
{
    string name;
}

enum AssignOp
{
    Assign,
    AddAssign,
    SubtractAssign,
    MultiplyAssign,
    DivideAssign,
    ModuloAssign,
    PowerAssign,
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

/// The `read` keyword: reads a value from input.
struct ReadExpr
{
}

struct IfExpr
{
    Expr* condition;
    Expr* trueBody;
    Expr* falseBody;
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
        (const VariableRef v) => v.name,
        (const BinaryExpr b) => format("(%s %s %s)", b.op, printExpr(*b.left), printExpr(*b.right)),
        (const UnaryExpr u) => format("(%s %s)", u.op, printExpr(*u.operand)),
        (const CallExpr c) => format("(call %s%s)", printExpr(*c.callee), c.args.map!(a => " " ~ printExpr(a)).join),
        (const MemberAccess m) => format("(. %s %s)", printExpr(*m.object), m.member),
        (const ReadExpr r) => "read",
        (const IfExpr i) => format("(if %s %s %s)", printExpr(*i.condition), printExpr(*i.trueBody), printExpr(*i.falseBody)),
        (const BlockExpr b) => format("(block %s %s)", b.statements.map!(s => printStmt(s)).join, printExpr(*b.returnExpr)),
    );
}

@("Build and match an expression")
unittest
{
    // a + b * 2
    Span span;
    auto a = new Expr(span, ExprKind(VariableRef("a")));
    auto b = new Expr(span, ExprKind(VariableRef("b")));
    auto two = new Expr(span, ExprKind(IntLiteral(2)));
    auto product = new Expr(span, ExprKind(BinaryExpr(BinaryOp.Multiply, b, two)));
    auto sum = Expr(span, ExprKind(BinaryExpr(BinaryOp.Add, a, product)));

    assert(printExpr(sum) == "(Add a (Multiply b 2))");
}

struct Stmt
{
    Span span;
    StmtKind kind;
}

alias StmtKind = SumType!(VarDecl, AssignStmt, ExprStmt, IfStmt, PrintStmt, ImportStmt, FunctionDecl,
    ReturnStmt);

struct PrintStmt
{
    Expr expr;
    bool newline;
}

struct VarDecl
{
    string name;
    Expr value;
    bool mutable;
}

struct AssignStmt
{
    Expr target;
    AssignOp op;
    Expr value;
}

/// An expression evaluated for its effect, e.g. a call.
struct ExprStmt
{
    Expr expr;
}

/// An if statement with optional else-if and else blocks.
struct IfStmt
{
    Expr condition;
    Stmt[] body;
    Stmt[] elseBody;
}

/// `import a.b`; `path` is the dotted name split into parts, e.g. ["a", "b"].
struct ImportStmt
{
    string[] path;
}

struct FunctionDecl
{
    string name;
    string[] params;
    Expr* body;
    string returnType;
}

struct BlockExpr
{
    Stmt[] statements;
    Expr* returnExpr;
}

struct ReturnStmt
{
    Expr value;
}

string printModule(const Module m)
{
    import std.format : format;
    import std.algorithm : map;
    import std.array : join;
    return m.statements.map!(printStmt).join("\n");
}

string printStmt(const Stmt s)
{
    import std.algorithm : map;
    import std.array : join;
    import std.format : format;
    return s.kind.match!(
        (const VarDecl v) => format("(%s %s %s)", v.mutable ? "mutable val" : "val", v.name, printExpr(v.value)),
        (const ExprStmt e) => printExpr(e.expr),
        (const IfStmt i) => format("(if %s (%s) (%s))", printExpr(i.condition), i.body.map!(printStmt).join(" "), i.elseBody.map!(printStmt).join(" ")),
        (const PrintStmt p) => format("(%s %s)", p.newline ? "printl" : "print", printExpr(p.expr)),
        (const AssignStmt a) => format("(assign %s %s %s)", printExpr(a.target), a.op, printExpr(a.value)),
        (const ImportStmt i) => format("(import %s)", i.path.join(".")),
        (const FunctionDecl f) => format("(def %s (%s) : %s %s)", f.name, f.params.join(" "), f.returnType, printExpr(*f.body)),
        (const ReturnStmt r) => format("(return %s)", printExpr(r.value)),
    );
}

@("Build and match a statement")
unittest
{
    Span span;
    auto one = Expr(span, ExprKind(IntLiteral(1)));
    auto decl = Stmt(span, StmtKind(VarDecl("x", one, false)));

    assert(printStmt(decl) == "(val x 1)");
}
