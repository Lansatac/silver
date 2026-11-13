/// Semantic analysis. Results live in side tables keyed by node IDs; the AST is
/// never modified.
module silver.sema;

public import silver.sema.analysis;
public import silver.sema.typing : FieldInfo, FunctionUse, IndexFunctions, LoopFunctions, Witness;
public import silver.sema.constant : ConstChar, ConstInt, ConstUInt, ConstUnit, ConstValue;
public import silver.sema.resolve : SymbolId;
public import silver.sema.target;
public import silver.sema.type;
