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
    /// A module named as part of `lang` that isn't the compiler's own file of that name.
    NotInLang = "L0004",
    /// An import, in a module of `lang`, of a module outside it.
    LangImportsOutside = "L0005",
    /// A companion test file, `name.test.ag`, started from as a program, or with no `name.ag`.
    CompanionStarted = "L0006",
    /// Something in a companion test file that only its module can have.
    NotInCompanion = "L0007",
    /// A conformance in a module that's in the program only because a companion test file reaches it.
    TestOnlyConformance = "L0008",
    /// A file that exists and can't be read as text.
    UnreadableFile = "L0009",
    /// An import of a module in a package that the importing module's package doesn't list.
    ImportOutsideUses = "L0010",
    /// A package that lists a program among what it uses.
    UsesProgram = "L0011",
    /// Packages whose lists of what they use form a cycle.
    PackageCycle = "L0012",
    /// A description of the packages that can't be followed, as a list naming an unknown package.
    InvalidPackages = "L0013",
    /// A package asked for its program that has none: no module of it or of the packages it describes declares `main`.
    NoProgram = "L0014",
    /// A package asked for its program that holds more than one, between itself and the packages it describes.
    SeveralPrograms = "L0015",
    /// A package asked for its program that has more than one module declaring `main`.
    SeveralMains = "L0016",
    /// One `native library` name given different files by the packages of two modules of one program.
    NativeFilesDisagree = "L0017",

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
    MissingConstantType = "S0016",
    InvalidConstantType = "S0017",
    JumpOutsideLoop = "S0018",
    CapturedMutable = "S0019",
    PrivateMember = "S0020",
    PrivateTypeExposed = "S0021",
    RecursiveAlias = "S0022",
    AliasIsNotAValue = "S0023",
    IntrinsicOutsideLang = "S0024",
    /// An `intrinsic def` or `intrinsic alias` the compiler doesn't implement.
    UnknownIntrinsic = "S0025",
    /// An interface named where a type is wanted.
    InterfaceIsNotAType = "S0026",
    /// A type named where a bound wants an interface.
    NotAnInterface = "S0027",
    /// A cycle of forward imports that never settles on what a module passes on by a name.
    ForwardCycle = "S0028",
    /// A `conform` whose type is one of the type parameters it introduces.
    ConformsTypeParameter = "S0029",
    /// An interface that requires itself, directly or through others.
    RequiresItself = "S0030",
    /// A `when` bound on a name that isn't a type parameter its conformance introduces.
    UnknownWhenParameter = "S0031",
    /// An `if type` on a type that isn't a type parameter of the function it's in.
    TestsNonParameter = "S0032",
    /// A function in a companion test file named like one of its module's own.
    CompanionOverload = "S0033",

    TypeMismatch = "T0001",
    NotCallable = "T0002",
    WrongArgumentCount = "T0003",
    InvalidOperand = "T0005",
    UnknownMember = "T0006",
    LiteralOutOfRange = "T0007",
    NonConstantInitializer = "T0008",
    ConstantCycle = "T0009",
    ConstantEvaluationFailed = "T0010",
    UntypedNone = "T0011",
    InvalidPropagation = "T0012",
    InvalidOptionPayload = "T0013",
    InvalidArrayElement = "T0014",
    UntypedEmptyArray = "T0015",
    /// Syntax with a decided future that sema can't give a meaning to yet.
    NotSupportedYet = "T0016",
    UnusedValue = "T0017",
    InvalidTupleElement = "T0018",
    PatternMismatch = "T0019",
    MutabilityMismatch = "T0020",
    /// Two `mutable` arguments of one call, or two updates of one `with`, that reach the same place.
    OverlappingWrites = "T0021",
    MutableNativeParameter = "T0022",
    InvalidSumMember = "T0023",
    NonExhaustiveMatch = "T0024",
    UnreachableArm = "T0025",
    UntypedLambdaParameter = "T0026",
    UninhabitedType = "T0027",
    /// A type in a native's signature that has no C equivalent.
    InvalidNativeType = "T0028",
    /// Type arguments that don't fit what they're given to: too many or too few, or any at all.
    WrongTypeArgumentCount = "T0029",
    InvalidTypeArgument = "T0030",
    CannotInferTypeArgument = "T0031",
    /// Something generic code can't do with a value whose type mentions a type parameter.
    OpaqueTypeParameter = "T0032",
    /// A call or function value that none of the functions of its name fits.
    NoMatchingOverload = "T0033",
    /// A call or function value that more than one function of its name fits equally well.
    AmbiguousOverload = "T0034",
    /// Two functions of one name in a module that a call couldn't tell apart.
    DuplicateOverload = "T0035",
    /// `expect` outside a test.
    ExpectOutsideTest = "T0037",
    /// An error list that repeats a type or lists one that can't be an error.
    InvalidErrorType = "T0038",
    /// `Ok(x)` or `Error(e)` where nothing says which error union it is.
    UntypedErrorUnion = "T0039",
    /// `panics` outside a test.
    PanicsOutsideTest = "T0041",
    /// A bound where there can't be one, or an interface declared in a way the language doesn't allow.
    InvalidBound = "T0042",
    /// A type argument that doesn't satisfy a bound, or a result or value whose type doesn't
    /// satisfy the interface written for it.
    UnsatisfiedBound = "T0043",
    /// A search for a conformance that keeps needing a larger one.
    BoundSearchTooDeep = "T0044",
    /// A result type that's worked out from a body which needs it already.
    RecursiveResultType = "T0045",
    /// A lambda written as an operand of `==` or `!=`, or in a value one builds, which can't be
    /// equal to the other side.
    LambdaInComparison = "T0047",
    /// A generic type or function that needs itself at ever larger type arguments, so it would
    /// need endlessly many instances.
    PolymorphicRecursion = "T0048",
    /// A constructor pattern of a generic type without type arguments, on a value that can be
    /// more than one instance of it.
    AmbiguousInstance = "T0049",
    /// A value where an error union is expected that is one of its errors and could also become
    /// its success, so it has to be written as `Error(...)` or `Ok(...)`.
    ErrorOrSuccess = "T0050",
    /// A conformance for which a function of the interface isn't found, or doesn't return what it has to.
    UnmetConformance = "T0051",
    /// A conformance to an interface that requires another the type has no conformance to.
    MissingRequiredConformance = "T0052",
    /// Two conformances that could apply to the same type and interface.
    OverlappingConformance = "T0053",
    /// An `opEquals`, `opHash` or `opString` that isn't its type's module's, hasn't the shape, or is
    /// an `opEquals` without an `opHash` or the reverse.
    InvalidTypeFunction = "T0054",
    /// A dictionary literal with the same constant written as two of its keys.
    RepeatedKey = "T0055",
    /// An arithmetic or bitwise operator function whose parameters are all built-in numbers, which the
    /// operator does itself.
    InvalidOperatorFunction = "T0056",
    /// Two natives that bind one C symbol with signatures C passes differently.
    NativeSymbolMismatch = "T0057",

    /// A runtime failure nothing has classified yet.
    RuntimeError = "R0001",
    MissingNativeBinding = "R0002",
    DivisionByZero = "R0003",
    InvalidConversion = "R0004",
    IntegerOverflow = "R0005",
    InvalidShift = "R0006",
    IndexOutOfRange = "R0007",
    /// The program called `panic`.
    ExplicitPanic = "R0008",
    StackOverflow = "R0009",
    /// A `Ref` used from inside its own `update`.
    RefInUpdate = "R0010",
    /// The program needed more memory than there is.
    OutOfMemory = "R0011",

    /// Something the implementation doesn't handle yet, or a broken invariant.
    InternalError = "I0001",
    /// A construct that lowering to Core, or a backend running Core, doesn't handle yet.
    NotImplemented = "I0002",
    /// Generic instances whose type arguments keep growing, as polymorphic recursion makes.
    InstanceNestingTooDeep = "I0003",
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
