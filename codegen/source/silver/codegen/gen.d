module silver.codegen.gen;

import std.algorithm : all, canFind, filter, fold, map;
import std.array : array, join;
import std.format : format;
import std.sumtype : match;

import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException, SourceMap, Span;
import silver.codegen.runtime_bindings : runtime;
import silver.core;
import silver.sema : FunctionData, IntegerInfo, Intrinsic, Type;

/// The LLVM IR for `program`, as text. `sources` locates spans for panic messages.
/// Throws: DiagnosticException (`NotImplemented`) at the first construct codegen doesn't handle yet.
string generate(const Program program, const SourceMap sources)
{
    return new Generator(program, sources).emitProgram();
}

/// The code for one expression and the operand holding its value. Fragments are values: an
/// expression's fragment is built from its children's, and the parent decides where each one
/// goes. Evaluation order is the order they're sequenced with `then`. A fragment starts in
/// whatever block the parent places it in and ends in `endBlock`.
private struct Fragment
{
    /// Instructions and labels in order, instructions already indented.
    string[] code;
    /// A temp (`%.t3`), a constant (`42`) or a global (`@.str.0`). Null for a value with no
    /// operand, like `()`, and for a statement.
    string value;
    /// The block control is in after `code` runs, or null when the code opened no block and so
    /// ends in the one it started in.
    string endBlock;

    /// A value that needs no code.
    static Fragment constant(string operand)
    {
        return Fragment(null, operand);
    }

    static Fragment instruction(string text, string value = null)
    {
        return Fragment(["  " ~ text], value);
    }

    static Fragment store(string type, string value, string pointer)
    {
        return instruction("store %s %s, ptr %s".format(type, value, pointer));
    }

    /// Starts block `name`: everything sequenced after this is in it.
    static Fragment label(string name)
    {
        return Fragment([name ~ ":"], null, name);
    }

    /// Ends the current block by branching on the `i1` operand `condition`.
    static Fragment branch(string condition, string ifTrue, string ifFalse)
    {
        return instruction("br i1 %s, label %%%s, label %%%s".format(condition, ifTrue, ifFalse));
    }

    /// Ends the current block by going to `target`.
    static Fragment jump(string target)
    {
        return instruction("br label %%%s".format(target));
    }

    /// Ends the current block, which control can't reach the end of.
    static Fragment unreachable()
    {
        return instruction("unreachable");
    }

    /// Returns `value`, which is `type`; a `void` function returns nothing.
    static Fragment ret(string type, string value)
    {
        return instruction(type == "void" ? "ret void" : "ret %s %s".format(type, value));
    }

    /// This fragment followed by `next`, with `next`'s value.
    Fragment then(Fragment next) const
    {
        return Fragment(code ~ next.code, next.value,
            next.endBlock !is null ? next.endBlock : endBlock);
    }

    /// The same code, with another value, or none for a statement.
    Fragment withValue(string newValue) const
    {
        return Fragment(code.dup, newValue, endBlock);
    }
}

/// Where each local of one function lives: a pointer for every local with an operand, which is
/// its own stack slot, or for a mutable param, its caller's.
private struct Slots
{
    string[const Local] pointers;
    /// The `alloca` of each stack slot, for the top of the entry block.
    string[] allocas;
    /// How many locals of each name have a slot, so a reused name gets a slot of its own.
    private int[string] _named;

    /// A stack slot of `type` for `local`.
    void allocate(const Local local, string type)
    {
        auto count = _named.require(local.name, 0);
        _named[local.name] = count + 1;
        auto slot = count == 0 ? "%%%s.addr".format(local.name) : "%%%s.addr.%s".format(local.name, count);
        pointers[local] = slot;
        allocas ~= "  %s = alloca %s".format(slot, type);
    }

    /// `pointer`, which already points at a slot of `local`'s type, as where it lives.
    void bind(const Local local, string pointer)
    {
        pointers[local] = pointer;
    }

    /// Where `local` lives, or null for one with no operand.
    string opIndex(const Local local) const
    {
        auto pointer = local in pointers;
        return pointer is null ? null : *pointer;
    }
}

/// The blocks a `Loop` jumps to: `head` starts its body again, and `end` leaves it.
private struct LoopTargets
{
    string head;
    string end;
}

/// What's unique within one function: the names it has handed out, and where each local lives.
/// A fresh one per function.
private final class FunctionState
{
    /// Where every local lives, fixed before any of the function's code is generated.
    const Slots slots;
    /// The function's LLVM return type, which `Return` needs.
    string returnType;
    /// The blocks of each loop being generated, by its label.
    LoopTargets[size_t] loops;
    /// Whether the function has the runtime hand back a String or buffer, which comes through
    /// these two slots, allocated once at the top of the function.
    bool usesOutSlots;
    private int _nextTemp;
    private int _nextLabel;

    enum outData = "%.out.data";
    enum outLength = "%.out.length";

    this(Slots slots, string returnType)
    {
        this.slots = slots;
        this.returnType = returnType;
    }

    /// A fresh SSA name. Silver identifiers can't contain `.`, so names that start with one
    /// never clash with anything taken from source.
    string newTemp()
    {
        return "%%.t%s".format(_nextTemp++);
    }

    /// A fresh block name, which starts with `.` for the same reason.
    string newLabel(string hint)
    {
        return ".%s.%s".format(hint, _nextLabel++);
    }

    /// `text` as an instruction whose result goes in a new temp, or in `name` if given, which is
    /// the fragment's value.
    Fragment result(string text, string name = null)
    {
        if (name is null) name = newTemp();
        return Fragment.instruction(name ~ " = " ~ text, name);
    }

    Fragment load(string type, string pointer)
    {
        return result("load %s, ptr %s".format(type, pointer));
    }

    /// `value` of `from` converted to `to` by the cast instruction `op`, e.g. `sext` or `trunc`.
    Fragment convert(string op, string from, string value, string to)
    {
        return result("%s %s %s to %s".format(op, from, value, to));
    }

    /// Element `index` of `aggregate`, a value of the struct type `type`.
    Fragment extract(string type, string aggregate, size_t index)
    {
        return result("extractvalue %s %s, %s".format(type, aggregate, index));
    }

    /// `aggregate`, of the struct type `type`, with element `index` set to `value` of `elementType`.
    Fragment insert(string type, string aggregate, string elementType, string value, size_t index)
    {
        return result("insertvalue %s %s, %s %s, %s".format(type, aggregate, elementType, value, index));
    }

    /// Calls `callee` with `arguments`, each already written with its type (`i64 %x`). The value
    /// is the result's temp, or null for a `void` function. `convention` is written before the
    /// return type when given.
    Fragment call(string returnType, string callee, const string[] arguments, string convention = null)
    {
        auto text = "call %s%s %s(%s)".format(convention is null ? "" : convention ~ " ", returnType, callee,
            arguments.join(", "));
        return returnType == "void" ? Fragment.instruction(text) : result(text);
    }
}

/// The LLVM type of every String and array: where element zero is, and how many elements.
private enum sliceLayout = "{ ptr, i64 }";
/// The LLVM type of every function value: its function's descriptor, then the environment the
/// code takes after its params.
private enum closureLayout = "{ ptr, ptr }";
/// A constant for each function used as a value: the code a closure calls, then the String a
/// function value prints as.
private enum descriptorLayout = "{ ptr, " ~ sliceLayout ~ " }";

private final class Generator
{
    private const Program _program;
    private const SourceMap _sources;
    private FunctionState _function;

    /// The runtime functions and intrinsics used, each declared once at the top of the module.
    private bool[string] _usedRuntime;
    private bool[string] _usedIntrinsics;
    /// The declaration of each C function a native binds, by its symbol.
    private string[string] _foreign;
    private string[] _globals;
    private string[string] _stringGlobals;
    /// The thunk letting a function that isn't a lambda be called through a closure, by the
    /// function's index, once one has been asked for.
    private string[size_t] _thunks;
    private string[] _thunkDefinitions;
    /// The descriptor of each function used as a value, by the function's index.
    private string[size_t] _descriptors;

    this(const ref Program program, const SourceMap sources)
    {
        _program = program;
        _sources = sources;
    }

    string emitProgram()
    {
        string[] functions;
        foreach (i, ref func; _program.functions)
        {
            functions ~= emitFunction(i, func);
        }
        auto entry = emitEntry();
        // After the functions and the entry, so every runtime call and string literal has been seen.
        return emitDeclares() ~ _globals.map!(s => s ~ "\n").join ~ "\n" ~ functions.join("\n") ~ "\n"
            ~ _thunkDefinitions.join("\n") ~ "\n" ~ entry;
    }

    /// `silver_main`, which the runtime calls once druntime has started.
    private string emitEntry()
    {
        if (_program.entryPoint == size_t.max) return emitTestEntry();
        return "define void @silver_main() {\n.entry:\n  call void %s()\n  ret void\n}\n".format(mangled(_program.entryPoint));
    }

