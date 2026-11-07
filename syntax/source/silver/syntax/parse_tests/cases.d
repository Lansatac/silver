module silver.syntax.parse_tests.cases;

version (unittest):

import silver.syntax.parse_tests.helpers;
import silver.syntax.cases;

// Not yet handled by lower, so grammar only for now: collectionLiterals, indexing.
mixin AstCases!(
    layout, comments,
    literals, stringLiterals, radixLiterals, constructors,
    operators, precedence, associativity,
    postfix, optionalChaining,
    ifs, blocks, loops,
    assignments, declarations, uninitializedDeclarations, typeAnnotations, constantDeclarations, moduleDeclarations, imports,
    functions, typeDeclarations, typeConstruction,
);
