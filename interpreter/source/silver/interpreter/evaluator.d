module silver.interpreter.evaluator;

import std.format : format;
import std.meta : AliasSeq;
import std.sumtype : has, match;
import std.traits : isSigned;

import silver.ast : Diagnostic, DiagnosticCode, Span;
import silver.sema;
import silver.core;
import silver.interpreter.errors;
import silver.interpreter.stack : checkStack, runOnLargeStack;
import silver.interpreter.foreign : foreignFunctions;
import silver.interpreter.values;

private alias IntegerTypes = AliasSeq!(byte, short, int, long, ubyte, ushort, uint, ulong);

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
            (const IntLit literal) => Value(literal.value),
            (const FloatLit literal) => Value(literal.value),
            (const ForeignCall call) => evaluate(e, call, frame),
            (const IntrinsicCall call) => evaluate(e, call, frame),
            (const Prim prim) => evaluate(e, prim, frame),
            (other) => notImplemented(typeof(other).stringof, e.span),
        ));
    }

    /// A Prim's operands share one type, except a shift's amount, so the first one's type says
    /// how to read them all.
    private Value evaluate(const Expr e, const Prim prim, Frame frame)
    {
        import std.algorithm : map;
        import std.array : array;

        auto args = prim.args.map!(arg => evaluate(arg, frame)).array;
        switch (prim.op)
        {
            case PrimOp.Concat:
                return concat(args);
            case PrimOp.Append:
                return append(args[0], args[1]);
            case PrimOp.Not:
                return Value(!args[0].as!bool);
            default:
                break;
        }

        auto types = _program.types;
        auto operandType = prim.args[0].type;
        if (types.isInteger(operandType))
        {
            auto info = types.integerOf(operandType);
            foreach (T; IntegerTypes)
            {
                if (info.bits == T.sizeof * 8 && info.signed == isSigned!T) return integerPrim!T(prim.op, args);
            }
            assert(0, "an integer type with no D type of its width");
        }
        auto lhs = args[0];
        if (lhs.has!double) return floatPrim(prim.op, lhs.as!double, args);
        if (lhs.has!bool) return compare(prim.op, lhs.as!bool, args[1].as!bool);
        if (lhs.has!string) return compare(prim.op, lhs.as!string, args[1].as!string);
        if (lhs.has!Unit) return compare(prim.op, 0, 0);
        assert(0, "lowering only makes a Prim of primitives, arrays aside");
    }

    private static Value concat(Value[] parts)
    {
        import std.algorithm : map;
        import std.array : join;

        if (parts[0].has!string) return Value(parts.map!(p => p.as!string).join);
        return Value(ArrayValue(parts.map!(p => p.as!ArrayValue.elements).join));
    }

    /// D's `~=` extends the buffer in place when `lhs` ends at its used part, as the frontier
    /// rule does.
    private static Value append(Value lhs, Value rhs)
    {
        if (lhs.has!string)
        {
            auto text = lhs.as!string;
            text ~= rhs.as!string;
            return Value(text);
        }
        auto elements = lhs.as!ArrayValue.elements;
        elements ~= rhs.as!ArrayValue.elements;
        return Value(ArrayValue(elements));
    }

    private static Value floatPrim(PrimOp op, double lhs, Value[] args)
    {
        if (op == PrimOp.Negate) return Value(-lhs);
        auto rhs = args[1].as!double;
        switch (op)
        {
            case PrimOp.Add: return Value(lhs + rhs);
            case PrimOp.Subtract: return Value(lhs - rhs);
            case PrimOp.Multiply: return Value(lhs * rhs);
            case PrimOp.Divide: return Value(lhs / rhs);
            case PrimOp.Modulo: return Value(lhs % rhs);
            default: return compare(op, lhs, rhs);
        }
    }

    /// `T` is the D type of the operands' width and signedness. A `Value` holds every integer as
    /// a `long`, so each is cast to `T`, computed there, and cast back, which sign- or
    /// zero-extends it as the type requires.
    private static Value integerPrim(T)(PrimOp op, Value[] args)
    {
        static Value integer(T value)
        {
            return Value(cast(long) value);
        }

        auto lhs = cast(T) args[0].as!long;
        switch (op)
        {
            case PrimOp.Negate:
                static if (isSigned!T)
                {
                    if (lhs == T.min) throw overflow();
                    return integer(cast(T) -lhs);
                }
                else assert(0, "sema only negates signed integers");
            case PrimOp.BitNot:
                return integer(cast(T) ~lhs);
            // The amount can be of any integer type. Read as a `ulong`, a negative one is huge, so
            // one range check rejects it along with every amount too large.
            case PrimOp.ShiftLeft, PrimOp.ShiftRight:
                auto amount = cast(ulong) args[1].as!long;
                if (amount >= T.sizeof * 8)
                {
                    throw new CodedException(DiagnosticCode.InvalidShift, "Shift amount is out of range");
                }
                auto count = cast(int) amount;
                return integer(cast(T)(op == PrimOp.ShiftLeft ? lhs << count : lhs >> count));
            default:
                break;
        }

        auto rhs = cast(T) args[1].as!long;
        switch (op)
        {
            case PrimOp.Add: return integer(checked!"+"(lhs, rhs));
            case PrimOp.Subtract: return integer(checked!"-"(lhs, rhs));
            case PrimOp.Multiply: return integer(checked!"*"(lhs, rhs));
            case PrimOp.WrappingAdd: return integer(cast(T)(lhs + rhs));
            case PrimOp.WrappingSubtract: return integer(cast(T)(lhs - rhs));
            case PrimOp.WrappingMultiply: return integer(cast(T)(lhs * rhs));
            case PrimOp.Divide, PrimOp.Modulo:
                if (rhs == 0) throw new CodedException(DiagnosticCode.DivisionByZero, "Division by zero");
                static if (isSigned!T)
                {
                    if (lhs == T.min && rhs == -1) throw overflow();
                }
                return integer(cast(T)(op == PrimOp.Divide ? lhs / rhs : lhs % rhs));
            case PrimOp.BitAnd: return integer(cast(T)(lhs & rhs));
            case PrimOp.BitOr: return integer(cast(T)(lhs | rhs));
            case PrimOp.BitXor: return integer(cast(T)(lhs ^ rhs));
            default: return compare(op, lhs, rhs);
        }
    }

    private static Value compare(T)(PrimOp op, T lhs, T rhs)
    {
        switch (op)
        {
            case PrimOp.Equal: return Value(lhs == rhs);
            case PrimOp.NotEqual: return Value(lhs != rhs);
            case PrimOp.Less: return Value(lhs < rhs);
            case PrimOp.LessEqual: return Value(lhs <= rhs);
            case PrimOp.Greater: return Value(lhs > rhs);
            case PrimOp.GreaterEqual: return Value(lhs >= rhs);
            default: assert(0, "sema checked the operator against the operands' type");
        }
    }

    private static T checked(string op, T)(T lhs, T rhs)
    {
        static if (T.sizeof < 4)
        {
            // These fit an int, whatever the operator.
            int wide = mixin("int(lhs) " ~ op ~ " int(rhs)");
            if (wide < T.min || wide > T.max) throw overflow();
            return cast(T) wide;
        }
        else
        {
            import core.checkedint : adds, addu, muls, mulu, subs, subu;

            bool overflowed;
            static if (isSigned!T)
            {
                static if (op == "+") T result = adds(lhs, rhs, overflowed);
                else static if (op == "-") T result = subs(lhs, rhs, overflowed);
                else T result = muls(lhs, rhs, overflowed);
            }
            else
            {
                static if (op == "+") T result = addu(lhs, rhs, overflowed);
                else static if (op == "-") T result = subu(lhs, rhs, overflowed);
                else T result = mulu(lhs, rhs, overflowed);
            }
            if (overflowed) throw overflow();
            return result;
        }
    }

    private static CodedException overflow()
    {
        return new CodedException(DiagnosticCode.IntegerOverflow, "Integer overflow");
    }

    private Value evaluate(const Expr e, const IntrinsicCall call, Frame frame)
    {
        import std.algorithm : map;
        import std.range : array;

        Value[] args = call.args.map!(arg => evaluate(arg, frame)).array;
        switch (call.intrinsic)
        {
            case Intrinsic.print:
                write(valueToString(args[0], call.args[0].type));
                return Value(Unit());
            case Intrinsic.printl:
                write(valueToString(args[0], call.args[0].type), true);
                return Value(Unit());
            default:
                return notImplemented("the intrinsic `%s`".format(call.intrinsic), e.span);
        }
    }

    /// A call to a C function, which only the standard library's natives can reach for now: the
    /// interpreter has each of them built in.
    private Value evaluate(const Expr e, const ForeignCall call, Frame frame)
    {
        import std.algorithm : map;
        import std.range : array;

        auto native = call.symbol in foreignFunctions;
        if (native is null)
        {
            throw new RuntimeError(Diagnostic(DiagnosticCode.MissingNativeBinding, e.span,
                "`%s` can't be called when interpreting: only the standard library's natives can be, for now"
                    .format(call.symbol)));
        }
        return (*native)(call.args.map!(arg => evaluate(arg, frame)).array);
    }

    private string valueToString(Value value, Type type)
    {
        import std.conv : to;

        auto types = _program.types;
        if (types.isInteger(type))
        {
            auto bits = value.as!long;
            return types.integerOf(type).signed ? bits.to!string : (cast(ulong) bits).to!string;
        }
        return value.match!(
            (Unit _) => "()",
            (bool b) => b.to!string,
            (double d) =>  d != d ? "nan" : d.to!string,
            (string s) => s,
            (_) => assert(0, "lowering only passes primitives to an intrinsic"),
        );
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

    /// What the program prints, for the intrinsics that print.
    private void write(string text, bool newLine = false)
    {
        import std.stdio : stdout;

        if(newLine)
        {
            text ~= "\n";
        }

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