    /// `silver_main` for running the tests: each runs through a guard, which a panic in it or `?`
    /// on `None` jumps back to, using LLVM's own setjmp and longjmp. Those only save and restore the
    /// frame, stack and resume address, and unwind nothing, which suits frames with no unwind
    /// information. The guard is the setjmp's own function, so it's live while the test runs.
    private string emitTestEntry()
    {
        foreach (declaration; ["declare ptr @llvm.frameaddress.p0(i32 immarg)", "declare ptr @llvm.stacksave.p0()",
            "declare i32 @llvm.eh.sjlj.setjmp(ptr)", "declare void @llvm.eh.sjlj.longjmp(ptr)"])
        {
            useIntrinsic(declaration);
        }
        foreach (name; ["silver_test_start", "silver_test_begin", "silver_test_end"]) _usedRuntime[name] = true;

        auto text = "@silver.test.jump = internal global [5 x ptr] zeroinitializer\n\n"
            ~ "define private void @silver.test.escape() noinline {\n.entry:\n"
            ~ "  call void @llvm.eh.sjlj.longjmp(ptr @silver.test.jump)\n  unreachable\n}\n\n"
            ~ "define private void @silver.test.guard(ptr %test) noinline {\n.entry:\n"
            ~ "  %frame = call ptr @llvm.frameaddress.p0(i32 0)\n"
            ~ "  store ptr %frame, ptr @silver.test.jump\n"
            ~ "  %stack = call ptr @llvm.stacksave.p0()\n"
            ~ "  %slot = getelementptr [5 x ptr], ptr @silver.test.jump, i64 0, i64 2\n"
            ~ "  store ptr %stack, ptr %slot\n"
            ~ "  %jumped = call i32 @llvm.eh.sjlj.setjmp(ptr @silver.test.jump)\n"
            ~ "  %fresh = icmp eq i32 %jumped, 0\n"
            ~ "  br i1 %fresh, label %run, label %done\nrun:\n  call void %test()\n  br label %done\ndone:\n  ret void\n}\n\n"
            ~ "define void @silver_main() {\n.entry:\n  call void @silver_test_start(ptr @silver.test.escape)\n";
        foreach (i, test; _program.tests)
        {
            text ~= ("  %%begin.%1$s = call i1 @silver_test_begin(i64 %1$s)\n"
                ~ "  br i1 %%begin.%1$s, label %%run.%1$s, label %%next.%1$s\nrun.%1$s:\n"
                ~ "  call void @silver.test.guard(ptr %2$s)\n  call void @silver_test_end()\n"
                ~ "  br label %%next.%1$s\nnext.%1$s:\n").format(i, mangled(test.function_));
        }
        return text ~ "  ret void\n}\n";
    }

    private string emitDeclares()
    {
        string text;
        foreach (name; _usedRuntime.byKey)
        {
            auto f = runtime[name];
            text ~= "declare %s @%s(%s) %s\n".format(f.returnType, name, f.params.join(", "), f.attributes);
        }
        foreach (line; _foreign.byValue)
        {
            text ~= line ~ "\n";
        }
        foreach (line; _usedIntrinsics.byKey)
        {
            text ~= line ~ "\n";
        }
        return text;
    }

    private string emitFunction(size_t index, const Function func)
    {
        auto returnType = llvmType(func.returnType, func.body.span);
        _function = new FunctionState(planSlots(func), returnType);
        auto stackCheck = emitStackCheck(func.body.span);

        string[] params;
        Fragment receive;
        foreach (param; func.params)
        {
            auto type = paramType(param, func.body.span);
            if (type is null) continue;
            params ~= type ~ " " ~ incoming(param);
            // A mutable param's slot is its caller's, which it was passed.
            if (!param.mutable) receive = receive.then(Fragment.store(type, incoming(param), _function.slots[param]));
        }
        if (func.origin == FunctionOrigin.lambda)
        {
            params ~= "ptr %.env";
            receive = receive.then(receiveCaptures(func));
        }

        auto body = emitExpr(func.body);
        auto ending = func.body.type == _program.types.never ? Fragment.unreachable() : Fragment.ret(returnType, body.value);
        auto whole = Fragment.label(".entry")
            .then(stackCheck)
            .then(receive)
            .then(body)
            .then(ending);

        // The allocas go right after the entry label.
        auto allocas = _function.slots.allocas.dup;
        if (_function.usesOutSlots)
        {
            allocas ~= ["  %s = alloca ptr".format(FunctionState.outData), "  %s = alloca i64".format(FunctionState.outLength)];
        }
        auto lines = whole.code[0 .. 1] ~ allocas ~ whole.code[1 .. $];
        auto linkage = func.origin == FunctionOrigin.declared ? "" : "private ";
        return "define %s%s %s(%s) {\n%s\n}\n".format(linkage, returnType, mangled(index), params.join(", "), lines.join("\n"));
    }

    /// The LLVM parameter that receives `param`.
    private static string incoming(const Local param)
    {
        return "%" ~ param.name;
    }

    /// The struct a closure's environment points to: each capture with an operand, in order.
    private string environmentLayout(const Function func)
    {
        auto stored = func.captures.map!(c => llvmType(c.type, func.body.span)).filter!(t => t != "void");
        return "{ %-(%s, %) }".format(stored);
    }

    /// A lambda's captures, loaded from its environment into their slots.
    private Fragment receiveCaptures(const Function func)
    {
        auto layout = environmentLayout(func);
        Fragment code;
        size_t at = 0;
        foreach (capture; func.captures)
        {
            auto type = llvmType(capture.type, func.body.span);
            if (type == "void") continue;
            auto pointer = fieldPointer(layout, "%.env", at++);
            auto value = _function.load(type, pointer.value);
            code = code.then(pointer).then(value).then(Fragment.store(type, value.value, _function.slots[capture]));
        }
        return code;
    }

    /// Where every local of `func` lives. Slots are allocated in the order their code will be
    /// generated, a `Let`'s after its value's, so a reused name is numbered as it's met.
    private Slots planSlots(const Function func)
    {
        Slots slots;
        foreach (param; func.params)
        {
            auto type = paramType(param, func.body.span);
            if (type is null) continue;
            if (param.mutable) slots.bind(param, incoming(param));
            else slots.allocate(param, type);
        }
        foreach (capture; func.captures)
        {
            auto type = llvmType(capture.type, func.body.span);
            if (type != "void") slots.allocate(capture, type);
        }
        planSlots(slots, func.body);
        return slots;
    }

    /// Every node is listed, so a new kind of Core node can't be skipped by accident.
    private void planSlots(ref Slots slots, const Expr e)
    {
        void all(const Expr[] exprs)
        {
            foreach (ref expr; exprs) planSlots(slots, expr);
        }

        e.kind.match!(
            (const UnitLit _) {},
            (const BoolLit _) {},
            (const IntLit _) {},
            (const FloatLit _) {},
            (const StringLit _) {},
            (const LocalRef _) {},
            (const Break _) {},
            (const Continue _) {},
            (const Call call) => all(call.args),
            (const CallClosure call) {
                planSlots(slots, *call.callee);
                all(call.args);
            },
            (const MakeClosure closure) => all(closure.captures),
            (const ForeignCall call) => all(call.args),
            (const IntrinsicCall call) => all(call.args),
            (const Prim prim) => all(prim.args),
            (const Convert convert) => planSlots(slots, *convert.value),
            (const If if_) {
                planSlots(slots, *if_.condition);
                planSlots(slots, *if_.trueBody);
                planSlots(slots, *if_.falseBody);
            },
            (const Block block) {
                foreach (ref statement; block.statements) planSlots(slots, statement);
                if (block.result !is null) planSlots(slots, *block.result);
            },
            (const Loop loop) => planSlots(slots, *loop.body),
            (const Return return_) => planSlots(slots, *return_.value),
            (const Construct construct) => all(construct.fields),
            (const Field field) => planSlots(slots, *field.object),
            (const Update update) {
                planSlots(slots, *update.object);
                planSlots(slots, *update.value);
            },
            (const Inject inject) {
                if (inject.payload !is null) planSlots(slots, *inject.payload);
            },
            (const IsMember test) => planSlots(slots, *test.subject),
            (const Payload payload) => planSlots(slots, *payload.subject),
            (const ArrayLit literal) => all(literal.elements),
            (const Index index) {
                planSlots(slots, *index.array);
                planSlots(slots, *index.index);
            },
            (const Slice slice) {
                planSlots(slots, *slice.array);
                planSlots(slots, *slice.start);
                planSlots(slots, *slice.end);
            },
            (const Length length) => planSlots(slots, *length.array),
            (const Cell cell) => all(cell.args),
            (const TestFailure failure) => planSlots(slots, *failure.message),
        );
    }

    private void planSlots(ref Slots slots, const Stmt s)
    {
        s.kind.match!(
            (const Let let) {
                planSlots(slots, let.value);
                auto type = llvmType(let.local.type, s.span);
                if (type != "void") slots.allocate(let.local, type);
            },
            (const Assign assign) => planSlots(slots, assign.value),
            (const AssignElement assign) {
                planSlots(slots, assign.index);
                planSlots(slots, assign.value);
            },
            (const Eval eval) => planSlots(slots, eval.expr),
        );
    }

