module silver.codegen.gen;

import std.algorithm : all, any, canFind, count, filter, fold, map;
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

/// The code for one expression and the operands holding its value. Fragments are values: an
/// expression's fragment is built from its children's, and the parent decides where each one
/// goes. Evaluation order is the order they're sequenced with `then`. A fragment starts in
/// whatever block the parent places it in and ends in `endBlock`.
private struct Fragment
{
    /// Instructions and labels in order, instructions already indented.
    string[] code;
    /// An operand for each scalar the value is made of, in the order `scalarsOf` gives its type's:
    /// each a temp (`%.t3`), a constant (`42`) or a global (`@.str.0`). A struct is never one
    /// operand. None for a value made of nothing, like `()`, and for a statement.
    const(string)[] operands;
    /// The block control is in after `code` runs, or null when the code opened no block and so
    /// ends in the one it started in.
    string endBlock;

    /// The operand of a value that is one scalar, or null for one made of nothing.
    string value() const
    {
        assert(operands.length <= 1, "a value of several scalars has an operand for each");
        return operands.length == 0 ? null : operands[0];
    }

    /// A value that needs no code.
    static Fragment constant(string operand)
    {
        return Fragment(null, [operand]);
    }

    static Fragment instruction(string text, string value = null)
    {
        return Fragment(["  " ~ text], value is null ? null : [value]);
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

    /// This fragment followed by `next`, with `next`'s value. Appending extends the array in place
    /// when this fragment is the only one that ends there, so building code a step at a time
    /// doesn't copy what's there at every step. Lines are never changed once written.
    Fragment then(Fragment next) const
    {
        auto joined = cast(string[]) code;
        if (joined.length == 0) joined = next.code;
        else joined ~= next.code;
        return Fragment(joined, next.operands, next.endBlock !is null ? next.endBlock : endBlock);
    }

    /// The same code, with another value of one scalar, or none for a statement.
    Fragment withValue(string newValue) const
    {
        return Fragment(cast(string[]) code, newValue is null ? null : [newValue], endBlock);
    }

    /// The same code, with another value.
    Fragment withOperands(const string[] newOperands) const
    {
        return Fragment(cast(string[]) code, newOperands, endBlock);
    }
}

/// Where each local of one function lives: a pointer for every local that is made of something,
/// which is a stack slot, or for a mutable param, its caller's. Locals whose lifetimes don't
/// overlap share a slot of their type, so a frame grows with how many values are live at once
/// rather than with how many locals there are: at -O0 LLVM gives every alloca its own memory, and
/// ignores lifetime markers.
private struct Slots
{
    string[const Local] pointers;
    /// The `alloca` of each stack slot, for the top of the entry block.
    string[] allocas;
    /// What `keepAlive` keeps where each loop is left, by label, and which loops can be left: what
    /// `Lifetimes` found.
    const(Local)[][size_t] kept;
    bool[size_t] left;
    private Slot[] _slots;
    /// How many slots are named after each local name, so a reused name gets a slot of its own.
    private int[string] _named;

    private struct Slot
    {
        string pointer;
        string type;
        /// Where the last lifetime of a local in it ends.
        size_t free;
    }

    /// A stack slot of `type` for `local`, which is in use from `start` to `end`: one of the slots
    /// already made that is free by `start`, or a new one. Locals come in order of `start`.
    void allocate(const Local local, string type, size_t start, size_t end)
    {
        foreach (ref slot; _slots)
        {
            if (slot.type != type || slot.free >= start) continue;
            slot.free = end;
            pointers[local] = slot.pointer;
            return;
        }
        auto count = _named.require(local.name, 0);
        _named[local.name] = count + 1;
        auto pointer = count == 0 ? "%%%s.addr".format(local.name) : "%%%s.addr.%s".format(local.name, count);
        _slots ~= Slot(pointer, type, end);
        pointers[local] = pointer;
        allocas ~= "  %s = alloca %s".format(pointer, type);
    }

    /// `pointer`, which already points at a slot of `local`'s type, as where it lives.
    void bind(const Local local, string pointer)
    {
        pointers[local] = pointer;
    }

    /// Where `local` lives, or null for one made of nothing.
    string opIndex(const Local local) const
    {
        auto pointer = local in pointers;
        return pointer is null ? null : *pointer;
    }
}

/// When each local that gets a slot is in use, measured by a clock that ticks at the start and end
/// of every statement and loop, in the order the code is generated. A local's lifetime starts with
/// its `Let`, whose value may be written into the slot while it's worked out, and ends with the
/// statement that last names it, since an expression may read a local in place after evaluating
/// its other parts. A local named in a loop it was declared outside is in use until the loop ends,
/// since the next iteration can read it again.
private struct Lifetimes
{
    const(Local)[] locals;
    string[] types;
    size_t[] starts;
    size_t[] ends;
    private size_t[const Local] _index;
    private size_t _clock;
    /// The locals named in each statement being walked, innermost last.
    private size_t[][] _statements;
    private OpenLoop[] _loops;
    /// For each loop, by label, the locals declared before it that it names, which are what
    /// `keepAlive` keeps where it's left.
    size_t[][size_t] kept;
    /// The loops something leaves other than by an error: a `Break` to or past it, a `Continue`
    /// past it, or a `Return` in it.
    bool[size_t] left;

    private struct OpenLoop
    {
        size_t label;
        size_t entry;
        size_t[] named;
    }

    /// `local`, which has a slot of `type`, starting now and lasting at least as long as the
    /// statement declaring it. A mutable param has no slot of its own and a null `type`: it's
    /// declared only so a loop that names it keeps it.
    void declare(const Local local, string type)
    {
        auto at = locals.length;
        _index[local] = at;
        locals ~= local;
        types ~= type;
        starts ~= _clock;
        ends ~= _clock;
        if (_statements.length > 0) _statements[$ - 1] ~= at;
    }

    /// A read or write of `local`. A local that wasn't declared (one made of nothing) is ignored.
    void use(const Local local)
    {
        auto at = local in _index;
        if (at is null) return;
        if (_statements.length == 0) ends[*at] = size_t.max;
        else _statements[$ - 1] ~= *at;
        if (_loops.length > 0) _loops[$ - 1].named ~= *at;
    }

    void beginStatement()
    {
        _clock++;
        _statements ~= null;
    }

    void endStatement()
    {
        import std.algorithm : max;

        _clock++;
        foreach (i; _statements[$ - 1]) ends[i] = max(ends[i], _clock);
        _statements.length--;
    }

    void beginLoop(size_t label)
    {
        _clock++;
        _loops ~= OpenLoop(label, _clock);
    }

    void endLoop()
    {
        import std.algorithm : canFind, max;

        _clock++;
        auto loop = _loops[$ - 1];
        _loops.length--;
        size_t[] outside;
        foreach (i; loop.named)
        {
            if (starts[i] >= loop.entry) continue;
            ends[i] = max(ends[i], _clock);
            if (_loops.length > 0) _loops[$ - 1].named ~= i;
            if (!outside.canFind(i)) outside ~= i;
        }
        kept[loop.label] = outside;
    }

    /// A `Break` to the loop `label` (`inclusive`) or a `Continue` of it, which leaves every loop
    /// inside it.
    void jump(size_t label, bool inclusive)
    {
        foreach_reverse (ref loop; _loops)
        {
            if (loop.label == label && !inclusive) return;
            left[loop.label] = true;
            if (loop.label == label) return;
        }
    }

