/// The LLVM backend. `generate` turns a Core program into textual LLVM IR;
/// the toolchain module links that IR and the runtime into an executable.
module silver.codegen;

public import silver.codegen.gen;
public import silver.codegen.toolchain;
