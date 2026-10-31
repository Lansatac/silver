module silver.grammar_tests.cases;

version (unittest):

import silver.grammar_tests.helpers;
import silver.syntax_cases;

mixin GrammarCases!(
    layout, comments,
    literals, radixLiterals, constructors, collectionLiterals,
    operators, precedence, associativity,
    postfix, indexing, optionalChaining,
    ifs, blocks, loops,
    assignments, declarations, uninitializedDeclarations, typeAnnotations, imports,
    functions,
);
