module silver.core.print;

import std.array : Appender;
import std.conv : to;
import std.format : format;
import std.sumtype : match;

import silver.core.nodes;
import silver.sema.type : Type, TypeTable;

/// `func` as text, for tests and debugging. Two locals that share a name print as `x` and `x.1`,
/// since Core tells them apart by identity.
string print(const Function func, const TypeTable types)
{
    auto printer = Printer(types);
    printer.function_(func);
    return printer.output[];
}

/// ditto, for an expression on its own.
string print(const Expr expr, const TypeTable types)
{
    auto printer = Printer(types);
    printer.expr(expr);
    return printer.output[];
}

private struct Printer
{
    const TypeTable types;
    Appender!string output;
    private int _indent;
    private string[const Local] _names;
    private bool[string] _taken;

    void function_(const Function func)
    {
        output ~= "def %s(".format(func.name);
        foreach (i, param; func.params)
        {
            if (i > 0) output ~= ", ";
            declaration(param);
        }
        output ~= "): %s ".format(types.describe(func.returnType));
        expr(func.body);
    }

    void expr(const Expr e)
    {
        e.kind.match!(
            (const UnitLit _) { output ~= "()"; },
            (const BoolLit literal) { output ~= literal.value.to!string; },
            (const IntLit literal) { output ~= literal.value.to!string; },
            (const Break _) { output ~= "break"; },
            (const Continue _) { output ~= "continue"; },
            (const Loop loop) {
                output ~= "loop ";
                expr(*loop.body);
            },
            (const LocalRef use) { output ~= name(use.local); },
            (const Prim prim) {
                output ~= "%s(".format(prim.op);
                foreach (i, arg; prim.args)
                {
                    if (i > 0) output ~= ", ";
                    expr(arg);
                }
                output ~= ")";
            },
            (const If if_) {
                output ~= "if (";
                expr(*if_.condition);
                output ~= ") ";
                expr(*if_.trueBody);
                output ~= " else ";
                expr(*if_.falseBody);
            },
            (const Block block) {
                output ~= "{";
                _indent += 1;
                foreach (statement; block.statements)
                {
                    newline();
                    stmt(statement);
                }
                if (block.result !is null)
                {
                    newline();
                    expr(*block.result);
                }
                _indent -= 1;
                newline();
                output ~= "}";
            },
        );
    }

    void stmt(const Stmt s)
    {
        s.kind.match!(
            (const Let let) {
                output ~= let.local.mutable ? "let mutable " : "let ";
                declaration(let.local);
                output ~= " = ";
                expr(let.value);
            },
            (const Assign assign) {
                output ~= name(assign.local) ~ " = ";
                expr(assign.value);
            },
            (const Eval eval) { expr(eval.expr); },
        );
    }

    /// Where `local` is introduced, which is the one place its type is shown.
    private void declaration(const Local local)
    {
        output ~= "%s: %s".format(name(local), types.describe(local.type));
    }

    private string name(const Local local)
    {
        if (auto existing = local in _names) return *existing;
        string chosen = local.name;
        for (int n = 1; chosen in _taken; n++) chosen = "%s.%s".format(local.name, n);
        _taken[chosen] = true;
        _names[local] = chosen;
        return chosen;
    }

    private void newline()
    {
        output ~= "\n";
        foreach (_; 0 .. _indent) output ~= "    ";
    }
}
