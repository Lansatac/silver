module silver.ast.nodes;

import std.range : iota;
import std.sumtype;

import silver.ast.span;

import silver.ast.id;

/// The node kinds that get IDs. One NodeIds is shared by every module in a Program.
alias NodeIds = IdSource!(Module, Expr, TypeExpr, VarDecl, Param, FunctionDecl, ImportStmt, TypeDecl, Field, ConstDecl, Pattern, AliasDecl);

/// The types every module can name, which no declaration can take the name of.
enum Builtin
{
    Never, Unit, Bool, Int, Float, String, Any,
    Int8, Int16, Int32, Int64,
    UInt, UInt8, UInt16, UInt32, UInt64,
}

struct Module
{
    Id!Module id;
    string name;
    Span span;
    Decl[] declarations;
    /// null when the file has no `module` line, which only a file that's never imported may omit.
    ModuleDeclaration* declaration;
    /// `native library "name"`, or null.
    NativeLibrary* library;
}

/// `native library "name"`: where every native function in a module is found.
struct NativeLibrary
{
    string name;
    Span span;
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

alias DeclKind = SumType!(ImportStmt, FunctionDecl, TypeDecl, ConstDecl, AliasDecl);

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
    /// Whether each param is `mutable`, or empty when none is.
    bool[] mutableParams;
    TypeExpr* returnType;

    bool isMutable(size_t i) const => mutableParams.length > 0 && mutableParams[i];
}

/// `()`.
struct UnitType
{
}

/// `(Int, String)`, with at least two elements.
struct TupleType
{
    TypeExpr[] elements;
}

alias TypeExprKind = SumType!(OptionType, ArrayType, NamedType, FunctionType, UnitType, TupleType);

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
        (const FunctionType f) => "(" ~ f.params.length.iota.map!(i => (f.isMutable(i) ? "mutable " : "") ~ printTypeExpr(f.params[i])).join(", ") ~ ") -> "
            ~ printTypeExpr(*f.returnType),
        (const UnitType u) => "()",
        (const TupleType t) => "(" ~ t.elements.map!printTypeExpr.join(", ") ~ ")",
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
    SomeExpr, NoneLiteral, PropagateExpr, SafeMemberAccess, ArrayLiteral, MapLiteral, IndexExpr, RangeExpr,
    TupleLiteral, WithExpr, MatchExpr, Lambda);

/// `(x, y) => body`. A `def` inside a block is one of these bound to a local.
struct Lambda
{
    Param[] params;
    /// null when it's inferred.
    TypeExpr* returnType;
    Expr* body;
    /// For a nested `def`, its name and the local it's bound to, which its body can call.
    string name;
    Id!VarDecl self;
}

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
    WrappingAdd = "+%",
    WrappingSubtract = "-%",
    WrappingMultiply = "*%",
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
    /// Whether each argument is written `mutable`, or empty when none is.
    bool[] mutableArgs;

    bool isMutable(size_t i) const => mutableArgs.length > 0 && mutableArgs[i];
}

/// `object with (a = 1, b.c = 2)`.
struct WithExpr
{
    Expr* object;
    FieldUpdate[] updates;
}

