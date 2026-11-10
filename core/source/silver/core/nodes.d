module silver.core.nodes;

import std.sumtype;
import std.typecons : Rebindable;

import silver.ast : Span;
import silver.sema : Type, TypeTable;

/// A whole program as Core: everything a backend needs, with no AST or Analysis behind it.
struct Program
{
    /// Rebindable so a Program can still be assigned, which a `const` member would prevent.
    Rebindable!(const TypeTable) types;
    Function[] functions;
    /// Where `main` is in `functions`.
    size_t entryPoint;
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

alias ExprKind = SumType!(UnitLit, BoolLit, IntLit, FloatLit, LocalRef, Call, NativeCall, Prim, If, Block, Loop, Break, Continue);

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

/// A call to a `native def`, named as in the source. The runtime's symbol for it adds a suffix
/// for each `Any` parameter, which is the argument's type, so only codegen needs it.
struct NativeCall
{
    string name;
    Expr[] args;
    /// Which of `args` fill an `Any` parameter.
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
