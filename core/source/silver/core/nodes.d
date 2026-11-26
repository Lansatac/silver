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
    /// Each native type with no fields the program uses. A value of one is a pointer that a library owns.
    bool[Type] nativeTypes;
    /// Each native type with fields the program uses, which crosses into C as a structure. It's a
    /// product otherwise, with its fields in `recordFields`.
    bool[Type] nativeStructures;
    /// Each C function the program calls, once for each symbol, library and declared signature, which a
    /// `ForeignCall` indexes. The natives that bind one symbol all pass the same C types.
    Native[] natives;
    /// When the program is run for its tests, those tests in the order written, and `entryPoint`
    /// is unused.
    TestCase[] tests;
}

/// A C function a `native def` binds, as it's declared.
struct Native
{
    string symbol;
    /// What the native's module names in `native library`, or null when it has none.
    string library;
    /// The parameter types as declared, which an argument of type `Never` doesn't have, and the result
    /// type: what `describeCall` says crosses how.
    const(Type)[] params;
    Type result;
    /// The first call of it, or the first use of it as a value, for an error saying it can't be found.
    Span span;
}

/// A `test`, which is a function in `Program.functions` taking nothing and returning Unit.
struct TestCase
{
    string name;
    size_t function_;
    Span span;
}

/// A variable. It has an identity of its own because lowering invents temporaries that no
/// `val` in the source stands behind.
final class Local
{
    string name;
    Type type;
    bool mutable;
    /// Which of its function's locals it is, counting params, then captures, then each `Let`: a
    /// backend can keep a call's locals in an array of the function's `localCount`.
    size_t slot;

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
    /// How a function value of it prints: `identity<Int>`, `Point`, `lambda`.
    string printedName;
    /// For a lambda with captures, the derived function telling whether two closures of it hold
    /// equal captures, as `(a: F, b: F): Bool` reading them with `Capture`. `noFunction` when
    /// nothing is captured, or the program compares no function values.
    size_t captureEquality = noFunction;
    /// Likewise, the derived function hashing a closure's captures, as `(f: F): UInt` reading them
    /// with `Capture`. `noFunction` when nothing is captured, or the program hashes no function values.
    size_t captureHash = noFunction;
    /// How many locals it has, each with its own `Local.slot` below this.
    size_t localCount;
}

/// A `Function.captureEquality` or `captureHash` that there isn't.
enum size_t noFunction = size_t.max;

enum FunctionOrigin
{
    /// A `def` at module level.
    declared,
    /// A lambda or nested `def`, lifted out of the function it was written in. It's only called
    /// through a closure, which carries its captures.
    lambda,
    /// Made up by lowering: structural equality, hashing, formatting, or a constructor or native
    /// used as a value.
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
    Inject, IsMember, Payload, ArrayLit, Index, Slice, Length, Cell, Capture, TestFailure);

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

/// A call to a `native def`: the C function `Program.natives[native]`, through the C calling
/// convention, as `describeCall` describes it. Every argument is an integer, `Float`, `Float32`,
/// `Bool`, native type or option of a native type with no fields, and so is the result, unless it's
/// `Unit` or `Never`. An option of a native type crosses as a pointer, `None` being null, and a native
/// type with fields as a C structure.
struct ForeignCall
{
    size_t native;
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
    /// Comparisons take two arguments of one primitive type. `Equal` and `NotEqual` also take two
    /// `Ref`s, equal when they're the same cell, two values of a native type, equal when they're the
    /// same address, and two function values, equal when they're
    /// closures of the same function and its `captureEquality`, if it has one, says so.
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
    /// An integer, `Float`, `Bool` or function value as a String, the way `print` shows it: a
    /// function value as its function's `printedName`. A value of a native type is its address, as
    /// `0x` and lowercase hex digits.
    Format,
    /// An integer, `Float`, `Bool`, `Char`, String, `Ref`, native type or function value as a `UInt`
    /// hash, with its bits mixed. `0.0` and `-0.0` hash alike. A `Ref` hashes by which cell it is, a
    /// native type by its address, and a
    /// function value by its function and, when that has a `captureHash`, what it gives.
    Hash,
    /// How many bits of a `UInt` are set, as an `Int`.
    CountOnes,
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

/// Capture `index` of `closure`, a function value that is a closure of the lambda `target`.
struct Capture
{
    Expr* closure;
    size_t target;
    size_t index;
}

/// A failure of the running test, with `message`, a String that already says where it happened.
/// With `ends`, it stops the test, and is `Never`; otherwise the test carries on, and it's Unit.
/// Only a test reaches one.
struct TestFailure
{
    Expr* message;
    bool ends;
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

alias StmtKind = SumType!(Let, Assign, AssignElement, Eval);

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

/// Gives a mutable `Local`, an array, its array with element `index` replaced by `value`,
/// panicking if there's no such element. `index`, of any integer type, is evaluated first, then
/// `value`, then the local is read. No other value holding the old array sees the change; both
/// backends copy the array for now, since nothing yet says when it's held only by the local.
struct AssignElement
{
    Local local;
    Expr index;
    Expr value;
}

/// Evaluates `expr` and drops its value.
struct Eval
{
    Expr expr;
}
