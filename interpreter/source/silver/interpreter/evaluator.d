module silver.interpreter.evaluator;

import core.exception : OutOfMemoryError;
import std.conv : to;
import std.format : format;
import std.meta : AliasSeq, staticIndexOf;
import std.traits : isSigned;

import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException, Span;
import silver.sema;
import silver.core;
import silver.interpreter.errors;
import silver.interpreter.frames : FrameStack;
import silver.interpreter.stack : runOnLargeStack, stackNearlyFull, stackOverflow;
import silver.interpreter.foreign : addressText, callC, findNative, fromCString, toCString;
import silver.interpreter.values;
import silver.runtime.files : pathExists, readWhole, writeWhole;
import silver.runtime.floattext : float32Text, floatText;

private alias IntegerTypes = AliasSeq!(byte, short, int, long, ubyte, ushort, uint, ulong);

/// Which of `Sum`'s kinds `T` is, as its `typeIndex` gives it.
private enum tagOf(Sum, T) = staticIndexOf!(T, Sum.Types);

/// The `T` that `kind`, a Core `SumType`, holds, which its `typeIndex` has already said. The
/// evaluator switches on the index and reads the member straight from the storage: `match` is three
/// calls a node that dmd doesn't inline, which was most of what a loop step cost.
private ref const(T) member(T, Sum)(ref const Sum kind) @trusted
{
    enum index = tagOf!(Sum, T);
    static assert(index >= 0, T.stringof ~ " isn't one of " ~ Sum.stringof ~ "'s kinds");
    // The storage is a union with a field for each kind, in order.
    static assert(is(typeof(kind.tupleof[0].tupleof[index]) == const T));
    assert(kind.typeIndex == index);
    return kind.tupleof[0].tupleof[index];
}

/// Runs a Core program by walking its tree.
final class Evaluator
{
    private Program _program;
    private bool _useStdOut;
    private string _output;
    private string _errorOutput;
    /// Whether tests are running, so `read` finds no input; and the failures of the current one.
    private bool _testing;
    private string[] _failures;
    /// The program's arguments, each already known to be UTF-8.
    private string[] _arguments;
    /// What a relative path is relative to, or null for the process's working directory.
    private string _directory;
    /// How to call each of the program's `natives`, found and described before anything runs.
    private Callable[] _natives;
    /// The shared library to load for a `native library` name, where one is given.
    private const(string[string]) _libraryFiles;
    /// Every running call's locals.
    private FrameStack _frames;
    private Type _int;
    /// Each integer type and `Char`, with how a Value holds it, so that asking needs no call.
    private IntegerLayout[9] _integerLayouts;

    private static struct IntegerLayout
    {
        Type type;
        IntegerInfo info;
    }

    private static struct Callable
    {
        const(void)* address;
        CallDescription description;
        /// How many words its arguments' parts take.
        size_t words;
        /// Where each structure argument's C image is in a call's one buffer of `imageBytes`, by
        /// argument, and the result's when it's a structure; each a multiple of 8 bytes.
        uint[] imageAt;
        uint resultImageAt;
        uint imageBytes;
        /// Why calling it is refused, or null.
        string refusal;
    }

    /// With `useStdOut`, output goes straight to standard output; otherwise it's kept for `output`.
    /// `directory` stands in for the directory the program was started in, so programs in one process
    /// can each have their own. `libraryFiles` gives the file to load for a `native library` name, which
    /// is otherwise found by the system's search.
    this(Program program, bool useStdOut = false, string[] arguments = null, string directory = null,
        const string[string] libraryFiles = null)
    {
        _program = program;
        _useStdOut = useStdOut;
        _arguments = arguments;
        _directory = directory;
        _libraryFiles = libraryFiles;
        auto types = program.types;
        _int = types.int_;
        foreach (i, type; [types.int8, types.int16, types.int32, types.int_, types.uint8, types.uint16, types.uint32,
            types.uint_, types.char_])
        {
            _integerLayouts[i] = IntegerLayout(type, types.integerOf(type));
        }
    }

    /// Whether `type` is an integer type or `Char`, and so held as an integer of `info`'s width and
    /// signedness.
    private bool integerLayout(Type type, out IntegerInfo info) const
    {
        foreach (ref layout; _integerLayouts)
        {
            if (same(layout.type, type))
            {
                info = layout.info;
                return true;
            }
        }
        return false;
    }

    /// Everything the program has printed so far.
    string output() const
    {
        return _output;
    }