    private Fragment emitExpr(const Expr e)
    {
        return e.kind.match!(kind => emit(e, kind));
    }

    /// Each of `exprs` in order, with the operand of each, null for one with none.
    private Fragment emitAll(const Expr[] exprs, out string[] operands)
    {
        Fragment code;
        foreach (ref expr; exprs)
        {
            auto value = emitExpr(expr);
            code = code.then(value);
            operands ~= operandOf(expr, value);
        }
        return code.withValue(null);
    }

    /// `value`'s operand, as the parent uses it. A `Never` has none, and the code after it is never
    /// reached, so `undef` stands in for whatever type the parent wants.
    private string operandOf(const Expr e, Fragment value)
    {
        if (value.value is null && e.type == _program.types.never) return "undef";
        return value.value;
    }

    private Fragment emit(const Expr e, const UnitLit)
    {
        return Fragment.init;
    }

    private Fragment emit(const Expr e, const BoolLit literal)
    {
        return Fragment.constant(literal.value ? "true" : "false");
    }

    /// Signed, since a negative literal is its two's complement and LLVM accepts a negative
    /// constant for an integer of any width. An unsigned value too large for the signed type of
    /// its width is written as the negative number with the same bits.
    private Fragment emit(const Expr e, const IntLit literal)
    {
        import std.conv : to;

        auto info = _program.types.integerOf(e.type);
        auto value = cast(long) literal.value;
        if (info.bits < 64 && !info.signed && value >= (1L << (info.bits - 1))) value -= 1L << info.bits;
        return Fragment.constant(value.to!string);
    }

    /// As its bits, since a decimal constant has to be exact in LLVM.
    private Fragment emit(const Expr e, const FloatLit literal)
    {
        return Fragment.constant(floatConstant(literal.value));
    }

    private static string floatConstant(double value)
    {
        return "0x%016X".format(*cast(ulong*) &value);
    }

    private Fragment emit(const Expr e, const StringLit literal)
    {
        return Fragment.constant(stringConstant(literal.value));
    }

    /// A String constant: a private global holding `text`'s bytes, with no terminator.
    private string stringConstant(string text)
    {
        if (text.length == 0) return "zeroinitializer";
        if (auto existing = text in _stringGlobals) return *existing;
        auto name = "@.str.%s".format(_globals.length);
        _globals ~= "%s = private unnamed_addr constant [%s x i8] c\"%s\"".format(name, text.length, escaped(text));
        auto operand = "{ ptr %s, i64 %s }".format(name, text.length);
        _stringGlobals[text] = operand;
        return operand;
    }

    /// The body of an LLVM `c"..."`: printable ASCII as is, every other byte as `\XX`.
    private static string escaped(string text)
    {
        string result;
        foreach (char c; text)
        {
            if (c >= ' ' && c <= '~' && c != '"' && c != '\\') result ~= c;
            else result ~= "\\%02X".format(cast(ubyte) c);
        }
        return result;
    }

    /// A local's value, loaded from its slot. A local with no operand, like a Unit one, has no slot.
    private Fragment emit(const Expr e, const LocalRef use)
    {
        auto slot = _function.slots[use.local];
        if (slot is null) return Fragment.init;
        return _function.load(llvmType(use.local.type, e.span), slot);
    }

    private Fragment emit(const Expr e, const Call call)
    {
        auto func = _program.functions[call.target];
        auto params = func.params.map!(p => paramType(p, e.span)).array;
        auto arguments = emitArguments(call.args, params, func.params.map!(p => p.mutable).array);
        auto called = arguments.code.then(_function.call(llvmType(func.returnType, e.span), mangled(call.target),
            arguments.operands));
        return endIfNever(called, e.type);
    }

    private struct Arguments
    {
        Fragment code;
        string[] operands;
    }

    /// Arguments as a call passes them, and their code. `params` is how each is passed, from
    /// `passedAs`, with null for one that's left out, and `mutables` which are mutable.
    private Arguments emitArguments(const Expr[] args, string[] params, const bool[] mutables)
    {
        Arguments result;
        foreach (i, ref arg; args)
        {
            auto type = params[i];
            if (mutables[i])
            {
                // Core passes a mutable local here, and the callee writes through its slot.
                if (type is null) continue;
                auto local = arg.kind.match!((const LocalRef use) => use.local, _ => cast(const(Local)) null);
                assert(local !is null, "lowering passes a local to a mutable param");
                result.operands ~= "ptr " ~ _function.slots[local];
                continue;
            }
            // Evaluated even when it has no operand, for what it does.
            auto value = emitExpr(arg);
            result.code = result.code.then(value);
            if (type !is null) result.operands ~= type ~ " " ~ operandOf(arg, value);
        }
        result.code = result.code.withValue(null);
        return result;
    }

    /// How `param` is passed: as its LLVM type, as a `ptr` to the caller's slot when it's mutable,
    /// or not at all, which is null, when its type has no operand. Definitions and calls agree
    /// because both ask this.
    private string paramType(const Local param, Span span)
    {
        return passedAs(param.type, param.mutable, span);
    }

    private string passedAs(Type type, bool mutable, Span span)
    {
        auto llType = llvmType(type, span);
        if (llType == "void") return null;
        return mutable ? "ptr" : llType;
    }

    /// `code`, followed by the end of its block when `type` is `Never`: whatever follows is never
    /// reached, but it still needs a block to be in.
    private Fragment endIfNever(Fragment code, Type type)
    {
        if (type != _program.types.never) return code;
        return code.then(Fragment.unreachable()).then(Fragment.label(_function.newLabel("after.noreturn")));
    }

    /// A call through a function value: its code takes the arguments, then its environment.
    private Fragment emit(const Expr e, const CallClosure call)
    {
        auto signature = functionData(call.callee.type);
        auto closure = emitExpr(*call.callee);
        auto descriptor = _function.extract(closureLayout, closure.value, 0);
        auto code = _function.load("ptr", descriptor.value);
        auto env = _function.extract(closureLayout, closure.value, 1);
        string[] params;
        bool[] mutables;
        foreach (i, param; signature.params)
        {
            params ~= passedAs(param, signature.isMutable(i), e.span);
            mutables ~= signature.isMutable(i);
        }
        auto arguments = emitArguments(call.args, params, mutables);
        auto called = closure.then(descriptor).then(code).then(env).then(arguments.code)
            .then(_function.call(llvmType(signature.ret, e.span), code.value, arguments.operands ~ ("ptr " ~ env.value)));
        return endIfNever(called, e.type);
    }

    /// A function value. A lambda's environment is a copy of its captures on the heap; any other
    /// function goes through a thunk that takes an environment and ignores it.
    private Fragment emit(const Expr e, const MakeClosure closure)
    {
        auto func = _program.functions[closure.target];
        auto descriptor = descriptorOf(closure.target, e.span);
        if (func.origin != FunctionOrigin.lambda) return Fragment.constant("{ ptr %s, ptr null }".format(descriptor));
        auto layout = environmentLayout(func);
        string[] operands;
        auto values = emitAll(closure.captures, operands);
        if (layout == "{  }") return values.withValue("{ ptr %s, ptr null }".format(descriptor));

        auto env = alloc(layout);
        auto result = values.then(env);
        size_t at = 0;
        foreach (i, capture; func.captures)
        {
            if (operands[i] is null) continue;
            auto pointer = fieldPointer(layout, env.value, at++);
            result = result.then(pointer).then(Fragment.store(llvmType(capture.type, e.span), operands[i], pointer.value));
        }
        return result.then(_function.insert(closureLayout, "{ ptr %s, ptr undef }".format(descriptor), "ptr", env.value, 1));
    }

    /// The descriptor of function `target`, which a closure of it points to. A lambda's code takes
    /// its environment itself; any other function's goes through a thunk.
    private string descriptorOf(size_t target, Span span)
    {
        if (auto existing = target in _descriptors) return *existing;
        auto func = _program.functions[target];
        auto code = func.origin == FunctionOrigin.lambda ? mangled(target) : thunk(target, span);
        auto name = "@\".fn.%s\"".format(target);
        _descriptors[target] = name;
        auto printed = stringConstant(func.printedName);
        _globals ~= "%s = private constant %s { ptr %s, %s %s }".format(name, descriptorLayout, code, sliceLayout, printed);
        return name;
    }

    /// The thunk for calling function `target` through a closure.
    private string thunk(size_t target, Span span)
    {
        if (auto existing = target in _thunks) return *existing;
        auto name = "@\".thunk.%s\"".format(target);
        _thunks[target] = name;

        auto func = _program.functions[target];
        string[] declared;
        foreach (i, param; func.params)
        {
            auto type = paramType(param, span);
            if (type !is null) declared ~= "%s %%.a%s".format(type, i);
        }
        auto returned = llvmType(func.returnType, span);
        auto body = returned == "void"
            ? "  call void %s(%s)\n  ret void\n".format(mangled(target), declared.join(", "))
            : "  %%.r = call %s %s(%s)\n  ret %s %%.r\n".format(returned, mangled(target), declared.join(", "), returned);
        _thunkDefinitions ~= "define private %s %s(%s) {\n.entry:\n%s}\n".format(returned, name,
            (declared ~ "ptr %.env").join(", "), body);
        return name;
    }

