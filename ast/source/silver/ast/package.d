/// Silver's abstract syntax tree.
///
/// This package must never depend on Pegged (or any parser): the syntax package
/// lowers parse trees into these nodes, and the interpreter, semantic analysis
/// and future compiler only ever see the AST.
module silver.ast;

public import silver.ast.span;
public import silver.ast.diagnostic;
public import silver.ast.nodes;
public import silver.ast.program;