/// `b.c = 2` in a `with`.
struct FieldUpdate
{
    string[] path;
    Span span;
    Expr value;
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

/// `(a, b)`, with at least two elements.
struct TupleLiteral
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

/// Where a MatchExpr came from. `if val Literal(text) = p ...` lowers to a match with a `_` arm for
/// its else, so only a written `match` has its arms checked for coverage.
enum MatchOrigin
{
    Match,
    /// An `if val` with an `else`.
    IfValElse,
    /// An `if val` with no `else`, whose value is `()`.
    IfVal,
}

/// `match subject { pattern => body ... }`. Arms are tried in order.
struct MatchExpr
{
    Expr* subject;
    MatchArm[] arms;
    MatchOrigin origin;
}

struct MatchArm
{
    Span span;
    Pattern pattern;
    Expr body;
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
        (const CallExpr c) => format("(call %s%s)", printExpr(*c.callee),
            c.args.length.iota.map!(i => (c.isMutable(i) ? " mutable " : " ") ~ printExpr(c.args[i])).join),
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
        (const TupleLiteral t) => format("(tuple%s)", t.elements.map!(e => " " ~ printExpr(e)).join),
        (const WithExpr w) => format("(with %s%s)", printExpr(*w.object),
            w.updates.map!(u => format(" (%-(%s.%) %s)", u.path, printExpr(u.value))).join),
        (const Lambda l) => format("(lambda (%-(%s %)) %s)", l.params.map!(p => p.name), printExpr(*l.body)),
        (const MatchExpr m) => format("(match %s%s)", printExpr(*m.subject),
            m.arms.map!(a => format(" (%s %s)", printPattern(a.pattern), printExpr(a.body))).join),
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

alias StmtKind = SumType!(VarDecl, AssignStmt, ExprStmt, FunctionDecl, ReturnStmt, BreakStmt, ContinueStmt,
    PatternDecl);

/// The name of a VarDecl that binds nothing: its value is evaluated and dropped, and no name is
/// declared, so any number of them can share a scope.
enum discardName = "_";

struct VarDecl
{
    Id!VarDecl id;
    string name;
    Span nameSpan;
    /// Unused in a Pattern, where the binding holds the part of the PatternDecl's value at its place.
    Expr value;
    /// null when the type isn't annotated.
    TypeExpr* type;
    bool mutable;
}

/// `val (a, b) = value`, which takes `value` apart. Each binding is a VarDecl in `pattern`, which
/// says whether it's mutable.
struct PatternDecl
{
    Pattern pattern;
    Expr value;
}

/// What a value is taken apart by. A PatternDecl only holds bindings and tuples, which match every
/// value of their type; the rest only appear in a `match`. A binding with a type in a `match` tests
/// for that member of a sum.
struct Pattern
{
    Id!Pattern id;
    Span span;
    PatternKind kind;
}

/// `(p, q)`, with at least two elements.
struct TuplePattern
{
    Pattern[] elements;
}

/// `Literal(text)`, or `Red` with no arguments. `type` names a declared type.
struct ConstructorPattern
{
    TypeExpr type;
    Pattern[] arguments;
}

/// `Some(p)`.
struct SomePattern
{
    Pattern* inner;
}

/// `None`.
struct NonePattern
{
}

/// `1`, `"a"` or `true`, which matches a value equal to it.
struct LiteralPattern
{
    Expr* value;
}

alias PatternKind = SumType!(VarDecl, TuplePattern, ConstructorPattern, SomePattern, NonePattern, LiteralPattern);

/// The tuple literal `value` is when `pattern` takes it apart element by element, so each element is
/// bound as its own `val` would be and no tuple is built; null when the whole value is taken apart.
const(TupleLiteral)* elementwise(ref const Pattern pattern, ref const Expr value)
{
    auto count = pattern.kind.match!(
        (ref const TuplePattern tuple) => tuple.elements.length,
        _ => size_t(0),
    );
    if (count == 0) return null;
    return value.kind.match!(
        (ref const TupleLiteral literal) => literal.elements.length == count ? &literal : null,
        _ => cast(const(TupleLiteral)*) null,
    );
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
    bool mutable;
    /// False for a lambda's parameter that takes its type from the context; `type` is unset then.
    bool annotated = true;
}

/// `def name(params): Type => expr` or `def name(params): Type { ... }`.
/// A block body is a BlockExpr, so either way the body is one expression.
/// `native def` and `intrinsic def` have no body.
struct FunctionDecl
{
    Id!FunctionDecl id;
    string name;
    Span nameSpan;
    Param[] params;
    /// null unless the kind is `ordinary`.
    Expr* body;
    TypeExpr returnType;
    FunctionKind kind;
    /// The C symbol a native binds, which is its name unless `native("...")` gives another.
    string symbol;
    bool isPrivate;
}

enum FunctionKind
{
    ordinary,
    /// `native def`, a C function.
    native,
    /// `intrinsic def`, which the compiler implements.
    intrinsic,
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
    /// What a sum type's values can be; empty for any other type. A member the sum declares is its
    /// own TypeDecl in the module, beside this one.
    SumMember[] members;
    /// Declared by being named bare in a sum, with no declaration of that name in the module.
    bool implicitMarker;
    /// On a sum, also set on each member it declares.
    bool isPrivate;
}

/// `alias Name = Type`, a second name for a type. Sema expands it, so the backends never see one.
struct AliasDecl
{
    Id!AliasDecl id;
    string name;
    Span nameSpan;
    /// For an intrinsic alias, a placeholder naming the alias itself, which sema gives the
    /// type the alias stands for on the target.
    TypeExpr target;
    bool isPrivate;
    /// `intrinsic alias Name`, written with no target.
    bool intrinsic;
}

/// One alternative of `type Name = A(x: Int) | B | geo.C`.
struct SumMember
{
    TypeExpr type;
    /// Whether the sum declares this member, rather than naming a type that already exists.
    bool owned;
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
    bool isPrivate;
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
    import std.algorithm : map;
    import std.array : array, join;