    /// A call to the C function `call.symbol`, declared from the types at the call.
    private Fragment emit(const Expr e, const ForeignCall call)
    {
        auto returnType = cType(e.type, e.span);
        Fragment arguments;
        string[] params;
        string[] operands;
        foreach (ref arg; call.args)
        {
            auto param = cType(arg.type, arg.span);
            auto value = emitExpr(arg);
            arguments = arguments.then(value);
            if (param == "void") continue;
            params ~= param;
            operands ~= param ~ " " ~ operandOf(arg, value);
        }

        auto declaration = "declare ccc %s @%s(%s)%s".format(returnType, call.symbol, params.join(", "),
            e.type == _program.types.never ? " noreturn" : "");
        if (call.symbol in runtime) return notImplemented("a native named like the runtime's own " ~ call.symbol, e.span);
        if (auto existing = call.symbol in _foreign)
        {
            if (*existing != declaration)
            {
                return notImplemented("natives that bind `%s` with different signatures".format(call.symbol), e.span);
            }
        }
        _foreign[call.symbol] = declaration;

        auto called = arguments.then(_function.call(returnType, "@" ~ call.symbol, operands, "ccc"));
        return endIfNever(called, e.type);
    }

    /// `type` as a C function takes or returns it: C's ABI wants `bool`, and integers narrower
    /// than an `int`, extended to 32 bits by whoever passes them, which LLVM leaves to the attribute.
    private string cType(Type type, Span span)
    {
        auto types = _program.types;
        if (type == types.bool_) return "zeroext i1";
        if (types.isInteger(type))
        {
            auto info = types.integerOf(type);
            if (info.bits < 32) return "%s i%s".format(info.signed ? "signext" : "zeroext", info.bits);
        }
        return llvmType(type, span);
    }

    private Fragment emit(const Expr e, const IntrinsicCall call)
    {
        final switch (call.intrinsic)
        {
            case Intrinsic.print, Intrinsic.printl:
                return emitPrint(call);
            case Intrinsic.read:
                return emitRead();
            case Intrinsic.panic:
                return emitExplicitPanic(call.args[0], e.span);
            case Intrinsic.length, Intrinsic.get, Intrinsic.set, Intrinsic.update, Intrinsic.assert_, Intrinsic.expect:
                assert(0, "lowering makes `length` a Length, `assert` and `expect` a test, and the others operations on a Cell");
        }
    }

    /// A call to the runtime's `silver_<name>`, with a suffix naming the type of the `Any` argument.
    private Fragment emitPrint(const IntrinsicCall call)
    {
        import std.conv : to;

        auto types = _program.types;
        auto arg = call.args[0];
        auto value = emitExpr(arg);
        if (arg.type == types.never) return value;
        auto name = "silver_%s_%s".format(call.intrinsic.to!string, runtimeSuffix(arg.type));
        string[] operands;
        if (arg.type == types.string_)
        {
            auto parts = sliceParts(value.value);
            value = value.then(parts.code);
            operands = [parts.data, parts.length];
        }
        else if (value.value !is null)
        {
            auto argument = value.value;
            if (types.isInteger(arg.type))
            {
                value = value.then(widened(arg.type, argument, arg.span));
                argument = value.value;
            }
            operands = [argument];
        }
        return value.then(callRuntime(name, operands)).withValue(null);
    }

    /// The suffix for an argument of `type` passed as `Any`. Every integer is `int` or `uint`.
    private string runtimeSuffix(Type type)
    {
        auto types = _program.types;
        if (types.isInteger(type)) return types.integerOf(type).signed ? "int" : "uint";
        if (type == types.float_) return "float";
        if (type == types.bool_) return "bool";
        if (type == types.unit) return "unit";
        if (type == types.string_) return "string";
        assert(0, "lowering only passes primitives to an intrinsic's Any");
    }

    /// A line of input, as a `String?`: the runtime says whether there was one, and hands the
    /// String back through the out slots.
    private Fragment emitRead()
    {
        _function.usesOutSlots = true;
        auto present = callRuntime("silver_read", [FunctionState.outData, FunctionState.outLength]);
        auto text = loadOutSlice();
        auto layout = optionLayout(sliceLayout);
        auto tagged = _function.insert(layout, "undef", "i1", present.value, 0);
        auto whole = _function.insert(layout, tagged.value, sliceLayout, text.value, 1);
        return present.then(text).then(tagged).then(whole);
    }

    /// The String or array a runtime call has just written to the out slots.
    private Fragment loadOutSlice()
    {
        auto data = _function.load("ptr", FunctionState.outData);
        auto length = _function.load("i64", FunctionState.outLength);
        return data.then(length).then(buildSlice(data.value, length.value));
    }

    /// A call to the runtime function `name`, which hands back a String through the out slots.
    private Fragment callRuntimeForString(string name, string[] operands)
    {
        _function.usesOutSlots = true;
        return callRuntime(name, operands ~ [FunctionState.outData, FunctionState.outLength]).then(loadOutSlice());
    }

    /// A failure of the running test, which the runtime records. One that ends the test returns to
    /// its guard.
    private Fragment emit(const Expr e, const TestFailure failure)
    {
        auto text = emitExpr(*failure.message);
        auto parts = sliceParts(text.value);
        auto recorded = text.then(parts.code);
        if (!failure.ends) return recorded.then(callRuntime("silver_test_failed", [parts.data, parts.length])).withValue(null);
        return recorded.then(callRuntime("silver_test_stopped", [parts.data, parts.length]))
            .then(Fragment.unreachable())
            .then(Fragment.label(_function.newLabel("after.stop")))
            .withValue(null);
    }

    /// `panic(message)`: the message, with the location first, as other panics have.
    private Fragment emitExplicitPanic(const Expr message, Span span)
    {
        auto text = emitExpr(message);
        auto prefix = stringConstant(located(span) ~ ": ");
        auto joined = text.then(emitConcat([prefix, text.value], "i8", "1"));
        auto parts = sliceParts(joined.value);
        return joined.then(parts.code)
            .then(callRuntime("silver_panic_message", [parts.data, parts.length]))
            .then(Fragment.unreachable())
            .then(Fragment.label(_function.newLabel("after.panic")))
            .withValue(null);
    }

    /// An integer as the runtime takes it: 64 bits, sign- or zero-extended.
    private Fragment widened(Type type, string value, Span span)
    {
        auto info = _program.types.integerOf(type);
        if (info.bits == 64) return Fragment.constant(value);
        return _function.convert(info.signed ? "sext" : "zext", llvmType(type, span), value, "i64");
    }

    /// A Prim's operands share one type, except a shift's amount, so the first one's type says
    /// which instruction each operation is.
    private Fragment emit(const Expr e, const Prim prim)
    {
        auto types = _program.types;
        auto operandType = prim.args[0].type;

        string[] operands;
        auto arguments = emitAll(prim.args, operands);

        switch (prim.op)
        {
            case PrimOp.Concat:
                auto layout = llvmType(elementOf(e.type), e.span);
                return arguments.then(emitConcat(operands, layout, elementSizeOf(layout)));
            case PrimOp.Append:
                return arguments.then(emitAppend(operands[0], operands[1], llvmType(elementOf(e.type), e.span)));
            case PrimOp.Format:
                return arguments.then(emitFormat(operandType, operands[0], e.span));
            default:
                break;
        }

        // `()` has one value, so comparing two is a constant.
        if (operandType == types.unit) return arguments.then(Fragment.constant(prim.op == PrimOp.Equal ? "true" : "false"));
        if (operandType == types.string_) return arguments.then(emitStringComparison(prim.op, operands[0], operands[1]));
        return arguments.then(operation(prim, operandType, operands, e.span));
    }

