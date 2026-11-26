module silver.interpreter.evaluator;

import core.exception : OutOfMemoryError;
import std.conv : to;
import std.format : format;
import std.meta : AliasSeq;
import std.sumtype : match;
import std.traits : isSigned;

import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException, Span;
import silver.sema;
import silver.core;
import silver.interpreter.errors;
import silver.interpreter.stack : checkStack, runOnLargeStack;
import silver.interpreter.foreign : addressText, callC, findNative, fromCString, toCString;
import silver.interpreter.values;
import silver.runtime.files : pathExists, readWhole, writeWhole;
import silver.runtime.floattext : float32Text, floatText;

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
    /// The program's arguments, each already known to be UTF-8.
    private string[] _arguments;
    /// What a relative path is relative to, or null for the process's working directory.
    private string _directory;
    /// How to call each of the program's `natives`, found and described before anything runs.
    private Callable[] _natives;

    private static struct Callable
    {
        const(void)* address;
        CallDescription description;
        /// How many words its arguments' parts take.
        size_t words;
        /// Why calling it is refused, or null.
        string refusal;
    }

    /// With `useStdOut`, output goes straight to standard output; otherwise it's kept for `output`.
    /// `directory` stands in for the directory the program was started in, so programs in one process
    /// can each have their own.
    this(Program program, bool useStdOut = false, string[] arguments = null, string directory = null)
    {
        _program = program;
        _useStdOut = useStdOut;
        _arguments = arguments;
        _directory = directory;
    }

    /// Everything the program has printed so far.
    string output() const
    {
        return _output;
    }

    /// Throws: RuntimeError when the program panics, ProgramFailed when `main` returns an error, and
    /// DiagnosticException, before it starts, when a native it calls can't be found.
    void run()
    {
        if (auto mistake = argumentsMistake(_arguments)) throw new ProgramFailed(mistake);
        findNatives();
        runOnLargeStack(&runProgram);
    }

    /// Runs each of the program's tests on its own, so a panic ends only that one.
    /// Throws: DiagnosticException, before any test runs, when a native can't be found.
    TestRun[] runTests()
    {
        findNatives();
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
            invoke(test.function_, [], null);
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
        catch (OutOfMemoryError)
        {
            run.panic = new Diagnostic(DiagnosticCode.OutOfMemory, _program.functions[test.function_].body.span, "Out of memory");
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

    /// Finds every C function the program calls, as linking a compiled one does.
    /// Throws: DiagnosticException (`MissingNativeBinding`) at the first call of one that can't be found.
    private void findNatives()
    {
        auto types = _program.types;
        _natives = new Callable[_program.natives.length];
        foreach (i, ref native; _program.natives)
        {
            string problem;
            auto callable = &_natives[i];
            callable.address = findNative(native.symbol, native.library, problem);
            if (callable.address is null)
            {
                throw new DiagnosticException(Diagnostic(DiagnosticCode.MissingNativeBinding, native.span,
                    "`%s` can't be called when interpreting: %s".format(native.symbol, problem)));
            }
            callable.description = describeCall(_program, native, hostConvention);
            foreach (ref argument; callable.description.arguments) callable.words += argument.parts.length;
            foreach (param; native.params)
            {
                if (types.isInteger(param) && types.integerOf(param).bits < 32)
                {
                    callable.refusal = "`%s` can't be called when interpreting as it's declared: a parameter narrower than C's `int` is passed with its upper bits undefined on Windows, so the interpreter refuses `%s`"
                        .format(native.symbol, types.describe(param));
                    break;
                }
            }
        }
    }

    private void runProgram()
    {
        try
        {
            invoke(_program.entryPoint, [], null);
        }
        catch (CodedException error)
        {
            throw new RuntimeError(Diagnostic(error.code, _program.functions[_program.entryPoint].body.span, error.msg));
        }
        catch (OutOfMemoryError)
        {
            throw new RuntimeError(Diagnostic(DiagnosticCode.OutOfMemory, _program.functions[_program.entryPoint].body.span, "Out of memory"));
        }
    }

    /// Runs function `target` with `args` and, for a lambda, `captures`.
    private Value invoke(size_t target, Value[] args, Value[] captures)
    {
        auto func = &_program.functions[target];
        auto frame = newFrame(*func);
        frame[0 .. args.length] = args[];
        return enter(*func, frame, captures);
    }

    /// A call's locals, each at its `Local.slot`, and after them the value a `Return` leaves with.
    private static Value[] newFrame(ref const Function func)
    {
        return new Value[func.localCount + 1];
    }

    /// Runs `func` in `frame`, which already holds its arguments.
    private Value enter(ref const Function func, Value[] frame, Value[] captures)
    {
        // At the function being entered, as compiled code checks on entry.
        try checkStack();
        catch (CodedException error) throw new RuntimeError(Diagnostic(error.code, func.body.span, error.msg));
        foreach (i, capture; func.captures) frame[capture.slot] = captures[i];
        auto result = evaluate(func.body, frame);
        return result.has!Jump ? frame[$ - 1] : result;
    }

    /// The value of `e`, or the `Jump` that leaves it, which whatever evaluated `e` gives in turn
    /// until the loop or call it's for takes it.
    /// Throws: RuntimeError, located at the innermost node being evaluated, when a primitive fails.
    private Value evaluate(ref const Expr e, Value[] frame)
    {
        try
        {
            return e.kind.match!(
                (ref const UnitLit _) => Value(Unit()),
                (ref const BoolLit literal) => Value(literal.value),
                (ref const IntLit literal) => Value(cast(long) literal.value),
                (ref const FloatLit literal) => Value(literal.value),
                (ref const StringLit literal) => Value(literal.value),
                (ref const LocalRef use) => frame[use.local.slot],
                (ref const Block block) => evaluate(block, frame),
                (ref const Call call) => callWith(call.target, null, call.args, frame),
                (ref const CallClosure call) => evaluate(call, frame),
                (ref const MakeClosure closure) => evaluate(closure, frame),
                (ref const ForeignCall call) => evaluate(e, call, frame),
                (ref const IntrinsicCall call) => evaluate(e, call, frame),
                (ref const Prim prim) => evaluate(prim, frame),
                (ref const Convert convert) => evaluate(e, convert, frame),
                (ref const If if_) => evaluate(if_, frame),
                (ref const Loop loop) => evaluate(loop, frame),
                (ref const Break jump) => Value(Jump(Jump.Kind.break_, jump.label)),
                (ref const Continue jump) => Value(Jump(Jump.Kind.continue_, jump.label)),
                (ref const Return return_) => evaluate(return_, frame),
                (ref const Construct construct) => evaluate(construct, frame),
                (ref const Field field) => evaluate(field, frame),
                (ref const Update update) => evaluate(update, frame),
                (ref const Inject inject) => evaluate(inject, frame),
                (ref const IsMember test) => evaluate(test, frame),
                (ref const Payload payload) => evaluate(payload, frame),
                (ref const ArrayLit literal) => evaluate(e, literal, frame),
                (ref const Index index) => evaluate(index, frame),
                (ref const Slice slice) => evaluate(slice, frame),
                (ref const Length length) => evaluate(length, frame),
                (ref const Cell cell) => evaluate(cell, frame),
                (ref const Capture capture) => evaluate(capture, frame),
                (ref const TestFailure failure) => evaluate(failure, frame),
            );
        }
        catch (CodedException error)
        {
            throw new RuntimeError(Diagnostic(error.code, e.span, error.msg));
        }
    }

    /// Each of `exprs`, in order, as `values`. Gives the `Jump` one of them left with, which ends
    /// it, and Unit otherwise.
    private Value all(const Expr[] exprs, Value[] frame, out Value[] values)
    {
        values = new Value[exprs.length];
        foreach (i, ref expr; exprs)
        {
            values[i] = evaluate(expr, frame);
            if (values[i].has!Jump) return values[i];
        }
        return Value(Unit());
    }

    private Value fail(string message, bool ends)
    {
        if (ends) throw new TestStop(message);
        _failures ~= message;
        return Value(Unit());
    }

    private Value evaluate(ref const TestFailure failure, Value[] frame)
    {
        auto message = evaluate(*failure.message, frame);
        if (message.has!Jump) return message;
        return fail(message.as!string, failure.ends);
    }

    private Value evaluate(ref const Return return_, Value[] frame)
    {
        auto value = evaluate(*return_.value, frame);
        if (value.has!Jump) return value;
        frame[$ - 1] = value;
        return Value(Jump(Jump.Kind.return_));
    }

    private Value evaluate(ref const MakeClosure closure, Value[] frame)
    {
        Value[] captures;
        auto jump = all(closure.captures, frame, captures);
        if (jump.has!Jump) return jump;
        return Value(Closure(closure.target, captures));
    }

    /// The callee is evaluated before the arguments.
    private Value evaluate(ref const CallClosure call, Value[] frame)
    {
        auto callee = evaluate(*call.callee, frame);
        if (callee.has!Jump) return callee;
        auto closure = callee.as!Closure;
        return callWith(closure.target, closure.captures, call.args, frame);
    }

    /// Calls `target` with `args`, each evaluated into the callee's frame. An argument for a
    /// mutable param is read once the others have been evaluated, and gets the param's final
    /// value when the call ends.
    private Value callWith(size_t target, Value[] captures, const Expr[] args, Value[] frame)
    {
        auto func = &_program.functions[target];
        auto params = func.params;
        auto callee = newFrame(*func);
        auto anyMutable = false;
        foreach (i, ref arg; args)
        {
            if (params[i].mutable)
            {
                anyMutable = true;
                continue;
            }
            auto value = evaluate(arg, frame);
            if (value.has!Jump) return value;
            callee[params[i].slot] = value;
        }
        if (!anyMutable) return enter(*func, callee, captures);

        foreach (i, ref arg; args)
        {
            if (params[i].mutable) callee[params[i].slot] = frame[mutableLocal(arg).slot];
        }
        auto result = enter(*func, callee, captures);
        foreach (i, ref arg; args)
        {
            if (params[i].mutable) frame[mutableLocal(arg).slot] = callee[params[i].slot];
        }
        return result;
    }

    private static const(Local) mutableLocal(ref const Expr arg)
    {
        return arg.kind.match!(
            (ref const LocalRef use) => use.local,
            (ref const _) => assert(0, "lowering passes a local to a mutable param"),
        );
    }

    private Value evaluate(ref const If if_, Value[] frame)
    {
        auto condition = evaluate(*if_.condition, frame);
        if (condition.has!Jump) return condition;
        return evaluate(condition.as!bool ? *if_.trueBody : *if_.falseBody, frame);
    }

    private Value evaluate(ref const Loop loop, Value[] frame)
    {
        while (true)
        {
            auto left = evaluate(*loop.body, frame);
            if (!left.has!Jump) continue;
            auto jump = left.as!Jump;
            if (jump.kind == Jump.Kind.return_ || jump.label != loop.label) return left;
            if (jump.kind == Jump.Kind.break_) return Value(Unit());
        }
    }

    private Value evaluate(ref const Construct construct, Value[] frame)
    {
        Value[] fields;
        auto jump = all(construct.fields, frame, fields);
        if (jump.has!Jump) return jump;
        return Value(Record(0, fields));
    }

    private Value evaluate(ref const Field field, Value[] frame)
    {
        auto object = evaluate(*field.object, frame);
        if (object.has!Jump) return object;
        return object.as!Record.fields[field.index];
    }

    private Value evaluate(ref const Update update, Value[] frame)
    {
        auto object = evaluate(*update.object, frame);
        if (object.has!Jump) return object;
        auto value = evaluate(*update.value, frame);
        if (value.has!Jump) return value;
        auto record = object.as!Record;
        auto fields = record.fields.dup;
        fields[update.index] = value;
        return Value(Record(record.tag, fields));
    }

    private Value evaluate(ref const Inject inject, Value[] frame)
    {
        if (inject.payload is null) return Value(Record(inject.member, null));
        auto payload = evaluate(*inject.payload, frame);
        if (payload.has!Jump) return payload;
        return Value(Record(inject.member, [payload]));
    }

    private Value evaluate(ref const IsMember test, Value[] frame)
    {
        auto subject = evaluate(*test.subject, frame);
        if (subject.has!Jump) return subject;
        return Value(subject.as!Record.tag == test.member);
    }

    private Value evaluate(ref const Payload payload, Value[] frame)
    {
        auto subject = evaluate(*payload.subject, frame);
        if (subject.has!Jump) return subject;
        return subject.as!Record.fields[0];
    }

    private Value evaluate(ref const Capture capture, Value[] frame)
    {
        auto closure = evaluate(*capture.closure, frame);
        if (closure.has!Jump) return closure;
        return closure.as!Closure.captures[capture.index];
    }

    private Value evaluate(ref const Expr e, ref const Convert convert, Value[] frame)
    {
        auto value = evaluate(*convert.value, frame);
        if (value.has!Jump) return value;
        return this.convert(value, convert.value.type, e.type);
    }

    private Value evaluate(ref const Expr e, ref const ArrayLit literal, Value[] frame)
    {
        Value[] elements;
        auto jump = all(literal.elements, frame, elements);
        if (jump.has!Jump) return jump;
        return arrayOf(elements, e.type);
    }

    private Value evaluate(ref const Length length, Value[] frame)
    {
        auto array = evaluate(*length.array, frame);
        if (array.has!Jump) return array;
        if (array.has!string) return Value(cast(long) array.as!string.length);
        return Value(cast(long) array.as!ArrayValue.elements.length);
    }

    /// An index of any integer type, as unsigned, so a negative one is too large.
    private static ulong position(Value index)
    {
        return cast(ulong) index.as!long;
    }

    private Value evaluate(ref const Index index, Value[] frame)
    {
        auto array = evaluate(*index.array, frame);
        if (array.has!Jump) return array;
        auto place = evaluate(*index.index, frame);
        if (place.has!Jump) return place;
        auto at = position(place);
        if (array.has!string)
        {
            auto bytes = array.as!string;
            if (at >= bytes.length) throw new CodedException(DiagnosticCode.IndexOutOfRange, "Index is out of range");
            return Value(long(cast(ubyte) bytes[cast(size_t) at]));
        }
        auto elements = array.as!ArrayValue.elements;
        if (at >= elements.length) throw new CodedException(DiagnosticCode.IndexOutOfRange, "Index is out of range");
        return elements[cast(size_t) at];
    }

    /// An array of `type` holding `elements`. A `[UInt8]` is held as a D string, the way a String
    /// is, so `bytes` and the conversion back share the buffer instead of copying it.
    private Value arrayOf(Value[] elements, Type type)
    {
        import std.algorithm : map;
        import std.array : array;

        auto types = _program.types;
        if (!types.isArray(type) || types.arrayElement(type) != types.uint8) return Value(ArrayValue(elements));
        return Value(cast(string) elements.map!(e => cast(char) e.as!long).array);
    }

    /// The bytes of a `[UInt8]`, which is an ArrayValue only when it was written `[]`.
    private static string byteString(Value array)
    {
        return array.has!string ? array.as!string : null;
    }

    private Value evaluate(ref const Slice slice, Value[] frame)
    {
        auto array = evaluate(*slice.array, frame);
        if (array.has!Jump) return array;
        auto from = evaluate(*slice.start, frame);
        if (from.has!Jump) return from;
        auto to = evaluate(*slice.end, frame);
        if (to.has!Jump) return to;
        auto start = position(from);
        auto end = position(to);
        auto length = array.has!string ? array.as!string.length : array.as!ArrayValue.elements.length;
        if (start > end || end > length)
        {
            throw new CodedException(DiagnosticCode.IndexOutOfRange, "Slice is out of range");
        }
        if (array.has!string) return Value(array.as!string[cast(size_t) start .. cast(size_t) end]);
        return Value(ArrayValue(array.as!ArrayValue.elements[cast(size_t) start .. cast(size_t) end]));
    }

    private Value evaluate(ref const Cell cell, Value[] frame)
    {
        auto first = evaluate(cell.args[0], frame);
        if (first.has!Jump) return first;
        if (cell.op == CellOp.New) return Value(new CellValue(first));
        Value second;
        if (cell.args.length > 1)
        {
            second = evaluate(cell.args[1], frame);
            if (second.has!Jump) return second;
        }
        auto target = first.as!CellValue;
        if (cell.op == CellOp.Fill)
        {
            target.contents = second;
            target.full = true;
            return Value(Unit());
        }
        if (!target.full) throw new CodedException(DiagnosticCode.RefInUpdate, "Ref is being updated");
        final switch (cell.op)
        {
            case CellOp.Get:
                return target.contents;
            case CellOp.Set:
                target.contents = second;
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
    private Value evaluate(ref const Prim prim, Value[] frame)
    {
        if (prim.op == PrimOp.Concat)
        {
            Value[] parts;
            auto jump = all(prim.args, frame, parts);
            return jump.has!Jump ? jump : concat(parts);
        }
        auto lhs = evaluate(prim.args[0], frame);
        if (lhs.has!Jump) return lhs;
        Value rhs;
        if (prim.args.length > 1)
        {
            rhs = evaluate(prim.args[1], frame);
            if (rhs.has!Jump) return rhs;
        }
        switch (prim.op)
        {
            case PrimOp.Append:
                return append(lhs, rhs);
            case PrimOp.Not:
                return Value(!lhs.as!bool);
            case PrimOp.Format:
                return Value(formatted(lhs, prim.args[0].type));
            case PrimOp.Hash:
                return Value(cast(long) hashed(lhs));
            case PrimOp.CountOnes:
                import core.bitop : popcnt;

                return Value(cast(long) popcnt(cast(ulong) lhs.as!long));
            default:
                break;
        }

        auto types = _program.types;
        auto operandType = prim.args[0].type;
        // Most arithmetic is on `Int`, and asking the table about a type costs a lookup.
        if (operandType == types.int_) return integerPrim!long(prim.op, lhs, rhs);
        if (operandType == types.char_) return compare(prim.op, lhs.as!long, rhs.as!long);
        if (types.isInteger(operandType))
        {
            auto info = types.integerOf(operandType);
            switch (info.bits)
            {
                case 8: return info.signed ? integerPrim!byte(prim.op, lhs, rhs) : integerPrim!ubyte(prim.op, lhs, rhs);
                case 16: return info.signed ? integerPrim!short(prim.op, lhs, rhs) : integerPrim!ushort(prim.op, lhs, rhs);
                case 32: return info.signed ? integerPrim!int(prim.op, lhs, rhs) : integerPrim!uint(prim.op, lhs, rhs);
                case 64: return info.signed ? integerPrim!long(prim.op, lhs, rhs) : integerPrim!ulong(prim.op, lhs, rhs);
                default: assert(0, "an integer type with no D type of its width");
            }
        }
        if (lhs.has!Closure || lhs.has!CellValue || lhs.has!Handle)
        {
            assert(prim.op == PrimOp.Equal || prim.op == PrimOp.NotEqual,
                "function values, Refs and native types are only compared for equality");
            auto same = lhs.has!Closure ? sameFunction(lhs.as!Closure, rhs.as!Closure)
                : lhs.has!Handle ? lhs.as!Handle.address is rhs.as!Handle.address
                : lhs.as!CellValue is rhs.as!CellValue;
            return Value(prim.op == PrimOp.Equal ? same : !same);
        }
        if (lhs.has!double)
        {
            return operandType == types.float32 ? float32Prim(prim.op, cast(float) lhs.as!double, rhs)
                : floatPrim(prim.op, lhs.as!double, rhs);
        }
        if (lhs.has!bool) return compare(prim.op, lhs.as!bool, rhs.as!bool);
        if (lhs.has!string) return compare(prim.op, lhs.as!string, rhs.as!string);
        if (lhs.has!Unit) return compare(prim.op, 0, 0);
        assert(0, "lowering only makes a Prim of primitives, arrays aside");
    }

    /// Whether `a` and `b` are closures of one function holding equal captures.
    private bool sameFunction(Closure a, Closure b)
    {
        if (a.target != b.target) return false;
        auto compare = _program.functions[a.target].captureEquality;
        if (compare == noFunction) return true;
        return invoke(compare, [Value(a), Value(b)], null).as!bool;
    }

    /// `PrimOp.Hash`, computed as the runtime does for everything but a `Ref` and a function
    /// value, whose identities differ between the backends.
    private ulong hashed(Value value)
    {
        if (value.has!bool) return mixHash(value.as!bool);
        if (value.has!long) return mixHash(value.as!long);
        if (value.has!double)
        {
            // `0.0 == -0.0`, so both hash as `0.0`.
            auto x = value.as!double;
            return mixHash(x == 0.0 ? 0 : *cast(ulong*) &x);
        }
        if (value.has!string) return hashBytes(cast(const(ubyte)[]) value.as!string);
        if (value.has!CellValue) return mixHash(cast(size_t) cast(void*) value.as!CellValue);
        if (value.has!Handle) return mixHash(cast(size_t) value.as!Handle.address);
        assert(value.has!Closure, "lowering hashes only primitives, Refs, native types and function values with `Hash`");
        auto closure = value.as!Closure;
        auto captures = _program.functions[closure.target].captureHash;
        auto hash = captures == noFunction ? 0 : cast(ulong) invoke(captures, [value], null).as!long;
        return mixHash(closure.target ^ hash);
    }

    private static Value concat(Value[] parts)
    {
        import std.algorithm : map;
        import std.array : join;

        import std.algorithm : any;

        if (parts.any!(p => p.has!string)) return Value(parts.map!(p => byteString(p)).join);
        return Value(ArrayValue(parts.map!(p => p.as!ArrayValue.elements).join));
    }

    /// D's `~=` extends the buffer in place when `lhs` ends at its used part, as the frontier
    /// rule does.
    private static Value append(Value lhs, Value rhs)
    {
        if (lhs.has!string || rhs.has!string)
        {
            auto text = byteString(lhs);
            text ~= byteString(rhs);
            return Value(text);
        }
        auto elements = lhs.as!ArrayValue.elements;
        elements ~= rhs.as!ArrayValue.elements;
        return Value(ArrayValue(elements));
    }

    private static Value floatPrim(PrimOp op, double lhs, Value second)
    {
        if (op == PrimOp.Negate) return Value(-lhs);
        auto rhs = second.as!double;
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

    /// A `Float32` is held as the `double` it widens to, which is exact. Each result is stored in a
    /// `float`, so it's rounded to single precision as the compiled code rounds it, and not later.
    private static Value float32Prim(PrimOp op, float lhs, Value second)
    {
        static Value single(float value) => Value(cast(double) value);

        if (op == PrimOp.Negate) return single(-lhs);
        float rhs = cast(float) second.as!double;
        float result;
        switch (op)
        {
            case PrimOp.Add:
                result = lhs + rhs;
                break;
            case PrimOp.Subtract:
                result = lhs - rhs;
                break;
            case PrimOp.Multiply:
                result = lhs * rhs;
                break;
            case PrimOp.Divide:
                result = lhs / rhs;
                break;
            case PrimOp.Modulo:
                result = lhs % rhs;
                break;
            default:
                return compare(op, lhs, rhs);
        }
        return single(result);
    }

    /// `T` is the D type of the operands' width and signedness. A `Value` holds every integer as
    /// a `long`, so each is cast to `T`, computed there, and cast back, which sign- or
    /// zero-extends it as the type requires.
    private static Value integerPrim(T)(PrimOp op, Value first, Value second)
    {
        static Value integer(T value)
        {
            return Value(cast(long) value);
        }

        auto lhs = cast(T) first.as!long;
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
                auto amount = cast(ulong) second.as!long;
                if (amount >= T.sizeof * 8)
                {
                    throw new CodedException(DiagnosticCode.InvalidShift, "Shift amount is out of range");
                }
                auto count = cast(int) amount;
                return integer(cast(T)(op == PrimOp.ShiftLeft ? lhs << count : lhs >> count));
            default:
                break;
        }

        auto rhs = cast(T) second.as!long;
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
        if (to == types.float32)
        {
            if (types.isFloat(from)) return Value(cast(double) cast(float) value.as!double);
            auto bits = value.as!long;
            return Value(cast(double) (types.integerOf(from).signed ? cast(float) bits : cast(float) cast(ulong) bits));
        }
        if (to == types.float_)
        {
            if (types.isFloat(from)) return value;
            auto bits = value.as!long;
            return Value(types.integerOf(from).signed ? cast(double) bits : cast(double) cast(ulong) bits);
        }

        auto target = types.integerOf(to);
        foreach (T; IntegerTypes)
        {
            if (target.bits != T.sizeof * 8 || target.signed != isSigned!T) continue;
            if (types.isFloat(from))
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

    /// A line of input as `readLine` in `lang.io` gives it, matching the runtime's
    /// `silver_readLine`: 0 and the line without its ending, 1 at the end of input, 2 for a line
    /// that isn't UTF-8, or 3 and the OS's message.
    private Value readLine()
    {
        import std.stdio : readln, StdioException;
        import std.utf : UTFException, validate;

        Value result(long status, string text = "") => Value(Record(0, [Value(status), Value(text)]));

        if (_testing) return result(1);
        string line;
        while (true)
        {
            try
            {
                line = readln();
                break;
            }
            catch (StdioException e)
            {
                enum interrupted = 4;
                if (e.errno != interrupted) return result(3, e.msg.idup);
            }
        }
        if (line.length == 0) return result(1);
        if (line[$ - 1] == '\n')
        {
            line = line[0 .. $ - 1];
            if (line.length > 0 && line[$ - 1] == '\r') line = line[0 .. $ - 1];
        }
        try validate(line);
        catch (UTFException) return result(2);
        return result(0, line);
    }

    /// `path` as the program means it, relative to the directory it was started in.
    private string located(string path)
    {
        import std.path : buildPath, isRooted;

        return _directory is null || path.length == 0 || isRooted(path) ? path : buildPath(_directory, path);
    }

    private static Value withStatus(int status, const(char)[] text)
    {
        return Value(Record(0, [Value(long(status)), Value(cast(string) text)]));
    }

    private Value evaluate(ref const Expr e, ref const IntrinsicCall call, Value[] frame)
    {
        Value[] args;
        auto jump = all(call.args, frame, args);
        if (jump.has!Jump) return jump;
        final switch (call.intrinsic)
        {
            case Intrinsic.print:
                write(formatted(args[0], call.args[0].type));
                return Value(Unit());
            case Intrinsic.printl:
                write(formatted(args[0], call.args[0].type), true);
                return Value(Unit());
            case Intrinsic.readLine:
                return readLine();
            case Intrinsic.readWhole:
                auto read = readWhole(located(args[0].as!string), args[1].as!bool);
                return withStatus(read.status, read.text);
            case Intrinsic.writeWhole:
                auto written = writeWhole(located(args[0].as!string), cast(const(ubyte)[]) byteString(args[1]),
                    args[2].as!bool);
                return withStatus(written.status, written.text);
            case Intrinsic.exists:
                return Value(pathExists(located(args[0].as!string)));
            case Intrinsic.panic:
                throw new CodedException(DiagnosticCode.ExplicitPanic, args[0].as!string);
            case Intrinsic.exitWithError:
                throw new ProgramFailed(args[0].as!string);
            case Intrinsic.programArguments:
                Value[] each;
                foreach (argument; _arguments) each ~= Value(argument);
                return Value(ArrayValue(each));
            case Intrinsic.bytes, Intrinsic.uncheckedString:
                return Value(byteString(args[0]));
            case Intrinsic.toCString:
                return Value(Handle(toCString(byteString(args[0]))));
            case Intrinsic.fromCString:
                auto text = fromCString(args[0].as!Handle.address);
                return text is null ? Value(Record(0, null)) : Value(Record(1, [Value(text)]));
            case Intrinsic.length, Intrinsic.get, Intrinsic.set, Intrinsic.update, Intrinsic.assert_, Intrinsic.expect, Intrinsic.uncheckedChar:
            case Intrinsic.hash, Intrinsic.countOnes:
                assert(0, "lowering makes `length` a Length, `assert` and `expect` a test, `uncheckedChar` a Convert, `hash` a derived function, `countOnes` a CountOnes, and the others operations on a Cell");
            case Intrinsic.derivedCompare:
                assert(0, "lowering expands `derivedCompare` into calls of `compare`");
            case Intrinsic.panics:
                auto work = args[0].as!Closure;
                try invoke(work.target, [], work.captures);
                catch (RuntimeError error) return Value(Record(1, [Value(error.diagnostic.message)]));
                return Value(Record(0, null));
        }
    }

    /// A call to a C function, through the platform's convention as `describeCall` describes it.
    private Value evaluate(ref const Expr e, ref const ForeignCall call, Value[] frame)
    {
        auto types = _program.types;
        auto native = &_natives[call.native];
        if (native.refusal !is null) throw new RuntimeError(Diagnostic(DiagnosticCode.MissingNativeBinding, e.span, native.refusal));

        Value[] values;
        auto jump = all(call.args, frame, values);
        if (jump.has!Jump) return jump;
        ulong[16] few;
        auto words = native.words <= few.length ? few[0 .. native.words] : new ulong[native.words];
        size_t next;
        foreach (i, value; values)
        {
            foreach (part; native.description.arguments[i].parts) words[next++] = bitsOf(value, part);
        }

        auto returned = callC(native.address, native.description, words);
        if (native.description.result.passing == Passing.nothing) return Value(Unit());
        // A scalar result is one part; a structure's would be put together from each.
        auto part = native.description.result.parts[0];
        auto bits = part.place.where == Where.floatRegister ? returned.floats[part.place.index]
            : returned.integers[part.place.index];
        final switch (part.type)
        {
            case CType.void_:
                assert(0, "a void result passes nothing");
            case CType.bool_:
                return Value((bits & 1) != 0);
            case CType.int8, CType.uint8, CType.int16, CType.uint16, CType.int32, CType.uint32, CType.int64, CType.uint64:
                return Value(fitted(bits, types.integerOf(e.type)));
            case CType.double_:
                return Value(*cast(double*) &bits);
            case CType.float_:
                auto single = cast(uint) bits;
                return Value(cast(double) *cast(float*) &single);
            case CType.pointer:
                auto address = cast(void*) bits;
                if (!isNullableHandle(e.type)) return Value(Handle(address));
                return address is null ? Value(Record(0, null)) : Value(Record(1, [Value(Handle(address))]));
        }
    }

    /// The bits of `value` that C is passed as `part`: an integer as its two's complement, which a
    /// `Value` already holds extended, a `float` in the low 32 bits, an option of a handle as null for
    /// `None`. A scalar is the whole of its one part.
    private static ulong bitsOf(Value value, Part part)
    {
        final switch (part.type)
        {
            case CType.void_:
                assert(0, "no parameter is void");
            case CType.bool_:
                return value.as!bool ? 1 : 0;
            case CType.int8, CType.uint8, CType.int16, CType.uint16, CType.int32, CType.uint32, CType.int64, CType.uint64:
                return value.as!long;
            case CType.double_:
                auto double_ = value.as!double;
                return *cast(ulong*) &double_;
            case CType.float_:
                float single = value.as!double;
                return *cast(uint*) &single;
            case CType.pointer:
                if (value.has!Handle) return cast(ulong) value.as!Handle.address;
                auto option = value.as!Record;
                return option.tag == 0 ? 0 : cast(ulong) option.fields[0].as!Handle.address;
        }
    }

    /// `bits` cut to the integer type `info` and extended back, as a `Value` holds that type.
    private static long fitted(long bits, IntegerInfo info)
    {
        if (info.bits == 64) return bits;
        auto mask = (1L << info.bits) - 1;
        auto low = bits & mask;
        if (info.signed && (low >> (info.bits - 1)) != 0) return low | ~mask;
        return low;
    }

    /// Whether `type` is an option of a native type, which crosses into C as a pointer that may be null.
    private bool isNullableHandle(Type type)
    {
        auto types = _program.types;
        return types.isOption(type) && (types.optionInner(type) in _program.nativeTypes) !is null;
    }

    /// A primitive or function `value` of `type`, as `print` shows it.
    private string formatted(Value value, Type type)
    {
        import std.conv : to;

        auto types = _program.types;
        if (type == types.char_) return [cast(dchar) value.as!long].to!string;
        if (types.isInteger(type))
        {
            auto bits = value.as!long;
            return types.integerOf(type).signed ? bits.to!string : (cast(ulong) bits).to!string;
        }
        if (value.has!Unit) return "()";
        if (value.has!bool) return value.as!bool.to!string;
        if (value.has!double)
        {
            return type == types.float32 ? float32Text(cast(float) value.as!double) : floatText(value.as!double);
        }
        if (value.has!string) return value.as!string;
        if (value.has!Handle) return addressText(value.as!Handle.address);
        assert(value.has!Closure, "lowering formats anything else itself");
        return _program.functions[value.as!Closure.target].printedName;
    }

    private Value evaluate(ref const Block block, Value[] frame)
    {
        foreach (ref statement; block.statements)
        {
            auto jump = execute(statement, frame);
            if (jump.has!Jump) return jump;
        }
        if (block.result is null) return Value(Unit());
        return evaluate(*block.result, frame);
    }

    /// Unit, or the `Jump` that leaves the statement.
    private Value execute(ref const Stmt s, Value[] frame)
    {
        return s.kind.match!(
            (ref const Let let) => store(let.local, let.value, frame),
            (ref const Assign assign) => store(assign.local, assign.value, frame),
            (ref const AssignElement assign) => execute(s, assign, frame),
            (ref const Eval eval) {
                auto value = evaluate(eval.expr, frame);
                return value.has!Jump ? value : Value(Unit());
            },
        );
    }

    private Value store(const Local local, ref const Expr value, Value[] frame)
    {
        auto stored = evaluate(value, frame);
        if (stored.has!Jump) return stored;
        frame[local.slot] = stored;
        return Value(Unit());
    }

    private Value execute(ref const Stmt s, ref const AssignElement assign, Value[] frame)
    {
        auto place = evaluate(assign.index, frame);
        if (place.has!Jump) return place;
        auto at = position(place);
        auto value = evaluate(assign.value, frame);
        if (value.has!Jump) return value;
        auto slot = assign.local.slot;
        // A statement has no expression around it of its own to give the panic its place.
        RuntimeError outOfRange() => new RuntimeError(Diagnostic(DiagnosticCode.IndexOutOfRange, s.span, "Index is out of range"));
        if (frame[slot].has!string)
        {
            auto bytes = frame[slot].as!string;
            if (at >= bytes.length) throw outOfRange();
            auto changed = bytes.dup;
            changed[cast(size_t) at] = cast(char) value.as!long;
            frame[slot] = Value(cast(string) changed);
            return Value(Unit());
        }
        auto elements = frame[slot].as!ArrayValue.elements;
        if (at >= elements.length) throw outOfRange();
        auto replaced = elements.dup;
        replaced[cast(size_t) at] = value;
        frame[slot] = Value(ArrayValue(replaced));
        return Value(Unit());
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

/// Thrown when a test stops, as `?` on `None` stops it, and caught by the test runner.
private class TestStop : Throwable
{
    this(string message)
    {
        super(message);
        info = noTrace;
    }
}

/// A `TestStop` with `info` already set isn't given a stack trace when it's thrown. Capturing one
/// costs milliseconds on Windows.
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

/// `x` with its bits mixed, by MurmurHash3's finalizer, as codegen's `@silver.hash.mix` does.
private ulong mixHash(ulong x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53;
    return x ^ (x >> 33);
}

/// A String's hash: FNV-1a over its bytes, then mixed, as `silver_hash_string` does.
private ulong hashBytes(const(ubyte)[] bytes)
{
    ulong hash = 0xcbf29ce484222325;
    foreach (b; bytes) hash = (hash ^ b) * 0x100000001b3;
    return mixHash(hash);
}
