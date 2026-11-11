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
    /// The field types, in order, of every declared type that isn't a sum and that the program
    /// uses. A marker has none.
    const(Type)[][Type] recordFields;
    /// What each sum the program uses can be, in order, which is what a tag indexes. An option
    /// isn't here: it has two members, `None` (0) with no payload and `Some` (1).
    const(Type)[][Type] sumMembers;
    /// What each `Ref` type the program uses holds.
    Type[Type] cellContents;
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
    /// The module it was written in. With `name`, it identifies a `declared` function; other
    /// kinds can share a name.
    string moduleName;
    Local[] params;
    /// For a lambda, the values its closure carries, which its body reads like params.
    Local[] captures;
    Type returnType;
    Expr body;
    FunctionOrigin origin;
}

enum FunctionOrigin
{
    /// A `def` at module level.
    declared,
    /// A lambda or nested `def`, lifted out of the function it was written in. It's only called
    /// through a closure, which carries its captures.
    lambda,
    /// Made up by lowering: structural equality, formatting, or a constructor or native used as
    /// a value.
    derived,
}

struct Expr
{
    Type type;
    Span span;
    ExprKind kind;
}

alias ExprKind = SumType!(UnitLit, BoolLit, IntLit, FloatLit, StringLit, LocalRef, Call, CallClosure, MakeClosure,
    ForeignCall, IntrinsicCall, Prim, Convert, If, Block, Loop, Break, Continue, Return, Construct, Field, Update,
    Inject, IsMember, Payload, ArrayLit, Index, Slice, Length, Cell);

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

struct StringLit
{
    string value;
}

struct LocalRef
{
    Local local;
}

/// A call to a Silver function, which `target` indexes in `Program.functions`. An argument for
/// a mutable parameter is a `LocalRef` to a mutable local, which the call writes back to; it's
/// read when the call starts, after every other argument has been evaluated.
struct Call
{
    size_t target;
    Expr[] args;
}

/// A call through `callee`, a function value. Arguments for mutable parameters are as for `Call`.
struct CallClosure
{
    Expr* callee;
    Expr[] args;
}

/// A function value: `target` with the values its `captures` take, in order. Only a lambda has
/// captures.
struct MakeClosure
{
    size_t target;
    Expr[] captures;
}

/// A call to a `native def`: the C function `symbol`, through the C calling convention. Every
/// argument is an integer, `Float` or `Bool`, and so is the result, unless it's `Unit` or `Never`.
struct ForeignCall
{
    string symbol;
    Expr[] args;
}

/// A call to an `intrinsic def`, an operation each backend implements itself. `print` and
/// `printl` only take a primitive: lowering formats anything else to a String first.
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
    /// An integer, `Float` or `Bool` as a String, the way `print` shows it. A function value too,
    /// as its name, where the backend can.
    Format,
}

struct Prim
{
    PrimOp op;
    Expr[] args;
}

/// A number converted to the expression's numeric type, panicking if the value doesn't fit. A
/// Float is truncated toward zero first.
struct Convert
{
    Expr* value;
}

struct If
{
    Expr* condition;
    Expr* trueBody;
    Expr* falseBody;
}

/// Runs `body` until a `Break` leaves it. Every kind of source loop becomes one of these.
/// `label` is unique within the function, and names it for `Break` and `Continue`, which can
/// leave a loop other than the innermost: a `break` in a `while` condition is the enclosing
/// loop's, though Core evaluates the condition inside the `while`'s own loop.
struct Loop
{
    Expr* body;
    size_t label;
}

/// Leaves the `Loop` named `label`. Type `Never`, so it can be an `If` arm.
struct Break
{
    size_t label;
}

/// Starts the body of the `Loop` named `label` again. Type `Never`.
struct Continue
{
    size_t label;
}

/// Leaves the function with `value`, whose type is the function's return type. Type `Never`.
struct Return
{
    Expr* value;
}

/// A tuple, or a value of a declared type that isn't a sum, from its fields in order.
struct Construct
{
    Expr[] fields;
}

/// Field `index` of a tuple or of a value of a declared type.
struct Field
{
    Expr* object;
    size_t index;
}

/// A copy of `object`, a tuple or a value of a declared type, with field `index` replaced by `value`.
struct Update
{
    Expr* object;
    size_t index;
    Expr* value;
}

/// A value of the sum or option that is the expression's type: member `member`, holding
/// `payload`, whose type is the member's. Null only for an option's `None`.
struct Inject
{
    size_t member;
    Expr* payload;
}

/// Whether `subject`, a sum or option, is member `member`. Type `Bool`.
struct IsMember
{
    Expr* subject;
    size_t member;
}

/// What `subject`, a sum or option, holds as member `member`, which it must be.
struct Payload
{
    Expr* subject;
    size_t member;
}

/// `[a, b]`, of the expression's array type.
struct ArrayLit
{
    Expr[] elements;
}

/// Element `index` of an array, panicking if there's no such element. The index can be of any
/// integer type.
struct Index
{
    Expr* array;
    Expr* index;
}

/// The elements of an array from `start` up to `end`, panicking unless
/// `start <= end <= length`. The bounds can be of any integer type.
struct Slice
{
    Expr* array;
    Expr* start;
    Expr* end;
}

/// How many elements an array has, as an `Int`.
struct Length
{
    Expr* array;
}

/// What a `Ref` is: a place on the heap holding a value, which every copy of the `Ref` shares. A
/// cell is empty while `update` runs, and using it then panics, except to `Fill` it.
enum CellOp
{
    /// A new cell holding the argument, of the expression's `Ref` type.
    New,
    /// What the cell holds.
    Get,
    /// Replaces what the cell holds with the second argument, which is evaluated first. Type `Unit`.
    Set,
    /// What the cell holds, leaving it empty.
    Take,
    /// Puts the second argument in the cell, which is empty. Type `Unit`.
    Fill,
}

/// An operation on a cell, the first argument except for `New`.
struct Cell
{
    CellOp op;
    Expr[] args;
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
