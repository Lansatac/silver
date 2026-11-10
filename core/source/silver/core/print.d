module silver.core.print;

import std.array : Appender;
import std.conv : to;
import std.format : format;
import std.sumtype : match;

import silver.core.nodes;
import silver.sema.type : Type, TypeTable;

/// `program`'s functions as text, the entry point first, for tests and debugging. Two locals
/// that share a name print as `x` and `x.1`, since Core tells them apart by identity.
string print(const Program program)
{
    auto printer = Printer(program.types, program.functions);
    printer.function_(program.functions[program.entryPoint]);
    foreach (i, func; program.functions)
    {
        if (i == program.entryPoint) continue;
        printer.output ~= "\n\n";
        printer.function_(func);
    }
    return printer.output[];
}

private struct Printer
{
    const TypeTable types;
    const(Function)[] functions;
    Appender!string output;
    private int _indent;
    private string[const Local] _names;
    private bool[string] _taken;

    void function_(const Function func)
    {
        // Locals belong to one function, so each starts with every name free.
        _names = null;
        _taken = null;
        output ~= "def %s(".format(func.name);
        foreach (i, param; func.params)
        {
            if (i > 0) output ~= ", ";
            if (param.mutable) output ~= "mutable ";
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
            (const IntLit literal) {
                auto signed = types.isInteger(e.type) && types.integerOf(e.type).signed;
                output ~= signed ? (cast(long) literal.value).to!string : literal.value.to!string;
            },
            (const FloatLit literal) {
                import std.algorithm : canFind;

                // `10.0` and `10` would print alike, hiding where a literal adapted to Float.
                auto text = literal.value.to!string;
                output ~= text.canFind!(c => c == '.' || c == 'e' || c == 'n') ? text : text ~ ".0";
            },
            (const Break _) { output ~= "break"; },
            (const Continue _) { output ~= "continue"; },
            (const Loop loop) {
                output ~= "loop ";
                expr(*loop.body);
            },
            (const LocalRef use) { output ~= name(use.local); },
            (const Prim prim) {
                output ~= "%s".format(prim.op);
                arguments(prim.args);
            },
            (const Call call) {
                output ~= functions[call.target].name;
                arguments(call.args);
            },
            (const NativeCall call) {
                output ~= "native " ~ call.name;
                arguments(call.args);
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

    private void arguments(const Expr[] args)
    {
        output ~= "(";
        foreach (i, arg; args)
        {
            if (i > 0) output ~= ", ";
            expr(arg);
        }
        output ~= ")";
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
