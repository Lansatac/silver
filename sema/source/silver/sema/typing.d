/// What type checking learned about a program: the side tables lowering reads, by node ID.
module silver.sema.typing;

import silver.ast;
import silver.sema.constant : ConstValue;
import silver.sema.resolve : SymbolId;
import silver.sema.table : SideTable;
import silver.sema.type;
import silver.sema.table : SideTable;

package struct Typing
{
    TypeTable types;
    SideTable!(Id!Expr, Type) exprTypes;
    SideTable!(SymbolId, Type) symbolTypes;
    SideTable!(Id!TypeDecl, FieldInfo[]) fields;
    SideTable!(Id!Expr, size_t) fieldIndexes;
    SideTable!(Id!Expr, size_t[][]) updatePaths;
    SideTable!(Id!ConstDecl, ConstValue) constants;
    /// Where a value becomes an option, by the option type it's wrapped into.
    SideTable!(Id!Expr, Type) promotions;
    /// For each use of a generic function, by the expression naming it, what its type parameters stand
    /// for, in terms of the type parameters of the function the use is in.
    SideTable!(Id!Expr, Type[]) typeArguments;
    /// For each use of a function with bounds, by the expression naming it, the function found for
    /// each function its bounds declare, in the order of `Resolution.boundFunctions`.
    SideTable!(Id!Expr, Witness[]) witnesses;
    /// For a use inside a generic function of a function that others ask more than, the ones
    /// that could stand in for it there, most demanding first. Each holds only where the
    /// instance's answers to the queries it depends on are there.
    SideTable!(Id!Expr, Witness[]) alternatives;
    /// What each generic function asks of its type parameters beyond its bounds, worked out from
    /// its body. Each query's witnesses follow its bounds' among those of each use of it.
    SideTable!(Id!FunctionDecl, Query[]) queries;
    /// What each bound of a type parameter names, in the order written. One that couldn't be
    /// resolved is there too, and isn't `valid`.
    SideTable!(Id!TypeParam, Bound[]) bounds;
    SideTable!(Id!Expr, const(Expr)[]) concatOperands;
    SideTable!(Id!Expr, const(CallExpr)*) methodCalls;
    SideTable!(Id!Expr, Id!FunctionDecl) methodCallees;
    /// For a `for` over something other than an array or `a..b`, the functions it calls, by the `for`.
    SideTable!(Id!Expr, LoopFunctions) loops;
    /// The `for`s over an `Interval` value, which loop over its bounds as `for` over `a..b` does.
    SideTable!(Id!Expr, bool) intervalLoops;
    /// For each indexing of something other than an array, the functions it calls, by the indexing.
    SideTable!(Id!Expr, IndexFunctions) indexing;
    /// For each overloaded name, the function chosen, by the name's expression.
    SideTable!(Id!Expr, SymbolId) chosenSymbols;
    /// For each call of an overloaded name, the function chosen, by the call.
    SideTable!(Id!Expr, Id!FunctionDecl) chosenCallees;
    /// The functions that share their name with another of their module.
    SideTable!(Id!FunctionDecl, bool) overloaded;
    SideTable!(Id!TypeDecl, Type) nominalTypes;
    /// What each sum's values can be, in declaration order.
    SideTable!(Id!TypeDecl, Type[]) members;
    /// For a construction that produces its owner, the member it builds on the way.
    SideTable!(Id!Expr, Type) constructedMembers;
    SideTable!(Id!Pattern, Type) patternSubjects;
    SideTable!(Id!Pattern, size_t) patternMembers;
    /// For a pattern on an error list that reaches through a declared sum the list names, which
    /// member that sum is, and the list. Its `patternSubjects` entry is the sum.
    SideTable!(Id!Pattern, size_t) patternsThrough;
    SideTable!(Id!Pattern, Type) patternListSubjects;
    SideTable!(Id!Pattern, Id!TypeDecl) patternConstructors;
    /// What the invariant of each type that has one gives when it doesn't hold, in terms of the
    /// type's own parameters.
    SideTable!(Id!TypeDecl, Type) invariantErrors;
    /// The fields each invariant's condition names, which change only through `with`.
    SideTable!(Id!TypeDecl, string[]) invariantMentions;
    /// For a `with` that checks invariants, the place of each value it checks, as field indexes
    /// from the whole value, longest first. The empty path is the whole value.
    SideTable!(Id!Expr, size_t[][]) withChecks;
}

struct FieldInfo { string name; Type type; }

/// A function that syntax calls, such as `for` or `x[i]`, and what its type parameters stand for,
/// in terms of the type parameters of the function the syntax is in.
struct FunctionUse
{
    Id!FunctionDecl func;
    Type[] typeArgs;
    Witness[] witnesses;
    /// As `Typing.alternatives` for a use by name.
    Witness[] alternatives;

    bool found() const => func.isValid;
}

/// An interface with its type arguments, as a bound names it.
struct Bound
{
    Id!InterfaceDecl decl;
    Type[] args;

    bool valid() const => decl.isValid;
}

/// The function found for a function that a bound declares: which one, what its type parameters
/// stand for, and the witnesses its own bounds need, all in terms of the function the search was
/// made in. When `func` is one a bound of that function supplies, it stands for whichever function
/// the instance being compiled was given for it.
///
/// A witness can depend on the answers to a function's queries. One with a `slot` stands for the
/// instance's witness there, which may be absent. Otherwise it holds when its bounds' witnesses
/// do, and `alternatives`, tried first, are more demanding functions that fit where the answers
/// they depend on are there. One with neither a function nor a slot never holds by itself.
struct Witness
{
    Id!FunctionDecl func;
    Type[] typeArgs;
    /// The witnesses its bounds need, then the answers to its queries.
    Witness[] witnesses;
    size_t slot = size_t.max;
    Witness[] alternatives;

    bool isSlot() const => slot != size_t.max;
}

/// A question a generic function asks about a type made from its type parameters: whether the
/// functions in `requests` can be called on it. It has a witness for each, all there or none.
struct Query
{
    /// The interface asked about, or none for what `for` needs to loop by index.
    Id!InterfaceDecl decl;
    Type self;
    Type[] args;
    Request[] requests;
    /// The function whose body asks it first, which an error about the answer names.
    Id!FunctionDecl asker;
}

/// A function a query asks for: its name, and its type as a call would need it.
struct Request
{
    string name;
    Type wanted;
}

/// How a `for` loops over a value: by index with `length` and `opIndex` when `index` is set, and
/// otherwise by stepping it with `next`.
struct LoopFunctions
{
    FunctionUse length;
    FunctionUse index;
    FunctionUse next;
    /// For one that steps, `length` and `opIndex` where they hold for the instance's types, so it
    /// loops by index there instead. Empty, or both.
    Witness[] indexedIf;

    bool indexed() const => index.found;
}

/// The functions `x[i]` calls when `x` isn't an array. Any of them can be missing: `read` is
/// `opIndex`, which `x[a..b]` calls too; `write` is `opIndexAssign`, for an assignment to it or
/// through it; `length` gives a slice its left-out end.
struct IndexFunctions
{
    FunctionUse read;
    FunctionUse write;
    FunctionUse length;
}
