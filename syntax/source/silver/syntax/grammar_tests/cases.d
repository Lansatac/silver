module silver.syntax.grammar_tests.cases;

version (unittest):

import silver.syntax.grammar_tests.helpers;
import silver.syntax.cases;

mixin GrammarCases!(
    layout, continuations, comments,
    literals, stringLiterals, radixLiterals, constructors, collectionLiterals, tupleLiterals,
    operators, precedence, associativity,
    postfix, indexing, optionalChaining,
    ifs, blocks, loops,
    discards, assignments, destructuring, declarations, uninitializedDeclarations, typeAnnotations, constantDeclarations, moduleDeclarations, imports,
    functions, typeDeclarations, typeConstruction, tupleTypes, sumDeclarations, matches,
);
