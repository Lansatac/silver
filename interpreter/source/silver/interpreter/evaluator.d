module silver.interpreter.evaluator;

import std.conv : to;
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
    /// Whether tests are running, so `read` finds no input; and the failures of the current one.
    private bool _testing;
    private string[] _failures;

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

    /// Throws: RuntimeError when the program panics, and ProgramFailed when `main` returns an error.
    void run()
    {
        runOnLargeStack(&runProgram);
    }

    /// Runs each of the program's tests on its own, so a panic ends only that one.
    TestRun[] runTests()
    {
        TestRun[] runs;
        _testing = true;
        runOnLargeStack(() {
            foreach (test; _program.tests) runs ~= runTest(test);
        });
        return runs;
    }

    private TestRun runTest(const TestCase test)
    {
        _output = null;
        _failures = null;
        TestRun run;
        try
        {
            invoke(test.function_, [], null, null);
        }
        catch (CodedException error)
        {
            run.panic = new Diagnostic(error.code, _program.functions[test.function_].body.span, error.msg);
        }
        catch (RuntimeError error)
        {
            run.panic = new Diagnostic(error.diagnostic.code, error.diagnostic.span, error.diagnostic.message);
        }
        catch (TestStop stop)
        {
            _failures ~= stop.msg;
        }
        // Anything else is a fault in the interpreter, which can still be reported against the test.
        catch (Throwable fault)
        {
            run.crash = fault.msg;
        }
        run.failures = _failures;
        run.output = _output;
        return run;
    }

    private void runProgram()
    {
        try
        {
            invoke(_program.entryPoint, [], null, null);
        }
        catch (CodedException error)
        {
            throw new RuntimeError(Diagnostic(error.code, _program.functions[_program.entryPoint].body.span, error.msg));
        }
    }

    /// Runs function `target` with `args` and, for a lambda, `captures`. When `frame` is given,
    /// it's set to the callee's locals once the call ends, so mutable params can be written back.
    private Value invoke(size_t target, Value[] args, Value[] captures, Frame* frame)
    {
        auto func = &_program.functions[target];
        // At the function being entered, as compiled code checks on entry.
        try checkStack();
        catch (CodedException error) throw new RuntimeError(Diagnostic(error.code, func.body.span, error.msg));
        auto locals = new Frame;
        foreach (i, param; func.params)
        {
            locals.values[param] = args[i];
        }
        foreach (i, capture; func.captures)
        {
            locals.values[capture] = captures[i];
        }
        Value result;
        try
        {
            result = evaluate(func.body, locals);
        }
        catch (ReturnSignal signal)
        {
            result = signal.value;
        }
        if (frame !is null) *frame = locals;
        return result;
    }

    /// Throws: RuntimeError, located at the innermost node being evaluated, when a primitive fails.
    private Value evaluate(const Expr e, Frame frame)
    {
        try
        {
            return e.kind.match!(
                (const UnitLit _) => Value(Unit()),
                (const BoolLit literal) => Value(literal.value),
                (const IntLit literal) => Value(cast(long) literal.value),
                (const FloatLit literal) => Value(literal.value),
                (const StringLit literal) => Value(literal.value),
                (const LocalRef use) => frame.values[use.local],
                (const Block block) => evaluate(block, frame),
                (const Call call) => evaluate(call, frame),
                (const CallClosure call) => evaluate(call, frame),
                (const MakeClosure closure) => Value(Closure(closure.target, all(closure.captures, frame))),
                (const ForeignCall call) => evaluate(e, call, frame),
                (const IntrinsicCall call) => evaluate(e, call, frame),
                (const Prim prim) => evaluate(prim, frame),
                (const Convert convert) => this.convert(evaluate(*convert.value, frame), convert.value.type, e.type),
                (const If if_) => evaluate(if_, frame),
                (const Loop loop) => evaluate(loop, frame),
                (const Break jump) => this.jump!BreakSignal(jump.label),
                (const Continue jump) => this.jump!ContinueSignal(jump.label),
                (const Return return_) => leave(evaluate(*return_.value, frame)),
                (const Construct construct) => Value(Record(0, all(construct.fields, frame))),
                (const Field field) => evaluate(*field.object, frame).as!Record.fields[field.index],
                (const Update update) => evaluate(update, frame),
                (const Inject inject) => evaluate(inject, frame),
                (const IsMember test) => Value(evaluate(*test.subject, frame).as!Record.tag == test.member),
                (const Payload payload) => evaluate(*payload.subject, frame).as!Record.fields[0],
                (const ArrayLit literal) => Value(ArrayValue(all(literal.elements, frame))),
                (const Index index) => evaluate(index, frame),
                (const Slice slice) => evaluate(slice, frame),
                (const Length length) => Value(cast(long) evaluate(*length.array, frame).as!ArrayValue.elements.length),
                (const Cell cell) => evaluate(cell, frame),
                (const TestFailure failure) => fail(evaluate(*failure.message, frame).as!string, failure.ends),
            );
        }
        catch (CodedException error)
        {
            throw new RuntimeError(Diagnostic(error.code, e.span, error.msg));
        }
    }

    /// Each of `exprs`, in order.
    private Value[] all(const Expr[] exprs, Frame frame)
    {
        auto values = new Value[exprs.length];
        foreach (i, ref expr; exprs)
        {
            values[i] = evaluate(expr, frame);
        }
        return values;
    }

    private Value jump(Signal)(size_t label)
    {
        throw new Signal(label);
    }

    private Value fail(string message, bool ends)
    {
        if (ends) throw new TestStop(message);
        _failures ~= message;
        return Value(Unit());
    }

    private Value leave(Value value)
    {
        throw new ReturnSignal(value);
    }

    private Value evaluate(const Call call, Frame frame)
    {
        return callWith(call.target, null, call.args, frame);
    }

    /// The callee is evaluated before the arguments.
    private Value evaluate(const CallClosure call, Frame frame)
    {
        auto closure = evaluate(*call.callee, frame).as!Closure;
        return callWith(closure.target, closure.captures, call.args, frame);
    }

    /// Calls `target` with `args`. An argument for a mutable param is read once the others have
    /// been evaluated, and gets the param's final value when the call ends.
    private Value callWith(size_t target, Value[] captures, const Expr[] args, Frame frame)
    {
        auto params = _program.functions[target].params;
        auto values = new Value[args.length];
        auto anyMutable = false;
        foreach (i, ref arg; args)
        {
            if (params[i].mutable) anyMutable = true;
            else values[i] = evaluate(arg, frame);
        }
        if (!anyMutable) return invoke(target, values, captures, null);

        foreach (i, ref arg; args)
        {
            if (params[i].mutable) values[i] = frame.values[mutableLocal(arg)];
        }
        Frame callee;
        auto result = invoke(target, values, captures, &callee);
        foreach (i, ref arg; args)
        {
            if (params[i].mutable) frame.values[mutableLocal(arg)] = callee.values[params[i]];
        }
        return result;
    }

    private static const(Local) mutableLocal(const Expr arg)
    {
        return arg.kind.match!(
            (const LocalRef use) => use.local,
            (_) => assert(0, "lowering passes a local to a mutable param"),
        );
    }

    private Value evaluate(const If if_, Frame frame)
    {
        if (evaluate(*if_.condition, frame).as!bool) return evaluate(*if_.trueBody, frame);
        return evaluate(*if_.falseBody, frame);
    }

    private Value evaluate(const Loop loop, Frame frame)
    {
        while (true)
        {
            try
            {
                evaluate(*loop.body, frame);
            }
            catch (ContinueSignal signal)
            {
                if (signal.label != loop.label) throw signal;
            }
            catch (BreakSignal signal)
            {
                if (signal.label != loop.label) throw signal;
                break;
            }
        }
        return Value(Unit());
    }

    private Value evaluate(const Update update, Frame frame)
    {
        auto record = evaluate(*update.object, frame).as!Record;
        auto fields = record.fields.dup;
        fields[update.index] = evaluate(*update.value, frame);
        return Value(Record(record.tag, fields));
    }

    private Value evaluate(const Inject inject, Frame frame)
    {
        if (inject.payload is null) return Value(Record(inject.member, null));
        return Value(Record(inject.member, [evaluate(*inject.payload, frame)]));
    }

    /// An index of any integer type, as unsigned, so a negative one is too large.
    private static ulong position(Value index)
    {
        return cast(ulong) index.as!long;
    }

    private Value evaluate(const Index index, Frame frame)
    {
        auto elements = evaluate(*index.array, frame).as!ArrayValue.elements;
        auto at = position(evaluate(*index.index, frame));
        if (at >= elements.length) throw new CodedException(DiagnosticCode.IndexOutOfRange, "Index is out of range");
        return elements[cast(size_t) at];
    }

    private Value evaluate(const Slice slice, Frame frame)
    {
        auto elements = evaluate(*slice.array, frame).as!ArrayValue.elements;
        auto start = position(evaluate(*slice.start, frame));
        auto end = position(evaluate(*slice.end, frame));
        if (start > end || end > elements.length)
        {
            throw new CodedException(DiagnosticCode.IndexOutOfRange, "Slice is out of range");
        }
        return Value(ArrayValue(elements[cast(size_t) start .. cast(size_t) end]));
    }

    private Value evaluate(const Cell cell, Frame frame)
    {
        auto args = all(cell.args, frame);
        if (cell.op == CellOp.New) return Value(new CellValue(args[0]));
        auto target = args[0].as!CellValue;
        if (cell.op == CellOp.Fill)
        {
            target.contents = args[1];
            target.full = true;
            return Value(Unit());
        }
        if (!target.full) throw new CodedException(DiagnosticCode.RefInUpdate, "Ref is being updated");
        final switch (cell.op)
        {
            case CellOp.Get:
                return target.contents;
            case CellOp.Set:
                target.contents = args[1];
                return Value(Unit());
            case CellOp.Take:
                target.full = false;
                auto contents = target.contents;
                target.contents = Value.init;
                return contents;
            case CellOp.New, CellOp.Fill:
                assert(0, "handled above");
        }
    }

    /// A Prim's operands share one type, except a shift's amount, so the first one's type says
    /// how to read them all.
    private Value evaluate(const Prim prim, Frame frame)
    {
        auto args = all(prim.args, frame);
        switch (prim.op)
        {
            case PrimOp.Concat:
                return concat(args);
            case PrimOp.Append:
                return append(args[0], args[1]);
            case PrimOp.Not:
                return Value(!args[0].as!bool);
            case PrimOp.Format:
                return Value(formatted(args[0], prim.args[0].type));
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

    /// `value`, of the number type `from`, as `to`. A Float is truncated toward zero first, and
    /// a value that doesn't fit `to`, NaN among them, panics.
    private Value convert(Value value, Type from, Type to)
    {
        auto types = _program.types;
        if (to == types.float_)
        {
            if (from == types.float_) return value;
            auto bits = value.as!long;
            return Value(types.integerOf(from).signed ? cast(double) bits : cast(double) cast(ulong) bits);
        }

        auto target = types.integerOf(to);
        foreach (T; IntegerTypes)
        {
            if (target.bits != T.sizeof * 8 || target.signed != isSigned!T) continue;
            if (from == types.float_)
            {
                auto number = value.as!double;
                if (!floatFits!T(number)) throw conversionFailure!T();
                return Value(cast(long) cast(T) number);
            }
            auto source = types.integerOf(from);
            auto bits = value.as!long;
            if (source.signed)
            {
                if (!integerFits!T(bits)) throw conversionFailure!T();
            }
            else
            {
                if (!integerFits!T(cast(ulong) bits)) throw conversionFailure!T();
            }
            return Value(cast(long) cast(T) bits);
        }
        assert(0, "sema only converts numbers");
    }

    private static CodedException conversionFailure(T)()
    {
        auto name = "%sInt%s".format(isSigned!T ? "" : "U", T.sizeof * 8);
        return new CodedException(DiagnosticCode.InvalidConversion, "Value is out of range for " ~ name);
    }

    /// Whether `value`, truncated toward zero, is a `T`. False for NaN.
    private static bool floatFits(T)(double value)
    {
        enum bits = T.sizeof * 8;
        static if (isSigned!T)
        {
            enum double limit = 2.0 ^^ (bits - 1);
            static if (bits == 64)
            {
                return value >= -limit && value < limit;
            }
            else
            {
                return value > -limit - 1 && value < limit;
            }
        }
        else
        {
            enum double limit = 2.0 ^^ bits;
            return value > -1 && value < limit;
        }
    }

    private static bool integerFits(T, S)(S value)
    {
        static if (isSigned!S)
        {
            if (value < 0)
            {
                static if (isSigned!T)
                {
                    return long(value) >= long(T.min);
                }
                else
                {
                    return false;
                }
            }
        }
        return cast(ulong) value <= cast(ulong) T.max;
    }

    private Value evaluate(const Expr e, const IntrinsicCall call, Frame frame)
    {
        import std.stdio : readln;

        auto args = all(call.args, frame);
        final switch (call.intrinsic)
        {
            case Intrinsic.print:
                write(formatted(args[0], call.args[0].type));
                return Value(Unit());
            case Intrinsic.printl:
                write(formatted(args[0], call.args[0].type), true);
                return Value(Unit());
            case Intrinsic.read:
                if (_testing) return Value(Record(0, null));
                auto line = readln();
                if (line.length == 0) return Value(Record(0, null));
                return Value(Record(1, [Value(line)]));
            case Intrinsic.panic:
                throw new CodedException(DiagnosticCode.ExplicitPanic, args[0].as!string);
            case Intrinsic.exitWithError:
                throw new ProgramFailed(args[0].as!string);
            case Intrinsic.length, Intrinsic.get, Intrinsic.set, Intrinsic.update, Intrinsic.assert_, Intrinsic.expect:
                assert(0, "lowering makes `length` a Length, `assert` and `expect` a test, and the others operations on a Cell");
        }
    }

    /// A call to a C function, which only the standard library's natives can reach for now: the
    /// interpreter has each of them built in.
    private Value evaluate(const Expr e, const ForeignCall call, Frame frame)
    {
        auto native = call.symbol in foreignFunctions;
        if (native is null)
        {
            throw new RuntimeError(Diagnostic(DiagnosticCode.MissingNativeBinding, e.span,
                "`%s` can't be called when interpreting: only the standard library's natives can be, for now"
                    .format(call.symbol)));
        }
        return (*native)(all(call.args, frame));
    }

    /// A primitive or function `value` of `type`, as `print` shows it.
    private string formatted(Value value, Type type)
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
            (double d) => d != d ? "nan" : d.to!string,
            (string s) => s,
            (Closure c) => _program.functions[c.target].printedName,
            (_) => assert(0, "lowering formats anything else itself"),
        );
    }

    private Value evaluate(const Block block, Frame frame)
    {
        foreach (ref statement; block.statements)
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
            (const Assign assign) { frame.values[assign.local] = evaluate(assign.value, frame); },
            (const AssignElement assign) {
                auto at = position(evaluate(assign.index, frame));
                auto value = evaluate(assign.value, frame);
                auto elements = frame.values[assign.local].as!ArrayValue.elements;
                if (at >= elements.length)
                {
                    // A statement has no expression around it of its own to give the panic its place.
                    throw new RuntimeError(Diagnostic(DiagnosticCode.IndexOutOfRange, s.span, "Index is out of range"));
                }
                auto replaced = elements.dup;
                replaced[cast(size_t) at] = value;
                frame.values[assign.local] = Value(ArrayValue(replaced));
            },
            (const Eval eval) { evaluate(eval.expr, frame); },
        );
    }

    /// What the program prints, for the intrinsics that print.
    private void write(string text, bool newLine = false)
    {
        import std.stdio : stdout;

        if (newLine)
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
}