    /// Everything the program has written to standard error so far, when it's kept (see `writeError`).
    string errorOutput() const
    {
        return _errorOutput;
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
        auto mark = _frames.mark;
        // A test that ends early leaves the frames of the calls it was in.
        scope (exit) _frames.release(mark);
        try
        {
            invoke(test.function_, [], null);
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
            auto file = native.library is null ? null : native.library in _libraryFiles;
            callable.address = findNative(native.symbol, native.library, problem, file is null ? null : *file);
            if (callable.address is null)
            {
                throw new DiagnosticException(Diagnostic(DiagnosticCode.MissingNativeBinding, native.span,
                    "`%s` can't be called when interpreting: %s".format(native.symbol, problem)));
            }
            callable.description = describeCall(_program, native, hostConvention);
            foreach (ref argument; callable.description.arguments)
            {
                callable.words += argument.parts.length;
                callable.imageAt ~= callable.imageBytes;
                if (argument.type.kind == CKind.structure) callable.imageBytes += wordBytes(argument.type);
            }
            callable.resultImageAt = callable.imageBytes;
            if (callable.description.result.type.kind == CKind.structure)
            {
                callable.imageBytes += wordBytes(callable.description.result.type);
            }
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
        catch (OutOfMemoryError)
        {
            throw new RuntimeError(Diagnostic(DiagnosticCode.OutOfMemory, _program.functions[_program.entryPoint].body.span, "Out of memory"));
        }
    }

    /// Runs function `target` with `args` and, for a lambda, `captures`.
    private Value invoke(size_t target, Value[] args, Value[] captures)
    {
        auto func = &_program.functions[target];
        auto mark = _frames.mark;
        auto frame = newFrame(*func);
        frame[0 .. args.length] = args[];
        auto result = enter(*func, frame, captures);
        _frames.release(mark);
        return result;
    }

    /// A call's locals, each at its `Local.slot`, and after them the value a `Return` leaves with,
    /// taken from `_frames`, which the caller gives back when the call ends.
    private Value[] newFrame(ref const Function func)
    {
        return _frames.take(func.localCount + 1);
    }

    /// Runs `func` in `frame`, which already holds its arguments.
    private Value enter(ref const Function func, Value[] frame, Value[] captures)
    {
        // At the function being entered, as compiled code checks on entry.
        if (stackNearlyFull()) throw new RuntimeError(Diagnostic(DiagnosticCode.StackOverflow, func.body.span, stackOverflow));
        foreach (i, capture; func.captures) frame[capture.slot] = captures[i];
        auto result = evaluate(func.body, frame);
        return result.has!Jump ? frame[$ - 1] : result;
    }

    /// The value of `e`, or the `Jump` that leaves it, which whatever evaluated `e` gives in turn
    /// until the loop or call it's for takes it.
    /// Throws: RuntimeError, located at the innermost node being evaluated, when a primitive fails.
    ///
    /// The handlers it calls are `pragma(inline, false)`: inlined here, each kept stack slots of its
    /// own, which made this function's frame 2.4 KB, paid at every level of nesting and recursion.
    private Value evaluate(ref const Expr e, Value[] frame)
    {
        alias K = ExprKind;
        switch (e.kind.typeIndex)
        {
            case tagOf!(K, LocalRef): return frame[e.kind.member!LocalRef.local.slot];
            case tagOf!(K, IntLit): return Value(cast(long) e.kind.member!IntLit.value);
            case tagOf!(K, UnitLit): return Value(Unit());
            case tagOf!(K, BoolLit): return Value(e.kind.member!BoolLit.value);
            case tagOf!(K, FloatLit): return Value(e.kind.member!FloatLit.value);
            case tagOf!(K, StringLit): return Value(e.kind.member!StringLit.value);
            case tagOf!(K, Block): return evaluate(e.kind.member!Block, frame);
            case tagOf!(K, Call):
                auto call = &e.kind.member!Call();
                return callWith(call.target, null, call.args, frame);
            case tagOf!(K, CallClosure): return evaluate(e.kind.member!CallClosure, frame);
            case tagOf!(K, MakeClosure): return evaluate(e.kind.member!MakeClosure, frame);
            case tagOf!(K, If): return evaluate(e.kind.member!If, frame);
            case tagOf!(K, Loop): return evaluate(e.kind.member!Loop, frame);
            case tagOf!(K, Break): return Value(Jump(Jump.Kind.break_, e.kind.member!Break.label));
            case tagOf!(K, Continue): return Value(Jump(Jump.Kind.continue_, e.kind.member!Continue.label));
            case tagOf!(K, Return): return evaluate(e.kind.member!Return, frame);
            case tagOf!(K, Construct): return evaluate(e.kind.member!Construct, frame);
            case tagOf!(K, Field): return evaluate(e.kind.member!Field, frame);
            case tagOf!(K, Update): return evaluate(e.kind.member!Update, frame);
            case tagOf!(K, Inject): return evaluate(e.kind.member!Inject, frame);
            case tagOf!(K, IsMember): return evaluate(e.kind.member!IsMember, frame);
            case tagOf!(K, Payload): return evaluate(e.kind.member!Payload, frame);
            case tagOf!(K, ArrayLit): return evaluate(e, e.kind.member!ArrayLit, frame);
            case tagOf!(K, Length): return evaluate(e.kind.member!Length, frame);
            case tagOf!(K, Capture): return evaluate(e.kind.member!Capture, frame);
            case tagOf!(K, TestFailure): return evaluate(e.kind.member!TestFailure, frame);
            case tagOf!(K, Prim): return evaluate(e, e.kind.member!Prim, frame);
            case tagOf!(K, Convert): return evaluate(e, e.kind.member!Convert, frame);
            case tagOf!(K, Index): return evaluate(e, e.kind.member!Index, frame);
            case tagOf!(K, Slice): return evaluate(e, e.kind.member!Slice, frame);
            case tagOf!(K, Cell): return evaluate(e, e.kind.member!Cell, frame);
            case tagOf!(K, ForeignCall): return evaluate(e, e.kind.member!ForeignCall, frame);
            case tagOf!(K, IntrinsicCall): return evaluate(e, e.kind.member!IntrinsicCall, frame);
            default: assert(0, "an Expr is one of these");
        }
    }

    /// The panic `code` with `message`, located at `at`, the node that failed. Each node that can
    /// fail itself throws one, rather than a `try` around every node adding the place, which cost
    /// about a sixth of a loop step.
    pragma(inline, false)
    private static RuntimeError panicAt(Span at, DiagnosticCode code, string message)
    {
        return new RuntimeError(Diagnostic(code, at, message));
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

    pragma(inline, false)
    private Value evaluate(ref const TestFailure failure, Value[] frame)
    {
        auto message = evaluate(*failure.message, frame);
        if (message.has!Jump) return message;
        return fail(message.as!string, failure.ends);
    }

    pragma(inline, false)
    private Value evaluate(ref const Return return_, Value[] frame)
    {
        auto value = evaluate(*return_.value, frame);
        if (value.has!Jump) return value;
        frame[$ - 1] = value;
        return Value(Jump(Jump.Kind.return_));
    }

    pragma(inline, false)
    private Value evaluate(ref const MakeClosure closure, Value[] frame)
    {
        Value[] captures;
        auto jump = all(closure.captures, frame, captures);
        if (jump.has!Jump) return jump;
        return Value(Closure(closure.target, captures));
    }

    /// The callee is evaluated before the arguments.
    pragma(inline, false)
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
        auto mark = _frames.mark;
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
            if (value.has!Jump)
            {
                _frames.release(mark);
                return value;
            }
            callee[params[i].slot] = value;
        }
        if (anyMutable)
        {
            foreach (i, ref arg; args)
            {
                if (params[i].mutable) callee[params[i].slot] = frame[mutableLocal(arg).slot];
            }
        }
        auto result = enter(*func, callee, captures);
        if (anyMutable)
        {
            foreach (i, ref arg; args)
            {
                if (params[i].mutable) frame[mutableLocal(arg).slot] = callee[params[i].slot];
            }
        }
        _frames.release(mark);
        return result;
    }

