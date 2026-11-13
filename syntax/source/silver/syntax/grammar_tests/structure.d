/// Checks on the shape of the parse tree, for syntax `lower` can't handle
/// yet. Once it can, these belong in a cases table instead.
module silver.syntax.grammar_tests.structure;

version (unittest):

import fluent.asserts;
import silver.syntax.grammar;

@("Optional Binds Tighter Than Function Arrow")
unittest
{
    auto type = Silver.decimateTree(Silver.Type("(Int) -> Int?"));
    type.successful.should.equal(true);
    // Type -> OptionalType -> BaseType -> FunctionType; the `?` belongs to the return type
    type[0][0][0].name.should.equal("Silver.FunctionType");
    type.children.length.should.equal(1);
    type[0].children.length.should.equal(1);
}

@("Error Mark Binds Tighter Than Function Arrow")
unittest
{
    auto type = Silver.decimateTree(Silver.Type("(Int) -> Int ! A | B"));
    type.successful.should.equal(true);
    type.children.length.should.equal(1);
    auto ret = type[0][0][0][$ - 1];
    ret.name.should.equal("Silver.Type");
    ret[1].name.should.equal("Silver.ErrorTypes");
    ret[1].children.length.should.equal(2);
}

@("Assert Success Is A Postfix Operator, Not Part Of !=")
unittest
{
    auto postfix = Silver.decimateTree(Silver.Postfix("b!"));
    postfix[1][0].name.should.equal("Silver.AssertSuccess");
    Silver.decimateTree(Silver.Postfix("b!=")).matches.should.equal(["b"]);
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
