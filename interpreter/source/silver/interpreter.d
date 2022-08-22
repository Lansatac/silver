module silver.interpreter;

import std.stdio;

import silver.grammar;
import silver.context;
import pegged.grammar : ParseTree;

/// Interprets a string representing silver code.
int interpret(string code)
{
    auto parseTree = Silver(code);

    writeln(parseTree);

    if(!parseTree.successful)
    {
        writeln(parseTree.errorMessage);
        return 1;
    }

    auto context = new Context(parseTree);

    context.run();

    return 0;
}

unittest
{

}

private string errorMessage(ParseTree tree)
{
    ParseTree terminal = tree;

    while(terminal.children.length > 0)
    {
        foreach (child; terminal.children)
        {
            if(!child.successful)
            {
                terminal = child;
                break;
            }
        }
    }

    return terminal.failMsg;
}