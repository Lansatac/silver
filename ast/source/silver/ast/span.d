module silver.ast.span;

/// A range of source text that a node was lowered from, used for error messages.
/// Offsets are byte offsets into the file's text (matching Pegged's ParseTree.begin/end);
/// line and column are computed from the text only when an error is reported.
struct Span
{
    string file;
    size_t start;
    size_t end;
}
