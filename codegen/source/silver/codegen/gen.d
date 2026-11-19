module silver.codegen.gen;

import std.algorithm : all, canFind, count, filter, fold, map;
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
/// which is its own stack slot, or for a mutable param, its caller's.
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

    /// Where `local` lives, or null for one made of nothing.
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
    /// The scalars of the function's return type, which `Return` needs.
    const(string)[] returnScalars;
    /// The blocks of each loop being generated, by its label.
    LoopTargets[size_t] loops;
    /// Whether the function has the runtime hand back a String or buffer, which comes through
    /// these two slots, allocated once at the top of the function.
    bool usesOutSlots;
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
/// value prints as, then its `captureEquality`, or null. Two closures are of one function when
/// they point to one descriptor.
private immutable descriptorScalars = ["ptr", "ptr", "i64", "ptr"];

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
    private bool[Type] _boxed;
    /// The name of each struct type, by what it's made of, and their definitions.
    private string[immutable(string)[]] _structs;
    private string[] _structDefinitions;
    private bool[Type] _scalarsPending;

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
        return _structDefinitions.map!(s => s ~ "\n").join ~ emitDeclares() ~ functionAttributes
            ~ _globals.map!(s => s ~ "\n").join ~ "\n"
            ~ functions.join("\n") ~ "\n"
            ~ _thunkDefinitions.join("\n") ~ "\n" ~ entry;
    }

    /// On every Silver function. Nothing unwinds through one: a panic exits, or in a test jumps,
    /// and the runtime's functions are `nothrow`. The unwind tables stay, for a debugger and for
    /// a D `Error` leaving the runtime, which `nothrow` doesn't rule out.
    private enum functionAttributes = "attributes #0 = { nounwind uwtable }\n";

    /// `silver_main`, which the runtime calls once druntime has started.
    private string emitEntry()
    {
        if (_program.entryPoint == size_t.max) return emitTestEntry();
        return "define void @silver_main() #0 {\n.entry:\n  call void %s()\n  ret void\n}\n".format(mangled(_program.entryPoint));
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
            ~ "define private void @silver.test.guard(ptr %test) #0 noinline {\n.entry:\n"
            ~ "  %frame = call ptr @llvm.frameaddress.p0(i32 0)\n"
            ~ "  store ptr %frame, ptr @silver.test.jump\n"
            ~ "  %stack = call ptr @llvm.stacksave.p0()\n"
            ~ "  %slot = getelementptr [5 x ptr], ptr @silver.test.jump, i64 0, i64 2\n"
            ~ "  store ptr %stack, ptr %slot\n"
            ~ "  %jumped = call i32 @llvm.eh.sjlj.setjmp(ptr @silver.test.jump)\n"
            ~ "  %fresh = icmp eq i32 %jumped, 0\n"
            ~ "  br i1 %fresh, label %run, label %done\nrun:\n  call void %test()\n  br label %done\ndone:\n  ret void\n}\n\n"
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
        auto stackCheck = emitStackCheck(span);

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

        auto body = isStruct(returnType)
            ? emitInto(func.body, _function.returnScalars, FunctionState.resultSlot)
            : emitExpr(func.body);
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
    private Fragment emitInto(const Expr e, const string[] layout, string pointer)
    {
        Fragment whole()
        {
            auto source = sourceOf(e, layout);
            return source.code.then(write(source, layout, pointer));
        }

        return e.kind.match!(
            (const Update update) {
                if (!isInline(e.type) || layout.length == 1) return whole();
                auto object = emitInto(*update.object, layout, pointer);
                auto at = storedAt(e.type, update.index, e.span);
                auto value = emitExpr(*update.value);
                auto replacement = at.count == 0 ? null : operandsOf(*update.value, value.operands, at.count);
                return object.then(value).then(storeScalars(layout, pointer, at.offset, replacement));
            },
            (const Construct construct) {
                // A record around one value is laid out as that value is.
                auto fields = fieldTypes(e.type);
                if (!isInline(e.type) || fields.count!(f => !isEmpty(f)) != 1) return whole();
                Fragment code;
                foreach (i, ref field; construct.fields)
                {
                    code = code.then(isEmpty(fields[i]) ? emitExpr(field).withValue(null) : emitInto(field, layout, pointer));
                }
                return code;
            },
            (const Block block) {
                if (block.result is null) return whole();
                Fragment statements;
                foreach (statement; block.statements) statements = statements.then(emitStmt(statement));
                return statements.then(emitInto(*block.result, layout, pointer));
            },
            (const If if_) {
                auto condition = emitExpr(*if_.condition);
                auto thenLabel = _function.newLabel("then");
                auto elseLabel = _function.newLabel("else");
                auto mergeLabel = _function.newLabel("merge");
                return condition
                    .then(Fragment.branch(condition.value, thenLabel, elseLabel))
                    .then(Fragment.label(thenLabel)).then(emitInto(*if_.trueBody, layout, pointer)).then(Fragment.jump(mergeLabel))
                    .then(Fragment.label(elseLabel)).then(emitInto(*if_.falseBody, layout, pointer)).then(Fragment.jump(mergeLabel))
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
        return scalars.map!(s => s == "ptr" ? "null" : s == "double" ? "0.0" : s == "i1" ? "false" : "0").array;
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

    /// Where every local of `func` lives. Slots are allocated in the order their code will be
    /// generated, a `Let`'s after its value's, so a reused name is numbered as it's met.
    private Slots planSlots(const Function func)
    {
        Slots slots;
        foreach (param; func.params)
        {
            auto passed = paramTypes(param, func.body.span);
            if (passed.length == 0) continue;
            if (param.mutable) slots.bind(param, incoming(param, 1)[0]);
            else slots.allocate(param, structOf(passed));
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
            (const Capture capture) => planSlots(slots, *capture.closure),
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
        auto func = _program.functions[call.target];
        Type[] types;
        foreach (param; func.params) types ~= param.type;
        auto arguments = emitArguments(call.args, types, func.params.map!(p => p.mutable).array, e.span);
        auto called = arguments.code.then(callFunction(func.returnType, mangled(call.target), arguments.operands, e.span));
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
        auto signature = functionData(call.callee.type);
        auto closure = emitExpr(*call.callee);
        auto parts = operandsOf(*call.callee, closure.operands, 2);
        auto code = _function.load("ptr", parts[0]);
        bool[] mutables;
        foreach (i; 0 .. signature.params.length) mutables ~= signature.isMutable(i);
        auto arguments = emitArguments(call.args, signature.params, mutables, e.span);
        auto called = closure.then(code).then(arguments.code)
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
        _globals ~= "%s = private constant %s { ptr %s, ptr %s, i64 %s, ptr %s }".format(name, structOf(descriptorScalars),
            code, printed[0], printed[1], compare);
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

        // `nobuiltin`, or LLVM takes a native named like a C library function for that function, and
        // works out or rewrites calls to it with arithmetic of its own, which rounds differently.
        auto declaration = "declare ccc %s @%s(%s) nobuiltin%s".format(returnType, call.symbol, params.join(", "),
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
            case Intrinsic.readLine:
                return emitReadLine();
            case Intrinsic.panic:
                return emitExplicitPanic(call.args[0], e.span);
            case Intrinsic.exitWithError:
                return emitExitWithError(call.args[0]);
            case Intrinsic.bytes, Intrinsic.uncheckedString:
                // A String and a `[UInt8]` have one layout, so the value is already the other.
                return emitExpr(call.args[0]);
            case Intrinsic.length, Intrinsic.get, Intrinsic.set, Intrinsic.update, Intrinsic.assert_, Intrinsic.expect, Intrinsic.uncheckedChar:
                assert(0, "lowering makes `length` a Length, `assert` and `expect` a test, `uncheckedChar` a Convert, and the others operations on a Cell");
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
        if (type == types.bool_) return "bool";
        if (type == types.unit) return "unit";
        if (type == types.string_) return "string";
        if (type == types.char_) return "char";
        assert(0, "lowering only passes primitives to an intrinsic's Any");
    }

    /// A line of input, as the `(Int32, String)` of a status and the line or the OS's message: the
    /// runtime returns the status and hands the String back through the out slots.
    private Fragment emitReadLine()
    {
        _function.usesOutSlots = true;
        auto status = callRuntime("silver_readLine", [FunctionState.outData, FunctionState.outLength]);
        auto text = loadOutSlice();
        return status.then(text).withOperands(status.value ~ text.operands);
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
            default:
                break;
        }

        // `()` has one value, so comparing two is a constant.
        if (operandType == types.unit) return arguments.then(Fragment.constant(prim.op == PrimOp.Equal ? "true" : "false"));
        if (types.isFunction(operandType) || operandType in _program.cellContents)
        {
            assert(prim.op == PrimOp.Equal || prim.op == PrimOp.NotEqual, "function values and Refs are only compared for equality");
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
        if (type == types.bool_) return callRuntimeForString("silver_format_bool", value);
        if (type == types.char_) return callRuntimeForString("silver_format_char", value);
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
        return callRuntime("silver_panic", [cString(located(span)), cString(message)])
            .then(Fragment.unreachable());
    }

    /// Either arm's value, through a phi for each scalar. An arm that leaves, being `Never`, has
    /// none, and the phis take `undef` from wherever its dead block ends.
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
        auto scalars = _function.returnScalars;
        Fragment value;
        Fragment leave;
        if (scalars.length > 1)
        {
            value = emitInto(*return_.value, scalars, FunctionState.resultSlot);
            leave = Fragment.jump(FunctionState.returnBlock);
        }
        else
        {
            value = emitExpr(*return_.value);
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
        Stored[] targets;
        if (layout.length > 1 && replacesFields(assign.value, assign.local, values, targets))
        {
            const(string)[][] operands;
            Fragment code;
            foreach (ref value; values)
            {
                auto evaluated = emitExpr(value);
                code = code.then(evaluated);
                operands ~= evaluated.operands;
            }
            foreach (i, target; targets)
            {
                if (target.count == 0) continue;
                code = code.then(storeScalars(layout, slot, target.offset, operandsOf(values[i], operands[i], target.count)));
            }
            return code;
        }
        auto source = sourceOf(assign.value, layout);
        return source.code.then(write(source, layout, slot));
    }

    /// Whether `e` is `local` with fields replaced, one after another, by values that assign
    /// nothing. `values` and `targets` are then each replacement and the scalars it replaces, in
    /// the order they're made.
    private bool replacesFields(const Expr e, const Local local, ref const(Expr)[] values, ref Stored[] targets)
    {
        return e.kind.match!(
            (const LocalRef use) => use.local is local,
            (const Update update) {
                if (!isInline(e.type) || !assignsNothing(*update.value)) return false;
                if (!replacesFields(*update.object, local, values, targets)) return false;
                values ~= *update.value;
                targets ~= storedAt(e.type, update.index, e.span);
                return true;
            },
            _ => false,
        );
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

    // Records. A tuple or a declared type's value is its fields' scalars, one after another, except
    // for a declared type that holds itself, whose value is a pointer to them on the heap, which
    // never change once written.

    /// Whether a value of the record `type` is its fields, not a pointer to them.
    private bool isInline(Type type)
    {
        return _program.types.isTuple(type) || !isBoxed(type);
    }

    /// Whether the declared type `type` can hold a value of itself with nothing but records, options
    /// and error unions in between, so that its fields would never end. Each type on such a cycle
    /// is boxed.
    private bool isBoxed(Type type)
    {
        if (auto known = type in _boxed) return *known;
        bool[Type] seen;
        bool reaches(Type from)
        {
            foreach (part; heldInline(from))
            {
                if (part == type) return true;
                if (part in seen) continue;
                seen[part] = true;
                if (reaches(part)) return true;
            }
            return false;
        }

        auto boxed = reaches(type);
        _boxed[type] = boxed;
        return boxed;
    }

    /// The types whose values are part of a value of `type` itself, were no record boxed. An array,
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

    /// The scalars of a record's fields, in order, which a boxed record's pointer points to.
    private const(string)[] recordScalars(Type type, Span span)
    {
        const(string)[] scalars;
        foreach (field; fieldTypes(type)) scalars ~= scalarsOf(field, span);
        return scalars;
    }

    /// Which of `recordScalars` are field `index`.
    private Stored storedAt(Type type, size_t index, Span span)
    {
        auto fields = fieldTypes(type);
        size_t offset = 0;
        foreach (field; fields[0 .. index]) offset += scalarsOf(field, span).length;
        return Stored(offset, scalarsOf(fields[index], span).length);
    }

    private struct Stored
    {
        size_t offset;
        size_t count;
    }

    /// Whether a value of `type` is made of nothing. This doesn't ask for its scalars: a sum asks
    /// it of its members' fields, which can hold the sum.
    private bool isEmpty(Type type)
    {
        auto types = _program.types;
        if (type == types.unit || type == types.never || type == types.none) return true;
        if (types.isTuple(type)) return types.tupleElements(type).all!(t => isEmpty(t));
        if (auto fields = type in _program.recordFields) return !isBoxed(type) && (*fields).all!(f => isEmpty(f));
        return false;
    }

    private Fragment emit(const Expr e, const Construct construct)
    {
        const(string)[][] operands;
        auto values = emitAll(construct.fields, operands);
        const(string)[] whole;
        foreach (i, field; fieldTypes(e.type))
        {
            whole ~= operandsOf(construct.fields[i], operands[i], scalarsOf(field, e.span).length);
        }
        if (isInline(e.type)) return values.withOperands(whole);

        auto layout = recordScalars(e.type, e.span);
        auto object = alloc(structOf(layout));
        return values.then(object).then(storeScalars(layout, object.value, 0, whole)).withValue(object.value);
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
    /// or a field of one of those or of a boxed record. Reading one field of a wide record then
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
                auto at = storedAt(type, field.index, e.span);
                if (!isInline(type))
                {
                    auto object = emitExpr(*field.object);
                    return Place(object.withValue(null), operandOf(*field.object, object), recordScalars(type, e.span),
                        at.offset, at.count);
                }
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
        auto object = emitExpr(*field.object);
        auto type = field.object.type;
        auto at = storedAt(type, field.index, e.span);
        auto whole = operandsOf(*field.object, object.operands, recordScalars(type, e.span).length);
        return object.withOperands(whole[at.offset .. at.offset + at.count]);
    }

    /// A record's scalars with the field's replaced; a boxed one is copied to a new object.
    private Fragment emit(const Expr e, const Update update)
    {
        auto object = emitExpr(*update.object);
        auto value = emitExpr(*update.value);
        auto code = object.then(value);
        auto type = e.type;
        auto at = storedAt(type, update.index, e.span);
        if (at.count == 0) return code.withOperands(object.operands);
        auto layout = recordScalars(type, e.span);
        auto replacement = operandsOf(*update.value, value.operands, at.count);
        if (isInline(type))
        {
            auto whole = operandsOf(*update.object, object.operands, layout.length);
            return code.withOperands(whole[0 .. at.offset] ~ replacement ~ whole[at.offset + at.count .. $]);
        }

        auto copy = alloc(structOf(layout));
        return code.then(copy).then(move(layout, copy.value, operandOf(*update.object, object)))
            .then(storeScalars(layout, copy.value, at.offset, replacement))
            .withValue(copy.value);
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
        if (type == types.unit || type == types.never || type == types.none) return null;
        if (type == types.bool_) return ["i1"];
        if (type == types.float_) return ["double"];
        if (types.isInteger(type) || type == types.char_) return ["i%s".format(types.integerOf(type).bits)];
        if (type == types.string_ || type == types.emptyArray || types.isArray(type)) return sliceScalars;
        if (types.isFunction(type)) return closureScalars;
        if (types.isOption(type)) return "i1" ~ scalarsOf(types.optionInner(type), span);
        if (types.isErrorUnion(type))
        {
            return "i1" ~ scalarsOf(types.successOf(type), span) ~ scalarsOf(types.errorOf(type), span);
        }
        if (types.isTuple(type)) return recordScalars(type, span);
        if (type in _program.recordFields) return isBoxed(type) ? ["ptr"] : recordScalars(type, span);
        if (type in _program.cellContents) return ["ptr"];
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
