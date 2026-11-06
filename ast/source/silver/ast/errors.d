module silver.ast.errors;

/// A stable ID for each kind of diagnostic. The member name is for code; the value is
/// what users see, so it must never change once released, even if the member is renamed.
/// The letter says which phase finds the problem: P parse, L load, S name resolution,
/// T type checking, R runtime, I compiler bug.
enum DiagnosticCode : string
{
    ParseError = "P0001",

    ModuleNotFound = "L0001",
    MissingModuleDeclaration = "L0002",
    ModuleDeclarationMismatch = "L0003",

    DuplicateDeclaration = "S0001",
    UnknownName = "S0002",
    AmbiguousName = "S0003",
    UnknownModuleMember = "S0004",
    ModuleIsNotAValue = "S0005",
    UnknownType = "S0006",
    DuplicateParameter = "S0007",
    MissingMain = "S0008",
    MainInvalidDefinition = "S0009",
    AssignToImmutable = "S0010",
    InvalidAssignmentTarget = "S0011",
    MultipleMains = "S0012",
    ShadowedDeclaration = "S0013",
    TypeEmptyParens = "S0014",
    DuplicateField = "S0015",

    TypeMismatch = "T0001",
    NotCallable = "T0002",
    WrongArgumentCount = "T0003",
    ConditionNotBool = "T0004",
    InvalidOperand = "T0005",
    UnknownMember = "T0006",

    /// A runtime failure nothing has classified yet.
    RuntimeError = "R0001",
    MissingNativeBinding = "R0002",
    DivisionByZero = "R0003",
    InvalidConversion = "R0004",

    /// Something the implementation doesn't handle yet, or a broken invariant.
    InternalError = "I0001",
}

// Two members sharing a code would make the code ambiguous, and `to!string` would
// silently name the first one.
static assert({
    import std.algorithm : canFind;
    import std.traits : EnumMembers;

    string[] seen;
    foreach (code; EnumMembers!DiagnosticCode)
    {
        if (seen.canFind(cast(string) code))
        {
            return false;
        }
        seen ~= code;
    }
    return true;
}(), "Two DiagnosticCode members share a code");
