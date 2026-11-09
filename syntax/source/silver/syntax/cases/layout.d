module silver.syntax.cases.layout;

version (unittest):

import silver.syntax.cases.core;

/// Statement separators, blank lines and whitespace.
immutable Case[] layout = [
    parsesAs("print(a)", "(call print a)"),
    parsesAs("mutable val a = 0\n    print(a)", ["(mutable val a 0)", "(call print a)"]),
    rejects("mutable val a = 0 print(a)"), // two statements need a separator
    parsesAs("mutable val a = 1; print(a)", ["(mutable val a 1)", "(call print a)"]),
    parsesAs("if true { a = 1; print(a) }", "(if true (block (assign a 1) => (call print a)))"),

    parsesAs("mutable val a = 1\n\n", "(mutable val a 1)"),
    parsesAs("\nmutable val a = 1", "(mutable val a 1)"),
    parsesAs("mutable val a = 1\n\nprint(a)", ["(mutable val a 1)", "(call print a)"]),
    parsesAs("mutable val a = 1\n\n\nprint(a)", ["(mutable val a 1)", "(call print a)"]),

    // Escaped so editors don't strip the trailing spaces
    parsesAs("if true {  \n    print(1)\n}", "(if true (block => (call print 1)))"),
    parsesAs("if true {\n    print(1)\n} else {  \n    print(2)\n}",
        "(if true (block => (call print 1)) (block => (call print 2)))"),
];

