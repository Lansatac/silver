/// Shared syntax test cases: tables of Silver source and what parsing it
/// should produce. The grammar (CST) and AST suites each mix in the tables
/// they want to run; see silver.syntax.grammar_tests.cases and silver.syntax.parse_tests.cases.
///
/// A table is an `immutable Case[]` built with parsesAs, accepts and rejects.
/// Syntax the grammar accepts but `lower` can't handle yet goes in its own
/// table, which only the grammar suite includes until lowering lands.
module silver.syntax.cases;

version (unittest):

public import silver.syntax.cases.core;
public import silver.syntax.cases.control_flow;
public import silver.syntax.cases.functions;
public import silver.syntax.cases.layout;
public import silver.syntax.cases.literals;
public import silver.syntax.cases.operators;
public import silver.syntax.cases.postfix;
public import silver.syntax.cases.statements;
