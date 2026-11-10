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

    this(string name, Type type)
    {
        this.name = name;
        this.type = type;
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

alias ExprKind = SumType!(IntLit, LocalRef, Prim, If, Block);

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
    Greater,
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

alias StmtKind = SumType!(Let);

struct Let
{
    Local local;
    Expr value;
}
