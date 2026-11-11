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
    Id!TypeDecl[Id!Pattern] patternConstructors;
}

struct FieldInfo { string name; Type type; }
