/// Shared syntax test cases: tables of Silver source and what parsing it should produce, which
/// silver.syntax.parse_tests.cases mixes in.
///
/// A table is an `immutable Case[]` built with parsesAs, accepts and rejects.
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
public import silver.syntax.cases.types;
