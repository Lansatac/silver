module silver.core.nodes;

import std.sumtype;
import std.typecons : Rebindable;

import silver.ast : Span;
import silver.sema : Intrinsic, Type, TypeTable;

/// A whole program as Core: everything a backend needs, with no AST or Analysis behind it.
struct Program
{
    /// Rebindable so a Program can still be assigned, which a `const` member would prevent.
    Rebindable!(const TypeTable) types;
    Function[] functions;
    /// Where `main` is in `functions`.
    size_t entryPoint;
    /// What `native library` names in the modules whose natives are called, for the linker.
    string[] libraries;
}

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
    /// The module it was declared in, which together with `name` identifies it.
    string moduleName;
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

alias ExprKind = SumType!(UnitLit, BoolLit, IntLit, FloatLit, LocalRef, Call, ForeignCall, IntrinsicCall, Prim, If, Block, Loop, Break, Continue);

/// `()`.
struct UnitLit
{
}

struct BoolLit
{
    bool value;
}

/// An integer of the expression's integer type, which already fits it. A signed value is stored
/// as its 64-bit two's complement, so `-128` as an `Int8` is `cast(ulong) -128L`.
struct IntLit
{
    ulong value;
}

struct FloatLit
{
    double value;
}

struct LocalRef
{
    Local local;
}

/// A call to a Silver function, which `target` indexes in `Program.functions`. An argument for
/// a mutable parameter is a `LocalRef` to a mutable local, which the call writes back to.
struct Call
{
    size_t target;
    Expr[] args;
}

/// A call to a `native def`: the C function `symbol`, through the C calling convention. Every
/// argument is an integer, `Float` or `Bool`, and so is the result, unless it's `Unit` or `Never`.
struct ForeignCall
{
    string symbol;
    Expr[] args;
}

/// A call to an `intrinsic def`, an operation each backend implements itself.
struct IntrinsicCall
{
    Intrinsic intrinsic;
    Expr[] args;
    /// Which of `args` fill an `Any` parameter, so the backend has to look at the argument's type.
    bool[] anyArgs;
}

/// An operation each backend implements itself. Arithmetic is checked, panicking on overflow
/// or division by zero, except for the wrapping forms. A shift's amount, the second argument,
/// can be of any integer type.
enum PrimOp
{
    Add,
    Subtract,
    Multiply,
    Divide,
    Modulo,
    Negate,
    WrappingAdd,
    WrappingSubtract,
    WrappingMultiply,
    BitAnd,
    BitOr,
    BitXor,
    BitNot,
    ShiftLeft,
    ShiftRight,
    /// Comparisons take two arguments of one primitive type.
    Equal,
    NotEqual,
    Less,
    LessEqual,
    Greater,
    GreaterEqual,
    Not,
    /// Two or more Strings, or two or more arrays of one type, joined into a new value.
    Concat,
    /// `xs ~= ys`'s value: like `Concat` of two, but it may extend `xs`'s buffer in place and
    /// leave room to grow.
    Append,
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
