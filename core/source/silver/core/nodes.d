module silver.core.nodes;

import std.sumtype;

import silver.ast : Span;
import silver.sema : Type;

/// A variable. It has an identity of its own because lowering invents temporaries that no
/// `val` in the source stands behind.
final class Local
{
    string name;
    Type type;
    bool mutable;

    this(string name, Type type, bool mutable = false)
    {
        this.name = name;
        this.type = type;
        this.mutable = mutable;
    }
}

struct Function
{
    string name;
    Local[] params;
    Type returnType;
    Expr body;
}

struct Expr
{
    Type type;
    Span span;
    ExprKind kind;
}

alias ExprKind = SumType!(UnitLit, BoolLit, IntLit, LocalRef, Prim, If, Block, Loop, Break, Continue);

/// `()`.
struct UnitLit
{
}

struct BoolLit
{
    bool value;
}

struct IntLit
{
    ulong value;
}

struct LocalRef
{
    Local local;
}

/// An operation each backend implements itself.
enum PrimOp
{
    Add,
    Less,
    Greater,
    Equal,
    Not,
}

struct Prim
{
    PrimOp op;
    Expr[] args;
}

struct If
{
    Expr* condition;
    Expr* trueBody;
    Expr* falseBody;
}

/// Runs `body` until a `Break` leaves it. Every kind of source loop becomes one of these.
struct Loop
{
    Expr* body;
}

/// Leaves the innermost `Loop`. Type `Never`, so it can be an `If` arm.
struct Break
{
}

/// Starts the innermost `Loop`'s body again. Type `Never`.
struct Continue
{
}

struct Block
{
    Stmt[] statements;
    /// Null when the block has no value.
    Expr* result;
}

struct Stmt
{
    Span span;
    StmtKind kind;
}

alias StmtKind = SumType!(Let, Assign, Eval);

struct Let
{
    Local local;
    Expr value;
}

/// Sets a mutable `Local`.
struct Assign
{
    Local local;
    Expr value;
}

/// Evaluates `expr` and drops its value.
struct Eval
{
    Expr expr;
}
