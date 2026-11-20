/// What type checking learned about a program: the side tables lowering reads, by node ID.
module silver.sema.typing;

import silver.ast;
import silver.sema.constant : ConstValue;
import silver.sema.resolve : Resolution, SymbolId;
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
    /// What each bound of a type parameter names, in the order written. One that couldn't be
    /// resolved is there too, and isn't `valid`.
    SideTable!(Id!TypeParam, Bound[]) bounds;
    /// What each interface requires, in the order written, in terms of its own type parameters.
    /// One that couldn't be resolved is there too, and isn't `valid`.
    SideTable!(Id!InterfaceDecl, Bound[]) requires;
    /// Every conformance the program declares, by interface, in declaration order.
    SideTable!(Id!InterfaceDecl, Conforming[]) conformances;
    /// What each `if type` asks its type to satisfy, by the `if`: the bounds written, then what
    /// they require, in the order of its functions.
    SideTable!(Id!Expr, Bound[]) testBounds;
    SideTable!(Id!Expr, const(Expr)[]) concatOperands;
    SideTable!(Id!Expr, const(CallExpr)*) methodCalls;
    SideTable!(Id!Expr, Id!FunctionDecl) methodCallees;
    /// For a `for` over something other than an array or `a..b`, the functions it calls, by the `for`.
    SideTable!(Id!Expr, LoopFunctions) loops;
    /// For `<`, `<=`, `>` or `>=` on anything but two numbers, Strings or Chars, `lang`'s
    /// function it calls, by the comparison.
    SideTable!(Id!Expr, FunctionUse) comparisons;
    /// For each call of `derivedCompare`, how it orders its type, by the call.
    SideTable!(Id!Expr, DerivedOrder) derivedOrders;
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

    bool found() const => func.isValid;
}

/// What a `conform` declares for one of its interfaces: `self`, in terms of the type parameters
/// the declaration introduces, which `holder` holds with their `when` bounds, satisfies `bound`
/// through `witnesses`, one for each of the interface's functions.
struct Conforming
{
    Id!ConformDecl decl;
    Bound bound;
    Type self;
    Witness[] witnesses;
    Id!FunctionDecl holder;
    /// The module the declaration is in, where its functions are found.
    string module_;
    /// Where the interface is written in the declaration.
    Span span;
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
struct Witness
{
    Id!FunctionDecl func;
    Type[] typeArgs;
    /// The witnesses its bounds need.
    Witness[] witnesses;
}

/// How a `for` steps a value that isn't an array or an interval: with the `next` of its type's
/// conformance to `Range`.
struct LoopFunctions
{
    FunctionUse next;
}

/// How `derivedCompare` orders two values of a declared type: for a sum, by which member each is,
/// compared as `Int`s with `tags`, and then by `parts`, one for each member in order. A type that
/// isn't a sum has one part.
struct DerivedOrder
{
    FunctionUse tags;
    DerivedPart[] parts;
}

/// One member of a sum, or a whole type that isn't one, as `derivedCompare` orders it: `whole`
/// through the one `compare` of its own conformance, and otherwise field by field, with a
/// `compare` for each.
struct DerivedPart
{
    bool whole;
    FunctionUse[] uses;
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

/// One bound of a type parameter of a generic function, and where the functions it supplies are
/// among the function's (`Resolution.boundFunctions`): `start` to `end`, empty for an interface
/// with no functions.
package struct BoundSlot
{
    Id!TypeParam param;
    size_t bound;
    size_t start;
    size_t end;
}

/// Every bound of every type parameter of `func`, in the order its functions are supplied.
package BoundSlot[] boundSlots(const Resolution resolution, const ref Typing typing, Id!FunctionDecl func)
{
    auto supplied = resolution.boundFunctions.get(func, null);
    BoundSlot[] slots;
    size_t at;
    foreach (param; resolution.typeParamsOf(func))
    {
        foreach (b; 0 .. typing.bounds.get(param.id, null).length)
        {
            auto start = at;
            while (at < supplied.length && resolution.requirements[supplied[at]].param == param.id
                && resolution.requirements[supplied[at]].bound == b) at++;
            slots ~= BoundSlot(param.id, b, start, at);
        }
    }
    assert(at == supplied.length, "every function a bound supplies is in a slot");
    return slots;
}
