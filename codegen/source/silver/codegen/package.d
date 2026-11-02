/// The LLVM backend. `generate` turns an analyzed Program into textual LLVM IR;
/// the toolchain module links that IR and the C runtime into an executable with clang.
module silver.codegen;

public import silver.codegen.gen;
public import silver.codegen.toolchain;
