module silver.grammar;

import pegged.grammar;

debug import std.stdio;

mixin(pegged.grammar.grammar(`
Silver:
    Module < Statement+ eoi

    Statement < (
                 / DeclarationStatement
                 / PrintStatement
                 / IfStatement
                 / AssignmentStatement
                 / CallStatement
                )

    DeclarationStatement < 'var' Variable '=' Expression  ';'
    
    AssignmentStatement < AssignTarget '=' Expression  ';'

    AssignTarget < Variable

    CallStatement < CallExpression ';'

    PrintStatement < ('print' / 'printl') Expression ';'

    IfStatement <- IfBlock (ElseIfBlock)* (ElseBlock)? "end"
    IfBlock <- "if" Expression "then" Statement+
    ElseIfBlock <- "else if" Expression "then" Statement+
    ElseBlock <- "else" Statement+
    
    Expression < LogicalExpression /
                 AdditionExpression /
                 MultiplyExpression /
                 Eval

    ReadExpression < 'read'

    CallExpression < Expression '(' (FunctionParam (:',' FunctionParam)*)? ')'
    FunctionParam < Expression

    LogicalOperator    < "==" / "&&" / "||"
    LogicalExpression  < (AdditionExpression / MultiplyExpression / Eval)
                         (LogicalOperator (AdditionExpression / MultiplyExpression / Eval))+

    AdditionOperator   < "+" / "-"
    AdditionExpression < (MultiplyExpression / Eval)
                         (AdditionOperator (MultiplyExpression / Eval))+

    MultiplyOperator   < "*" / "/"
    MultiplyExpression < Eval
                        (MultiplyOperator Eval)+
    
    Eval <  :'(' Expression :')'
            / ReadExpression
            / CallExpression
            / Literal
            / Variable

    Literal < BooleanLiteral
            / NumberLiteral

    AssignOp <  "~=" / "+=" / "-=" / "*=" / "^=" / "|=" / "&=" / "/=" / "="

    BooleanLiteral <- "true" / "false"

    NumberLiteral <-  ScientificLiteral
                    / FloatingLiteral
                    / UnsignedLiteral
                    / IntegerLiteral
                    / HexaLiteral
                    / BinaryLiteral

    ScientificLiteral <~ FloatingLiteral ( ('e' / 'E' ) IntegerLiteral )
    FloatingLiteral   <~ IntegerLiteral ('.' UnsignedLiteral )
    UnsignedLiteral   <~ [0-9]+
    IntegerLiteral    <~ SignLiteral? UnsignedLiteral
    HexaLiteral       <~ "0x" [0-9a-fA-F]+
    BinaryLiteral     <~ "0b" [01] [01_]*
    SignLiteral       <- '-' / '+'

    Variable <- identifier
`));