    /// `prim.op` on `operands`, which have been evaluated already.
    private Fragment operation(const Prim prim, Type operandType, string[] operands, Span span)
    {
        auto types = _program.types;
        auto type = llvmType(operandType, span);
        auto isFloat = operandType == types.float_;
        auto isInteger = types.isInteger(operandType);
        auto signed = isInteger && types.integerOf(operandType).signed;
        /// `op` on the operands, written after it, into a new temp.
        Fragment instruction(string op, string operands)
        {
            return _function.result("%s %s %s".format(op, type, operands));
        }
        auto both = operands.length == 2 ? operands[0] ~ ", " ~ operands[1] : null;

        final switch (prim.op)
        {
            case PrimOp.Add, PrimOp.Subtract, PrimOp.Multiply:
                if (!isFloat) return emitChecked(prim.op, operandType, operands[0], operands[1], span);
                return instruction(prim.op == PrimOp.Add ? "fadd" : prim.op == PrimOp.Subtract ? "fsub" : "fmul", both);
            case PrimOp.Divide, PrimOp.Modulo:
                auto isDivide = prim.op == PrimOp.Divide;
                if (isFloat) return instruction(isDivide ? "fdiv" : "frem", both);
                auto checks = emitDivisionChecks(operandType, operands[0], operands[1], span);
                return checks.then(instruction(isDivide ? (signed ? "sdiv" : "udiv") : (signed ? "srem" : "urem"), both));
            case PrimOp.Negate:
                // `fneg` rather than `fsub -0.0, x`, which gets -0.0 wrong.
                if (!isFloat) return emitChecked(PrimOp.Subtract, operandType, "0", operands[0], span);
                return instruction("fneg", operands[0]);
            case PrimOp.WrappingAdd: return instruction("add", both);
            case PrimOp.WrappingSubtract: return instruction("sub", both);
            case PrimOp.WrappingMultiply: return instruction("mul", both);
            case PrimOp.BitAnd: return instruction("and", both);
            case PrimOp.BitOr: return instruction("or", both);
            case PrimOp.BitXor: return instruction("xor", both);
            case PrimOp.BitNot: return instruction("xor", operands[0] ~ ", -1");
            case PrimOp.Not: return instruction("xor", operands[0] ~ ", true");
            case PrimOp.ShiftLeft, PrimOp.ShiftRight:
                auto count = emitShiftAmount(operandType, prim.args[1].type, operands[1], span);
                return count.then(instruction(prim.op == PrimOp.ShiftLeft ? "shl" : signed ? "ashr" : "lshr",
                    operands[0] ~ ", " ~ count.value));
            // `!=` is unordered so that comparing with NaN is true, as IEEE says it is.
            case PrimOp.Equal, PrimOp.NotEqual, PrimOp.Less, PrimOp.LessEqual, PrimOp.Greater, PrimOp.GreaterEqual:
                auto predicate = comparison(prim.op, isFloat, isInteger && !signed);
                return instruction((isFloat ? "fcmp " : "icmp ") ~ predicate, both);
            case PrimOp.Concat, PrimOp.Append, PrimOp.Format:
                assert(0, "handled by the caller");
        }
    }

    private static string comparison(PrimOp op, bool isFloat, bool unsigned)
    {
        switch (op)
        {
            case PrimOp.Equal: return isFloat ? "oeq" : "eq";
            case PrimOp.NotEqual: return isFloat ? "une" : "ne";
            case PrimOp.Less: return isFloat ? "olt" : unsigned ? "ult" : "slt";
            case PrimOp.LessEqual: return isFloat ? "ole" : unsigned ? "ule" : "sle";
            case PrimOp.Greater: return isFloat ? "ogt" : unsigned ? "ugt" : "sgt";
            case PrimOp.GreaterEqual: return isFloat ? "oge" : unsigned ? "uge" : "sge";
            default: assert(0, "not a comparison");
        }
    }

    /// `lhs op rhs` for two Strings, from the sign of the runtime's answer.
    private Fragment emitStringComparison(PrimOp op, string lhs, string rhs)
    {
        auto left = sliceParts(lhs);
        auto right = sliceParts(rhs);
        auto order = callRuntime("silver_string_compare", [left.data, left.length, right.data, right.length]);
        auto result = _function.result("icmp %s i32 %s, 0".format(comparison(op, false, false), order.value));
        return left.code.then(right.code).then(order).then(result);
    }

    /// A primitive or function value as a String, as `print` shows it.
    private Fragment emitFormat(Type type, string value, Span span)
    {
        auto types = _program.types;
        if (types.isInteger(type))
        {
            auto wide = widened(type, value, span);
            return wide.then(callRuntimeForString(types.integerOf(type).signed ? "silver_format_int" : "silver_format_uint",
                [wide.value]));
        }
        if (type == types.float_) return callRuntimeForString("silver_format_float", [value]);
        if (type == types.bool_) return callRuntimeForString("silver_format_bool", [value]);
        assert(types.isFunction(type), "lowering formats anything but a primitive or a function itself");
        auto descriptor = _function.extract(closureLayout, value, 0);
        auto printed = fieldPointer(descriptorLayout, descriptor.value, 1);
        return descriptor.then(printed).then(_function.load(sliceLayout, printed.value));
    }

    /// `lhs op rhs` through LLVM's overflow intrinsic, panicking if the result doesn't fit.
    private Fragment emitChecked(PrimOp op, Type type, string lhs, string rhs, Span span)
    {
        auto llType = llvmType(type, span);
        auto name = op == PrimOp.Add ? "add" : op == PrimOp.Subtract ? "sub" : "mul";
        auto intrinsic = "llvm.%s%s.with.overflow.%s".format(_program.types.integerOf(type).signed ? "s" : "u", name, llType);
        auto pairType = "{ %s, i1 }".format(llType);
        useIntrinsic("declare %s @%s(%s, %s)".format(pairType, intrinsic, llType, llType));

        auto pair = _function.call(pairType, "@" ~ intrinsic, [llType ~ " " ~ lhs, llType ~ " " ~ rhs]);
        auto value = _function.extract(pairType, pair.value, 0);
        auto overflowed = _function.extract(pairType, pair.value, 1);
        auto check = emitPanicIf(overflowed.value, span, "Integer overflow");
        return pair.then(value).then(overflowed).then(check).withValue(value.value);
    }

    /// Dividing by zero, and the most negative value by -1, are undefined in LLVM, so both panic first.
    private Fragment emitDivisionChecks(Type type, string lhs, string rhs, Span span)
    {
        auto info = _program.types.integerOf(type);
        auto llType = llvmType(type, span);
        auto isZero = _function.result("icmp eq %s %s, 0".format(llType, rhs));
        auto byZero = isZero.then(emitPanicIf(isZero.value, span, "Division by zero"));
        if (!info.signed) return byZero;

        auto isMin = _function.result("icmp eq %s %s, -%s".format(llType, lhs, info.minMagnitude));
        auto isMinusOne = _function.result("icmp eq %s %s, -1".format(llType, rhs));
        auto overflows = _function.result("and i1 %s, %s".format(isMin.value, isMinusOne.value));
        auto check = emitPanicIf(overflows.value, span, "Integer overflow");
        return byZero.then(isMin).then(isMinusOne).then(overflows).then(check).withValue(null);
    }

    /// The amount can be of any integer type, so it's checked at 64 bits, unsigned: a negative
    /// amount sign-extends to a huge one and fails the same check. Then it's made `type`'s width,
    /// which is the fragment's value.
    private Fragment emitShiftAmount(Type type, Type amountType, string amount, Span span)
    {
        auto bits = _program.types.integerOf(type).bits;
        auto wide = widened(amountType, amount, span);
        auto tooFar = _function.result("icmp uge i64 %s, %s".format(wide.value, bits));
        auto checked = wide.then(tooFar).then(emitPanicIf(tooFar.value, span, "Shift amount is out of range"));
        if (bits == 64) return checked.withValue(wide.value);
        return checked.then(_function.convert("trunc", "i64", wide.value, llvmType(type, span)));
    }

    /// `T(x)`: a number made another number type, panicking if it doesn't fit.
    private Fragment emit(const Expr e, const Convert convert)
    {
        auto types = _program.types;
        auto value = emitExpr(*convert.value);
        auto source = convert.value.type;
        auto target = e.type;
        if (source == target) return value;

        if (target == types.float_)
        {
            auto signed = types.integerOf(source).signed;
            return value.then(_function.convert(signed ? "sitofp" : "uitofp", llvmType(source, e.span), value.value, "double"));
        }

        auto to = types.integerOf(target);
        auto message = "Value is out of range for %sInt%s".format(to.signed ? "" : "U", to.bits);
        if (source == types.float_)
        {
            return value.then(emitFloatToIntegerCheck(value.value, to, e.span, message))
                .then(_function.convert(to.signed ? "fptosi" : "fptoui", "double", value.value, llvmType(target, e.span)));
        }

        auto from = types.integerOf(source);
        auto checks = emitIntegerRangeCheck(value.value, llvmType(source, e.span), from, to, e.span, message);
        auto converted = value.then(checks);
        if (from.bits == to.bits) return converted.withValue(value.value);
        auto opcode = to.bits < from.bits ? "trunc" : from.signed ? "sext" : "zext";
        return converted.then(_function.convert(opcode, llvmType(source, e.span), value.value, llvmType(target, e.span)));
    }

    /// Panics unless `value` of `from`'s type is between `to`'s bounds. Each bound is only
    /// compared when `from` can get past it, so the constant always fits `from`'s type.
    private Fragment emitIntegerRangeCheck(string value, string llType, IntegerInfo from, IntegerInfo to,
        Span span, string message)
    {
        Fragment checks;
        if (from.minMagnitude > to.minMagnitude)
        {
            auto inRange = _function.result("icmp sge %s %s, %s%s".format(llType, value,
                to.minMagnitude == 0 ? "" : "-", to.minMagnitude));
            auto outOfRange = _function.result("xor i1 %s, true".format(inRange.value));
            checks = checks.then(inRange).then(outOfRange).then(emitPanicIf(outOfRange.value, span, message));
        }
        if (from.maxValue > to.maxValue)
        {
            auto tooLarge = _function.result("icmp %s %s %s, %s".format(from.signed ? "sgt" : "ugt", llType, value, to.maxValue));
            checks = checks.then(tooLarge).then(emitPanicIf(tooLarge.value, span, message));
        }
        return checks.withValue(null);
    }