    /// A `Return`, which leaves every loop.
    void leaveAll()
    {
        foreach (ref loop; _loops) left[loop.label] = true;
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
    /// The scalars of the function's return type, which `Return` needs.
    const(string)[] returnScalars;
    /// The blocks of each loop being generated, by its label.
    LoopTargets[size_t] loops;
    /// The labels of the loops the code being generated is in, innermost last.
    size_t[] open;
    /// For a recursive function, its params, which are kept where it returns (`keptOnReturn`).
    const(Local)[] tailKept;
    /// Whether the function has the runtime hand back a String or buffer, which comes through
    /// these two slots, allocated once at the top of the function.
    bool usesOutSlots;
    /// The `alloca` of the memory each C structure crossing at a native's call is put into or read
    /// out of, for the top of the entry block.
    string[] cImages;
    private int _nextTemp;
    private int _nextLabel;

    enum outData = "%.out.data";
    enum outLength = "%.out.length";
    /// Where a function returning several scalars keeps its result, and the block that returns it.
    enum resultSlot = "%.result";
    enum returnBlock = ".return";

    this(Slots slots, const string[] returnScalars)
    {
        this.slots = slots;
        this.returnScalars = returnScalars;
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

    /// Memory for the C structure `type`, aligned to at least 8 so each 8-byte piece can be loaded
    /// and stored as the convention's types.
    string newCImage(const CType type)
    {
        auto name = "%%.c%s".format(cImages.length);
        cImages ~= "  %s = alloca [%s x i8], align %s".format(name, type.size, type.alignment > 8 ? type.alignment : 8);
        return name;
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

/// The scalars of every String and array: where element zero is, and how many elements.
private immutable sliceScalars = ["ptr", "i64"];
/// The scalars of every function value: its function's descriptor, then the environment the code
/// takes after its params.
private immutable closureScalars = ["ptr", "ptr"];
/// A constant for each function used as a value: the code a closure calls, the String a function
/// value prints as, then its `captureEquality` and its `captureHash`, each or null. Two closures
/// are of one function when they point to one descriptor.
private immutable descriptorScalars = ["ptr", "ptr", "i64", "ptr", "ptr"];

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
    private const(string)[][Type] _scalars;
    /// The thunk letting a function that isn't a lambda be called through a closure, by the
    /// function's index, once one has been asked for.
    private string[size_t] _thunks;
    private string[] _thunkDefinitions;
    /// The guard for `panics` calls, by the LLVM type their work returns.
    private string[string] _panicsGuards;
    /// The descriptor of each function used as a value, by the function's index.
    private string[size_t] _descriptors;
    /// Whether `@silver.function.equal` has been defined.
    private bool _functionEquality;
    /// Whether `@silver.function.hash` and `@silver.hash.mix` have been defined.
    private bool _functionHash, _hashMix;
    /// Whether each field of a declared type is boxed, by the type.
    private bool[][Type] _boxedFields;
    /// The zeros a boxed `None` reads its payload from, by the payload's layout.
    private string[string] _nones;
    /// The name of each struct type, by what it's made of, and their definitions.
    private string[immutable(string)[]] _structs;
    private string[] _structDefinitions;
    private bool[Type] _scalarsPending;
    /// The functions on a cycle of calls (`recursiveFunctions`), and their LLVM names.
    private bool[size_t] _recursive;
    /// The functions a call can reach through a function value: see `escapedFunctions`.
    private bool[size_t] _escaped;
    private bool[string] _recursiveNames;

    this(const ref Program program, const SourceMap sources)
    {
        _program = program;
        _sources = sources;
    }

    string emitProgram()
    {
        string[] functions;
        _recursive = recursiveFunctions();
        _escaped = escapedFunctions();
        foreach (index; _recursive.byKey) _recursiveNames[mangled(index)] = true;
        foreach (i, ref func; _program.functions)
        {
            functions ~= emitFunction(i, func);
        }
        auto entry = emitEntry();
        // After the functions and the entry, so every runtime call and string literal has been seen.
        return _structDefinitions.map!(s => s ~ "\n").join ~ emitDeclares() ~ functionAttributes
            ~ _globals.map!(s => s ~ "\n").join ~ "\n"
            ~ functions.join("\n") ~ "\n"
            ~ _thunkDefinitions.join("\n") ~ "\n" ~ entry;
    }

    /// On every Silver function. Nothing unwinds through one: a panic exits, or in a test jumps,
    /// and the runtime's functions are `nothrow`. The unwind tables stay, for a debugger and for
    /// a D `Error` leaving the runtime, which `nothrow` doesn't rule out.
    private enum functionAttributes = "attributes #0 = { nounwind uwtable }\n"
        // `keepAlive`'s asm.
        ~ "attributes #1 = { nounwind willreturn memory(inaccessiblemem: readwrite) }\n";

    /// `silver_main`, which the runtime calls once druntime has started, and the C `main` that starts it.
    private string emitEntry()
    {
        auto main = _program.entryPoint == size_t.max ? emitTestEntry()
            : "define void @silver_main() #0 {\n.entry:\n  call void %s()\n  ret void\n}\n".format(mangled(_program.entryPoint));
        return main ~ "\ndeclare i32 @silver_start(i32, ptr)\n\n"
            ~ "define i32 @main(i32 %argc, ptr %argv) #0 {\n.entry:\n"
            ~ "  %status = call i32 @silver_start(i32 %argc, ptr %argv)\n  ret i32 %status\n}\n";
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
            ~ "define private void @silver.test.escape() #0 noinline {\n.entry:\n"
            ~ "  call void @llvm.eh.sjlj.longjmp(ptr @silver.test.jump)\n  unreachable\n}\n\n"
            // No tail calls: a sibling call would free the frame the setjmp buffer points into
            // before the test runs, so a test that panics would jump into a frame that's gone. That
            // holds for the calls of a test inlined here too, which keep their own `tail` markers.
            ~ "define private void @silver.test.guard(ptr %test) #0 noinline \"disable-tail-calls\"=\"true\" {\n.entry:\n"
            ~ "  %frame = call ptr @llvm.frameaddress.p0(i32 0)\n"
            ~ "  store ptr %frame, ptr @silver.test.jump\n"
            ~ "  %stack = call ptr @llvm.stacksave.p0()\n"
            ~ "  %slot = getelementptr [5 x ptr], ptr @silver.test.jump, i64 0, i64 2\n"
            ~ "  store ptr %stack, ptr %slot\n"
            ~ "  %jumped = call i32 @llvm.eh.sjlj.setjmp(ptr @silver.test.jump)\n"
            ~ "  %fresh = icmp eq i32 %jumped, 0\n"
            ~ "  br i1 %fresh, label %run, label %done\nrun:\n  notail call void %test()\n  br label %done\ndone:\n  ret void\n}\n\n"
            ~ "define void @silver_main() #0 {\n.entry:\n  call void @silver_test_start(ptr @silver.test.escape)\n";
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
            text ~= "declare %s%s @%s(%s) nounwind %s\n".format(f.returnAttributes, f.returnType, name, f.params.join(", "),
                f.attributes);
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
        auto span = func.body.span;
        auto returnType = llvmType(func.returnType, span);
        _function = new FunctionState(planSlots(func), scalarsOf(func.returnType, span));
        // Only recursion can overflow the stack, and every cycle of calls passes through a
        // function on a cycle of direct calls or one reached through a function value.
        auto stackCheck = index in _recursive || index in _escaped ? emitStackCheck(span) : Fragment.init;

        string[] params;
        Fragment receive;
        foreach (param; func.params)
        {
            auto passed = paramTypes(param, span);
            auto names = incoming(param, passed.length);
            foreach (i, type; passed) params ~= type ~ " " ~ names[i];
            // A mutable param's slot is its caller's, which it was passed.
            if (!param.mutable) receive = receive.then(storeScalars(passed, _function.slots[param], 0, names));
        }
        if (func.origin == FunctionOrigin.lambda)
        {
            params ~= "ptr %.env";
            receive = receive.then(receiveCaptures(func));
        }

        if (index in _recursive) _function.tailKept = func.params;
        auto body = isStruct(returnType)
            ? emitInto(func.body, _function.returnScalars, FunctionState.resultSlot, true)
            : emitTail(func.body);
        auto whole = Fragment.label(".entry")
            .then(stackCheck)
            .then(receive)
            .then(body)
            .then(emitEnding(body.operands, func.body.type == _program.types.never));

        // The allocas go right after the entry label.
        auto allocas = _function.slots.allocas.dup;
        if (isStruct(returnType)) allocas ~= "  %s = alloca %s".format(FunctionState.resultSlot, returnType);
        if (_function.usesOutSlots)
        {
            allocas ~= ["  %s = alloca ptr".format(FunctionState.outData), "  %s = alloca i64".format(FunctionState.outLength)];
        }
        allocas ~= _function.cImages;
        auto lines = whole.code[0 .. 1] ~ allocas ~ whole.code[1 .. $];
        // Only `silver_main` is called from outside the module.
        auto linkage = func.origin == FunctionOrigin.declared ? "internal " : "private ";
        return "define %s%s %s(%s) #0 {\n%s\n}\n".format(linkage, returnType, mangled(index), params.join(", "), lines.join("\n"));
    }

    /// How the function ends, `operands` being its body's value. LLVM returns one value, so several
    /// scalars go back as a struct, which the caller takes apart at once. The body and every
    /// `Return` have written them to the result slot, and the struct is built from it in one block,
    /// so that a caller the function is inlined into gets each scalar and not a phi of structs.
    private Fragment emitEnding(const string[] operands, bool neverEnds)
    {
        auto scalars = _function.returnScalars;
        auto returnType = structOf(scalars);
        if (!isStruct(returnType))
        {
            return neverEnds ? Fragment.unreachable() : Fragment.ret(returnType, operands.length == 0 ? null : operands[0]);
        }
        auto last = neverEnds ? Fragment.unreachable() : Fragment.jump(FunctionState.returnBlock);
        auto built = Fragment.constant("undef");
        foreach (i, scalar; scalars)
        {
            auto field = fieldPointer(returnType, FunctionState.resultSlot, i);
            auto held = _function.load(stored(scalar), field.value);
            built = built.then(field).then(held)
                .then(_function.result("insertvalue %s %s, %s %s, %s".format(returnType, built.value, stored(scalar), held.value, i)));
        }
        return last.then(Fragment.label(FunctionState.returnBlock)).then(built).then(Fragment.ret(returnType, built.value));
    }

    /// The LLVM type holding `scalars`: nothing, the one scalar, or a struct of them in order. A
    /// struct is how a value is laid out in memory and returned, and nothing else: LLVM's passes
    /// don't see through a struct that is an operand, so every other value is its scalars. Each
    /// struct is defined once and used by name, or every instruction that reaches into a wide one
    /// would spell out all of it. An `i1` is an `i8` in one: copying a struct moves bytes, and LLVM
    /// keeps a slot in memory when it's written as a bit and copied as a byte.
    private string structOf(const string[] scalars)
    {
        if (scalars.length == 0) return "void";
        if (scalars.length == 1) return scalars[0];
        if (auto known = cast(immutable(string)[]) scalars in _structs) return *known;
        auto name = "%%T.%s".format(_structs.length);
        _structs[scalars.idup] = name;
        _structDefinitions ~= "%s = type { %-(%s, %) }".format(name, scalars.map!(s => stored(s)));
        return name;
    }

    /// The type a scalar has as a struct's field.
    private static string stored(string scalar)
    {
        return scalar == "i1" ? "i8" : scalar;
    }

    /// The scalar `field` holds, a struct's field of the type `scalar` is stored as.
    private Fragment fromStored(string scalar, string field)
    {
        return scalar == "i1" ? _function.convert("trunc", "i8", field, "i1") : Fragment.constant(field);
    }

    /// `operand`, a `scalar`, as a struct's field holds it.
    private Fragment toStored(string scalar, string operand)
    {
        if (scalar != "i1") return Fragment.constant(operand);
        if (operand == "true") return Fragment.constant("1");
        if (operand == "false") return Fragment.constant("0");
        if (operand == "undef") return Fragment.constant("undef");
        return _function.convert("zext", "i1", operand, "i8");
    }

    private static bool isStruct(string type)
    {
        import std.algorithm : startsWith;

        return type.startsWith("%T.");
    }

    /// The `count` scalars from `offset` on of the value `pointer` points to, which is made of
    /// `layout`.
    private Fragment loadScalars(const string[] layout, string pointer, size_t offset, size_t count)
    {
        if (count == 0) return Fragment.init;
        if (layout.length == 1) return _function.load(layout[0], pointer);
        auto type = structOf(layout);
        Fragment code;
        string[] operands;
        foreach (at; offset .. offset + count)
        {
            auto field = fieldPointer(type, pointer, at);
            auto held = _function.load(stored(layout[at]), field.value);
            auto value = fromStored(layout[at], held.value);
            code = code.then(field).then(held).then(value);
            operands ~= value.value;
        }
        return code.withOperands(operands);
    }

    /// Writes `operands` from `offset` on of the value `pointer` points to, which is made of `layout`.
    private Fragment storeScalars(const string[] layout, string pointer, size_t offset, const string[] operands)
    {
        if (operands.length == 0) return Fragment.init;
        if (layout.length == 1) return Fragment.store(layout[0], operands[0], pointer);
        auto type = structOf(layout);
        Fragment code;
        foreach (i, operand; operands)
        {
            auto field = fieldPointer(type, pointer, offset + i);
            auto held = toStored(layout[offset + i], operand);
            code = code.then(field).then(held).then(Fragment.store(stored(layout[offset + i]), held.value, field.value));
        }
        return code.withValue(null);
    }

    /// Copies a whole value made of `layout` from `source` to `target`, both in memory. A wide one
    /// never becomes operands, so it costs one instruction. A narrow one is moved a scalar at a
    /// time: unoptimized, `memcpy` is a call, since its size isn't a literal here.
    private Fragment move(const string[] layout, string target, string source)
    {
        if (layout.length <= narrowest)
        {
            auto value = loadScalars(layout, source, 0, layout.length);
            return value.then(storeScalars(layout, target, 0, value.operands));
        }
        useIntrinsic(memcpyDeclaration);
        return Fragment.instruction("call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %s, i1 false)".format(
            target, source, elementSizeOf(structOf(layout))));
    }

    private enum memcpyDeclaration = "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1 immarg)";
    /// The most scalars a value is made of for `move` to load and store each.
    private enum narrowest = 8;

    /// A value on its way to memory, once `code` has run: still where it was, at `pointer`, or in
    /// `operands`.
    private struct Source
    {
        Fragment code;
        string pointer;
        const(string)[] operands;
    }

    /// Evaluates `e`, whose value is made of `layout`, for `write` to put somewhere. A value that is
    /// already in memory stays there until then, so nothing that assigns a local may run in between.
    private Source sourceOf(const Expr e, const string[] layout)
    {
        return e.kind.match!(
            (const Block block) {
                if (block.result is null) return sourceOfValue(e, layout);
                Fragment statements;
                foreach (statement; block.statements) statements = statements.then(emitStmt(statement));
                auto result = sourceOf(*block.result, layout);
                return Source(statements.then(result.code), result.pointer, result.operands);
            },
            _ => sourceOfValue(e, layout),
        );
    }

    private Source sourceOfValue(const Expr e, const string[] layout)
    {
        auto place = placeOf(e);
        if (place.pointer is null)
        {
            auto value = emitExpr(e);
            return Source(value, null, value.operands);
        }
        if (layout.length > narrowest && place.count == layout.length && place.layout == layout)
        {
            return Source(place.code, place.pointer);
        }
        auto value = read(place);
        return Source(value, null, value.operands);
    }

    private Fragment write(Source source, const string[] layout, string pointer)
    {
        if (source.pointer !is null) return move(layout, pointer, source.pointer);
        // A `Never` has no operands, and what follows it is never reached.
        if (source.operands.length == 0) return Fragment.init;
        return storeScalars(layout, pointer, 0, source.operands);
    }

    /// Evaluates `e` and writes its value, which is made of `layout`, to `pointer`, which nothing
    /// `e` runs can read: a new local's slot, or memory that has just been allocated. So a record
    /// with a field replaced is copied there whole and the field written over it, and each arm of
    /// an `If` writes its own value there.
    private Fragment emitInto(const Expr e, const string[] layout, string pointer, bool tail = false)
    {
        Fragment leaf(Fragment code) => tail ? keepingOnReturn(e, code) : code;

        Fragment whole()
        {
            auto source = sourceOf(e, layout);
            return leaf(source.code.then(write(source, layout, pointer)));
        }

        return e.kind.match!(
            (const Update update) {
                if (layout.length == 1) return whole();
                auto object = emitInto(*update.object, layout, pointer);
                auto at = storedAt(e.type, update.index, e.span);
                auto replacement = emitHeld(e.type, update.index, *update.value, e.span);
                if (at.count == 0) return leaf(object.then(replacement).withValue(null));
                return leaf(object.then(replacement).then(storeScalars(layout, pointer, at.offset, replacement.operands)));
            },
            (const Construct construct) {
                // A record around one value is laid out as that value is.
                auto fields = fieldTypes(e.type);
                if (fields.count!(f => !isEmpty(f)) != 1) return whole();
                foreach (i; 0 .. fields.length) if (isBoxedField(e.type, i)) return whole();
                Fragment code;
                foreach (i, ref field; construct.fields)
                {
                    code = code.then(isEmpty(fields[i]) ? emitExpr(field).withValue(null) : emitInto(field, layout, pointer));
                }
                return leaf(code);
            },
            (const Block block) {
                if (block.result is null) return whole();
                Fragment statements;
                foreach (statement; block.statements) statements = statements.then(emitStmt(statement));
                return statements.then(emitInto(*block.result, layout, pointer, tail));
            },
            (const If if_) {
                auto condition = emitExpr(*if_.condition);
                auto thenLabel = _function.newLabel("then");
                auto elseLabel = _function.newLabel("else");
                auto mergeLabel = _function.newLabel("merge");
                return condition
                    .then(Fragment.branch(condition.value, thenLabel, elseLabel))
                    .then(Fragment.label(thenLabel)).then(emitInto(*if_.trueBody, layout, pointer, tail)).then(Fragment.jump(mergeLabel))
                    .then(Fragment.label(elseLabel)).then(emitInto(*if_.falseBody, layout, pointer, tail)).then(Fragment.jump(mergeLabel))
                    .then(Fragment.label(mergeLabel));
            },
            _ => whole(),
        );
    }

    /// A value of `scalars` that is `first` when control comes from the block `firstBlock`, and
    /// `second` from `secondBlock`.
    private Fragment merge(const string[] scalars, const string[] first, string firstBlock, const string[] second,
        string secondBlock)
    {
        Fragment code;
        string[] operands;
        foreach (i, scalar; scalars)
        {
            auto phi = _function.result("phi %s [ %s, %%%s ], [ %s, %%%s ]".format(scalar, first[i], firstBlock,
                second[i], secondBlock));
            code = code.then(phi);
            operands ~= phi.value;
        }
        return code.withOperands(operands);
    }

    /// A zero for each of `scalars`.
    private static string[] zeros(const string[] scalars)
    {
        return scalars.map!(s => s == "ptr" ? "null" : s == "double" || s == "float" ? "0.0" : s == "i1" ? "false" : "0").array;
    }

    /// The LLVM parameters that receive `param`, which is passed as `count` arguments.
    private static string[] incoming(const Local param, size_t count)
    {
        import std.range : iota;

        if (count == 1) return ["%" ~ param.name];
        return iota(count).map!(i => "%%%s.%s".format(param.name, i)).array;
    }

    /// What a closure's environment points to: each capture that is made of something, in order,
    /// laid out as it is in a slot, so that one is copied to the other whole.
    private const(string)[] environmentFields(const Function func)
    {
        const(string)[] fields;
        foreach (capture; func.captures)
        {
            auto type = llvmType(capture.type, func.body.span);
            if (type != "void") fields ~= type;
        }
        return fields;
    }

    /// Where field `index` is in the environment `pointer` points to, which holds `fields`.
    private Fragment environmentField(const string[] fields, string pointer, size_t index)
    {
        return fields.length == 1 ? Fragment.constant(pointer) : fieldPointer(structOf(fields), pointer, index);
    }

    /// A lambda's captures, copied from its environment into their slots.
    private Fragment receiveCaptures(const Function func)
    {
        auto fields = environmentFields(func);
        Fragment code;
        size_t at = 0;
        foreach (capture; func.captures)
        {
            auto scalars = scalarsOf(capture.type, func.body.span);
            if (scalars.length == 0) continue;
            auto held = environmentField(fields, "%.env", at++);
            code = code.then(held).then(move(scalars, _function.slots[capture], held.value));
        }
        return code.withValue(null);
    }

    /// Where every local of `func` lives. Slots are allocated in the order lifetimes start, so a
    /// reused name is numbered as its `Let` is met, and a `Let`'s comes before those in its value.
    private Slots planSlots(const Function func)
    {
        Slots slots;
        Lifetimes lifetimes;
        foreach (param; func.params)
        {
            auto passed = paramTypes(param, func.body.span);
            if (passed.length == 0) continue;
            if (param.mutable) slots.bind(param, incoming(param, 1)[0]);
            lifetimes.declare(param, param.mutable ? null : structOf(passed));
        }
        foreach (capture; func.captures)
        {
            auto type = llvmType(capture.type, func.body.span);
            if (type != "void") lifetimes.declare(capture, type);
        }
        trace(lifetimes, func.body);
        foreach (i, local; lifetimes.locals)
        {
            if (lifetimes.types[i] !is null) slots.allocate(local, lifetimes.types[i], lifetimes.starts[i], lifetimes.ends[i]);
        }
        foreach (label, indices; lifetimes.kept) slots.kept[label] = indices.map!(i => lifetimes.locals[i]).array;
        slots.left = lifetimes.left;
        return slots;
    }

    /// Every node is listed, so a new kind of Core node can't be skipped by accident.
    private void trace(ref Lifetimes lifetimes, const Expr e)
    {
        void all(const Expr[] exprs)
        {
            foreach (ref expr; exprs) trace(lifetimes, expr);
        }

        e.kind.match!(
            (const UnitLit _) {},
            (const BoolLit _) {},
            (const IntLit _) {},
            (const FloatLit _) {},
            (const StringLit _) {},
            (const LocalRef use) => lifetimes.use(use.local),
            (const Break jump) => lifetimes.jump(jump.label, true),
            (const Continue jump) => lifetimes.jump(jump.label, false),
            (const Call call) => all(call.args),
            (const CallClosure call) {
                trace(lifetimes, *call.callee);
                all(call.args);
            },
            (const MakeClosure closure) => all(closure.captures),
            (const ForeignCall call) => all(call.args),
            (const IntrinsicCall call) => all(call.args),
            (const Prim prim) => all(prim.args),
            (const Convert convert) => trace(lifetimes, *convert.value),
            (const If if_) {
                trace(lifetimes, *if_.condition);
                trace(lifetimes, *if_.trueBody);
                trace(lifetimes, *if_.falseBody);
            },
            (const Block block) {
                foreach (ref statement; block.statements) trace(lifetimes, statement);
                if (block.result !is null) trace(lifetimes, *block.result);
            },
            (const Loop loop) {
                lifetimes.beginLoop(loop.label);
                trace(lifetimes, *loop.body);
                lifetimes.endLoop();
            },
            (const Return return_) {
                lifetimes.leaveAll();
                trace(lifetimes, *return_.value);
            },
            (const Construct construct) => all(construct.fields),
            (const Field field) => trace(lifetimes, *field.object),
            (const Update update) {
                trace(lifetimes, *update.object);
                trace(lifetimes, *update.value);
            },
            (const Inject inject) {
                if (inject.payload !is null) trace(lifetimes, *inject.payload);
            },
            (const IsMember test) => trace(lifetimes, *test.subject),
            (const Payload payload) => trace(lifetimes, *payload.subject),
            (const ArrayLit literal) => all(literal.elements),
            (const Index index) {
                trace(lifetimes, *index.array);
                trace(lifetimes, *index.index);
            },
            (const Slice slice) {
                trace(lifetimes, *slice.array);
                trace(lifetimes, *slice.start);
                trace(lifetimes, *slice.end);
            },
            (const Length length) => trace(lifetimes, *length.array),
            (const Cell cell) => all(cell.args),
            (const Capture capture) => trace(lifetimes, *capture.closure),
            (const TestFailure failure) => trace(lifetimes, *failure.message),
        );
    }

    private void trace(ref Lifetimes lifetimes, const Stmt s)
    {
        lifetimes.beginStatement();
        s.kind.match!(
            (const Let let) {
                auto type = llvmType(let.local.type, s.span);
                if (type != "void") lifetimes.declare(let.local, type);
                trace(lifetimes, let.value);
            },
            (const Assign assign) {
                lifetimes.use(assign.local);
                trace(lifetimes, assign.value);
            },
            (const AssignElement assign) {
                lifetimes.use(assign.local);
                trace(lifetimes, assign.index);
                trace(lifetimes, assign.value);
            },
            (const Eval eval) => trace(lifetimes, eval.expr),
        );
        lifetimes.endStatement();
    }

    private Fragment emitExpr(const Expr e)
    {
        return e.kind.match!(kind => emit(e, kind));
    }

    /// Each of `exprs` in order, with the operands of each.
    private Fragment emitAll(const Expr[] exprs, out const(string)[][] operands)
    {
        Fragment code;
        foreach (ref expr; exprs)
        {
            auto value = emitExpr(expr);
            code = code.then(value);
            operands ~= value.operands;
        }
        return code.withValue(null);
    }

    /// The operands of `e`'s value, as a parent that wants `count` scalars uses them. A `Never` has
    /// none, and the code after it is never reached, so `undef` stands in for each.
    private const(string)[] operandsOf(const Expr e, const string[] operands, size_t count)
    {
        import std.range : repeat;

        if (operands.length == count) return operands;
        assert(operands.length == 0 && e.type == _program.types.never, "lowering gives every value its type's scalars");
        return "undef".repeat(count).array;
    }

    /// The operand of `e`'s value, for a parent that wants one scalar.
    private string operandOf(const Expr e, Fragment value)
    {
        return operandsOf(e, value.operands, 1)[0];
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

    /// As its bits, since a decimal constant has to be exact in LLVM. LLVM writes a `float` constant
    /// as the bits of the `double` of the same value, and refuses one that isn't exactly a `float`,
    /// so a `Float32` is rounded first.
    private Fragment emit(const Expr e, const FloatLit literal)
    {
        auto value = e.type == _program.types.float32 ? cast(double) cast(float) literal.value : literal.value;
        return Fragment.constant(floatConstant(value));
    }

    private static string floatConstant(double value)
    {
        return "0x%016X".format(*cast(ulong*) &value);
    }

    private Fragment emit(const Expr e, const StringLit literal)
    {
        return Fragment.init.withOperands(stringConstant(literal.value));
    }

    /// A String constant: a private global holding `text`'s bytes, with no terminator.
    private string[] stringConstant(string text)
    {
        import std.conv : to;

        if (text.length == 0) return ["null", "0"];
        if (auto existing = text in _stringGlobals) return [*existing, text.length.to!string];
        auto name = "@.str.%s".format(_globals.length);
        _globals ~= "%s = private unnamed_addr constant [%s x i8] c\"%s\"".format(name, text.length, escaped(text));
        _stringGlobals[text] = name;
        return [name, text.length.to!string];
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

    /// A local's value, loaded from its slot. A local made of nothing, like a Unit one, has no slot.
    private Fragment emit(const Expr e, const LocalRef use)
    {
        auto place = placeOf(e);
        return place.pointer is null ? Fragment.init : read(place);
    }

    private Fragment emit(const Expr e, const Call call)
    {
        return emitCall(e, call, false);
    }

    /// A call, which for one in tail position (`tail`) is preceded by `keptOnReturn`.
    private Fragment emitCall(const Expr e, const Call call, bool tail)
    {
        auto func = _program.functions[call.target];
        Type[] types;
        foreach (param; func.params) types ~= param.type;
        auto arguments = emitArguments(call.args, types, func.params.map!(p => p.mutable).array, e.span);
        auto kept = tail ? keptOnReturn(e.span) : Fragment.init;
        auto called = arguments.code.then(kept)
            .then(callFunction(func.returnType, mangled(call.target), arguments.operands, e.span));
        return endIfNever(called, e.type);
    }

    /// Calls `callee`, which returns a value of `type`. Several scalars come back as a struct,
    /// which is taken apart at once.
    private Fragment callFunction(Type type, string callee, const string[] arguments, Span span)
    {
        auto scalars = scalarsOf(type, span);
        auto returned = structOf(scalars);
        auto called = _function.call(returned, callee, arguments);
        if (!isStruct(returned)) return called;
        auto fields = called;
        string[] operands;
        foreach (i; 0 .. scalars.length)
        {
            auto held = _function.extract(returned, called.value, i);
            auto field = fromStored(scalars[i], held.value);
            fields = fields.then(held).then(field);
            operands ~= field.value;
        }
        return fields.withOperands(operands);
    }

    private struct Arguments
    {
        Fragment code;
        string[] operands;
    }

    /// Arguments as a call passes them, each written with its type, and their code. `types` is the
    /// type of each param, and `mutables` which are mutable.
    private Arguments emitArguments(const Expr[] args, const Type[] types, const bool[] mutables, Span span)
    {
        Arguments result;
        foreach (i, ref arg; args)
        {
            auto passed = passedAs(types[i], mutables[i], span);
            if (mutables[i])
            {
                // Core passes a mutable local here, and the callee writes through its slot.
                if (passed.length == 0) continue;
                auto local = arg.kind.match!((const LocalRef use) => use.local, _ => cast(const(Local)) null);
                assert(local !is null, "lowering passes a local to a mutable param");
                result.operands ~= "ptr " ~ _function.slots[local];
                continue;
            }
            // Evaluated even when it's made of nothing, for what it does.
            auto value = emitExpr(arg);
            result.code = result.code.then(value);
            foreach (at, operand; operandsOf(arg, value.operands, passed.length)) result.operands ~= passed[at] ~ " " ~ operand;
        }
        result.code = result.code.withValue(null);
        return result;
    }

    /// The LLVM types of the arguments `param` is passed as. Definitions and calls agree because
    /// both ask this.
    private const(string)[] paramTypes(const Local param, Span span)
    {
        return passedAs(param.type, param.mutable, span);
    }

    /// How a param of `type` is passed: an argument for each of its scalars, or one `ptr` to the
    /// caller's slot when it's mutable. A type made of nothing isn't passed at all.
    private const(string)[] passedAs(Type type, bool mutable, Span span)
    {
        auto scalars = scalarsOf(type, span);
        return mutable && scalars.length > 0 ? ["ptr"] : scalars;
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
        return emitCallClosure(e, call, false);
    }

    /// A call through a function value, which for one in tail position (`tail`) is preceded by
    /// `keptOnReturn`.
    private Fragment emitCallClosure(const Expr e, const CallClosure call, bool tail)
    {
        auto signature = functionData(call.callee.type);
        auto closure = emitExpr(*call.callee);
        auto parts = operandsOf(*call.callee, closure.operands, 2);
        auto code = _function.load("ptr", parts[0]);
        bool[] mutables;
        foreach (i; 0 .. signature.params.length) mutables ~= signature.isMutable(i);
        auto arguments = emitArguments(call.args, signature.params, mutables, e.span);
        auto kept = tail ? keptOnReturn(e.span) : Fragment.init;
        auto called = closure.then(code).then(arguments.code).then(kept)
            .then(callFunction(signature.ret, code.value, arguments.operands ~ ("ptr " ~ parts[1]), e.span));
        return endIfNever(called, e.type);
    }

    /// A function value. A lambda's environment is a copy of its captures on the heap; any other
    /// function goes through a thunk that takes an environment and ignores it.
    private Fragment emit(const Expr e, const MakeClosure closure)
    {
        auto func = _program.functions[closure.target];
        auto descriptor = descriptorOf(closure.target, e.span);
        if (func.origin != FunctionOrigin.lambda) return Fragment.init.withOperands([descriptor, "null"]);
        auto fields = environmentFields(func);
        if (fields.length == 0)
        {
            const(string)[][] operands;
            return emitAll(closure.captures, operands).withOperands([descriptor, "null"]);
        }

        auto env = alloc(structOf(fields));
        auto result = env;
        size_t at = 0;
        foreach (i, capture; func.captures)
        {
            auto scalars = scalarsOf(capture.type, e.span);
            if (scalars.length == 0)
            {
                result = result.then(emitExpr(closure.captures[i]));
                continue;
            }
            auto held = environmentField(fields, env.value, at++);
            result = result.then(held).then(emitInto(closure.captures[i], scalars, held.value));
        }
        return result.withOperands([descriptor, env.value]);
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
        auto compare = func.captureEquality == noFunction ? "null" : mangled(func.captureEquality);
        auto hasher = func.captureHash == noFunction ? "null" : mangled(func.captureHash);
        _globals ~= "%s = private constant %s { ptr %s, ptr %s, i64 %s, ptr %s, ptr %s }".format(name,
            structOf(descriptorScalars), code, printed[0], printed[1], compare, hasher);
        return name;
    }

    /// Whether the function values `a` and `b` are equal: closures of one function, whose
    /// `captureEquality`, if it has one, says their captures are.
    private Fragment emitFunctionEquality(const string[] a, const string[] b)
    {
        enum name = "@silver.function.equal";
        if (!_functionEquality)
        {
            _functionEquality = true;
            _thunkDefinitions ~= "define private i1 %s(ptr %%a, ptr %%a.env, ptr %%b, ptr %%b.env) {\n.entry:\n".format(name)
                ~ "  %same = icmp eq ptr %a, %b\n"
                ~ "  br i1 %same, label %same.function, label %unequal\nsame.function:\n"
                ~ "  %%field = getelementptr %s, ptr %%a, i32 0, i32 3\n".format(structOf(descriptorScalars))
                ~ "  %compare = load ptr, ptr %field\n"
                ~ "  %none = icmp eq ptr %compare, null\n"
                ~ "  br i1 %none, label %equal, label %captures\ncaptures:\n"
                ~ "  %result = call i1 %compare(ptr %a, ptr %a.env, ptr %b, ptr %b.env)\n"
                ~ "  ret i1 %result\nequal:\n  ret i1 true\nunequal:\n  ret i1 false\n}\n";
        }
        return _function.result("call i1 %s(ptr %s, ptr %s, ptr %s, ptr %s)".format(name, a[0], a[1], b[0], b[1]));
    }

    /// The hash of the function value `f`: its descriptor's address, with what its `captureHash`,
    /// if it has one, gives, mixed.
    private Fragment emitFunctionHash(const string[] f)
    {
        enum name = "@silver.function.hash";
        auto mix = hashMix();
        if (!_functionHash)
        {
            _functionHash = true;
            _thunkDefinitions ~= "define private i64 %s(ptr %%f, ptr %%f.env) {\n.entry:\n".format(name)
                ~ "  %%field = getelementptr %s, ptr %%f, i32 0, i32 4\n".format(structOf(descriptorScalars))
                ~ "  %hasher = load ptr, ptr %field\n"
                ~ "  %none = icmp eq ptr %hasher, null\n"
                ~ "  br i1 %none, label %done, label %captures\ncaptures:\n"
                ~ "  %held = call i64 %hasher(ptr %f, ptr %f.env)\n"
                ~ "  br label %done\ndone:\n"
                ~ "  %captured = phi i64 [ 0, %.entry ], [ %held, %captures ]\n"
                ~ "  %code = ptrtoint ptr %f to i64\n"
                ~ "  %both = xor i64 %code, %captured\n"
                ~ "  %%hash = call i64 %s(i64 %%both)\n".format(mix)
                ~ "  ret i64 %hash\n}\n";
        }
        return _function.result("call i64 %s(ptr %s, ptr %s)".format(name, f[0], f[1]));
    }

    /// MurmurHash3's finalizer, which `PrimOp.Hash` mixes a primitive's bits with, as the
    /// interpreter's `mixHash` does.
    private string hashMix()
    {
        enum name = "@silver.hash.mix";
        if (!_hashMix)
        {
            _hashMix = true;
            _thunkDefinitions ~= "define private i64 %s(i64 %%x) {\n.entry:\n".format(name)
                ~ "  %s1 = lshr i64 %x, 33\n  %x1 = xor i64 %x, %s1\n  %m1 = mul i64 %x1, -49064778989728563\n"
                ~ "  %s2 = lshr i64 %m1, 33\n  %x2 = xor i64 %m1, %s2\n  %m2 = mul i64 %x2, -4265267296055464877\n"
                ~ "  %s3 = lshr i64 %m2, 33\n  %x3 = xor i64 %m2, %s3\n  ret i64 %x3\n}\n";
        }
        return name;
    }

    /// `PrimOp.Hash` of `value`, of the primitive, `Ref`, native or function type `type`.
    private Fragment emitHash(Type type, const string[] value, Span span)
    {
        auto types = _program.types;
        if (type == types.string_) return callRuntime("silver_hash_string", value);
        if (types.isFunction(type)) return emitFunctionHash(value);
        Fragment bits;
        if (type in _program.cellContents || type in _program.nativeTypes)
        {
            bits = _function.convert("ptrtoint", "ptr", value[0], "i64");
        }
        else if (types.isInteger(type)) bits = widened(type, value[0], span);
        else if (type == types.bool_) bits = _function.convert("zext", "i1", value[0], "i64");
        else if (type == types.char_) bits = _function.convert("zext", llvmType(type, span), value[0], "i64");
        else
        {
            assert(types.isFloat(type), "lowering hashes only primitives, Refs, native types and function values with `Hash`");
            // A `Float32` hashes as the `Float` it widens to, as the interpreter holds it.
            Fragment widen;
            string x = value[0];
            if (type == types.float32)
            {
                widen = _function.convert("fpext", "float", x, "double");
                x = widen.value;
            }
            // `0.0 == -0.0`, so both hash as `0.0`.
            auto zero = _function.result("fcmp oeq double %s, 0.0".format(x));
            auto chosen = _function.result("select i1 %s, double 0.0, double %s".format(zero.value, x));
            bits = widen.then(zero).then(chosen).then(_function.convert("bitcast", "double", chosen.value, "i64"));
        }
        return bits.then(_function.result("call i64 %s(i64 %s)".format(hashMix(), bits.value)));
    }

    /// Capture `capture.index` of a closure of the lambda `capture.target`, from its environment.
    private Fragment emit(const Expr e, const Capture capture)
    {
        auto func = _program.functions[capture.target];
        auto closure = emitExpr(*capture.closure);
        auto scalars = scalarsOf(func.captures[capture.index].type, e.span);
        if (scalars.length == 0) return closure.withValue(null);
        size_t at = 0;
        foreach (before; func.captures[0 .. capture.index])
        {
            if (scalarsOf(before.type, e.span).length > 0) at++;
        }
        auto env = operandsOf(*capture.closure, closure.operands, 2)[1];
        auto held = environmentField(environmentFields(func), env, at);
        return closure.then(held).then(loadScalars(scalars, held.value, 0, scalars.length));
    }

    /// The thunk for calling function `target` through a closure.
    private string thunk(size_t target, Span span)
    {
        if (auto existing = target in _thunks) return *existing;
        auto name = "@\".thunk.%s\"".format(target);
        _thunks[target] = name;

        auto func = _program.functions[target];
        string[] declared;
        foreach (param; func.params)
        {
            foreach (type; paramTypes(param, span)) declared ~= "%s %%.a%s".format(type, declared.length);
        }
        auto returned = llvmType(func.returnType, span);
        auto body = returned == "void"
            ? "  call void %s(%s)\n  ret void\n".format(mangled(target), declared.join(", "))
            : "  %%.r = call %s %s(%s)\n  ret %s %%.r\n".format(returned, mangled(target), declared.join(", "), returned);
        _thunkDefinitions ~= "define private %s %s(%s) #0 {\n.entry:\n%s}\n".format(returned, name,
            (declared ~ "ptr %.env").join(", "), body);
        return name;
    }

    /// A call to a C function, declared with the types the platform's convention gives the native's
    /// declared parameters and result. A structure is put into C's layout in memory of the function's
    /// own, and passed from there as the convention says; one that comes back is read out of it.
    private Fragment emit(const Expr e, const ForeignCall call)
    {
        auto native = &_program.natives[call.native];
        auto description = describeCall(_program, *native, hostConvention);
        Fragment code;
        string[] params;
        string[] operands;
        string resultImage;
        if (description.result.passing == Passing.hidden)
        {
            resultImage = _function.newCImage(description.result.type);
            auto param = inMemory("sret", description.result.type);
            params ~= param;
            operands ~= param ~ " " ~ resultImage;
        }
        foreach (i, ref arg; call.args)
        {
            auto value = emitExpr(arg);
            code = code.then(value);
            auto crossing = description.arguments[i];
            if (crossing.type.kind != CKind.structure)
            {
                assert(crossing.parts.length == 1, "a scalar crosses whole, as one part");
                string scalar;
                if (isNullableHandle(native.params[i]))
                {
                    // `None` is null, whatever its pointer scalar holds.
                    auto option = operandsOf(arg, value.operands, 2);
                    auto pointer = _function.result("select i1 %s, ptr %s, ptr null".format(option[0], option[1]));
                    code = code.then(pointer);
                    scalar = pointer.value;
                }
                else scalar = operandOf(arg, value);
                params ~= llvmParam(crossing.parts[0]);
                operands ~= llvmParam(crossing.parts[0]) ~ " " ~ scalar;
                continue;
            }

            auto image = _function.newCImage(crossing.type);
            auto given = operandsOf(arg, value.operands, scalarsOf(native.params[i], e.span).length);
            code = code.then(packStructure(native.params[i], crossing.type, given, image, 0, e.span));
            final switch (crossing.passing)
            {
                case Passing.value:
                    foreach (part; crossing.parts)
                    {
                        auto address = byteAddress(image, part.offset);
                        auto piece = _function.load(llvmPart(part), address.value);
                        code = code.then(address).then(piece);
                        params ~= llvmPart(part);
                        operands ~= llvmPart(part) ~ " " ~ piece.value;
                    }
                    break;
                case Passing.copy:
                    params ~= "ptr";
                    operands ~= "ptr " ~ image;
                    break;
                case Passing.stack:
                    auto param = inMemory("byval", crossing.type);
                    params ~= param;
                    operands ~= param ~ " " ~ image;
                    break;
                case Passing.nothing, Passing.hidden:
                    assert(0, "only a result passes nothing or through a hidden pointer");
            }
        }

        auto result = description.result;
        string returnType;
        final switch (result.passing)
        {
            case Passing.nothing, Passing.hidden:
                returnType = "void";
                break;
            case Passing.value:
                if (result.type.kind != CKind.structure) returnType = llvmResult(result.parts[0]);
                else returnType = result.parts.length == 1 ? llvmPart(result.parts[0])
                    : "{ %s }".format(result.parts.map!(part => llvmPart(part)).join(", "));
                break;
            case Passing.copy, Passing.stack:
                assert(0, "a result comes back in registers or through a hidden pointer");
        }

        // `nobuiltin`, or LLVM takes a native named like a C library function for that function, and
        // works out or rewrites calls to it with arithmetic of its own, which rounds differently.
        auto symbol = native.symbol;
        auto declaration = "declare ccc %s @%s(%s) nobuiltin%s".format(returnType, symbol, params.join(", "),
            e.type == _program.types.never ? " noreturn" : "");
        if (symbol in runtime) return notImplemented("a native named like the runtime's own " ~ symbol, e.span);
        assert((symbol in _foreign) is null || _foreign[symbol] == declaration,
            "lowering refuses natives that bind one symbol with signatures C passes differently");
        _foreign[symbol] = declaration;

        auto called = code.then(_function.call(returnType, "@" ~ symbol, operands, "ccc"));
        if (result.type.kind == CKind.structure)
        {
            auto image = resultImage;
            if (result.passing == Passing.value)
            {
                image = _function.newCImage(result.type);
                auto returned = called.value;
                foreach (i, part; result.parts)
                {
                    auto address = byteAddress(image, part.offset);
                    called = called.then(address);
                    auto piece = returned;
                    if (result.parts.length > 1)
                    {
                        auto taken = _function.extract(returnType, returned, i);
                        called = called.then(taken);
                        piece = taken.value;
                    }
                    called = called.then(Fragment.store(llvmPart(part), piece, address.value));
                }
            }
            auto unpacked = unpackStructure(e.type, result.type, image, 0, e.span);
            return called.then(unpacked);
        }
        if (isNullableHandle(e.type))
        {
            auto present = _function.result("icmp ne ptr %s, null".format(called.value));
            return called.then(present).withOperands([present.value, called.value]);
        }
        return endIfNever(called, e.type);
    }

    /// A `byval` or `sret` pointer parameter to C memory of the structure `type`, which LLVM needs
    /// only the size and alignment of. A copy on the stack is in whole 8-byte words, and aligned so,
    /// as clang declares it.
    private static string inMemory(string attribute, const CType type)
    {
        auto alignment = attribute == "byval" && type.alignment < 8 ? 8 : type.alignment;
        return "ptr %s([%s x i8]) align %s".format(attribute, type.size, alignment);
    }

    /// The address `offset` bytes into `image`.
    private Fragment byteAddress(string image, uint offset)
    {
        if (offset == 0) return Fragment.constant(image);
        return _function.result("getelementptr inbounds i8, ptr %s, i64 %s".format(image, offset));
    }

    /// Code writing `operands`, a value of the native structure `type`, into C's layout `layout` at
    /// `at` bytes into `image`: a `Bool` as a byte, and an option of a handle as a pointer that's
    /// null for `None`.
    private Fragment packStructure(Type type, const CType layout, const(string)[] operands, string image, uint at, Span span)
    {
        Fragment code;
        size_t next;
        foreach (i, field; _program.recordFields[type])
        {
            auto count = scalarsOf(field, span).length;
            auto held = operands[next .. next + count];
            next += count;
            auto c = layout.fields[i];
            if (c.type.kind == CKind.structure)
            {
                code = code.then(packStructure(field, c.type, held, image, at + c.offset, span));
                continue;
            }
            auto address = byteAddress(image, at + c.offset);
            code = code.then(address);
            if (c.type.kind == CKind.bool_)
            {
                auto byte_ = _function.convert("zext", "i1", held[0], "i8");
                code = code.then(byte_).then(Fragment.store("i8", byte_.value, address.value));
            }
            else if (isNullableHandle(field))
            {
                auto pointer = _function.result("select i1 %s, ptr %s, ptr null".format(held[0], held[1]));
                code = code.then(pointer).then(Fragment.store("ptr", pointer.value, address.value));
            }
            else code = code.then(Fragment.store(llvmScalar(c.type.kind), held[0], address.value));
        }
        return code;
    }

    /// Code reading a value of the native structure `type` out of C's layout `layout` at `at` bytes
    /// into `image`, with an operand for each of its scalars: a `Bool` is a byte that isn't 0, and an
    /// option of a handle is `None` for null.
    private Fragment unpackStructure(Type type, const CType layout, string image, uint at, Span span)
    {
        Fragment code;
        string[] operands;
        foreach (i, field; _program.recordFields[type])
        {
            auto c = layout.fields[i];
            if (c.type.kind == CKind.structure)
            {
                auto inner = unpackStructure(field, c.type, image, at + c.offset, span);
                code = code.then(inner);
                operands ~= inner.operands;
                continue;
            }
            auto address = byteAddress(image, at + c.offset);
            code = code.then(address);
            if (c.type.kind == CKind.bool_)
            {
                auto byte_ = _function.load("i8", address.value);
                auto set = _function.result("icmp ne i8 %s, 0".format(byte_.value));
                code = code.then(byte_).then(set);
                operands ~= set.value;
            }
            else if (isNullableHandle(field))
            {
                auto pointer = _function.load("ptr", address.value);
                auto present = _function.result("icmp ne ptr %s, null".format(pointer.value));
                code = code.then(pointer).then(present);
                operands ~= [present.value, pointer.value];
            }
            else
            {
                auto loaded = _function.load(llvmScalar(c.type.kind), address.value);
                code = code.then(loaded);
                operands ~= loaded.value;
            }
        }
        return code.withOperands(operands);
    }

    /// Whether `type` is an option of a native type, which crosses into C as a pointer that may be null.
    private bool isNullableHandle(Type type)
    {
        auto types = _program.types;
        return types.isOption(type) && (types.optionInner(type) in _program.nativeTypes) !is null;
    }

    /// The LLVM type of a C parameter, with the attribute that has the caller extend it after it.
    private static string llvmParam(Part part)
    {
        auto extension = extensionAttribute(part.extension);
        return extension is null ? llvmPart(part) : llvmPart(part) ~ " " ~ extension;
    }

    /// The LLVM type of a C result, with the attribute saying the callee extended it before it, as
    /// clang requires.
    private static string llvmResult(Part part)
    {
        auto extension = extensionAttribute(part.extension);
        return extension is null ? llvmPart(part) : extension ~ " " ~ llvmPart(part);
    }

    private static string extensionAttribute(Extension extension)
    {
        final switch (extension)
        {
            case Extension.none: return null;
            case Extension.zero: return "zeroext";
            case Extension.sign: return "signext";
        }
    }

    /// The LLVM type of `part` as it's passed: a structure's bytes as the integer of their size, or
    /// two of its floats as a vector, as clang passes them.
    private static string llvmPart(Part part)
    {
        if (part.type == CKind.integer) return "i%s".format(part.size * 8);
        if (part.type == CKind.floatPair) return "<2 x float>";
        return llvmScalar(part.type);
    }

    private static string llvmScalar(CKind kind)
    {
        final switch (kind)
        {
            case CKind.void_: return "void";
            case CKind.bool_: return "i1";
            case CKind.int8, CKind.uint8: return "i8";
            case CKind.int16, CKind.uint16: return "i16";
            case CKind.int32, CKind.uint32: return "i32";
            case CKind.int64, CKind.uint64: return "i64";
            case CKind.pointer: return "ptr";
            case CKind.float_: return "float";
            case CKind.double_: return "double";
            case CKind.structure, CKind.integer, CKind.floatPair: assert(0, "not a scalar");
        }
    }

    private Fragment emit(const Expr e, const IntrinsicCall call)
    {
        final switch (call.intrinsic)
        {
            case Intrinsic.print, Intrinsic.printl:
                return emitPrint(call);
            case Intrinsic.readLine:
                return emitWithStatus("silver_readLine", call);
            case Intrinsic.readWhole:
                return emitWithStatus("silver_readWhole", call);
            case Intrinsic.writeWhole:
                return emitWithStatus("silver_writeWhole", call);
            case Intrinsic.exists:
                auto path = emitExpr(call.args[0]);
                return path.then(callRuntime("silver_exists", operandsOf(call.args[0], path.operands, 2)));
            case Intrinsic.panic:
                return emitExplicitPanic(call.args[0], e.span);
            case Intrinsic.exitWithError:
                return emitExitWithError(call.args[0]);
            case Intrinsic.programArguments:
                // A `[String]`, handed back through the out slots as a String is.
                return callRuntimeForString("silver_arguments", []);
            case Intrinsic.bytes, Intrinsic.uncheckedString:
                // A String and a `[UInt8]` have one layout, so the value is already the other.
                return emitExpr(call.args[0]);
            case Intrinsic.toCString:
                auto text = emitExpr(call.args[0]);
                return text.then(callRuntime("silver_toCString", operandsOf(call.args[0], text.operands, 2)));
            case Intrinsic.fromCString:
                return emitFromCString(call.args[0]);
            case Intrinsic.length, Intrinsic.get, Intrinsic.set, Intrinsic.update, Intrinsic.assert_, Intrinsic.expect, Intrinsic.uncheckedChar:
            case Intrinsic.hash, Intrinsic.countOnes:
                assert(0, "lowering makes `length` a Length, `assert` and `expect` a test, `uncheckedChar` a Convert, `hash` a derived function, `countOnes` a CountOnes, and the others operations on a Cell");
            case Intrinsic.derivedCompare:
                assert(0, "lowering expands `derivedCompare` into calls of `compare`");
            case Intrinsic.panics:
                return emitPanics(call.args[0], e.span);
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
        if (types.isInteger(arg.type)) value = value.then(widened(arg.type, value.value, arg.span));
        return value.then(callRuntime(name, value.operands)).withValue(null);
    }

    /// The suffix for an argument of `type` passed as `Any`. Every integer is `int` or `uint`.
    private string runtimeSuffix(Type type)
    {
        auto types = _program.types;
        if (types.isInteger(type)) return types.integerOf(type).signed ? "int" : "uint";
        if (type == types.float_) return "float";
        if (type == types.float32) return "float32";
        if (type == types.bool_) return "bool";
        if (type == types.unit) return "unit";
        if (type == types.string_) return "string";
        if (type == types.char_) return "char";
        assert(0, "lowering only passes primitives to an intrinsic's Any");
    }

    /// A call of the runtime's `name` with `call`'s arguments, as the `(Int32, String)` of the status it
    /// returns and the String it hands back through the out slots.
    private Fragment emitWithStatus(string name, const IntrinsicCall call)
    {
        Fragment arguments;
        string[] operands;
        foreach (arg; call.args)
        {
            auto value = emitExpr(arg);
            arguments = arguments.then(value);
            operands ~= operandsOf(arg, value.operands, scalarsOf(arg.type, arg.span).length);
        }
        _function.usesOutSlots = true;
        auto status = callRuntime(name, operands ~ [FunctionState.outData, FunctionState.outLength]);
        auto text = loadOutSlice();
        return arguments.then(status).then(text).withOperands(status.value ~ text.operands);
    }

    /// `fromCString(s)`: the runtime says whether the bytes are UTF-8, and hands back the String
    /// through the out slots, which makes the `String?`.
    private Fragment emitFromCString(const Expr pointer)
    {
        _function.usesOutSlots = true;
        auto value = emitExpr(pointer);
        auto valid = callRuntime("silver_fromCString",
            [operandOf(pointer, value), FunctionState.outData, FunctionState.outLength]);
        auto text = loadOutSlice();
        return value.then(valid).then(text).withOperands(valid.value ~ text.operands);
    }

    /// The String or array a runtime call has just written to the out slots.
    private Fragment loadOutSlice()
    {
        auto data = _function.load("ptr", FunctionState.outData);
        auto length = _function.load("i64", FunctionState.outLength);
        return data.then(length).withOperands([data.value, length.value]);
    }

    /// A call to the runtime function `name`, which hands back a String through the out slots.
    private Fragment callRuntimeForString(string name, const string[] operands)
    {
        _function.usesOutSlots = true;
        return callRuntime(name, operands ~ [FunctionState.outData, FunctionState.outLength]).then(loadOutSlice());
    }

    /// A failure of the running test, which the runtime records. One that ends the test returns to
    /// its guard.
    private Fragment emit(const Expr e, const TestFailure failure)
    {
        auto text = emitExpr(*failure.message);
        auto parts = operandsOf(*failure.message, text.operands, 2);
        if (!failure.ends) return text.then(callRuntime("silver_test_failed", parts)).withValue(null);
        return text.then(callRuntime("silver_test_stopped", parts))
            .then(Fragment.unreachable())
            .then(Fragment.label(_function.newLabel("after.stop")))
            .withValue(null);
    }

    /// `panics(work)`: `Some` of the message of the panic that ended `work`, or `None` if it returned.
    /// The work runs through a guard nested in the running test's.
    private Fragment emitPanics(const Expr work, Span span)
    {
        auto returned = llvmType(functionData(work.type).ret, span);
        auto closure = emitExpr(work);
        auto parts = operandsOf(work, closure.operands, 2);
        auto code = _function.load("ptr", parts[0]);
        auto panicked = _function.call("i1", panicsGuard(returned), ["ptr " ~ code.value, "ptr " ~ parts[1]]);

        auto noneLabel = _function.newLabel("panics.none");
        auto caughtLabel = _function.newLabel("panics.caught");
        auto doneLabel = _function.newLabel("panics.done");
        auto message = callRuntimeForString("silver_panics_message", []);
        auto scalars = ["i1"] ~ sliceScalars;
        auto result = merge(scalars, zeros(scalars), noneLabel, "true" ~ message.operands, caughtLabel);
        return closure.then(code).then(panicked)
            .then(Fragment.jump(noneLabel)).then(Fragment.label(noneLabel))
            .then(Fragment.branch(panicked.value, caughtLabel, doneLabel))
            .then(Fragment.label(caughtLabel)).then(message)
            .then(Fragment.jump(doneLabel))
            .then(Fragment.label(doneLabel)).then(result);
    }

    /// The guard for a `panics` call whose work returns the LLVM type `returned`, which says whether
    /// the work panicked. The runtime keeps the guard it runs under and puts it back afterwards,
    /// since nothing the guard computed before a jump back to it can be relied on after.
    private string panicsGuard(string returned)
    {
        if (auto existing = returned in _panicsGuards) return *existing;
        auto name = "@silver.panics.guard.%s".format(_panicsGuards.length);
        _panicsGuards[returned] = name;
        foreach (used; ["silver_panics_enter", "silver_panics_leave"]) _usedRuntime[used] = true;
        _thunkDefinitions ~= "define private i1 %s(ptr %%code, ptr %%env) #0 noinline {\n.entry:\n".format(name)
            ~ "  call void @silver_panics_enter(ptr @silver.test.jump)\n"
            ~ "  %frame = call ptr @llvm.frameaddress.p0(i32 0)\n"
            ~ "  store ptr %frame, ptr @silver.test.jump\n"
            ~ "  %stack = call ptr @llvm.stacksave.p0()\n"
            ~ "  %slot = getelementptr [5 x ptr], ptr @silver.test.jump, i64 0, i64 2\n"
            ~ "  store ptr %stack, ptr %slot\n"
            ~ "  %jumped = call i32 @llvm.eh.sjlj.setjmp(ptr @silver.test.jump)\n"
            ~ "  %fresh = icmp eq i32 %jumped, 0\n"
            ~ "  br i1 %fresh, label %run, label %done\nrun:\n"
            ~ (returned == "void" ? "  call void %code(ptr %env)\n" : "  %%.r = call %s %%code(ptr %%env)\n".format(returned))
            ~ "  br label %done\ndone:\n"
            ~ "  %panicked = phi i1 [ false, %run ], [ true, %.entry ]\n"
            ~ "  call void @silver_panics_leave(ptr @silver.test.jump)\n"
            ~ "  ret i1 %panicked\n}\n";
        return name;
    }

    /// `panic(message)`, which says where it is as other panics do.
    private Fragment emitExplicitPanic(const Expr message, Span span)
    {
        auto text = emitExpr(message);
        return text
            .then(callRuntime("silver_panic_message", cString(located(span)) ~ operandsOf(message, text.operands, 2)))
            .then(Fragment.unreachable())
            .then(Fragment.label(_function.newLabel("after.panic")))
            .withValue(null);
    }

    /// `main` returned an error, which `message` is, formatted.
    private Fragment emitExitWithError(const Expr message)
    {
        auto text = emitExpr(message);
        return text
            .then(callRuntime("silver_exit_error", operandsOf(message, text.operands, 2)))
            .then(Fragment.unreachable())
            .then(Fragment.label(_function.newLabel("after.exit")))
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

        if (prim.op == PrimOp.Append)
        {
            auto element = scalarsOf(elementOf(e.type), e.span);
            auto appended = prim.args[1].kind.match!(
                (const ArrayLit literal) => element.length > 0 && literal.elements.length > 0
                    ? emitAppendElements(prim.args[0], literal, element) : Fragment.init,
                _ => Fragment.init,
            );
            if (appended.operands.length > 0) return appended;
        }

        const(string)[][] operands;
        auto arguments = emitAll(prim.args, operands);
        /// Each argument as a parent that wants `count` scalars of each uses it.
        const(string)[][] each(size_t count)
        {
            const(string)[][] result;
            foreach (i, held; operands) result ~= operandsOf(prim.args[i], held, count);
            return result;
        }

        switch (prim.op)
        {
            case PrimOp.Concat:
                auto layout = llvmType(elementOf(e.type), e.span);
                return arguments.then(emitConcat(each(2), layout, elementSizeOf(layout)));
            case PrimOp.Append:
                auto slices = each(2);
                return arguments.then(emitAppend(slices[0], slices[1], llvmType(elementOf(e.type), e.span)));
            case PrimOp.Format:
                return arguments.then(emitFormat(operandType, operands[0], e.span));
            case PrimOp.Hash:
                auto width = operandType == types.string_ || types.isFunction(operandType) ? 2 : 1;
                return arguments.then(emitHash(operandType, each(width)[0], e.span));
            default:
                break;
        }

        // `()` has one value, so comparing two is a constant.
        if (operandType == types.unit) return arguments.then(Fragment.constant(prim.op == PrimOp.Equal ? "true" : "false"));
        if (types.isFunction(operandType) || operandType in _program.cellContents || operandType in _program.nativeTypes)
        {
            assert(prim.op == PrimOp.Equal || prim.op == PrimOp.NotEqual,
                "function values, Refs and native types are only compared for equality");
            Fragment same;
            if (types.isFunction(operandType))
            {
                auto closures = each(2);
                same = emitFunctionEquality(closures[0], closures[1]);
            }
            else
            {
                auto cells = each(1);
                same = _function.result("icmp eq ptr %s, %s".format(cells[0][0], cells[1][0]));
            }
            if (prim.op == PrimOp.Equal) return arguments.then(same);
            return arguments.then(same).then(_function.result("xor i1 %s, true".format(same.value)));
        }
        if (operandType == types.string_)
        {
            auto strings = each(2);
            return arguments.then(emitStringComparison(prim.op, strings[0], strings[1]));
        }
        return arguments.then(operation(prim, operandType, each(1).map!(held => held[0]).array, e.span));
    }

    /// `prim.op` on `operands`, which have been evaluated already.
    private Fragment operation(const Prim prim, Type operandType, const string[] operands, Span span)
    {
        auto types = _program.types;
        auto type = llvmType(operandType, span);
        auto isFloat = types.isFloat(operandType);
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
            case PrimOp.CountOnes:
                useIntrinsic("declare i64 @llvm.ctpop.i64(i64)");
                return _function.result("call i64 @llvm.ctpop.i64(i64 %s)".format(operands[0]));
            case PrimOp.Concat, PrimOp.Append, PrimOp.Format, PrimOp.Hash:
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
    private Fragment emitStringComparison(PrimOp op, const string[] lhs, const string[] rhs)
    {
        auto order = callRuntime("silver_string_compare", lhs ~ rhs);
        return order.then(_function.result("icmp %s i32 %s, 0".format(comparison(op, false, false), order.value)));
    }

    /// A primitive or function value as a String, as `print` shows it.
    private Fragment emitFormat(Type type, const string[] value, Span span)
    {
        auto types = _program.types;
        if (types.isInteger(type))
        {
            auto wide = widened(type, value[0], span);
            return wide.then(callRuntimeForString(types.integerOf(type).signed ? "silver_format_int" : "silver_format_uint",
                [wide.value]));
        }
        if (type == types.float_) return callRuntimeForString("silver_format_float", value);
        if (type == types.float32) return callRuntimeForString("silver_format_float32", value);
        if (type == types.bool_) return callRuntimeForString("silver_format_bool", value);
        if (type == types.char_) return callRuntimeForString("silver_format_char", value);
        if (type in _program.nativeTypes) return callRuntimeForString("silver_format_address", value);
        assert(types.isFunction(type), "lowering formats anything but a primitive or a function itself");
        return loadScalars(descriptorScalars, value[0], 1, 2);
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

        if (types.isFloat(target))
        {
            auto result = llvmType(target, e.span);
            if (types.isFloat(source))
            {
                auto opcode = target == types.float32 ? "fptrunc" : "fpext";
                return value.then(_function.convert(opcode, llvmType(source, e.span), value.value, result));
            }
            auto signed = types.integerOf(source).signed;
            return value.then(_function.convert(signed ? "sitofp" : "uitofp", llvmType(source, e.span), value.value, result));
        }

        auto to = types.integerOf(target);
        auto message = "Value is out of range for %sInt%s".format(to.signed ? "" : "U", to.bits);
        if (types.isFloat(source))
        {
            // Checked as a `double`, which holds every `float` exactly, so the limits are the same
            // exact values for both.
            Fragment widen;
            auto operand = value.value;
            if (source == types.float32)
            {
                widen = _function.convert("fpext", "float", operand, "double");
                operand = widen.value;
            }
            return value.then(widen).then(emitFloatToIntegerCheck(operand, to, e.span, message))
                .then(_function.convert(to.signed ? "fptosi" : "fptoui", "double", operand, llvmType(target, e.span)));
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
        return callRuntime("silver_panic", [cString(located(span)), cString(message)])
            .then(Fragment.unreachable());
    }

    /// Either arm's value, through a phi for each scalar. An arm that leaves, being `Never`, has
    /// none, and the phis take `undef` from wherever its dead block ends.
    private Fragment emit(const Expr e, const If if_)
    {
        return emitIf(e, if_, &emitExpr);
    }

    /// An `If` whose arms are generated by `arm`.
    private Fragment emitIf(const Expr e, const If if_, Fragment delegate(const Expr) arm)
    {
        auto condition = emitExpr(*if_.condition);
        auto thenLabel = _function.newLabel("then");
        auto elseLabel = _function.newLabel("else");
        auto mergeLabel = _function.newLabel("merge");
        auto trueBody = Fragment.label(thenLabel).then(arm(*if_.trueBody));
        auto falseBody = Fragment.label(elseLabel).then(arm(*if_.falseBody));
        auto code = condition
            .then(Fragment.branch(condition.value, thenLabel, elseLabel))
            .then(trueBody).then(Fragment.jump(mergeLabel))
            .then(falseBody).then(Fragment.jump(mergeLabel))
            .then(Fragment.label(mergeLabel));

        auto scalars = scalarsOf(e.type, e.span);
        if (scalars.length == 0) return code.withValue(null);
        return code.then(merge(scalars, operandsOf(*if_.trueBody, trueBody.operands, scalars.length), trueBody.endBlock,
            operandsOf(*if_.falseBody, falseBody.operands, scalars.length), falseBody.endBlock));
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

    /// `e` where its value is what the function returns, followed by what is kept where it returns
    /// (`keptOnReturn`). A call there gets them once its arguments are worked out and before it's
    /// made, so it stays in tail position, which LLVM needs to make it a jump.
    private Fragment emitTail(const Expr e)
    {
        if (_function.tailKept.length == 0 && _function.open.length == 0) return emitExpr(e);
        return e.kind.match!(
            (const If if_) => emitIf(e, if_, &emitTail),
            (const Block block) {
                Fragment statements;
                foreach (statement; block.statements) statements = statements.then(emitStmt(statement));
                if (block.result is null) return statements.then(keptOnReturn(e.span)).withValue(null);
                return statements.then(emitTail(*block.result));
            },
            (const Call call) => emitCall(e, call, true),
            (const CallClosure call) => emitCallClosure(e, call, true),
            (_) => keepingOnReturn(e, emitExpr(e)),
        );
    }

    /// `value`, the value of `e`, which the function returns, then what's kept there.
    private Fragment keepingOnReturn(const Expr e, Fragment value)
    {
        return value.then(keptOnReturn(e.span)).withOperands(value.operands);
    }

    /// What's kept where the function returns from the code being generated. A recursive function
    /// can be made a loop by LLVM, and then its params are locals of that loop and are kept where
    /// it's left; and every loop being generated is left without passing its end.
    private Fragment keptOnReturn(Span span)
    {
        const(Local)[] locals = _function.tailKept;
        foreach_reverse (open; _function.open) locals ~= keptBy(open);
        return keepAlive(locals, span);
    }

    private Fragment emit(const Expr e, const Loop loop)
    {
        auto targets = LoopTargets(_function.newLabel("loop"), _function.newLabel("loop.end"));
        _function.loops[loop.label] = targets;
        _function.open ~= loop.label;
        auto body = emitExpr(*loop.body);
        _function.open.length--;
        auto kept = keptBy(loop.label);
        // A loop nothing leaves has no end to keep them at, and LLVM can remove every way out of
        // one that can, leaving its end unreachable. Only a loop that calls something can
        // allocate, and one that calls something it can't inline isn't vectorized anyway.
        auto leaves = (loop.label in _function.slots.left) !is null;
        auto atHead = !leaves || callsOutside(body) ? keepAlive(kept, e.span) : Fragment.init;
        return Fragment.jump(targets.head)
            .then(Fragment.label(targets.head))
            .then(atHead)
            .then(body)
            .then(Fragment.jump(targets.head))
            .then(Fragment.label(targets.end))
            .then(keepAlive(kept, e.span))
            .withValue(null);
    }

    private Fragment emit(const Expr e, const Break jump)
    {
        return keepLeaving(jump.label, e.span).then(leaveTo(_function.loops[jump.label].end));
    }

    private Fragment emit(const Expr e, const Continue jump)
    {
        return keepLeaving(jump.label, e.span).then(leaveTo(_function.loops[jump.label].head));
    }

    /// Whether `code` calls something that returns and that LLVM won't inline away: the runtime
    /// other than its panics, a native, a function value, or a recursive function. Other Silver
    /// functions are left out, since a loop calling one may vectorize once it's inlined.
    private bool callsOutside(const Fragment code)
    {
        import std.algorithm : startsWith;
        import std.string : indexOf;

        static immutable noReturn = ["@silver_panic(", "@silver_panic_message(", "@silver_exit_error(",
            "@silver_test_stopped("];
        foreach (line; code.code)
        {
            // `call [convention ]type callee(arguments)`, as `FunctionState.call` writes it.
            auto at = line.indexOf("call ");
            if (at < 0) continue;
            auto rest = line[at + "call ".length .. $];
            if (rest.startsWith("asm ")) continue;
            if (rest.startsWith("ccc ")) rest = rest["ccc ".length .. $];
            auto typeEnd = rest.startsWith("{") ? rest.indexOf("} ") + 1 : rest.indexOf(" ");
            auto name = rest[typeEnd + 1 .. $];
            if (name.startsWith("%")) return true;
            if (name.startsWith("@\""))
            {
                auto end = name.indexOf("\"(", 2);
                if (end > 0 && (name[0 .. end + 1] in _recursiveNames) !is null) return true;
                continue;
            }
            if (["@llvm.", "@.", "@silver."].any!(p => name.startsWith(p))) continue;
            if (noReturn.any!(n => name.startsWith(n))) continue;
            return true;
        }
        return false;
    }

    private const(Local)[] keptBy(size_t label)
    {
        auto kept = label in _function.slots.kept;
        return kept is null ? null : *kept;
    }

    /// What the loops inside the one labelled `label` keep, for a jump that leaves them all
    /// without passing their ends.
    private Fragment keepLeaving(size_t label, Span span)
    {
        const(Local)[] locals;
        foreach_reverse (open; _function.open)
        {
            if (open == label) break;
            locals ~= keptBy(open);
        }
        return keepAlive(locals, span);
    }

    /// Makes LLVM keep each of `locals`' pointers, as its slot holds them now, somewhere until this
    /// point. The collector is conservative and finds an object only through a pointer into it,
    /// while LLVM may keep only a pointer derived from one: a loop reading `xs[i - k]` can hold
    /// `xs - 8k`, which is in no block of ours, and drop `xs`. Each `asm` is opaque, so the value
    /// it's given has to be kept in a register or the frame up to it, which the collector scans;
    /// it touches no memory LLVM can see, so nothing else is held back. A loop keeps the locals
    /// declared before it that it names where it's left, which is outside it, and at its head
    /// only when it calls something that stays a call, so a loop that becomes free of calls is
    /// optimized as before. This covers the shapes known to need it; it isn't a proof.
    ///
    /// The pointers go to as few `asm`s as their registers allow, since LLVM's inliner counts each
    /// as a call: a range's `next` that's left a loop is otherwise too costly to inline.
    private Fragment keepAlive(const(Local)[] locals, Span span)
    {
        enum perAsm = 6;
        Fragment code;
        string[] values;
        void flush()
        {
            if (values.length == 0) return;
            code = code.then(Fragment.instruction("call void asm sideeffect \"\", \"%-(%s,%)\"(%-(ptr %s, %)) #1"
                .format(values.map!(_ => "r"), values)));
            values = null;
        }
        bool[const(Local)] seen;
        foreach (local; locals)
        {
            if (local in seen) continue;
            seen[local] = true;
            auto slot = _function.slots[local];
            if (slot is null) continue;
            auto layout = scalarsOf(local.type, span);
            foreach (i, scalar; layout)
            {
                if (scalar != "ptr") continue;
                auto value = loadScalars(layout, slot, i, 1);
                code = code.then(value);
                values ~= value.value;
                if (values.length == perAsm) flush();
            }
        }
        flush();
        return code.withValue(null);
    }

    private Fragment emit(const Expr e, const Return return_)
    {
        auto scalars = _function.returnScalars;
        Fragment value;
        Fragment leave;
        if (scalars.length > 1)
        {
            value = emitInto(*return_.value, scalars, FunctionState.resultSlot, true);
            leave = Fragment.jump(FunctionState.returnBlock);
        }
        else
        {
            value = emitTail(*return_.value);
            auto operands = operandsOf(*return_.value, value.operands, scalars.length);
            leave = Fragment.ret(structOf(scalars), operands.length == 0 ? null : operands[0]);
        }
        return value.then(leave)
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

    /// A value that is only looked at where it already is isn't loaded.
    private Fragment emit(const Stmt s, const Eval eval)
    {
        auto place = placeOf(eval.expr);
        return place.pointer is null ? emitExpr(eval.expr) : place.code;
    }

    /// A local that is itself with fields replaced has only those fields written, when working out
    /// their values can't assign it. Any other value might read the local while it's being
    /// evaluated, so it's evaluated first and then written.
    private Fragment emit(const Stmt s, const Assign assign)
    {
        auto slot = _function.slots[assign.local];
        if (slot is null) return emitExpr(assign.value);
        auto layout = scalarsOf(assign.local.type, s.span);

        const(Expr)[] values;
        size_t[] fields;
        if (layout.length > 1 && replacesFields(assign.value, assign.local, values, fields))
        {
            auto type = assign.local.type;
            const(string)[][] operands;
            Fragment code;
            foreach (i, field; fields)
            {
                auto held = emitHeld(type, field, values[i], s.span);
                code = code.then(held);
                operands ~= held.operands;
            }
            foreach (i, field; fields)
            {
                auto target = storedAt(type, field, s.span);
                code = code.then(storeScalars(layout, slot, target.offset, operands[i]));
            }
            return code;
        }
        auto source = sourceOf(assign.value, layout);
        return source.code.then(write(source, layout, slot));
    }

    /// Whether `e` is `local` with fields replaced, one after another, by values that assign
    /// nothing. `values` and `fields` are then each replacement and the index of the field it
    /// replaces, in the order they're made.
    private bool replacesFields(const Expr e, const Local local, ref const(Expr)[] values, ref size_t[] fields)
    {
        return e.kind.match!(
            (const LocalRef use) => use.local is local,
            (const Update update) {
                if (!assignsNothing(*update.value)) return false;
                if (!replacesFields(*update.object, local, values, fields)) return false;
                values ~= *update.value;
                fields ~= update.index;
                return true;
            },
            _ => false,
        );
    }

    /// Adds to `targets` every function `e` calls or makes a function value of, which is what
    /// LLVM can inline or call, and to `made` those it makes a function value of. `opaque` is set
    /// when it calls what the call graph can't see: a function value, a native or an intrinsic,
    /// or a comparison or hash of function values, which reaches their captures' functions.
    private void collectCalls(const Expr e, ref bool[size_t] targets, ref bool[size_t] made, ref bool opaque)
    {
        void all(const Expr[] exprs)
        {
            foreach (ref expr; exprs) collectCalls(expr, targets, made, opaque);
        }

        void inStmt(const Stmt s)
        {
            s.kind.match!(
                (const Let let) => collectCalls(let.value, targets, made, opaque),
                (const Assign assign) => collectCalls(assign.value, targets, made, opaque),
                (const AssignElement assign) {
                    collectCalls(assign.index, targets, made, opaque);
                    collectCalls(assign.value, targets, made, opaque);
                },
                (const Eval eval) => collectCalls(eval.expr, targets, made, opaque),
            );
        }

        e.kind.match!(
            (const Call call) {
                targets[call.target] = true;
                all(call.args);
            },
            (const CallClosure call) {
                opaque = true;
                collectCalls(*call.callee, targets, made, opaque);
                all(call.args);
            },
            (const MakeClosure closure) {
                targets[closure.target] = true;
                made[closure.target] = true;
                all(closure.captures);
            },
            (const ForeignCall call) {
                opaque = true;
                all(call.args);
            },
            (const IntrinsicCall call) {
                opaque = true;
                all(call.args);
            },
            (const Prim prim) {
                if (prim.args.any!(arg => _program.types.isFunction(arg.type))) opaque = true;
                all(prim.args);
            },
            (const Convert convert) => collectCalls(*convert.value, targets, made, opaque),
            (const If if_) {
                collectCalls(*if_.condition, targets, made, opaque);
                collectCalls(*if_.trueBody, targets, made, opaque);
                collectCalls(*if_.falseBody, targets, made, opaque);
            },
            (const Block block) {
                foreach (ref statement; block.statements) inStmt(statement);
                if (block.result !is null) collectCalls(*block.result, targets, made, opaque);
            },
            (const Loop loop) => collectCalls(*loop.body, targets, made, opaque),
            (const Return return_) => collectCalls(*return_.value, targets, made, opaque),
            (const Construct construct) => all(construct.fields),
            (const Field field) => collectCalls(*field.object, targets, made, opaque),
            (const Update update) {
                collectCalls(*update.object, targets, made, opaque);
                collectCalls(*update.value, targets, made, opaque);
            },
            (const Inject inject) {
                if (inject.payload !is null) collectCalls(*inject.payload, targets, made, opaque);
            },
            (const IsMember test) => collectCalls(*test.subject, targets, made, opaque),
            (const Payload payload) => collectCalls(*payload.subject, targets, made, opaque),
            (const ArrayLit literal) => all(literal.elements),
            (const Index index) {
                collectCalls(*index.array, targets, made, opaque);
                collectCalls(*index.index, targets, made, opaque);
            },
            (const Slice slice) {
                collectCalls(*slice.array, targets, made, opaque);
                collectCalls(*slice.start, targets, made, opaque);
                collectCalls(*slice.end, targets, made, opaque);
            },
            (const Length length) => collectCalls(*length.array, targets, made, opaque),
            (const Cell cell) => all(cell.args),
            (const Capture capture) => collectCalls(*capture.closure, targets, made, opaque),
            (const TestFailure failure) => collectCalls(*failure.message, targets, made, opaque),
            (_) {},
        );
    }

    /// The functions a call through a function value can reach that call something in turn, so
    /// that a cycle of calls the call graph can't see passes through one of them. Reached that way
    /// are every target of a closure, and what compares and hashes closures' captures, which the
    /// runtime calls through a closure's descriptor and which recur as deep as closures capture
    /// closures. One that calls nothing, as `x => x * 2` doesn't, is on no cycle.
    private bool[size_t] escapedFunctions()
    {
        bool[size_t] escaped;
        auto calls = new bool[](_program.functions.length);
        foreach (i, ref func; _program.functions)
        {
            bool[size_t] targets;
            bool opaque;
            collectCalls(func.body, targets, escaped, opaque);
            calls[i] = opaque || targets.length > 0;
            if (func.captureEquality != noFunction) escaped[func.captureEquality] = true;
            if (func.captureHash != noFunction) escaped[func.captureHash] = true;
        }
        foreach (i; escaped.keys)
        {
            if (!calls[i]) escaped.remove(i);
        }
        return escaped;
    }

    /// The functions on a cycle of calls, function values included (Tarjan's algorithm). LLVM can
    /// make a loop of any of them, by inlining around the cycle until a call in tail position is
    /// one of the function itself and making that a jump.
    private bool[size_t] recursiveFunctions()
    {
        auto count = _program.functions.length;
        auto callees = new size_t[][](count);
        foreach (i, ref func; _program.functions)
        {
            bool[size_t] targets, made;
            bool opaque;
            collectCalls(func.body, targets, made, opaque);
            callees[i] = targets.keys;
        }

        bool[size_t] recursive;
        auto order = new size_t[](count);
        auto low = new size_t[](count);
        auto onStack = new bool[](count);
        auto seen = new bool[](count);
        size_t[] stack;
        size_t next = 0;

        void visit(size_t v)
        {
            seen[v] = true;
            order[v] = low[v] = next++;
            stack ~= v;
            onStack[v] = true;
            foreach (w; callees[v])
            {
                if (!seen[w])
                {
                    visit(w);
                    if (low[w] < low[v]) low[v] = low[w];
                }
                else if (onStack[w] && order[w] < low[v]) low[v] = order[w];
            }
            if (low[v] != order[v]) return;
            size_t[] component;
            while (true)
            {
                auto w = stack[$ - 1];
                stack.length--;
                onStack[w] = false;
                component ~= w;
                if (w == v) break;
            }
            if (component.length > 1 || callees[v].canFind(v))
            {
                foreach (w; component) recursive[w] = true;
            }
        }

        foreach (v; 0 .. count) if (!seen[v]) visit(v);
        return recursive;
    }

    /// Whether evaluating `e` can't assign a local: it's made only of reads and of building values.
    /// Anything that could hold a statement or call a function with a mutable parameter isn't.
    private static bool assignsNothing(const Expr e)
    {
        bool every(const Expr[] exprs) => exprs.all!(expr => assignsNothing(expr));

        return e.kind.match!(
            (const UnitLit _) => true,
            (const BoolLit _) => true,
            (const IntLit _) => true,
            (const FloatLit _) => true,
            (const StringLit _) => true,
            (const LocalRef _) => true,
            (const Prim prim) => every(prim.args),
            (const Convert convert) => assignsNothing(*convert.value),
            (const Construct construct) => every(construct.fields),
            (const Field field) => assignsNothing(*field.object),
            (const Update update) => assignsNothing(*update.object) && assignsNothing(*update.value),
            (const Inject inject) => inject.payload is null || assignsNothing(*inject.payload),
            (const IsMember test) => assignsNothing(*test.subject),
            (const Payload payload) => assignsNothing(*payload.subject),
            (const ArrayLit literal) => every(literal.elements),
            (const Index index) => assignsNothing(*index.array) && assignsNothing(*index.index),
            (const Length length) => assignsNothing(*length.array),
            (const Capture capture) => assignsNothing(*capture.closure),
            _ => false,
        );
    }

    /// The local's array copied with one element replaced, until something says when it can be
    /// written in place.
    private Fragment emit(const Stmt s, const AssignElement assign)
    {
        auto at = position(assign.index);
        auto element = scalarsOf(elementOf(assign.local.type), s.span);
        auto value = sourceOf(assign.value, element);
        auto slot = _function.slots[assign.local];
        auto array = loadScalars(sliceScalars, slot, 0, 2);
        auto outside = _function.result("icmp uge i64 %s, %s".format(at.value, array.operands[1]));
        auto code = at.then(value.code).then(array).then(outside)
            .then(emitPanicIf(outside.value, s.span, "Index is out of range")).withValue(null);
        if (element.length == 0) return code;

        auto layout = structOf(element);
        auto copy = emitConcat([array.operands], layout, elementSizeOf(layout));
        auto pointer = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, copy.operands[0], at.value));
        return code.then(copy).then(pointer)
            .then(write(value, element, pointer.value))
            .then(storeScalars(sliceScalars, slot, 0, copy.operands));
    }

    private Fragment emit(const Stmt s, const Let let)
    {
        auto slot = _function.slots[let.local];
        if (slot is null) return emitExpr(let.value);
        return emitInto(let.value, scalarsOf(let.local.type, s.span), slot);
    }

    // Records. A tuple or a declared type's value is its fields' scalars, one after another. A field
    // whose type can hold a value of the declared type itself, with nothing but records, options
    // and error unions in between, would make those scalars never end, so it is held as a pointer
    // to its value on the heap, which never changes once written; a boxed option points to its
    // payload, and is null for `None`. A type's value then stays the same whatever holds it.

    /// Whether field `index` of the record `type` is held through a pointer.
    private bool isBoxedField(Type type, size_t index)
    {
        if (_program.types.isTuple(type)) return false;
        if (auto known = type in _boxedFields) return (*known)[index];
        bool[] boxed;
        foreach (field; fieldTypes(type)) boxed ~= reaches(field, type);
        _boxedFields[type] = boxed;
        return boxed[index];
    }

    /// Whether a value of `from` holds a value of `type` as part of itself, were no field boxed.
    private bool reaches(Type from, Type type)
    {
        bool[Type] seen;
        bool search(Type at)
        {
            if (at == type) return true;
            if (at in seen) return false;
            seen[at] = true;
            return heldInline(at).canFind!(part => search(part));
        }

        return search(from);
    }

    /// The types whose values are part of a value of `type` itself, were no field boxed. An array,
    /// a function value, a `Ref` and a sum hold theirs through a pointer.
    private const(Type)[] heldInline(Type type)
    {
        auto types = _program.types;
        if (types.isTuple(type)) return types.tupleElements(type);
        if (types.isOption(type)) return [types.optionInner(type)];
        if (types.isErrorUnion(type)) return [types.successOf(type), types.errorOf(type)];
        if (auto fields = type in _program.recordFields) return *fields;
        return null;
    }

    /// The types of a tuple's elements or a declared type's fields.
    private const(Type)[] fieldTypes(Type type)
    {
        if (_program.types.isTuple(type)) return _program.types.tupleElements(type);
        auto fields = type in _program.recordFields;
        assert(fields !is null, "lowering describes every declared type it uses");
        return *fields;
    }

    /// The scalars of a record's fields as they're held, in order.
    private const(string)[] recordScalars(Type type, Span span)
    {
        const(string)[] scalars;
        foreach (i, field; fieldTypes(type)) scalars ~= isBoxedField(type, i) ? ["ptr"] : scalarsOf(field, span);
        return scalars;
    }

    /// Which of `recordScalars` hold field `index`.
    private Stored storedAt(Type type, size_t index, Span span)
    {
        size_t offset = 0;
        foreach (i; 0 .. index) offset += heldCount(type, i, span);
        return Stored(offset, heldCount(type, index, span));
    }

    private size_t heldCount(Type type, size_t index, Span span)
    {
        return isBoxedField(type, index) ? 1 : scalarsOf(fieldTypes(type)[index], span).length;
    }

    private struct Stored
    {
        size_t offset;
        size_t count;
    }

    /// What a boxed field of type `field` points to: its value, or an option's payload.
    private const(string)[] boxLayout(Type field, Span span)
    {
        return scalarsOf(isOption(field) ? _program.types.optionInner(field) : field, span);
    }

    /// `e` evaluated, as field `index` of the record `type` holds it. A boxed field read from
    /// another of its type shares that one's box, which nothing writes to.
    private Fragment emitHeld(Type type, size_t index, const Expr e, Span span)
    {
        if (isBoxedField(type, index) && e.type == fieldTypes(type)[index] && isBoxedFieldRead(e)) return boxOf(e);
        auto value = emitExpr(e);
        return value.then(toHeld(type, index, e, value.operands, span));
    }

    /// `operands`, the value of `e`, as field `index` of the record `type` holds it: the same, or
    /// a pointer to a copy on the heap.
    private Fragment toHeld(Type type, size_t index, const Expr e, const string[] operands, Span span)
    {
        auto field = fieldTypes(type)[index];
        auto value = operandsOf(e, operands, scalarsOf(field, span).length);
        if (!isBoxedField(type, index)) return Fragment(null, value);
        if (e.type == _program.types.never) return Fragment.constant("undef");

        auto layout = boxLayout(field, span);
        Fragment copied(const string[] contents)
        {
            auto box = alloc(structOf(layout));
            return box.then(storeScalars(layout, box.value, 0, contents)).withValue(box.value);
        }

        if (!isOption(field)) return copied(value);
        if (value[0] == "false") return Fragment.constant("null");
        if (value[0] == "true") return copied(value[1 .. $]);
        auto testLabel = _function.newLabel("box.test");
        auto someLabel = _function.newLabel("box.some");
        auto doneLabel = _function.newLabel("box.done");
        auto some = Fragment.label(someLabel).then(copied(value[1 .. $]));
        return Fragment.jump(testLabel).then(Fragment.label(testLabel))
            .then(Fragment.branch(value[0], someLabel, doneLabel))
            .then(some).then(Fragment.jump(doneLabel))
            .then(Fragment.label(doneLabel))
            .then(merge(["ptr"], ["null"], testLabel, [some.value], some.endBlock));
    }

    /// The value of field `index` of the record `type`, from `held`, the operands it's held as.
    private Fragment fromHeld(Type type, size_t index, const string[] held, Span span)
    {
        if (!isBoxedField(type, index)) return Fragment(null, held);
        auto field = fieldTypes(type)[index];
        auto layout = boxLayout(field, span);
        if (!isOption(field)) return loadScalars(layout, held[0], 0, layout.length);
        auto box = boxedOption(field, held[0], span);
        auto payload = loadScalars(layout, box.operands[1], 0, layout.length);
        return box.then(payload).withOperands(box.operands[0] ~ payload.operands);
    }

    /// The tag of the boxed option `pointer` holds, and where its payload is: for `None`, zeros
    /// that nothing writes to, so a payload can always be read.
    private Fragment boxedOption(Type field, string pointer, Span span)
    {
        auto layout = boxLayout(field, span);
        auto tag = _function.result("icmp ne ptr %s, null".format(pointer));
        auto payload = _function.result("select i1 %s, ptr %s, ptr %s".format(tag.value, pointer, noneOf(layout)));
        return tag.then(payload).withOperands([tag.value, payload.value]);
    }

    /// A constant of zeros laid out as `layout`, one for each layout.
    private string noneOf(const string[] layout)
    {
        auto type = structOf(layout);
        if (auto known = type in _nones) return *known;
        auto name = "@.none.%s".format(_nones.length);
        _nones[type] = name;
        _globals ~= "%s = private unnamed_addr constant %s zeroinitializer".format(name, type);
        return name;
    }

    /// The operands that field `field.index` of `field.object` is held as.
    private Fragment heldOperands(const Expr e, const Field field)
    {
        auto type = field.object.type;
        auto at = storedAt(type, field.index, e.span);
        auto outer = placeOf(*field.object);
        if (outer.pointer !is null)
        {
            return outer.code.then(loadScalars(outer.layout, outer.pointer, outer.offset + at.offset, at.count));
        }
        auto object = emitExpr(*field.object);
        auto whole = operandsOf(*field.object, object.operands, recordScalars(type, e.span).length);
        return object.withOperands(whole[at.offset .. at.offset + at.count]);
    }

    /// Whether a value of `type` is made of nothing. This doesn't ask for its scalars: a sum asks
    /// it of its members' fields, which can hold the sum.
    private bool isEmpty(Type type)
    {
        auto types = _program.types;
        if (type == types.unit || type == types.never || type == types.none || type == types.emptyDictionary) return true;
        if (types.isTuple(type)) return types.tupleElements(type).all!(t => isEmpty(t));
        if (auto fields = type in _program.recordFields)
        {
            foreach (i, field; *fields)
            {
                if (isBoxedField(type, i) || !isEmpty(field)) return false;
            }
            return true;
        }
        return false;
    }

    private Fragment emit(const Expr e, const Construct construct)
    {
        Fragment code;
        const(string)[] whole;
        foreach (i, ref field; construct.fields)
        {
            auto held = emitHeld(e.type, i, field, e.span);
            code = code.then(held);
            whole ~= held.operands;
        }
        return code.withOperands(whole);
    }

    /// Scalars `offset` to `offset + count` of the memory `pointer` points to, which is laid out as
    /// `layout`, once `code` has run. No pointer when there's no such place.
    private struct Place
    {
        Fragment code;
        string pointer;
        const(string)[] layout;
        size_t offset;
        size_t count;
    }

    /// Where `e`'s value already is in memory: a local's slot, an array's element, a sum's payload,
    /// a boxed field's box, or a field of one of those. Reading one field of a wide record then
    /// loads only that field, and a whole value is copied without becoming operands. When there's
    /// no such place, no code has been generated.
    private Place placeOf(const Expr e)
    {
        return e.kind.match!(
            (const LocalRef use) {
                auto layout = scalarsOf(use.local.type, e.span);
                return Place(Fragment.init, _function.slots[use.local], layout, 0, layout.length);
            },
            (const Field field) {
                auto type = field.object.type;
                if (isBoxedField(type, field.index))
                {
                    if (isOption(e.type)) return Place.init;
                    auto box = heldOperands(e, field);
                    auto layout = boxLayout(e.type, e.span);
                    return Place(box.withValue(null), box.value, layout, 0, layout.length);
                }
                auto at = storedAt(type, field.index, e.span);
                auto outer = placeOf(*field.object);
                if (outer.pointer is null) return Place.init;
                return Place(outer.code, outer.pointer, outer.layout, outer.offset + at.offset, at.count);
            },
            (const Index index) {
                auto element = scalarsOf(e.type, e.span);
                if (element.length == 0) return Place.init;
                auto checked = emitIndexChecked(e, index);
                auto pointer = _function.result("getelementptr %s, ptr %s, i64 %s".format(structOf(element),
                    checked.operands[0], checked.operands[1]));
                return Place(checked.then(pointer).withValue(null), pointer.value, element, 0, element.length);
            },
            (const Payload payload) {
                auto type = payload.subject.type;
                auto member = scalarsOf(e.type, e.span);
                if (member.length == 0) return Place.init;
                if (isBoxedOption(*payload.subject))
                {
                    auto held = boxOf(*payload.subject);
                    auto box = boxedOption(type, held.value, e.span);
                    return Place(held.then(box).withValue(null), box.operands[1], member, 0, member.length);
                }
                if (isOption(type) || isErrorUnion(type))
                {
                    auto outer = placeOf(*payload.subject);
                    if (outer.pointer is null) return Place.init;
                    return Place(outer.code, outer.pointer, outer.layout, outer.offset + heldAt(type, payload.member, e.span),
                        member.length);
                }
                if (member == ["ptr"]) return Place.init;
                auto subject = emitExpr(*payload.subject);
                auto box = operandsOf(*payload.subject, subject.operands, 2)[1];
                return Place(subject.withValue(null), box, member, 0, member.length);
            },
            _ => Place.init,
        );
    }

    /// The value at `place`, loaded.
    private Fragment read(Place place)
    {
        return place.code.then(loadScalars(place.layout, place.pointer, place.offset, place.count));
    }

    private Fragment emit(const Expr e, const Field field)
    {
        auto place = placeOf(e);
        if (place.pointer !is null) return read(place);
        auto held = heldOperands(e, field);
        return held.then(fromHeld(field.object.type, field.index, held.operands, e.span));
    }

    /// Whether `e` reads a field that is a boxed option.
    private bool isBoxedOption(const Expr e)
    {
        return isOption(e.type) && isBoxedFieldRead(e);
    }

    /// Whether `e` reads a field that is boxed.
    private bool isBoxedFieldRead(const Expr e)
    {
        return e.kind.match!(
            (const Field field) => isBoxedField(field.object.type, field.index),
            _ => false,
        );
    }

    /// The pointer that `e`, which reads a boxed field, is held as.
    private Fragment boxOf(const Expr e)
    {
        return e.kind.match!(
            (const Field field) => heldOperands(e, field),
            _ => assert(0, "only a field is boxed"),
        );
    }

    /// A record's scalars with the field's replaced.
    private Fragment emit(const Expr e, const Update update)
    {
        auto object = emitExpr(*update.object);
        auto type = e.type;
        auto at = storedAt(type, update.index, e.span);
        auto replacement = emitHeld(type, update.index, *update.value, e.span);
        if (at.count == 0) return object.then(replacement).withOperands(object.operands);
        auto whole = operandsOf(*update.object, object.operands, recordScalars(type, e.span).length);
        return object.then(replacement)
            .withOperands(whole[0 .. at.offset] ~ replacement.operands ~ whole[at.offset + at.count .. $]);
    }

    // Sums and options. An option is an `i1` saying whether there's a payload, then the payload's
    // scalars. A sum is an `i32` and a `ptr`: the member's index, and its value, which is copied to
    // the heap unless it's already one pointer. A sum whose members are all markers is just the `i32`.

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

    private bool isAllMarkers(Type sum)
    {
        return membersOf(sum).all!(m => (m in _program.recordFields) !is null && isEmpty(m));
    }

    // An error union is an `i1` saying whether it's `Ok`, then the scalars of the value, then the
    // error's, the side it isn't being zero. Nothing is boxed.

    private bool isErrorUnion(Type type)
    {
        return _program.types.isErrorUnion(type);
    }

    private Fragment emit(const Expr e, const Inject inject)
    {
        auto types = _program.types;
        auto type = e.type;
        auto tag = "%s".format(inject.member);
        auto isSum = !isErrorUnion(type) && !isOption(type);
        auto member = isSum && !isAllMarkers(type) ? scalarsOf(membersOf(type)[inject.member], e.span) : null;
        if (inject.payload !is null && member.length > 0 && member != ["ptr"])
        {
            auto box = alloc(structOf(member));
            return box.then(emitInto(*inject.payload, member, box.value)).withOperands([tag, box.value]);
        }

        auto payload = inject.payload is null ? Fragment.init : emitExpr(*inject.payload);
        /// The payload as `scalars`, which its member is made of.
        const(string)[] held(const string[] scalars)
        {
            return inject.payload is null ? null : operandsOf(*inject.payload, payload.operands, scalars.length);
        }

        if (isErrorUnion(type))
        {
            auto success = scalarsOf(types.successOf(type), e.span);
            auto error = scalarsOf(types.errorOf(type), e.span);
            return payload.withOperands(inject.member == 1
                ? "true" ~ held(success) ~ zeros(error)
                : "false" ~ zeros(success) ~ held(error));
        }
        if (isOption(type))
        {
            auto scalars = scalarsOf(type, e.span);
            return payload.withOperands(inject.member == 0 ? zeros(scalars) : "true" ~ held(scalars[1 .. $]));
        }
        if (isAllMarkers(type)) return payload.withValue(tag);
        return payload.withOperands([tag, member.length == 0 ? "null" : held(member)[0]]);
    }

    private Fragment emit(const Expr e, const IsMember test)
    {
        auto type = test.subject.type;
        if (isBoxedOption(*test.subject))
        {
            auto box = boxOf(*test.subject);
            auto comparison = test.member == 1 ? "ne" : "eq";
            return box.then(_function.result("icmp %s ptr %s, null".format(comparison, box.value)));
        }
        auto place = placeOf(*test.subject);
        auto subject = place.pointer is null
            ? emitExpr(*test.subject)
            : place.code.then(loadScalars(place.layout, place.pointer, place.offset, 1));
        auto tag = place.pointer is null
            ? operandsOf(*test.subject, subject.operands, scalarsOf(type, e.span).length)[0]
            : subject.value;
        if (isOption(type) || isErrorUnion(type))
        {
            if (test.member == 1) return subject.withValue(tag);
            return subject.then(_function.result("xor i1 %s, true".format(tag)));
        }
        return subject.then(_function.result("icmp eq i32 %s, %s".format(tag, test.member)));
    }

    private Fragment emit(const Expr e, const Payload payload)
    {
        auto place = placeOf(e);
        if (place.pointer !is null) return read(place);
        auto subject = emitExpr(*payload.subject);
        auto type = payload.subject.type;
        auto member = scalarsOf(e.type, e.span);
        if (member.length == 0) return subject.withValue(null);
        auto whole = operandsOf(*payload.subject, subject.operands, scalarsOf(type, e.span).length);
        if (isOption(type) || isErrorUnion(type))
        {
            auto start = heldAt(type, payload.member, e.span);
            return subject.withOperands(whole[start .. start + member.length]);
        }
        return subject.withValue(whole[1]);
    }

    /// Where member `member`'s scalars start among those of the option or error union `type`.
    private size_t heldAt(Type type, size_t member, Span span)
    {
        if (isOption(type) || member == 1) return 1;
        return 1 + scalarsOf(_program.types.successOf(type), span).length;
    }

    // Arrays and Strings: a `ptr` and an `i64`, element zero and the length, in a buffer that the
    // runtime's `silver_array_append` makes and extends. An element made of nothing is never
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
        auto count = literal.elements.length;
        if (count == 0) return Fragment.init.withOperands(["null", "0"]);
        auto element = scalarsOf(elementOf(e.type), e.span);
        if (element.length == 0)
        {
            const(string)[][] operands;
            return emitAll(literal.elements, operands).withOperands(["null", "%s".format(count)]);
        }

        auto layout = structOf(element);
        auto buffer = reserve("%s".format(count), elementSizeOf(layout));
        return buffer.then(emitElements(literal, element, buffer.operands[0], "0")).withOperands(buffer.operands);
    }

    /// Evaluates each element of `literal`, which is made of `element`, and writes it where it
    /// goes: into `data`, from position `start` on, which has just been made room for them.
    private Fragment emitElements(const ArrayLit literal, const string[] element, string data, string start)
    {
        auto layout = structOf(element);
        Fragment code;
        foreach (i, ref value; literal.elements)
        {
            auto at = start == "0" ? Fragment.constant("%s".format(i)) : _function.result("add i64 %s, %s".format(start, i));
            auto pointer = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, data, at.value));
            code = code.then(at).then(pointer).then(emitInto(value, element, pointer.value));
        }
        return code.withValue(null);
    }

    /// `lhs ~= [a, b]`: room is made at `lhs`'s frontier and the elements written there, with no
    /// array made of them first. Room that is claimed and never filled is lost to `lhs`, whose next
    /// append then copies it whole, so when an element can leave, all are evaluated before any room
    /// is asked for.
    private Fragment emitAppendElements(const Expr lhs, const ArrayLit literal, const string[] element)
    {
        auto array = emitExpr(lhs);
        auto parts = operandsOf(lhs, array.operands, 2);
        immutable inPlace = literal.elements.all!(value => staysInside(value));
        const(string)[][] values;
        auto evaluated = inPlace ? Fragment.init : emitAll(literal.elements, values);

        _function.usesOutSlots = true;
        auto grown = callRuntime("silver_array_append", [parts[0], parts[1], "null", "%s".format(literal.elements.length),
            elementSizeOf(structOf(element)), "true", FunctionState.outData, FunctionState.outLength]).then(loadOutSlice());
        auto code = array.then(evaluated).then(grown);
        if (inPlace) return code.then(emitElements(literal, element, grown.operands[0], parts[1])).withOperands(grown.operands);

        auto layout = structOf(element);
        foreach (i, value; values)
        {
            auto at = _function.result("add i64 %s, %s".format(parts[1], i));
            auto pointer = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, grown.operands[0], at.value));
            code = code.then(at).then(pointer).then(storeScalars(element, pointer.value, 0, values[i]));
        }
        return code.withOperands(grown.operands);
    }

    /// Whether control can only leave `e` by finishing it or by a panic: nothing in it jumps to a
    /// loop or returns, which is what `?` does. A jump to a loop inside `e` counts, which costs
    /// only the faster way to do the same thing. Every node is listed, as in `planSlots`.
    private static bool staysInside(const Expr e)
    {
        bool every(const Expr[] exprs) => exprs.all!(expr => staysInside(expr));

        return e.kind.match!(
            (const UnitLit _) => true,
            (const BoolLit _) => true,
            (const IntLit _) => true,
            (const FloatLit _) => true,
            (const StringLit _) => true,
            (const LocalRef _) => true,
            (const Break _) => false,
            (const Continue _) => false,
            (const Return _) => false,
            (const Call call) => every(call.args),
            (const CallClosure call) => staysInside(*call.callee) && every(call.args),
            (const MakeClosure closure) => every(closure.captures),
            (const ForeignCall call) => every(call.args),
            (const IntrinsicCall call) => every(call.args),
            (const Prim prim) => every(prim.args),
            (const Convert convert) => staysInside(*convert.value),
            (const If if_) => staysInside(*if_.condition) && staysInside(*if_.trueBody) && staysInside(*if_.falseBody),
            (const Block block) => block.statements.all!(statement => statement.kind.match!(
                    (const Let let) => staysInside(let.value),
                    (const Assign assign) => staysInside(assign.value),
                    (const AssignElement assign) => staysInside(assign.index) && staysInside(assign.value),
                    (const Eval eval) => staysInside(eval.expr),
                )) && (block.result is null || staysInside(*block.result)),
            (const Loop loop) => staysInside(*loop.body),
            (const Construct construct) => every(construct.fields),
            (const Field field) => staysInside(*field.object),
            (const Update update) => staysInside(*update.object) && staysInside(*update.value),
            (const Inject inject) => inject.payload is null || staysInside(*inject.payload),
            (const IsMember test) => staysInside(*test.subject),
            (const Payload payload) => staysInside(*payload.subject),
            (const ArrayLit literal) => every(literal.elements),
            (const Index index) => staysInside(*index.array) && staysInside(*index.index),
            (const Slice slice) => staysInside(*slice.array) && staysInside(*slice.start) && staysInside(*slice.end),
            (const Length length) => staysInside(*length.array),
            (const Cell cell) => every(cell.args),
            (const Capture capture) => staysInside(*capture.closure),
            (const TestFailure failure) => !failure.ends && staysInside(*failure.message),
        );
    }

    /// `operands`, Strings or arrays whose elements are stored as `layout`, joined into one
    /// buffer of exactly their total length.
    private Fragment emitConcat(const string[][] operands, string layout, string size)
    {
        Fragment code;
        string total = "0";
        foreach (part; operands)
        {
            auto sum = _function.result("add i64 %s, %s".format(total, part[1]));
            code = code.then(sum);
            total = sum.value;
        }
        if (layout == "void") return code.withOperands(["null", total]);

        auto buffer = reserve(total, size);
        code = code.then(buffer);
        useIntrinsic(memcpyDeclaration);
        string offset = "0";
        foreach (part; operands)
        {
            auto target = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, buffer.operands[0], offset));
            auto bytes = _function.result("mul i64 %s, %s".format(part[1], size));
            auto copy = Fragment.instruction("call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %s, i1 false)".format(
                target.value, part[0], bytes.value));
            auto next = _function.result("add i64 %s, %s".format(offset, part[1]));
            code = code.then(target).then(bytes).then(copy).then(next);
            offset = next.value;
        }
        return code.withOperands(buffer.operands);
    }

    /// `lhs ~= rhs`'s value: in place at `lhs`'s frontier when there's room, leaving room to grow.
    private Fragment emitAppend(const string[] lhs, const string[] rhs, string layout)
    {
        if (layout == "void")
        {
            auto total = _function.result("add i64 %s, %s".format(lhs[1], rhs[1]));
            return total.withOperands(["null", total.value]);
        }
        _function.usesOutSlots = true;
        auto call = callRuntime("silver_array_append", [lhs[0], lhs[1], rhs[0], rhs[1],
            elementSizeOf(layout), "true", FunctionState.outData, FunctionState.outLength]);
        return call.then(loadOutSlice());
    }

    /// An index of any integer type as an unsigned 64-bit one, so a negative one is too large.
    private Fragment position(const Expr index)
    {
        auto value = emitExpr(index);
        return value.then(widened(index.type, value.value, index.span));
    }

    private Fragment emit(const Expr e, const Index index)
    {
        auto place = placeOf(e);
        return place.pointer is null ? emitIndexChecked(e, index).withValue(null) : read(place);
    }

    /// The array and the position `index` reads, checked to be inside it. The operands are the
    /// array's data and the position.
    private Fragment emitIndexChecked(const Expr e, const Index index)
    {
        auto array = emitExpr(*index.array);
        auto parts = operandsOf(*index.array, array.operands, 2);
        auto at = position(*index.index);
        auto outside = _function.result("icmp uge i64 %s, %s".format(at.value, parts[1]));
        return array.then(at).then(outside).then(emitPanicIf(outside.value, e.span, "Index is out of range"))
            .withOperands([parts[0], at.value]);
    }

    private Fragment emit(const Expr e, const Slice slice)
    {
        auto array = emitExpr(*slice.array);
        auto parts = operandsOf(*slice.array, array.operands, 2);
        auto start = position(*slice.start);
        auto end = position(*slice.end);
        auto reversed = _function.result("icmp ugt i64 %s, %s".format(start.value, end.value));
        auto tooLong = _function.result("icmp ugt i64 %s, %s".format(end.value, parts[1]));
        auto outside = _function.result("or i1 %s, %s".format(reversed.value, tooLong.value));
        auto length = _function.result("sub i64 %s, %s".format(end.value, start.value));
        auto code = array.then(start).then(end).then(reversed).then(tooLong).then(outside)
            .then(emitPanicIf(outside.value, e.span, "Slice is out of range")).then(length);
        auto layout = llvmType(elementOf(e.type), e.span);
        if (layout == "void") return code.withOperands(["null", length.value]);
        auto data = _function.result("getelementptr %s, ptr %s, i64 %s".format(layout, parts[0], start.value));
        return code.then(data).withOperands([data.value, length.value]);
    }

    private Fragment emit(const Expr e, const Length length)
    {
        auto array = emitExpr(*length.array);
        return array.withValue(operandsOf(*length.array, array.operands, 2)[1]);
    }

    // Cells. A `Ref` points to an `i1` and its value's scalars on the heap, laid out as an option
    // is: the `i1` says whether the cell holds its value, which it doesn't while `update` runs.

    private Fragment emit(const Expr e, const Cell cell)
    {
        const(string)[][] operands;
        auto args = emitAll(cell.args, operands);
        auto contents = scalarsOf(_program.cellContents[cell.op == CellOp.New ? e.type : cell.args[0].type], e.span);
        auto layout = "i1" ~ contents;
        /// Argument `index`, which is what a cell holds.
        const(string)[] held(size_t index) => operandsOf(cell.args[index], operands[index], contents.length);

        Fragment fill(string target, const string[] value)
        {
            return storeScalars(layout, target, 0, ["true"]).then(storeScalars(layout, target, 1, value));
        }

        if (cell.op == CellOp.New)
        {
            auto object = alloc(structOf(layout));
            return args.then(object).then(fill(object.value, held(0))).withValue(object.value);
        }
        auto target = operandsOf(cell.args[0], operands[0], 1)[0];
        if (cell.op == CellOp.Fill) return args.then(fill(target, held(1))).withValue(null);

        auto full = loadScalars(layout, target, 0, 1);
        auto empty = _function.result("xor i1 %s, true".format(full.value));
        auto code = args.then(full).then(empty).then(emitPanicIf(empty.value, e.span, "Ref is being updated"));
        if (cell.op == CellOp.Set) return code.then(storeScalars(layout, target, 1, held(1))).withValue(null);
        if (cell.op == CellOp.Take) code = code.then(storeScalars(layout, target, 0, ["false"]));
        return code.then(loadScalars(layout, target, 1, contents.length));
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
    private Fragment callRuntime(string name, const string[] operands)
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

    /// How a value of `type` is laid out in memory, and returned.
    private string llvmType(Type type, Span span)
    {
        return structOf(scalarsOf(type, span));
    }

    /// The LLVM types of the scalars a value of `type` is made of, in order: none for `()`, and
    /// for a record, option or error union, those of everything it holds.
    private const(string)[] scalarsOf(Type type, Span span)
    {
        if (auto known = type in _scalars) return *known;
        // Boxing ends every cycle, so this is only reached if a new kind of type holds itself.
        if (type in _scalarsPending)
        {
            return notImplemented!(const(string)[])("a type that holds itself by value: " ~ _program.types.describe(type), span);
        }
        _scalarsPending[type] = true;
        auto scalars = scalarsOfNew(type, span);
        _scalarsPending.remove(type);
        _scalars[type] = scalars;
        return scalars;
    }

    private const(string)[] scalarsOfNew(Type type, Span span)
    {
        auto types = _program.types;
        if (type == types.unit || type == types.never || type == types.none || type == types.emptyDictionary) return null;
        if (type == types.bool_) return ["i1"];
        if (type == types.float_) return ["double"];
        if (type == types.float32) return ["float"];
        if (types.isInteger(type) || type == types.char_) return ["i%s".format(types.integerOf(type).bits)];
        if (type == types.string_ || type == types.emptyArray || types.isArray(type)) return sliceScalars;
        if (types.isFunction(type)) return closureScalars;
        if (types.isOption(type)) return "i1" ~ scalarsOf(types.optionInner(type), span);
        if (types.isErrorUnion(type))
        {
            return "i1" ~ scalarsOf(types.successOf(type), span) ~ scalarsOf(types.errorOf(type), span);
        }
        if (types.isTuple(type)) return recordScalars(type, span);
        if (type in _program.recordFields) return recordScalars(type, span);
        if (type in _program.cellContents || type in _program.nativeTypes) return ["ptr"];
        if (type in _program.sumMembers) return isAllMarkers(type) ? ["i32"] : ["i32", "ptr"];
        return notImplemented!(const(string)[])("the type " ~ types.describe(type), span);
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