    /// Lowering passes a mutable param a `LocalRef`.
    private static const(Local) mutableLocal(ref const Expr arg)
    {
        return arg.kind.member!LocalRef.local;
    }

    pragma(inline, false)
    private Value evaluate(ref const If if_, Value[] frame)
    {
        auto condition = evaluate(*if_.condition, frame);
        if (condition.has!Jump) return condition;
        return evaluate(condition.as!bool ? *if_.trueBody : *if_.falseBody, frame);
    }

    pragma(inline, false)
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

    pragma(inline, false)
    private Value evaluate(ref const Construct construct, Value[] frame)
    {
        Value[] fields;
        auto jump = all(construct.fields, frame, fields);
        if (jump.has!Jump) return jump;
        return Value(Record(0, fields));
    }

    pragma(inline, false)
    private Value evaluate(ref const Field field, Value[] frame)
    {
        auto object = evaluate(*field.object, frame);
        if (object.has!Jump) return object;
        return object.as!Record.fields[field.index];
    }

    pragma(inline, false)
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

    pragma(inline, false)
    private Value evaluate(ref const Inject inject, Value[] frame)
    {
        if (inject.payload is null) return Value(Record(inject.member, null));
        auto payload = evaluate(*inject.payload, frame);
        if (payload.has!Jump) return payload;
        return Value(Record(inject.member, [payload]));
    }