    /// Panics unless `value`, truncated toward zero, fits `to`. The comparisons are ordered,
    /// so NaN fails them, and `fptosi`/`fptoui` are undefined for anything that gets past them.
    private Fragment emitFloatToIntegerCheck(string value, IntegerInfo to, Span span, string message)
    {
        double limit = 2.0 ^^ (to.signed ? to.bits - 1 : to.bits);
        // The lowest value that fits, or the highest one below that doesn't.
        auto lowest = to.signed && to.bits == 64;
        double lower = !to.signed ? -1.0 : lowest ? -limit : -limit - 1;
        auto aboveLower = _function.result("fcmp %s double %s, %s".format(lowest ? "oge" : "ogt", value, floatConstant(lower)));
        auto belowUpper = _function.result("fcmp olt double %s, %s".format(value, floatConstant(limit)));
        auto fits = _function.result("and i1 %s, %s".format(aboveLower.value, belowUpper.value));
        auto fails = _function.result("xor i1 %s, true".format(fits.value));
        return aboveLower.then(belowUpper).then(fits).then(fails).then(emitPanicIf(fails.value, span, message))
            .withValue(null);
    }

    /// Panics with `message` and the location of `span` if the `i1` operand `condition` is true.
    private Fragment emitPanicIf(string condition, Span span, string message)
    {
        auto panicLabel = _function.newLabel("panic");
        auto okLabel = _function.newLabel("ok");
        return Fragment.branch(condition, panicLabel, okLabel)
            .then(Fragment.label(panicLabel))
            .then(emitPanic(span, message))
            .then(Fragment.label(okLabel));
    }

    /// Panics with `message` and the location of `span`, ending the current block.
    private Fragment emitPanic(Span span, string message)
    {
        return callRuntime("silver_panic", [cString("%s: %s".format(located(span), message))])
            .then(Fragment.unreachable());
    }

    /// Either arm's value, through a phi. An arm that leaves, being `Never`, has none, and the
    /// phi takes `undef` from wherever its dead block ends.
    private Fragment emit(const Expr e, const If if_)
    {
        auto condition = emitExpr(*if_.condition);
        auto thenLabel = _function.newLabel("then");
        auto elseLabel = _function.newLabel("else");
        auto mergeLabel = _function.newLabel("merge");
        auto trueBody = Fragment.label(thenLabel).then(emitExpr(*if_.trueBody));
        auto falseBody = Fragment.label(elseLabel).then(emitExpr(*if_.falseBody));
        auto code = condition
            .then(Fragment.branch(condition.value, thenLabel, elseLabel))
            .then(trueBody).then(Fragment.jump(mergeLabel))
            .then(falseBody).then(Fragment.jump(mergeLabel))
            .then(Fragment.label(mergeLabel));

        auto type = llvmType(e.type, e.span);
        if (type == "void") return code.withValue(null);
        auto phi = _function.result("phi %s [ %s, %%%s ], [ %s, %%%s ]".format(type,
            orUndef(trueBody.value), trueBody.endBlock, orUndef(falseBody.value), falseBody.endBlock));
        return code.then(phi);
    }

    private static string orUndef(string value)
    {
        return value is null ? "undef" : value;
    }

    private Fragment emit(const Expr e, const Block block)
    {
        Fragment statements;
        foreach (statement; block.statements)
        {
            statements = statements.then(emitStmt(statement));
        }
        return block.result is null ? statements.withValue(null) : statements.then(emitExpr(*block.result));
    }

    private Fragment emit(const Expr e, const Loop loop)
    {
        auto targets = LoopTargets(_function.newLabel("loop"), _function.newLabel("loop.end"));
        _function.loops[loop.label] = targets;
        return Fragment.jump(targets.head)
            .then(Fragment.label(targets.head))
            .then(emitExpr(*loop.body))
            .then(Fragment.jump(targets.head))
            .then(Fragment.label(targets.end))
            .withValue(null);
    }

    private Fragment emit(const Expr e, const Break jump)
    {
        return leaveTo(_function.loops[jump.label].end);
    }

    private Fragment emit(const Expr e, const Continue jump)
    {
        return leaveTo(_function.loops[jump.label].head);
    }

    private Fragment emit(const Expr e, const Return return_)
    {
        auto value = emitExpr(*return_.value);
        return value.then(Fragment.ret(_function.returnType, value.value))
            .then(Fragment.label(_function.newLabel("after.return")))
            .withValue(null);
    }

    /// Goes to `target`. What follows is never reached, but needs a block to be in.
    private Fragment leaveTo(string target)
    {
        return Fragment.jump(target).then(Fragment.label(_function.newLabel("after.jump")));
    }

    /// A statement's code, which has no value.
    private Fragment emitStmt(const Stmt s)
    {
        return s.kind.match!(kind => emit(s, kind)).withValue(null);
    }

    private Fragment emit(const Stmt s, const Eval eval)
    {
        return emitExpr(eval.expr);
    }

    private Fragment emit(const Stmt s, const Assign assign)
    {
        return storeLocal(assign.local, emitExpr(assign.value), s.span);
    }