/// What happened when a test ran.
struct TestRun
{
    /// Each recorded failure, in order, each starting with where it happened. A test that stopped
    /// has its reason last.
    string[] failures;
    /// The panic that ended the test, if one did.
    const(Diagnostic)* panic;
    /// Why the interpreter itself failed while running the test, if it did.
    string crash;
    /// What the test printed.
    string output;
}

/// The locals of one call. Core's locals are objects, so a nested block needs no scope of its own.
private final class Frame
{
    Value[const Local] values;
}

/// Thrown by `Break`, `Continue` and `Return`, and caught by the loop or call they leave. They're
/// Throwables rather than Exceptions, so nothing that handles errors catches them by accident.
private class BreakSignal : Throwable
{
    size_t label;

    this(size_t label)
    {
        super("break outside of a loop");
        this.label = label;
        info = noTrace;
    }
}

/// ditto
private class ContinueSignal : Throwable
{
    size_t label;

    this(size_t label)
    {
        super("continue outside of a loop");
        this.label = label;
        info = noTrace;
    }
}

/// ditto
private class ReturnSignal : Throwable
{
    Value value;

    this(Value value)
    {
        super("return outside of a function");
        this.value = value;
        info = noTrace;
    }
}

/// Thrown when a test stops, as `?` on `None` stops it, and caught by the test runner.
private class TestStop : Throwable
{
    this(string message)
    {
        super(message);
        info = noTrace;
    }
}

/// A signal with `info` already set isn't given a stack trace when it's thrown. Capturing one
/// costs milliseconds on Windows, which a Silver `return` would otherwise pay every time.
private class NoTrace : Throwable.TraceInfo
{
    int opApply(scope int delegate(ref const(char[])) _) const => 0;
    int opApply(scope int delegate(ref size_t, ref const(char[])) _) const => 0;
    override string toString() const => "";
}

private NoTrace noTrace;

static this()
{
    noTrace = new NoTrace;
}
