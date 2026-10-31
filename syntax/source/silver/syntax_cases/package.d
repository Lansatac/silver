/// Shared syntax test cases: tables of Silver source and what parsing it
/// should produce. The grammar (CST) and AST suites each mix in the tables
/// they want to run; see silver.grammar_tests.cases and silver.parse_tests.cases.
///
/// A table is an `immutable Case[]` built with parsesAs, accepts and rejects.
/// Syntax the grammar accepts but cstToAst can't lower yet goes in its own
/// table, which only the grammar suite includes until lowering lands.
module silver.syntax_cases;

version (unittest):

public import silver.syntax_cases.core;
public import silver.syntax_cases.control_flow;
public import silver.syntax_cases.functions;
public import silver.syntax_cases.layout;
public import silver.syntax_cases.literals;
public import silver.syntax_cases.operators;
public import silver.syntax_cases.postfix;
public import silver.syntax_cases.statements;