    string[] lines;
    if (m.declaration !is null) lines ~= printModuleDeclaration(*m.declaration);
    if (m.library !is null) lines ~= printNativeLibrary(*m.library);
    return (lines ~ m.declarations.map!(printDecl).array).join("\n");
}

string printNativeLibrary(const NativeLibrary library)
{
    return "(native library \"" ~ library.name ~ "\")";
}

string printModuleDeclaration(const ModuleDeclaration d)
{
    import std.array : join;

    return "(module " ~ d.path.join(".") ~ ")";
}

string printDecl(const Decl d)
{
    static string marked(bool isPrivate, string printed) => isPrivate ? "(private " ~ printed ~ ")" : printed;

    return d.kind.match!(
        (const ImportStmt i) => printImport(i),
        (const FunctionDecl f) => marked(f.isPrivate, printFunctionDecl(f)),
        (const TypeDecl t) => marked(t.isPrivate, printTypeDecl(t)),
        (const ConstDecl c) => marked(c.isPrivate, printConstDecl(c)),
        (const AliasDecl a) => marked(a.isPrivate, a.intrinsic
            ? "(intrinsic alias " ~ a.name ~ ")"
            : "(alias " ~ a.name ~ " = " ~ printTypeExpr(a.target) ~ ")"),
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
        (const PatternDecl p) => format("(%s %s %s)", isMutable(p.pattern) ? "mutable val" : "val",
            printPattern(p.pattern), printExpr(p.value)),
    );
}

/// Whether `pattern`'s bindings are mutable, which they all are or none are.
private bool isMutable(const Pattern pattern)
{
    return pattern.kind.match!(
        (const VarDecl v) => v.mutable,
        (const TuplePattern t) => isMutable(t.elements[0]),
        (_) => false,
    );
}

string printPattern(const Pattern pattern)
{
    import std.algorithm : map;
    import std.array : join;

    return pattern.kind.match!(
        (const VarDecl v) => v.name ~ (v.type is null ? "" : ": " ~ printTypeExpr(*v.type)),
        (const TuplePattern t) => "(" ~ t.elements.map!printPattern.join(", ") ~ ")",
        (const ConstructorPattern c) => printTypeExpr(c.type)
            ~ (c.arguments.length > 0 ? "(" ~ c.arguments.map!printPattern.join(", ") ~ ")" : ""),
        (const SomePattern s) => "Some(" ~ printPattern(*s.inner) ~ ")",
        (const NonePattern _) => "None",
        (const LiteralPattern l) => printExpr(*l.value),
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

    final switch (f.kind)
    {
        case FunctionKind.ordinary:
            return format("(def %s %s %s)", f.name, printSignature(f), printExpr(*f.body));
        case FunctionKind.native:
            auto symbol = f.symbol == f.name ? "" : "(\"" ~ f.symbol ~ "\")";
            return format("(native%s def %s %s)", symbol, f.name, printSignature(f));
        case FunctionKind.intrinsic:
            return format("(intrinsic def %s %s)", f.name, printSignature(f));
    }
}

private string printTypeDecl(const TypeDecl t)
{
    import std.algorithm : map;
    import std.array : join;

    if (t.members.length > 0)
    {
        return "(type " ~ t.name ~ " = " ~ t.members.map!(m => printTypeExpr(m.type)).join(" | ") ~ ")";
    }
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

    return "(" ~ f.params.map!(p => (p.mutable ? "mutable " : "") ~ p.name ~ ": " ~ printTypeExpr(p.type)).join(", ") ~ "): "
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
