module silver.syntax.parse_tests.cases;

version (unittest):

import silver.syntax.parse_tests.helpers;
import silver.syntax.cases;

// Not yet handled by lower, so grammar only for now: radixLiterals,
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
