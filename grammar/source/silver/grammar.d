module silver.grammar;

import pegged.grammar;

debug import std.stdio;

mixin(pegged.grammar.grammar(`
Silver:
    Module         < EOL? StatementBlock eoi
    StatementBlock < (Statement EOL)+
    EOL            <: eol+ / eoi

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

    IfStatement < IfBlock ElseIfBlock* ElseBlock? :END
    IfBlock < :IF Expression :THEN EOL StatementBlock
    ElseIfBlock < :ELSE :IF Expression :THEN EOL StatementBlock
    ElseBlock < :ELSE EOL StatementBlock
    
    Expression     < OrExpression
    OrExpression   < AndExpression (OrOperator AndExpression)*
    AndExpression  < EqExpression (AndOperator EqExpression)*
    EqExpression   < AdditionExpression ((EqOperator) AdditionExpression)*
    AdditionExpression < MultiplyExpression (AdditionOperator MultiplyExpression)*
    MultiplyExpression < Unary (MultiplyOperator Unary)*
    Unary          < UnaryOperator? Postfix
    UnaryOperator  < "-" / "!"    

    ReadExpression < READ

    Postfix        < CallExpression / Eval
    CallExpression < Eval CallArgs+
    CallArgs       < :'(' (FunctionParam (:',' FunctionParam)*)? :')'
    FunctionParam  < Expression    

    Eval <  :'(' Expression :')'
        / ReadExpression
        / Literal
        / Variable

    Literal < BooleanLiteral
            / NumberLiteral

    OrOperator <  "||"
    AndOperator < "&&"
    EqOperator <  "==" / "!="
    AdditionOperator <  "+" / "-"
    MultiplyOperator <  "*" / "/" / "%" / "^"

    AssignOp <  "~=" / "+=" / "-=" / "*=" / "^=" / "|=" / "&=" / "/=" / "="

    BooleanLiteral <- TRUE / FALSE

    NumberLiteral <-  ScientificLiteral
                    / HexaLiteral
                    / BinaryLiteral
                    / FloatingLiteral
                    / UnsignedLiteral
                    / IntegerLiteral

    ScientificLiteral <~ (FloatingLiteral / IntegerLiteral) ( ('e' / 'E' ) IntegerLiteral )
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
