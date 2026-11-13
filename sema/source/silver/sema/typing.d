/// What type checking learned about a program: the side tables lowering reads, by node ID.
module silver.sema.typing;

import silver.ast;
import silver.sema.constant : ConstValue;
import silver.sema.resolve : SymbolId;
import silver.sema.type;

package struct Typing
{
    TypeTable types;
    Type[Id!Expr] exprTypes;
    Type[SymbolId] symbolTypes;
    FieldInfo[][Id!TypeDecl] fields;
    size_t[Id!Expr] fieldIndexes;
    size_t[][][Id!Expr] updatePaths;
    ConstValue[Id!ConstDecl] constants;
    /// Where a value becomes an option, by the option type it's wrapped into.
    Type[Id!Expr] promotions;
    /// For each use of a generic function, by the expression naming it, what its type parameters stand
    /// for, in terms of the type parameters of the function the use is in.
    Type[][Id!Expr] typeArguments;
    const(Expr)[][Id!Expr] concatOperands;
    const(CallExpr)*[Id!Expr] methodCalls;
    Id!FunctionDecl[Id!Expr] methodCallees;
    /// For a `for` over something other than an array or `a..b`, the functions it calls, by the `for`.
    LoopFunctions[Id!Expr] loops;
    /// For each indexing of something other than an array, the functions it calls, by the indexing.
    IndexFunctions[Id!Expr] indexing;
    /// For each overloaded name, the function chosen, by the name's expression.
    SymbolId[Id!Expr] chosenSymbols;
    /// For each call of an overloaded name, the function chosen, by the call.
    Id!FunctionDecl[Id!Expr] chosenCallees;
    /// The functions that share their name with another of their module.
    bool[Id!FunctionDecl] overloaded;
    Type[Id!TypeDecl] nominalTypes;
    /// What each sum's values can be, in declaration order.
    Type[][Id!TypeDecl] members;
    /// For a construction that produces its owner, the member it builds on the way.
    Type[Id!Expr] constructedMembers;
    Type[Id!Pattern] patternSubjects;
    size_t[Id!Pattern] patternMembers;
    /// For a pattern on an error list that reaches through a declared sum the list names, which
    /// member that sum is, and the list. Its `patternSubjects` entry is the sum.
    size_t[Id!Pattern] patternsThrough;
    Type[Id!Pattern] patternListSubjects;
    Id!TypeDecl[Id!Pattern] patternConstructors;
    /// What the invariant of each type that has one gives when it doesn't hold, in terms of the
    /// type's own parameters.
    Type[Id!TypeDecl] invariantErrors;
    /// The fields each invariant's condition names, which change only through `with`.
    string[][Id!TypeDecl] invariantMentions;
    /// For a `with` that checks invariants, the place of each value it checks, as field indexes
    /// from the whole value, longest first. The empty path is the whole value.
    size_t[][][Id!Expr] withChecks;
}

struct FieldInfo { string name; Type type; }

/// A function that syntax calls, such as `for` or `x[i]`, and what its type parameters stand for,
/// in terms of the type parameters of the function the syntax is in.
struct FunctionUse
{
    Id!FunctionDecl func;
    Type[] typeArgs;

    bool found() const => func.isValid;
}

/// How a `for` loops over a value: by index with `length` and `opIndex` when `index` is set, and
/// otherwise by stepping it with `next`.
struct LoopFunctions
{
    FunctionUse length;
    FunctionUse index;
    FunctionUse next;

    bool indexed() const => index.found;
}

/// The functions `x[i]` calls when `x` isn't an array. Any of them can be missing: `read` is
/// `opIndex`, or `opSlice` for `x[a..b]`; `write` is `opIndexAssign`, for an assignment to it or
/// through it; `length` gives a slice its left-out end.
struct IndexFunctions
{
    FunctionUse read;
    FunctionUse write;
    FunctionUse length;
}
