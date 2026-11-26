/// A native's calls as `Program` declares them: the C types of its signature, and the description
/// (`silver.sema.abi`) of what crosses. Both backends follow the description made here.
module silver.core.abi;

import silver.core.nodes : Native, Program;
import silver.sema : Type;
public import silver.sema.abi;

// Joins these with the description of C types the import brings, which a local name would hide.
alias describeCall = silver.sema.abi.describeCall;
alias crossesAlike = silver.sema.abi.crossesAlike;

/// A call of `native`, as it's declared.
CallDescription describeCall(const ref Program program, const ref Native native, Convention convention)
{
    return describeCall(program, native.params, native.result, convention);
}

/// The call of a native taking `params` and returning `result`, which are its Core types as declared.
CallDescription describeCall(const ref Program program, const(Type)[] params, Type result, Convention convention)
{
    CType[] types;
    foreach (param; params) types ~= cTypeOf(program, param);
    return describeCall(types, cTypeOf(program, result), convention);
}

/// Whether calls of `a` and `b` cross alike (`silver.sema.abi.crossesAlike`) under `convention`.
bool crossesAlike(const ref Program program, const ref Native a, const ref Native b, Convention convention)
{
    auto never = program.types.never;
    return crossesAlike(describeCall(program, a, convention), a.result == never,
        describeCall(program, b, convention), b.result == never);
}

/// The C type of `type`, which sema allows in a native's signature or a structure's field.
CType cTypeOf(const ref Program program, Type type)
{
    const(Program)* held = &program;
    return silver.sema.abi.cTypeOf(program.types, type, (Type t) => (t in held.nativeStructures) !is null,
        (Type t) => held.recordFields[t]);
}
