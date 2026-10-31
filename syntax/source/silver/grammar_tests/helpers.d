module silver.grammar_tests.helpers;

version (unittest):

import fluent.asserts;
import silver.grammar;
import silver.syntax_cases.core;

/// Adds one unittest per case in `tables`, checking that the grammar
/// accepts or rejects it. Tests are named `table: source`.
mixin template GrammarCases(tables...)
{
    import silver.grammar_tests.helpers : checkGrammar;
    import silver.syntax_cases.core : caseName;

    static foreach (table; tables)
    {
        static foreach (c; table)
        {
            @(caseName(__traits(identifier, table), c))
            unittest
            {
                checkGrammar(c);
            }
        }
    }
}

/// Failures are reported at the case's line in its table.
void checkGrammar(Case c)
{
    auto tree = Silver(c.source);
    final switch (c.outcome)
    {
    case Outcome.parsesAs:
    case Outcome.accepts:
        should(tree.successful, c.file, c.line).equal(true).because(tree.failMsg);
        break;
    case Outcome.rejects:
        should(tree.successful, c.file, c.line).equal(false);
        break;
    }
}
