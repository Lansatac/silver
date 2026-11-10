/+ dub.json:
{
	"name": "generate_grammar",
	"dependencies": { "pegged": "0.4.9" }
}
+/
/// Generates `silver.syntax.grammar` from `Silver.peg` at run time, so the parser generator
/// doesn't run in CTFE in every compilation that imports the grammar. `syntax/dub.json` runs it
/// before each build; the file is only rewritten when its contents change, so an unchanged
/// grammar doesn't trigger a rebuild.
///
/// Usage: generate_grammar <Silver.peg> <grammar.d>
module generate_grammar;

import std.array : replace;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : dirName;
import std.stdio : stderr;
import std.string : indexOf;
import pegged.grammar : grammar;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: generate_grammar <Silver.peg> <grammar.d>");
        return 2;
    }
    immutable source = args[1], target = args[2];

    // Sequences go through `detachedAnd`; see silver.syntax.detached.
    enum sequence = "pegged.peg.and!(";
    auto parser = grammar(readText(source));
    if (parser.indexOf(sequence) < 0)
    {
        stderr.writeln("generate_grammar: Pegged's generated code changed; ",
            "check whether the workaround in silver.syntax.detached is still needed");
        return 1;
    }

    immutable text = "// Generated from Silver.peg by syntax/tools/generate_grammar.d. Do not edit.\n"
        ~ "module silver.syntax.grammar;\n\n"
        ~ "public import pegged.peg;\n"
        ~ "import std.algorithm : startsWith;\n"
        ~ "import std.functional : toDelegate;\n"
        ~ "import silver.syntax.detached : detachedAnd;\n"
        ~ "debug import std.stdio;\n\n"
        ~ parser.replace(sequence, "detachedAnd!(") ~ "\n";

    if (target.exists && readText(target) == text) return 0;
    mkdirRecurse(target.dirName);
    write(target, text);
    return 0;
}
