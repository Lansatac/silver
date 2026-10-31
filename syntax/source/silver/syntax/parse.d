module silver.syntax.parse;

import silver.ast : Module, Diagnostic, DiagnosticException;
import silver.syntax.lower : lower;
import silver.syntax.cst : parseCst;

/// Thrown when Silver source code fails to parse.
class ParseException : DiagnosticException
{
    this(Diagnostic diagnostic, string file = __FILE__, size_t line = __LINE__)
    {
        super(diagnostic, file, line);
    }
}

/// Parses Silver source into an AST.
/// Throws: ParseException if the source does not parse.
Module parse(string source, string moduleName, string file = "<input>")
{
    return lower(parseCst(source, file), moduleName, file);
}
