module silver.syntax.grammar_tests.cases;

version (unittest):

import silver.syntax.grammar_tests.helpers;
import silver.syntax.cases;

mixin GrammarCases!(
    layout, comments,
    literals, radixLiterals, constructors, collectionLiterals,
    operators, precedence, associativity,
    postfix, indexing, optionalChaining,
    ifs, blocks, loops,
    assignments, declarations, uninitializedDeclarations, typeAnnotations, imports,
    functions,
);
