/// Checks on the shape of the parse tree, for syntax cstToAst can't lower
/// yet. Once it can, these belong in a syntax_cases table instead.
module silver.grammar_tests.structure;

version (unittest):

import fluent.asserts;
import silver.grammar;

@("Optional Binds Tighter Than Function Arrow")
unittest
{
    auto type = Silver.decimateTree(Silver.Type("(Int) -> Int?"));
    type.successful.should.equal(true);
    // Type -> BaseType -> FunctionType; the `?` belongs to the return type
    type[0][0].name.should.equal("Silver.FunctionType");
    type.children.length.should.equal(1);
}

@("Empty Map Is Not An Empty List")
unittest
{
    Silver.decimateTree(Silver.CollectionLiteral("[]"))[0].name.should.equal("Silver.ListLiteral");
    Silver.decimateTree(Silver.CollectionLiteral("[:]"))[0].name.should.equal("Silver.MapLiteral");
}

@("Propagate None Is A Postfix Operator")
unittest
{
    auto postfix = Silver.decimateTree(Silver.Postfix("b?"));
    postfix[1].name.should.equal("Silver.PostfixOp");
    postfix[1][0].name.should.equal("Silver.PropagateNone");
}
