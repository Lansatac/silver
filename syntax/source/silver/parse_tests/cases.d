module silver.parse_tests.cases;

version (unittest):

import silver.parse_tests.helpers;
import silver.syntax_cases;

// Not yet lowered by cstToAst, so grammar only for now: radixLiterals,
// constructors, collectionLiterals, indexing, optionalChaining,
// uninitializedDeclarations.
mixin AstCases!(
    layout, comments,
    literals,
    operators, precedence, associativity,
    postfix,
    ifs, blocks, loops,
    assignments, declarations, typeAnnotations, imports,
    functions,
);
