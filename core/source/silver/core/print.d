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
    foreach (library; program.libraries)
    {
        printer.output ~= "library \"%s\"\n\n".format(library);
    }
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
    /// The labels of the loops around what's being printed, innermost last.
    private size_t[] _loops;

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
            (const Break jump) { output ~= "break" ~ outward(jump.label); },
            (const Continue jump) { output ~= "continue" ~ outward(jump.label); },
            (const Loop loop) {
                output ~= "loop ";
                _loops ~= loop.label;
                expr(*loop.body);
                _loops = _loops[0 .. $ - 1];
            },
            (const LocalRef use) { output ~= name(use.local); },
            (const Prim prim) {
                output ~= "%s".format(prim.op);
                arguments(prim.args);
            },
            (const StringLit literal) { output ~= "%(%s%)".format([literal.value]); },
            (const Call call) {
                output ~= functions[call.target].name;
                arguments(call.args);
            },
            (const CallClosure call) {
                output ~= "call ";
                expr(*call.callee);
                arguments(call.args);
            },
            (const MakeClosure closure) {
                output ~= "closure " ~ functions[closure.target].name;
                if (closure.captures.length > 0) arguments(closure.captures);
            },
            (const Convert convert) {
                output ~= types.describe(e.type);
                arguments([*convert.value]);
            },
            (const Return return_) {
                output ~= "return ";
                expr(*return_.value);
            },
            (const Construct construct) {
                output ~= types.describe(e.type);
                arguments(construct.fields);
            },
            (const Field field) {
                expr(*field.object);
                output ~= ".%s".format(field.index);
            },
            (const Update update) {
                expr(*update.object);
                output ~= " with .%s = ".format(update.index);
                expr(*update.value);
            },
            (const Inject inject) {
                output ~= "%s#%s".format(types.describe(e.type), inject.member);
                if (inject.payload !is null) arguments([*inject.payload]);
            },
            (const IsMember test) {
                output ~= "is#%s".format(test.member);
                arguments([*test.subject]);
            },
            (const Payload payload) {
                output ~= "payload#%s".format(payload.member);
                arguments([*payload.subject]);
            },
            (const ArrayLit literal) {
                output ~= "[";
                foreach (i, element; literal.elements)
                {
                    if (i > 0) output ~= ", ";
                    expr(element);
                }
                output ~= "]";
            },
            (const Index index) {
                expr(*index.array);
                output ~= "[";
                expr(*index.index);
                output ~= "]";
            },
            (const Slice slice) {
                expr(*slice.array);
                output ~= "[";
                expr(*slice.start);
                output ~= "..";
                expr(*slice.end);
                output ~= "]";
            },
            (const Length length) {
                output ~= "length";
                arguments([*length.array]);
            },
            (const Cell cell) {
                output ~= "cell.%s".format(cell.op);
                arguments(cell.args);
            },
            (const ForeignCall call) {
                output ~= "foreign \"%s\"".format(call.symbol);
                arguments(call.args);
            },
            (const IntrinsicCall call) {
                output ~= "intrinsic %s".format(call.intrinsic);
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
            (const AssignElement assign) {
                output ~= name(assign.local) ~ "[";
                expr(assign.index);
                output ~= "] = ";
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

    /// Nothing for a jump out of the innermost loop, and otherwise how many loops further out it goes.
    private string outward(size_t label)
    {
        import std.algorithm : countUntil;
        import std.range : retro;

        auto depth = _loops.retro.countUntil(label);
        return depth == 0 ? "" : " %s".format(depth);
    }

    private void newline()
    {
        output ~= "\n";
        foreach (_; 0 .. _indent) output ~= "    ";
    }
}