    /// The local's array copied with one element replaced, until something says when it can be
    /// written in place.
    private Fragment emit(const Stmt s, const AssignElement assign)
    {
        auto at = position(assign.index);
        auto value = emitExpr(assign.value);
        auto slot = _function.slots[assign.local];
        auto array = _function.load(sliceLayout, slot);
        auto parts = sliceParts(array.value);
        auto outside = _function.result("icmp uge i64 %s, %s".format(at.value, parts.length));
        auto code = at.then(value).then(array).then(parts.code).then(outside)
            .then(emitPanicIf(outside.value, s.span, "Index is out of range"));
        auto layout = llvmType(elementOf(assign.local.type), s.span);
        if (layout == "void") return code;

        auto copy = emitConcat([array.value], layout, elementSizeOf(layout));
        auto copied = sliceParts(copy.value);
        auto pointer = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, copied.data, at.value));
        return code.then(copy).then(copied.code).then(pointer)
            .then(Fragment.store(layout, operandOf(assign.value, value), pointer.value))
            .then(Fragment.store(sliceLayout, copy.value, slot));
    }

    private Fragment emit(const Stmt s, const Let let)
    {
        return storeLocal(let.local, emitExpr(let.value), s.span);
    }

    /// A Unit or Never value has no operand, so its local has no slot.
    private Fragment storeLocal(const Local local, Fragment value, Span span)
    {
        auto slot = _function.slots[local];
        if (slot is null || value.value is null) return value;
        return value.then(Fragment.store(llvmType(local.type, span), value.value, slot));
    }

    // Records. A tuple is an LLVM struct by value, and a declared type's value is a pointer to one
    // on the heap, which never changes once built.

    private bool isTuple(Type type)
    {
        return _program.types.isTuple(type);
    }

    /// The types of a tuple's elements or a declared type's fields.
    private const(Type)[] fieldTypes(Type type)
    {
        if (isTuple(type)) return _program.types.tupleElements(type);
        auto fields = type in _program.recordFields;
        assert(fields !is null, "lowering describes every declared type it uses");
        return *fields;
    }

    /// The struct holding a record's fields: each with an operand, in order.
    private string recordLayout(Type type, Span span)
    {
        auto stored = fieldTypes(type).map!(f => llvmType(f, span)).filter!(t => t != "void");
        return "{ %-(%s, %) }".format(stored);
    }

    /// Where field `index` is in `recordLayout`, or -1 for one with no operand.
    private ptrdiff_t storedIndex(Type type, size_t index, Span span)
    {
        auto fields = fieldTypes(type);
        if (llvmType(fields[index], span) == "void") return -1;
        return fields[0 .. index].map!(f => llvmType(f, span)).filter!(t => t != "void").array.length;
    }

    /// Whether a declared type's values hold nothing, so each is a null pointer.
    private bool isEmptyRecord(Type type, Span span)
    {
        return fieldTypes(type).all!(f => llvmType(f, span) == "void");
    }

    private Fragment emit(const Expr e, const Construct construct)
    {
        string[] operands;
        auto values = emitAll(construct.fields, operands);
        auto layout = recordLayout(e.type, e.span);
        auto fields = fieldTypes(e.type);
        if (isTuple(e.type))
        {
            if (layout == "{  }") return values.withValue("zeroinitializer");
            Fragment built = Fragment.constant("undef");
            foreach (i, operand; operands)
            {
                auto at = storedIndex(e.type, i, e.span);
                if (at < 0) continue;
                built = built.then(_function.insert(layout, built.value, llvmType(fields[i], e.span), operand, at));
            }
            return values.then(built);
        }
        if (isEmptyRecord(e.type, e.span)) return values.withValue("null");

        auto object = alloc(layout);
        auto code = values.then(object);
        foreach (i, operand; operands)
        {
            auto at = storedIndex(e.type, i, e.span);
            if (at < 0) continue;
            auto pointer = fieldPointer(layout, object.value, at);
            code = code.then(pointer).then(Fragment.store(llvmType(fields[i], e.span), operand, pointer.value));
        }
        return code.withValue(object.value);
    }

    private Fragment emit(const Expr e, const Field field)
    {
        auto object = emitExpr(*field.object);
        auto type = field.object.type;
        auto at = storedIndex(type, field.index, e.span);
        if (at < 0) return object.withValue(null);
        auto layout = recordLayout(type, e.span);
        if (isTuple(type)) return object.then(_function.extract(layout, object.value, at));
        auto pointer = fieldPointer(layout, object.value, at);
        return object.then(pointer).then(_function.load(llvmType(e.type, e.span), pointer.value));
    }

    /// A tuple is changed by value; a declared type's value is copied to a new object.
    private Fragment emit(const Expr e, const Update update)
    {
        auto object = emitExpr(*update.object);
        auto value = emitExpr(*update.value);
        auto code = object.then(value);
        auto type = e.type;
        auto at = storedIndex(type, update.index, e.span);
        if (at < 0) return code.withValue(object.value);
        auto layout = recordLayout(type, e.span);
        auto fieldType = llvmType(fieldTypes(type)[update.index], e.span);
        if (isTuple(type)) return code.then(_function.insert(layout, object.value, fieldType, value.value, at));

        auto whole = _function.load(layout, object.value);
        auto changed = _function.insert(layout, whole.value, fieldType, value.value, at);
        auto copy = alloc(layout);
        return code.then(whole).then(changed).then(copy).then(Fragment.store(layout, changed.value, copy.value))
            .withValue(copy.value);
    }

    // Sums and options. An option is `{ i1, T }`, its tag saying whether there's a payload. A sum is
    // `{ i32, ptr }`: the member's index, and its value, which is boxed unless it's already a
    // pointer. A sum whose members are all markers is just the `i32`.

    private bool isOption(Type type)
    {
        return _program.types.isOption(type);
    }

    private const(Type)[] membersOf(Type type)
    {
        auto members = type in _program.sumMembers;
        assert(members !is null, "lowering describes every sum it uses");
        return *members;
    }

    private bool isAllMarkers(Type sum, Span span)
    {
        return membersOf(sum).all!(m => (m in _program.recordFields) !is null && isEmptyRecord(m, span));
    }

    private string optionLayout(string payload)
    {
        return payload == "void" ? "{ i1 }" : "{ i1, %s }".format(payload);
    }

    private Fragment emit(const Expr e, const Inject inject)
    {
        auto type = e.type;
        auto layout = llvmType(type, e.span);
        auto payload = inject.payload is null ? Fragment.init : emitExpr(*inject.payload);
        if (isOption(type))
        {
            if (inject.member == 0) return payload.withValue("zeroinitializer");
            auto tagged = _function.insert(layout, "undef", "i1", "true", 0);
            if (payload.value is null) return payload.then(tagged);
            auto inner = llvmType(_program.types.optionInner(type), e.span);
            return payload.then(tagged).then(_function.insert(layout, tagged.value, inner, payload.value, 1));
        }
        if (isAllMarkers(type, e.span)) return payload.withValue("%s".format(inject.member));

        auto memberLayout = llvmType(membersOf(type)[inject.member], e.span);
        auto boxed = payload;
        if (payload.value is null)
        {
            boxed = payload.withValue("null");
        }
        else if (memberLayout != "ptr")
        {
            auto box = alloc(memberLayout);
            boxed = payload.then(box).then(Fragment.store(memberLayout, payload.value, box.value)).withValue(box.value);
        }
        auto tagged = _function.insert(layout, "undef", "i32", "%s".format(inject.member), 0);
        return boxed.then(tagged).then(_function.insert(layout, tagged.value, "ptr", boxed.value, 1));
    }

    private Fragment emit(const Expr e, const IsMember test)
    {
        auto subject = emitExpr(*test.subject);
        auto type = test.subject.type;
        auto layout = llvmType(type, e.span);
        if (isOption(type))
        {
            auto tag = _function.extract(layout, subject.value, 0);
            if (test.member == 1) return subject.then(tag);
            return subject.then(tag).then(_function.result("xor i1 %s, true".format(tag.value)));
        }
        auto tag = isAllMarkers(type, e.span) ? subject : subject.then(_function.extract(layout, subject.value, 0));
        return tag.then(_function.result("icmp eq i32 %s, %s".format(tag.value, test.member)));
    }

    private Fragment emit(const Expr e, const Payload payload)
    {
        auto subject = emitExpr(*payload.subject);
        auto type = payload.subject.type;
        auto layout = llvmType(type, e.span);
        auto memberLayout = llvmType(e.type, e.span);
        if (memberLayout == "void") return subject.withValue(null);
        if (isOption(type)) return subject.then(_function.extract(layout, subject.value, 1));
        if (isAllMarkers(type, e.span)) return subject.withValue("null");
        auto pointer = _function.extract(layout, subject.value, 1);
        if (memberLayout == "ptr") return subject.then(pointer);
        return subject.then(pointer).then(_function.load(memberLayout, pointer.value));
    }

    // Arrays and Strings: `{ ptr, i64 }`, element zero and the length, in a buffer that the
    // runtime's `silver_array_append` makes and extends. An element with no operand is never
    // stored, so such an array's pointer is null.

    /// The element type of an array or String type.
    private Type elementOf(Type type)
    {
        auto types = _program.types;
        if (type == types.string_) return types.uint8;
        if (types.isArray(type)) return types.arrayElement(type);
        return types.never;
    }

    /// The size of an element stored as `layout`, as an `i64` operand, or zero when nothing is.
    private string elementSizeOf(string layout)
    {
        if (layout == "void") return "0";
        return "ptrtoint (ptr getelementptr (%s, ptr null, i32 1) to i64)".format(layout);
    }

    private struct SliceParts
    {
        Fragment code;
        string data;
        string length;
    }

    private SliceParts sliceParts(string value)
    {
        auto data = _function.extract(sliceLayout, value, 0);
        auto length = _function.extract(sliceLayout, value, 1);
        return SliceParts(data.then(length), data.value, length.value);
    }

    private Fragment buildSlice(string data, string length)
    {
        auto withData = _function.insert(sliceLayout, "undef", "ptr", data, 0);
        return withData.then(_function.insert(sliceLayout, withData.value, "i64", length, 1));
    }

    /// A new buffer with room for `count` elements of `size` bytes, as a slice whose elements the
    /// caller writes.
    private Fragment reserve(string count, string size)
    {
        _function.usesOutSlots = true;
        auto call = callRuntime("silver_array_append", ["null", "0", "null", count, size, "false",
            FunctionState.outData, FunctionState.outLength]);
        return call.then(loadOutSlice());
    }

    private Fragment emit(const Expr e, const ArrayLit literal)
    {
        string[] operands;
        auto values = emitAll(literal.elements, operands);
        auto count = literal.elements.length;
        if (count == 0) return values.withValue("zeroinitializer");
        auto layout = llvmType(elementOf(e.type), e.span);
        if (layout == "void") return values.then(buildSlice("null", "%s".format(count)));

        auto buffer = reserve("%s".format(count), elementSizeOf(layout));
        auto parts = sliceParts(buffer.value);
        auto code = values.then(buffer).then(parts.code);
        foreach (i, operand; operands)
        {
            auto pointer = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, parts.data, i));
            code = code.then(pointer).then(Fragment.store(layout, operand, pointer.value));
        }
        return code.withValue(buffer.value);
    }

    /// `operands`, Strings or arrays whose elements are stored as `layout`, joined into one
    /// buffer of exactly their total length.
    private Fragment emitConcat(string[] operands, string layout, string size)
    {
        Fragment code;
        SliceParts[] parts;
        string total = "0";
        foreach (operand; operands)
        {
            auto part = sliceParts(operand);
            parts ~= part;
            auto sum = _function.result("add i64 %s, %s".format(total, part.length));
            code = code.then(part.code).then(sum);
            total = sum.value;
        }
        if (layout == "void") return code.then(buildSlice("null", total));

        auto buffer = reserve(total, size);
        auto result = sliceParts(buffer.value);
        code = code.then(buffer).then(result.code);
        useIntrinsic("declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1 immarg)");
        string offset = "0";
        foreach (part; parts)
        {
            auto target = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, result.data, offset));
            auto bytes = _function.result("mul i64 %s, %s".format(part.length, size));
            auto copy = Fragment.instruction("call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %s, i1 false)".format(
                target.value, part.data, bytes.value));
            auto next = _function.result("add i64 %s, %s".format(offset, part.length));
            code = code.then(target).then(bytes).then(copy).then(next);
            offset = next.value;
        }
        return code.withValue(buffer.value);
    }

    /// `lhs ~= rhs`'s value: in place at `lhs`'s frontier when there's room, leaving room to grow.
    private Fragment emitAppend(string lhs, string rhs, string layout)
    {
        auto left = sliceParts(lhs);
        auto right = sliceParts(rhs);
        auto code = left.code.then(right.code);
        if (layout == "void")
        {
            auto total = _function.result("add i64 %s, %s".format(left.length, right.length));
            return code.then(total).then(buildSlice("null", total.value));
        }
        _function.usesOutSlots = true;
        auto call = callRuntime("silver_array_append", [left.data, left.length, right.data, right.length,
            elementSizeOf(layout), "true", FunctionState.outData, FunctionState.outLength]);
        return code.then(call).then(loadOutSlice());
    }

    /// An index of any integer type as an unsigned 64-bit one, so a negative one is too large.
    private Fragment position(const Expr index)
    {
        auto value = emitExpr(index);
        return value.then(widened(index.type, value.value, index.span));
    }

    private Fragment emit(const Expr e, const Index index)
    {
        auto array = emitExpr(*index.array);
        auto parts = sliceParts(array.value);
        auto at = position(*index.index);
        auto outside = _function.result("icmp uge i64 %s, %s".format(at.value, parts.length));
        auto code = array.then(parts.code).then(at).then(outside).then(emitPanicIf(outside.value, e.span, "Index is out of range"));
        auto layout = llvmType(e.type, e.span);
        if (layout == "void") return code.withValue(null);
        auto pointer = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, parts.data, at.value));
        return code.then(pointer).then(_function.load(layout, pointer.value));
    }

    private Fragment emit(const Expr e, const Slice slice)
    {
        auto array = emitExpr(*slice.array);
        auto parts = sliceParts(array.value);
        auto start = position(*slice.start);
        auto end = position(*slice.end);
        auto reversed = _function.result("icmp ugt i64 %s, %s".format(start.value, end.value));
        auto tooLong = _function.result("icmp ugt i64 %s, %s".format(end.value, parts.length));
        auto outside = _function.result("or i1 %s, %s".format(reversed.value, tooLong.value));
        auto code = array.then(parts.code).then(start).then(end).then(reversed).then(tooLong).then(outside)
            .then(emitPanicIf(outside.value, e.span, "Slice is out of range"));
        auto length = _function.result("sub i64 %s, %s".format(end.value, start.value));
        auto layout = llvmType(elementOf(e.type), e.span);
        if (layout == "void") return code.then(length).then(buildSlice("null", length.value));
        auto data = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, parts.data, start.value));
        return code.then(length).then(data).then(buildSlice(data.value, length.value));
    }

    private Fragment emit(const Expr e, const Length length)
    {
        auto array = emitExpr(*length.array);
        return array.then(_function.extract(sliceLayout, array.value, 1));
    }

    // Cells. A `Ref` points to a `{ i1, T }` on the heap, laid out as an option is: the `i1` says
    // whether the cell holds its value, which it doesn't while `update` runs.

    private Fragment emit(const Expr e, const Cell cell)
    {
        string[] operands;
        auto args = emitAll(cell.args, operands);
        auto contents = llvmType(_program.cellContents[cell.op == CellOp.New ? e.type : cell.args[0].type], e.span);
        auto layout = optionLayout(contents);

        Fragment fill(string target, string value)
        {
            auto flag = fieldPointer(layout, target, 0);
            auto code = flag.then(Fragment.store("i1", "true", flag.value));
            if (contents == "void") return code;
            auto pointer = fieldPointer(layout, target, 1);
            return code.then(pointer).then(Fragment.store(contents, value, pointer.value));
        }

        if (cell.op == CellOp.New)
        {
            auto object = alloc(layout);
            return args.then(object).then(fill(object.value, operands[0])).withValue(object.value);
        }
        auto target = operands[0];
        if (cell.op == CellOp.Fill) return args.then(fill(target, operands[1])).withValue(null);

        auto flag = fieldPointer(layout, target, 0);
        auto full = _function.load("i1", flag.value);
        auto empty = _function.result("xor i1 %s, true".format(full.value));
        auto code = args.then(flag).then(full).then(empty).then(emitPanicIf(empty.value, e.span, "Ref is being updated"));
        if (cell.op == CellOp.Set)
        {
            if (contents == "void") return code.withValue(null);
            auto pointer = fieldPointer(layout, target, 1);
            return code.then(pointer).then(Fragment.store(contents, operands[1], pointer.value)).withValue(null);
        }
        if (cell.op == CellOp.Take) code = code.then(Fragment.store("i1", "false", flag.value));
        if (contents == "void") return code.withValue(null);
        auto pointer = fieldPointer(layout, target, 1);
        return code.then(pointer).then(_function.load(contents, pointer.value));
    }


    // Helpers

    /// Room on the heap for one `layout`; the operand is its address.
    private Fragment alloc(string layout)
    {
        return callRuntime("silver_alloc", [elementSizeOf(layout)]);
    }

    /// The address of the field at `index` of the struct `object` points to.
    private Fragment fieldPointer(string layout, string object, size_t index)
    {
        return _function.result("getelementptr %s, ptr %s, i32 0, i32 %s".format(layout, object, index));
    }

    /// Every function checks on entry that it has room on the stack, and panics if not. Its
    /// names are fixed, since each function has one, so it uses none of the numbered temps.
    private Fragment emitStackCheck(Span span)
    {
        useIntrinsic("declare ptr @llvm.frameaddress.p0(i32 immarg)");
        useIntrinsic("@silver_stack_limit = external global ptr");
        auto frame = _function.result("call ptr @llvm.frameaddress.p0(i32 0)", "%.frame");
        auto limit = _function.result("load ptr, ptr @silver_stack_limit", "%.limit");
        auto tooDeep = _function.result("icmp ult ptr %s, %s".format(frame.value, limit.value), "%.too.deep");
        return frame.then(limit).then(tooDeep)
            .then(Fragment.branch(tooDeep.value, ".stack.overflow", ".stack.ok"))
            .then(Fragment.label(".stack.overflow"))
            .then(emitPanic(span, "Stack overflow"))
            .then(Fragment.label(".stack.ok"));
    }

    /// Declares an LLVM intrinsic, or another module-level line, once at the top of the module.
    private void useIntrinsic(string declaration)
    {
        _usedIntrinsics[declaration] = true;
    }

    /// Calls the runtime function `name` with `operands`, typed from its binding. The value is
    /// the result's temp, or null for a void function.
    private Fragment callRuntime(string name, string[] operands)
    {
        import std.range : zip;

        auto binding = runtime[name];
        assert(operands.length == binding.params.length, "the wrong number of operands for " ~ name);
        _usedRuntime[name] = true;
        auto args = zip(binding.params, operands).map!(p => p[0] ~ " " ~ p[1]).array;
        return _function.call(binding.returnType, "@" ~ name, args);
    }

    /// A NUL-terminated global holding `text`, for the runtime's C-string parameters.
    private string cString(string text)
    {
        auto name = "@.cstr.%s".format(_globals.length);
        _globals ~= "%s = private unnamed_addr constant [%s x i8] c\"%s\\00\"".format(name, text.length + 1, escaped(text));
        return name;
    }

    /// `file(line,column)`, as panic messages start.
    private string located(Span span)
    {
        auto location = _sources.locate(span);
        return "%s(%s,%s)".format(span.file, location.line, location.column);
    }

    private string llvmType(Type type, Span span)
    {
        auto types = _program.types;
        if (type == types.unit || type == types.never || type == types.none) return "void";
        if (type == types.bool_) return "i1";
        if (type == types.float_) return "double";
        if (types.isInteger(type)) return "i%s".format(types.integerOf(type).bits);
        if (type == types.string_ || type == types.emptyArray || types.isArray(type)) return sliceLayout;
        if (types.isFunction(type)) return closureLayout;
        if (types.isOption(type)) return optionLayout(llvmType(types.optionInner(type), span));
        if (types.isTuple(type)) return recordLayout(type, span);
        if (type in _program.recordFields) return "ptr";
        if (type in _program.cellContents) return "ptr";
        if (type in _program.sumMembers) return isAllMarkers(type, span) ? "i32" : "{ i32, ptr }";
        return notImplemented!string("the type " ~ types.describe(type), span);
    }

    private FunctionData functionData(Type type)
    {
        return _program.types[type].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "only a function value can be called"),
        );
    }

    /// A declared function is named for its module and name. Anything else can share a name, and
    /// so can two instances or overloads whose types name types of different modules alike, so
    /// its index is added.
    private string mangled(size_t index)
    {
        import std.string : replace;

        auto func = _program.functions[index];
        auto plain = !func.name.canFind!(c => c == '<' || c == '(' || c == '"' || c == '\\');
        if (func.origin == FunctionOrigin.declared && plain) return "@\"%s.%s\"".format(func.moduleName, func.name);
        return "@\"%s.%s.%s\"".format(func.moduleName, func.name.replace("\"", "'").replace("\\", "/"), index);
    }

    private T notImplemented(T = Fragment)(string what, Span span)
    {
        throw new DiagnosticException(Diagnostic(DiagnosticCode.NotImplemented, span,
            "Not implemented in codegen yet: " ~ what));
    }
}