    pragma(inline, false)
    private Value evaluate(ref const IsMember test, Value[] frame)
    {
        auto subject = evaluate(*test.subject, frame);
        if (subject.has!Jump) return subject;
        return Value(subject.as!Record.tag == test.member);
    }

    pragma(inline, false)
    private Value evaluate(ref const Payload payload, Value[] frame)
    {
        auto subject = evaluate(*payload.subject, frame);
        if (subject.has!Jump) return subject;
        return subject.as!Record.fields[0];
    }

    pragma(inline, false)
    private Value evaluate(ref const Capture capture, Value[] frame)
    {
        auto closure = evaluate(*capture.closure, frame);
        if (closure.has!Jump) return closure;
        return closure.as!Closure.captures[capture.index];
    }

    pragma(inline, false)
    private Value evaluate(ref const Expr e, ref const Convert convert, Value[] frame)
    {
        auto value = evaluate(*convert.value, frame);
        if (value.has!Jump) return value;
        return this.convert(value, convert.value.type, e.type, e.span);
    }

    pragma(inline, false)
    private Value evaluate(ref const Expr e, ref const ArrayLit literal, Value[] frame)
    {
        Value[] elements;
        auto jump = all(literal.elements, frame, elements);
        if (jump.has!Jump) return jump;
        return arrayOf(elements, e.type);
    }

    pragma(inline, false)
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

