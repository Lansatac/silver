module silver.parse;

import silver.ast : Module;
import silver.cstToAst : cstToAst;
import silver.parseCst : parseCst;

/// Thrown when Silver source code fails to parse.
class ParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/// Parses Silver source into an AST.
/// Throws: ParseException if the source does not parse.
Module parse(string source, string moduleName, string file = "<input>")
{
    return cstToAst(parseCst(source, file), moduleName, file);
}
