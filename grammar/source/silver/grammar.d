module silver.grammar;

import pegged.grammar;

debug import std.stdio;

mixin(pegged.grammar.grammar(`
Silver:
    Module < StatementBlock eol* eoi

    StatementBlock < Statement (eol Statement)*

    Statement < (
                 / DeclarationStatement
                 / PrintStatement
                 / IfStatement
                 / AssignmentStatement
                 / CallStatement
                )

    DeclarationStatement < :VAR Variable '=' Expression
    AssignmentStatement < AssignTarget '=' Expression

    AssignTarget < Variable

    CallStatement < CallExpression

    PrintStatement < (PRINT / PRINTL) Expression

    IfStatement < IfBlock (eol ElseIfBlock)* (eol ElseBlock)? eol :END
    IfBlock <- :IF Expression :THEN eol StatementBlock
    ElseIfBlock < :ELSE :IF Expression :THEN eol StatementBlock
    ElseBlock <- :ELSE eol StatementBlock
    
    Expression < LogicalExpression /
                 AdditionExpression /
                 MultiplyExpression /
                 Eval

    ReadExpression < READ

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

    BooleanLiteral <- TRUE / FALSE

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

    Kword(K)   <- K !IdentChar

    VAR     <- Kword("var")
    PRINT   <- Kword("print")
    PRINTL  <- Kword("printl")
    IF      <- Kword("if")
    THEN    <- Kword("then")
    ELSE    <- Kword("else")
    END     <- Kword("end")
    TRUE    <- Kword("true")
    FALSE   <- Kword("false")
    READ    <- Kword("read")

    Keyword  <- VAR / PRINTL / PRINT / IF / THEN / ELSE / END / TRUE / FALSE / READ
    IdentChar <- [a-zA-Z0-9_]
    Variable <- !Keyword identifier

    Spacing <- :(' ' / '\t')*
`));