/// Where a newline is whitespace: the token before it can't end a statement, or the one after it
/// can't begin one.
immutable Case[] continuations = [
    // After an operator or anything else that can't end a statement.
    parsesAs("a = 1 +\n    2", "(assign a (Add 1 2))"),
    parsesAs("a = 1 -\n    2", "(assign a (Subtract 1 2))"),
    parsesAs("a = b ~\n    c", "(assign a (Concat b c))"),
    parsesAs("a = b ||\n\n    // why\n    c", "(assign a (Or b c))"),
    parsesAs("a = -\n    b", "(assign a (Minus b))"),
    parsesAs("a =\n    1", "(assign a 1)"),
    parsesAs("a +=\n    1", "(assign a (Add a 1))"),
    parsesAs("val a =\n    1", "(val a 1)"),
    parsesAs("val a:\n    Int = 1", "(val a: Int 1)"),
    parsesAs("mutable\nval\na = 1", "(mutable val a 1)"),
    parsesAs("a = b.\n    c", "(assign a (. b c))"),
    parsesAs("a = b?.\n    c", "(assign a (?. b c))"),
    parsesAs("a = b ??\n    c", "(assign a (Coalesce b c))"),
    parsesAs("val f: (Int) ->\n    Int = g", "(val f: (Int) -> Int g)"),

    // Before anything that can't begin a statement.
    parsesAs("a = b\n    .c\n    .d()", "(assign a (call (. (. b c) d)))"),
    parsesAs("a = b\n    // why\n    ?.c", "(assign a (?. b c))"),
    parsesAs("a = b\n    ?", "(assign a (? b))"),
    parsesAs("a = b\n    ?? c", "(assign a (Coalesce b c))"),
    parsesAs("a = b\n    && c\n    || d", "(assign a (Or (And b c) d))"),
    parsesAs("a = 1\n    + 2\n    * 3", "(assign a (Add 1 (Multiply 2 3)))"),
    parsesAs("a = 4\n    / 2\n    % 3", "(assign a (Modulo (Divide 4 2) 3))"),
    parsesAs("a = 1\n    == 2", "(assign a (Equal 1 2))"),
    parsesAs("a = 1\n    != 2", "(assign a (NotEqual 1 2))"),
    parsesAs("a = 1\n    <= 2", "(assign a (LessEqual 1 2))"),
    parsesAs("a = 1\n    > 2", "(assign a (Greater 1 2))"),
    parsesAs("a = 1\n    << 2", "(assign a (ShiftLeft 1 2))"),
    parsesAs("a = 1\n    | 2\n    ^ 3\n    & 4", "(assign a (BitOr 1 (BitXor 2 (BitAnd 3 4))))"),
    parsesAs("a = 1\n    +% 2\n    -% 3", "(assign a (WrappingSubtract (WrappingAdd 1 2) 3))"),
    parsesAs("a = xs[1\n    .. 2]", "(assign a (index xs (.. 1 2)))"),
    parsesAs("a\n    = 1", "(assign a 1)"),
    parsesAs("a\n    ~= b", "(assign a (Append a b))"),
    parsesAs("val a\n    = 1", "(val a 1)"),
    parsesAs("val a\n    : Int = 1", "(val a: Int 1)"),
    parsesAs("val f: (Int)\n    -> Int = g", "(val f: (Int) -> Int g)"),

    // An incomplete `if`, `while` or `def`, and either side of `else` and `=>`.
    parsesAs("if a\n{\n    1\n}", "(if a (block => 1))"),
    parsesAs("if\n    a { 1 }", "(if a (block => 1))"),
    parsesAs("while a\n{ 1 }", "(while a (block => 1))"),
    parsesAs("while val a = b\n{ 1 }", "(while (val a b) (block => 1))"),
    parsesAs("for x in xs\n{ 1 }", "(for x xs (block => 1))"),
    parsesAs("for\n    x\n    in\n    xs { 1 }", "(for x xs (block => 1))"),
    parsesAs("for i in 0..\n    n { 1 }", "(for i (.. 0 n) (block => 1))"),
    parsesAs("while a {\n    break\n    b\n}", "(while a (block (break) => b))"),
    parsesAs("if a\n    => 1\n    else 2", "(if a 1 2)"),
    parsesAs("if a =>\n    1\nelse\n    2", "(if a 1 2)"),
    parsesAs("if a { 1 }\nelse { 2 }", "(if a (block => 1) (block => 2))"),
    parsesAs("if a { 1 }\nelse\n{ 2 }", "(if a (block => 1) (block => 2))"),
    declaresAs("def f(): Int\n{\n    1\n}", "(def f (): Int (block => 1))"),
    declaresAs("def f(): Int\n    => 1", "(def f (): Int 1)"),
    declaresAs("def f()\n    : Int => 1", "(def f (): Int 1)"),
    declaresAs("def\nf\n(): Int => 1", "(def f (): Int 1)"),

    // After an opening bracket, around commas and before a closing bracket.
    parsesAs("a = [\n    1,\n    2,\n]", "(assign a (array 1 2))"),
    parsesAs("a = [\n    1\n    , 2\n    ,\n]", "(assign a (array 1 2))"),
    parsesAs("a = [\n]", "(assign a (array))"),
    parsesAs("a = [1 +\n  2\n  + 3]", "(assign a (array (Add (Add 1 2) 3)))"),
    parsesAs("a = [ // first\n    1,\n    /* second */\n    2\n]\nb", ["(assign a (array 1 2))", "b"]),
    parsesAs("a = [\n    1: 2,\n    3\n    :\n    4,\n]", "(assign a (map (1 2) (3 4)))"),
    parsesAs("a = [\n:\n]", "(assign a (map))"),
    parsesAs("f(\n    1,\n    2\n)", "(call f 1 2)"),
    parsesAs("f(\n)", "(call f)"),
    parsesAs("a = xs[\n    0\n]", "(assign a (index xs 0))"),
    parsesAs("a = (\n    1\n    + 2\n)", "(assign a (Add 1 2))"),
    parsesAs("a = (\n)", "(assign a ())"),
    parsesAs("f({\n    a\n    b\n})", "(call f (block a => b))"),
    parsesAs("val a: [\n    Int\n] = b", "(val a: [Int] b)"),
    parsesAs("val a: (\n    Int,\n    Int\n) -> Int = b", "(val a: (Int, Int) -> Int b)"),
    parsesAs("val a: List<\n    Int,\n    Int\n> = b", "(val a: List<Int, Int> b)"),
    declaresAs("def f(\n    a: Int,\n    b: Int\n): Int => a", "(def f (a: Int, b: Int): Int a)"),
    declaresAs("type T(\n    a: Int,\n    b: Int\n)", "(type T (a: Int, b: Int))"),

    // Both can end and begin a statement, so a newline separates them.
    parsesAs("a\nb", ["a", "b"]),
    parsesAs("a = b\n- 1", ["(assign a b)", "(Minus 1)"]),
    parsesAs("a = b\n!c", ["(assign a b)", "(Not c)"]),
    parsesAs("a = b\n~c", ["(assign a b)", "(BitNot c)"]),
    parsesAs("a = b\n(c)", ["(assign a b)", "c"]),
    parsesAs("a = b\n[c]", ["(assign a b)", "(array c)"]),
    parsesAs("return\na", ["(return ())", "a"]),
    rejects("a = [1\n    - 2]"),
    rejects("f(1\n    - 2)"),
];

immutable Case[] comments = [
    parsesAs("// leading comment\na = 1", "(assign a 1)"),
    parsesAs("a = 1 // trailing comment\nb = 2", ["(assign a 1)", "(assign b 2)"]),
    parsesAs("a = 1\n// between statements\nb = 2", ["(assign a 1)", "(assign b 2)"]),
    parsesAs("a = 1 // comment at end of input", "(assign a 1)"),
    parsesAs("// only a comment", noStatements),
    parsesAs("a = 4 / 2 // division is not a comment", "(assign a (Divide 4 2))"),

    parsesAs("a = /* inline */ 1", "(assign a 1)"),
    parsesAs("/* leading */ a = 1", "(assign a 1)"),
    parsesAs("a = 1\n/* spans\n   lines */\nb = 2", ["(assign a 1)", "(assign b 2)"]),
    parsesAs("/* only a comment */", noStatements),
    parsesAs("a = 1 /* outer /* inner */ still outer */", "(assign a 1)"),
    rejects("a = 1 /* outer /* inner */"),
    rejects("a = 1 /*\n*/ b = 2"), // newlines inside a block comment aren't separators
];
