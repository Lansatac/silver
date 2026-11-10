module silver.interpreter.evaluator;

import std.sumtype : match;

import silver.ast : Diagnostic, DiagnosticCode, Span;
import silver.core;
import silver.interpreter.errors;
import silver.interpreter.stack : checkStack, runOnLargeStack;
import silver.interpreter.values;

/// Runs a Core program by walking its tree.
final class Evaluator
{
    private Program _program;
    private bool _useStdOut;
    private string _output;

    /// With `useStdOut`, output goes straight to standard output; otherwise it's kept for `output`.
    this(Program program, bool useStdOut = false)
    {
        _program = program;
        _useStdOut = useStdOut;
    }

    /// Everything the program has printed so far.
    string output() const
    {
        return _output;
    }

    /// Throws: RuntimeError when the program panics.
    void run()
    {
        runOnLargeStack(&runProgram);
    }

    private void runProgram()
    {
        call(_program.functions[_program.entryPoint], [], Span.init);
    }

    private Value call(const Function func, Value[] args, Span span)
    {
        located(span, () => checkStack());
        auto frame = new Frame;
        foreach (i, param; func.params)
        {
            frame.values[param] = args[i];
        }
        return evaluate(func.body, frame);
    }

    private Value evaluate(const Expr e, Frame frame)
    {
        return located(e.span, () => e.kind.match!(
            (const UnitLit _) => Value(Unit()),
            (const LocalRef use) => frame.values[use.local],
            (const Block block) => evaluate(block, frame),
            (other) => notImplemented(typeof(other).stringof, e.span),
        ));
    }

    private Value evaluate(const Block block, Frame frame)
    {
        foreach (statement; block.statements)
        {
            execute(statement, frame);
        }
        if (block.result is null) return Value(Unit());
        return evaluate(*block.result, frame);
    }

    private void execute(const Stmt s, Frame frame)
    {
        s.kind.match!(
            (const Let let) { frame.values[let.local] = evaluate(let.value, frame); },
            (const Eval eval) { evaluate(eval.expr, frame); },
            (other) { notImplemented!void(typeof(other).stringof, s.span); },
        );
    }

    /// What the program prints, for the natives that print.
    private void write(string text)
    {
        import std.stdio : stdout;

        if (_useStdOut)
        {
            stdout.write(text);
            stdout.flush();
        }
        else
        {
            _output ~= text;
        }
    }

    /// Runs `action`, giving a `CodedException` it throws the location `span`.
    private T located(T)(Span span, T delegate() action)
    {
        try
        {
            return action();
        }
        catch (RuntimeError error)
        {
            throw error;
        }
        catch (CodedException error)
        {
            throw new RuntimeError(Diagnostic(error.code, span, error.msg));
        }
    }

    private T notImplemented(T = Value)(string what, Span span)
    {
        throw new RuntimeError(Diagnostic(DiagnosticCode.NotImplemented, span,
            "Not implemented in the interpreter yet: " ~ what));
    }
}

/// The locals of one call. Core's locals are objects, so a nested block needs no scope of its own.
private final class Frame
{
    Value[const Local] values;
}