    pragma(inline, false)
    private Value evaluate(ref const Expr e, ref const Index index, Value[] frame)
    {
        auto array = evaluate(*index.array, frame);
        if (array.has!Jump) return array;
        auto place = evaluate(*index.index, frame);
        if (place.has!Jump) return place;
        auto at = position(place);
        if (array.has!string)
        {
            auto bytes = array.as!string;
            if (at >= bytes.length) throw panicAt(e.span, DiagnosticCode.IndexOutOfRange, "Index is out of range");
            return Value(long(cast(ubyte) bytes[cast(size_t) at]));
        }
        auto elements = array.as!ArrayValue.elements;
        if (at >= elements.length) throw panicAt(e.span, DiagnosticCode.IndexOutOfRange, "Index is out of range");
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

    pragma(inline, false)
    private Value evaluate(ref const Expr e, ref const Slice slice, Value[] frame)
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
            throw panicAt(e.span, DiagnosticCode.IndexOutOfRange, "Slice is out of range");
        }
        if (array.has!string) return Value(array.as!string[cast(size_t) start .. cast(size_t) end]);
        return Value(ArrayValue(array.as!ArrayValue.elements[cast(size_t) start .. cast(size_t) end]));
    }

    pragma(inline, false)
    private Value evaluate(ref const Expr e, ref const Cell cell, Value[] frame)
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
        if (!target.full) throw panicAt(e.span, DiagnosticCode.RefInUpdate, "Ref is being updated");
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
    pragma(inline, false)
    private Value evaluate(ref const Expr e, ref const Prim prim, Value[] frame)
    {
        if (prim.op == PrimOp.Concat) return concat(prim, frame);
        if (prim.op == PrimOp.Append && prim.args[1].kind.typeIndex == tagOf!(ExprKind, ArrayLit))
        {
            return appendLiteral(prim, prim.args[1].kind.member!ArrayLit, frame);
        }
        auto lhs = evaluate(prim.args[0], frame);
        if (lhs.has!Jump) return lhs;
        Value rhs;
        if (prim.args.length > 1)
        {
            rhs = evaluate(prim.args[1], frame);
            if (rhs.has!Jump) return rhs;
        }
        // Most arithmetic is on `Int`, and asking the table about a type costs a lookup.
        if (onNumbers[prim.op] && same(prim.args[0].type, _int)) return integerPrim!long(prim.op, lhs, rhs, e.span);
        return apply(e, prim, lhs, rhs);
    }

    /// `lhs ~= [a, b]`: the elements are appended to `lhs` with no array made of them first. As
    /// compiled code does, `lhs` is evaluated first and then every element, so one that leaves
    /// (`?`, `break`, `return`) appends nothing, and `xs ~= [xs[0]]` reads `xs` before it grows.
    pragma(inline, false)
    private Value appendLiteral(ref const Prim prim, ref const ArrayLit literal, Value[] frame)
    {
        auto lhs = evaluate(prim.args[0], frame);
        if (lhs.has!Jump) return lhs;
        Value only;
        Value[] elements;
        if (literal.elements.length == 1)
        {
            only = evaluate(literal.elements[0], frame);
            if (only.has!Jump) return only;
            elements = (&only)[0 .. 1];
        }
        else
        {
            auto jump = all(literal.elements, frame, elements);
            if (jump.has!Jump) return jump;
        }

        auto types = _program.types;
        if (lhs.has!string || lhs.as!ArrayValue.elements.length == 0 && types.arrayElement(prim.args[0].type) == types.uint8)
        {
            auto text = byteString(lhs);
            foreach (element; elements) text ~= cast(char) element.as!long;
            return Value(text);
        }
        auto held = lhs.as!ArrayValue.elements;
        held ~= elements;
        return Value(ArrayValue(held));
    }

    /// Whether `op` is arithmetic or a comparison, which `integerPrim` computes for an integer.
    private static immutable bool[PrimOp.max + 1] onNumbers = () {
        bool[PrimOp.max + 1] table = true;
        foreach (op; [PrimOp.Not, PrimOp.Concat, PrimOp.Append, PrimOp.Format, PrimOp.Hash, PrimOp.CountOnes])
        {
            table[op] = false;
        }
        return table;
    }();

    /// Whether `a` and `b` are one type. dmd compares a struct with `==` by calling `memcmp`.
    private static bool same(Type a, Type b)
    {
        return a.tupleof == b.tupleof;
    }

    pragma(inline, false)
    private Value concat(ref const Prim prim, Value[] frame)
    {
        Value[] parts;
        auto jump = all(prim.args, frame, parts);
        return jump.has!Jump ? jump : concat(parts);
    }

    /// `prim` of `lhs` and, if it has a second operand, `rhs`.
    pragma(inline, false)
    private Value apply(ref const Expr e, ref const Prim prim, Value lhs, Value rhs)
    {
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
        if (operandType == types.char_) return compare(prim.op, lhs.as!long, rhs.as!long);
        IntegerInfo info;
        if (integerLayout(operandType, info))
        {
            switch (info.bits)
            {
                case 8: return info.signed ? integerPrim!byte(prim.op, lhs, rhs, e.span) : integerPrim!ubyte(prim.op, lhs, rhs, e.span);
                case 16: return info.signed ? integerPrim!short(prim.op, lhs, rhs, e.span) : integerPrim!ushort(prim.op, lhs, rhs, e.span);
                case 32: return info.signed ? integerPrim!int(prim.op, lhs, rhs, e.span) : integerPrim!uint(prim.op, lhs, rhs, e.span);
                case 64: return info.signed ? integerPrim!long(prim.op, lhs, rhs, e.span) : integerPrim!ulong(prim.op, lhs, rhs, e.span);
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
    private static Value integerPrim(T)(PrimOp op, Value first, Value second, Span at)
    {
        static Value integer(T value)
        {
            return Value(cast(long) value);
        }

        auto lhs = cast(T) first.as!long;
        // Read only by an operator with a second operand. One switch for every operator, as each
        // case is a jump the processor has to guess.
        T rhs() => cast(T) second.as!long;
        switch (op)
        {
            case PrimOp.Add: return integer(checked!"+"(lhs, rhs, at));
            case PrimOp.Subtract: return integer(checked!"-"(lhs, rhs, at));
            case PrimOp.Multiply: return integer(checked!"*"(lhs, rhs, at));
            case PrimOp.Equal: return Value(lhs == rhs);
            case PrimOp.NotEqual: return Value(lhs != rhs);
            case PrimOp.Less: return Value(lhs < rhs);
            case PrimOp.LessEqual: return Value(lhs <= rhs);
            case PrimOp.Greater: return Value(lhs > rhs);
            case PrimOp.GreaterEqual: return Value(lhs >= rhs);
            case PrimOp.WrappingAdd: return integer(cast(T)(lhs + rhs));
            case PrimOp.WrappingSubtract: return integer(cast(T)(lhs - rhs));
            case PrimOp.WrappingMultiply: return integer(cast(T)(lhs * rhs));
            case PrimOp.Divide, PrimOp.Modulo:
                auto divisor = rhs;
                if (divisor == 0) throw panicAt(at, DiagnosticCode.DivisionByZero, "Division by zero");
                static if (isSigned!T)
                {
                    if (lhs == T.min && divisor == -1) throw overflow(at);
                }
                return integer(cast(T)(op == PrimOp.Divide ? lhs / divisor : lhs % divisor));
            case PrimOp.BitAnd: return integer(cast(T)(lhs & rhs));
            case PrimOp.BitOr: return integer(cast(T)(lhs | rhs));
            case PrimOp.BitXor: return integer(cast(T)(lhs ^ rhs));
            case PrimOp.Negate:
                static if (isSigned!T)
                {
                    if (lhs == T.min) throw overflow(at);
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
                    throw panicAt(at, DiagnosticCode.InvalidShift, "Shift amount is out of range");
                }
                auto count = cast(int) amount;
                return integer(cast(T)(op == PrimOp.ShiftLeft ? lhs << count : lhs >> count));
            default:
                assert(0, "sema checked the operator against the operands' type");
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

    private static T checked(string op, T)(T lhs, T rhs, Span at)
    {
        static if (T.sizeof < 4)
        {
            // These fit an int, whatever the operator.
            int wide = mixin("int(lhs) " ~ op ~ " int(rhs)");
            if (wide < T.min || wide > T.max) throw overflow(at);
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
            if (overflowed) throw overflow(at);
            return result;
        }
    }

    pragma(inline, false)
    private static RuntimeError overflow(Span at)
    {
        return panicAt(at, DiagnosticCode.IntegerOverflow, "Integer overflow");
    }

    /// `value`, of the number type `from`, as `to`. A Float is truncated toward zero first, and
    /// a value that doesn't fit `to`, NaN among them, panics.
    private Value convert(Value value, Type from, Type to, Span at)
    {
        // Every number that isn't an integer is a float.
        IntegerInfo source;
        auto fromFloat = !integerLayout(from, source);
        if (same(to, _program.types.float32))
        {
            if (fromFloat) return Value(cast(double) cast(float) value.as!double);
            auto bits = value.as!long;
            return Value(cast(double) (source.signed ? cast(float) bits : cast(float) cast(ulong) bits));
        }
        if (same(to, _program.types.float_))
        {
            if (fromFloat) return value;
            auto bits = value.as!long;
            return Value(source.signed ? cast(double) bits : cast(double) cast(ulong) bits);
        }

        IntegerInfo target;
        auto toInteger = integerLayout(to, target);
        assert(toInteger, "sema only converts numbers");
        foreach (T; IntegerTypes)
        {
            if (target.bits != T.sizeof * 8 || target.signed != isSigned!T) continue;
            if (fromFloat)
            {
                auto number = value.as!double;
                if (!floatFits!T(number)) throw conversionFailure!T(at);
                return Value(cast(long) cast(T) number);
            }
            auto bits = value.as!long;
            if (source.signed)
            {
                if (!integerFits!T(bits)) throw conversionFailure!T(at);
            }
            else
            {
                if (!integerFits!T(cast(ulong) bits)) throw conversionFailure!T(at);
            }
            return Value(cast(long) cast(T) bits);
        }
        assert(0, "sema only converts numbers");
    }

    pragma(inline, false)
    private static RuntimeError conversionFailure(T)(Span at)
    {
        auto name = "%sInt%s".format(isSigned!T ? "" : "U", T.sizeof * 8);
        return panicAt(at, DiagnosticCode.InvalidConversion, "Value is out of range for " ~ name);
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

    pragma(inline, false)
    private Value evaluate(ref const Expr e, ref const IntrinsicCall call, Value[] frame)
    {
        Value[] args;
        auto jump = all(call.args, frame, args);
        if (jump.has!Jump) return jump;
        final switch (call.intrinsic)
        {
            case Intrinsic.print:
                write(args[0].as!string);
                return Value(Unit());
            case Intrinsic.printl:
                write(args[0].as!string, true);
                return Value(Unit());
            case Intrinsic.eprint:
                writeError(args[0].as!string);
                return Value(Unit());
            case Intrinsic.eprintl:
                writeError(args[0].as!string, true);
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
                throw panicAt(e.span, DiagnosticCode.ExplicitPanic, args[0].as!string);
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
                auto mark = _frames.mark;
                try invoke(work.target, [], work.captures);
                catch (RuntimeError error)
                {
                    // The panic left the calls it ended without giving back their frames.
                    _frames.release(mark);
                    return Value(Record(1, [Value(error.diagnostic.message)]));
                }
                return Value(Record(0, null));
        }
    }

    /// A call to a C function, through the platform's convention as `describeCall` describes it. A
    /// structure is put into C's layout in a buffer, which its parts are taken from or whose address is
    /// passed, and one that comes back is read out of one.
    pragma(inline, false)
    private Value evaluate(ref const Expr e, ref const ForeignCall call, Value[] frame)
    {
        auto native = &_natives[call.native];
        if (native.refusal !is null) throw new RuntimeError(Diagnostic(DiagnosticCode.MissingNativeBinding, e.span, native.refusal));

        Value[] values;
        auto jump = all(call.args, frame, values);
        if (jump.has!Jump) return jump;
        ulong[16] few;
        auto words = native.words <= few.length ? few[0 .. native.words] : new ulong[native.words];
        // Every structure's C image, in one buffer that lives until the call returns: on this stack
        // when it's small, or else held by `held`, since `words`, which may hold an address into it,
        // isn't scanned by the collector.
        ulong[32] fewImages;
        auto held = native.imageBytes <= fewImages.sizeof ? fewImages[0 .. (native.imageBytes + 7) / 8]
            : new ulong[](native.imageBytes / 8);
        auto images = cast(ubyte[]) held;
        size_t next;
        foreach (i, value; values)
        {
            auto crossing = &native.description.arguments[i];
            if (crossing.type.kind != CKind.structure)
            {
                words[next++] = bitsOf(value, crossing.parts[0].type);
                continue;
            }
            auto image = images[native.imageAt[i] .. native.imageAt[i] + wordBytes(crossing.type)];
            pack(value, _program.natives[call.native].params[i], crossing.type, image, 0);
            if (crossing.passing == Passing.copy)
            {
                words[next++] = cast(ulong) image.ptr;
                continue;
            }
            foreach (part; crossing.parts) words[next++] = wordAt(image, part.offset, part.size);
        }

        auto result = &native.description.result;
        ubyte[] resultImage;
        if (result.type.kind == CKind.structure)
        {
            resultImage = images[native.resultImageAt .. native.resultImageAt + wordBytes(result.type)];
        }
        auto returned = callC(native.address, native.description, words,
            result.passing == Passing.hidden ? resultImage.ptr : null);
        keepAlive(held.ptr);
        if (result.passing == Passing.nothing) return Value(Unit());
        if (result.type.kind == CKind.structure)
        {
            if (result.passing == Passing.value)
            {
                foreach (part; result.parts)
                {
                    auto bits = part.place.where == Where.floatRegister ? returned.floats[part.place.index]
                        : returned.integers[part.place.index];
                    resultImage[part.offset .. part.offset + part.size] = (cast(ubyte*) &bits)[0 .. part.size];
                }
            }
            return unpack(e.type, result.type, resultImage, 0);
        }
        auto part = result.parts[0];
        auto bits = part.place.where == Where.floatRegister ? returned.floats[part.place.index]
            : returned.integers[part.place.index];
        // A `Bool` result is its low bit, as compiled code reads a `zeroext i1`.
        if (part.type == CKind.bool_) return Value((bits & 1) != 0);
        return valueOf(bits, part.type, e.type);
    }

    /// The room a C structure of `type` takes in a call's buffer, rounded up to whole 8-byte words so
    /// a part is read whole.
    private static uint wordBytes(const CType type)
    {
        return (type.size + 7) / 8 * 8;
    }

    /// Keeps what `pointer` points to from being collected before this is reached.
    pragma(inline, false)
    private static void keepAlive(const(void)* pointer) nothrow @nogc
    {
        asm nothrow @nogc { nop; }
    }

    /// The `size` bytes at `offset` in `image`, as the low bytes of a word.
    private static ulong wordAt(const(ubyte)[] image, uint offset, uint size)
    {
        ulong word;
        (cast(ubyte*) &word)[0 .. size] = image[offset .. offset + size];
        return word;
    }

    /// Writes `value`, of the native structure `type`, into C's layout `layout` at `at` bytes into
    /// `image`: a `Bool` as a byte, and an option of a handle as a pointer that's null for `None`.
    private void pack(Value value, Type type, const CType layout, ubyte[] image, uint at)
    {
        auto fields = value.as!Record.fields;
        foreach (i, field; _program.recordFields[type])
        {
            auto c = layout.fields[i];
            if (c.type.kind == CKind.structure)
            {
                pack(fields[i], field, c.type, image, at + c.offset);
                continue;
            }
            auto bits = bitsOf(fields[i], c.type.kind);
            auto offset = at + c.offset;
            image[offset .. offset + c.type.size] = (cast(ubyte*) &bits)[0 .. c.type.size];
        }
    }

    /// A value of the native structure `type`, read out of C's layout `layout` at `at` bytes into
    /// `image`: a `Bool` is a byte that isn't 0, and an option of a handle is `None` for null.
    private Value unpack(Type type, const CType layout, const(ubyte)[] image, uint at)
    {
        Value[] fields;
        foreach (i, field; _program.recordFields[type])
        {
            auto c = layout.fields[i];
            if (c.type.kind == CKind.structure)
            {
                fields ~= unpack(field, c.type, image, at + c.offset);
                continue;
            }
            auto bits = wordAt(image, at + c.offset, c.type.size);
            fields ~= c.type.kind == CKind.bool_ ? Value(bits != 0) : valueOf(bits, c.type.kind, field);
        }
        return Value(Record(0, fields));
    }

    /// The value of `type` that C gave as `bits` of the scalar `kind`: an integer cut to the declared
    /// width, a `float` from the low 32 bits, and an option of a handle `None` for null.
    private Value valueOf(ulong bits, CKind kind, Type type)
    {
        switch (kind)
        {
            case CKind.int8, CKind.uint8, CKind.int16, CKind.uint16, CKind.int32, CKind.uint32, CKind.int64, CKind.uint64:
                return Value(fitted(bits, _program.types.integerOf(type)));
            case CKind.double_:
                return Value(*cast(double*) &bits);
            case CKind.float_:
                auto single = cast(uint) bits;
                return Value(cast(double) *cast(float*) &single);
            case CKind.pointer:
                auto address = cast(void*) bits;
                if (!isNullableHandle(type)) return Value(Handle(address));
                return address is null ? Value(Record(0, null)) : Value(Record(1, [Value(Handle(address))]));
            default:
                assert(0, "a scalar C gives back is an integer, a floating-point number or a pointer");
        }
    }

    /// The bits of `value` that C is given as the scalar `kind`: an integer as its two's complement,
    /// which a `Value` already holds extended, a `float` in the low 32 bits, an option of a handle as
    /// null for `None`.
    private static ulong bitsOf(Value value, CKind kind)
    {
        switch (kind)
        {
            case CKind.bool_:
                return value.as!bool ? 1 : 0;
            case CKind.int8, CKind.uint8, CKind.int16, CKind.uint16, CKind.int32, CKind.uint32, CKind.int64, CKind.uint64:
                return value.as!long;
            case CKind.double_:
                auto double_ = value.as!double;
                return *cast(ulong*) &double_;
            case CKind.float_:
                float single = value.as!double;
                return *cast(uint*) &single;
            case CKind.pointer:
                if (value.has!Handle) return cast(ulong) value.as!Handle.address;
                auto option = value.as!Record;
                return option.tag == 0 ? 0 : cast(ulong) option.fields[0].as!Handle.address;
            default:
                assert(0, "C is given a scalar as an integer, a floating-point number or a pointer");
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

    pragma(inline, false)
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
        alias K = StmtKind;
        switch (s.kind.typeIndex)
        {
            case tagOf!(K, Let):
                auto let = &s.kind.member!Let();
                return store(let.local, let.value, frame);
            case tagOf!(K, Assign):
                auto assign = &s.kind.member!Assign();
                return store(assign.local, assign.value, frame);
            case tagOf!(K, AssignElement):
                return execute(s, s.kind.member!AssignElement, frame);
            case tagOf!(K, Eval):
                auto value = evaluate(s.kind.member!Eval.expr, frame);
                return value.has!Jump ? value : Value(Unit());
            default:
                assert(0, "a Stmt is one of these");
        }
    }

    private Value store(const Local local, ref const Expr value, Value[] frame)
    {
        auto stored = evaluate(value, frame);
        if (stored.has!Jump) return stored;
        frame[local.slot] = stored;
        return Value(Unit());
    }

    pragma(inline, false)
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

    /// What the program writes to standard error, for the intrinsics that do. A write that fails is ignored.
    /// Kept for `errorOutput` unless output goes to standard output or tests are running, which, as a compiled
    /// program's tests do, write it to the real standard error.
    private void writeError(string text, bool newLine = false)
    {
        import std.stdio : stderr;

        if (newLine) text ~= "\n";
        if (_useStdOut || _testing)
        {
            try
            {
                stderr.write(text);
                stderr.flush();
            }
            catch (Exception) {}
        }
        else
        {
            _errorOutput ~= text;
        }
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
