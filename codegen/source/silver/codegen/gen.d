module silver.codegen.gen;

import std.algorithm : fold, map;
import std.array : array, join;
import std.format : format;
import std.sumtype : match;

import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException, SourceMap, Span;
import silver.codegen.runtime_bindings : runtime;
import silver.core;
import silver.sema : Intrinsic, Type;

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
    /// Hoisted to the top of the entry block, so each slot is made once per call and mem2reg
    /// can promote it.
    string[] allocas;
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
        return Fragment(null, null, operand);
    }

    static Fragment instruction(string text, string value = null)
    {
        return Fragment(null, ["  " ~ text], value);
    }

    /// The stack slot `slot`, of `type`, whose name is the fragment's value.
    static Fragment alloca(string slot, string type)
    {
        return Fragment(["  %s = alloca %s".format(slot, type)], null, slot);
    }

    static Fragment store(string type, string value, string pointer)
    {
        return instruction("store %s %s, ptr %s".format(type, value, pointer));
    }

    /// Starts block `name`: everything sequenced after this is in it.
    static Fragment label(string name)
    {
        return Fragment(null, [name ~ ":"], null, name);
    }

    /// Ends the current block by branching on the `i1` operand `condition`.
    static Fragment branch(string condition, string ifTrue, string ifFalse)
    {
        return instruction("br i1 %s, label %%%s, label %%%s".format(condition, ifTrue, ifFalse));
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

    /// Every fragment in order, with the last one's value.
    static Fragment sequence(Fragment[] fragments)
    {
        return fragments.fold!((sequenced, next) => sequenced.then(next))(Fragment.init);
    }

    /// This fragment followed by `next`, with `next`'s value.
    Fragment then(Fragment next) const
    {
        return Fragment(allocas ~ next.allocas, code ~ next.code, next.value,
            next.endBlock !is null ? next.endBlock : endBlock);
    }

    /// The same code, with another value, or none for a statement.
    Fragment withValue(string newValue) const
    {
        return Fragment(allocas.dup, code.dup, newValue, endBlock);
    }
}

/// What's unique within one function: the names it has handed out, and where each local lives.
/// A fresh one per function.
private final class FunctionState
{
    /// Each local's stack slot, or for a mutable param, the pointer to its caller's.
    string[const Local] slots;
    private int _nextTemp;
    private int _nextLabel;
    private int[string] _slotNames;

    /// A fresh SSA name. Silver identifiers can't contain `.`, so names that start with one
    /// never clash with anything taken from source.
    string newTemp()
    {
        return "%%.t%s".format(_nextTemp++);
    }

    string newLabel(string hint)
    {
        return "%s.%s".format(hint, _nextLabel++);
    }

    /// A new stack slot for `local`, recorded as where it lives.
    Fragment newSlot(const Local local, string type)
    {
        auto count = _slotNames.require(local.name, 0);
        _slotNames[local.name] = count + 1;
        auto slot = count == 0 ? "%%%s.addr".format(local.name) : "%%%s.addr.%s".format(local.name, count);
        slots[local] = slot;
        return Fragment.alloca(slot, type);
    }

    /// Makes `pointer`, which already points at a slot of `local`'s type, its slot.
    void bindSlot(const Local local, string pointer)
    {
        slots[local] = pointer;
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
    private string[] _strings;

    this(const ref Program program, const SourceMap sources)
    {
        _program = program;
        _sources = sources;
    }

    string emitProgram()
    {
        string[] functions;
        foreach (ref func; _program.functions)
        {
            functions ~= emitFunction(func);
        }
        // After the functions, so every runtime call and string literal has been seen.
        return emitDeclares() ~ _strings.map!(s => s ~ "\n").join ~ "\n" ~ functions.join("\n") ~ "\n" ~ emitEntry();
    }

    /// `silver_main`, which the runtime calls once druntime has started.
    private string emitEntry()
    {
        auto main = _program.functions[_program.entryPoint];
        return "define void @silver_main() {\nentry:\n  call void %s()\n  ret void\n}\n".format(mangled(main));
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

    private string emitFunction(const Function func)
    {
        _function = new FunctionState;
        auto returnType = llvmType(func.returnType, func.body.span);
        auto stackCheck = emitStackCheck(func.body.span);

        string[] params;
        Fragment[] receive;
        foreach (param; func.params)
        {
            auto type = paramType(param, func.body.span);
            if (type is null) continue;
            auto incoming = "%" ~ param.name;
            params ~= type ~ " " ~ incoming;
            // A mutable param is a pointer to the caller's slot, so reads and writes go through it.
            if (param.mutable)
            {
                _function.bindSlot(param, incoming);
                continue;
            }
            auto slot = _function.newSlot(param, type);
            receive ~= slot.then(Fragment.store(type, incoming, slot.value));
        }

        auto body = emitExpr(func.body);
        auto whole = Fragment.label("entry")
            .then(stackCheck)
            .then(Fragment.sequence(receive))
            .then(body)
            .then(Fragment.ret(returnType, body.value));

        // The allocas go right after the entry label.
        auto lines = whole.code[0 .. 1] ~ whole.allocas ~ whole.code[1 .. $];
        return "define %s %s(%s) {\n%s\n}\n".format(returnType, mangled(func), params.join(", "), lines.join("\n"));
    }

    private Fragment emitExpr(const Expr e)
    {
        return e.kind.match!(kind => emit(e, kind));
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
    /// constant for an integer of any width; an unsigned one is zero-extended, so it's unchanged.
    private Fragment emit(const Expr e, const IntLit literal)
    {
        import std.conv : to;

        return Fragment.constant((cast(long) literal.value).to!string);
    }

    /// As its bits, since a decimal constant has to be exact in LLVM.
    private Fragment emit(const Expr e, const FloatLit literal)
    {
        double value = literal.value;
        return Fragment.constant("0x%016X".format(*cast(ulong*) &value));
    }

    /// A local's value, loaded from its slot. A local with no operand, like a Unit one, has no slot.
    private Fragment emit(const Expr e, const LocalRef use)
    {
        auto slot = use.local in _function.slots;
        if (slot is null) return Fragment.init;
        return _function.load(llvmType(use.local.type, e.span), *slot);
    }

    private Fragment emit(const Expr e, const Call call)
    {
        auto func = _program.functions[call.target];
        Fragment arguments;
        string[] operands;
        foreach (i, ref arg; call.args)
        {
            auto param = func.params[i];
            auto type = paramType(param, arg.span);
            if (param.mutable)
            {
                // Core passes a mutable local here, and the callee writes through its slot.
                auto local = arg.kind.match!((const LocalRef use) => use.local, _ => cast(const(Local)) null);
                assert(local !is null, "lowering passes a local to a mutable param");
                if (type !is null) operands ~= type ~ " " ~ _function.slots[local];
                continue;
            }
            // Evaluated even when it has no operand, for what it does.
            auto value = emitExpr(arg);
            arguments = arguments.then(value);
            if (type !is null) operands ~= type ~ " " ~ value.value;
        }
        auto called = arguments.then(_function.call(llvmType(func.returnType, e.span), mangled(func), operands));
        return func.returnType == _program.types.never ? called.then(noReturn()) : called;
    }

    /// How `param` is passed: as its LLVM type, as a `ptr` to the caller's slot when it's mutable,
    /// or not at all, which is null, when its type has no operand. Definitions and calls agree
    /// because both ask this.
    private string paramType(const Local param, Span span)
    {
        auto type = llvmType(param.type, span);
        if (type == "void") return null;
        return param.mutable ? "ptr" : type;
    }

    /// Ends the block after a call that doesn't return. Whatever follows is never reached, but it
    /// still needs a block to be in.
    private Fragment noReturn()
    {
        return Fragment.unreachable().then(Fragment.label(_function.newLabel("after.noreturn")));
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
            params ~= param;
            operands ~= param ~ " " ~ value.value;
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
        return e.type == _program.types.never ? called.then(noReturn()) : called;
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

    /// A call to the runtime's `silver_<name>`, with a suffix naming the argument's type for each
    /// `Any` parameter.
    private Fragment emit(const Expr e, const IntrinsicCall call)
    {
        import std.conv : to;

        auto types = _program.types;
        if (call.intrinsic == Intrinsic.panic) return notImplemented("panic", e.span);
        if (e.type == types.string_ || types.isOption(e.type))
        {
            return notImplemented("an intrinsic returning `%s`".format(types.describe(e.type)), e.span);
        }

        auto name = "silver_" ~ call.intrinsic.to!string;
        Fragment arguments;
        string[] operands;
        foreach (i, ref arg; call.args)
        {
            if (arg.type == types.string_) return notImplemented("passing a String to an intrinsic", arg.span);
            auto value = emitExpr(arg);
            if (call.anyArgs[i])
            {
                name ~= "_" ~ runtimeSuffix(arg.type);
                if (types.isInteger(arg.type)) value = value.then(widened(arg.type, value.value, arg.span));
            }
            arguments = arguments.then(value);
            if (value.value !is null) operands ~= value.value;
        }

        if (name !in runtime) return notImplemented("the intrinsic " ~ name, e.span);
        return arguments.then(callRuntime(name, operands));
    }

    /// The suffix for an argument of `type` passed as `Any`. Every integer is `int` or `uint`.
    private string runtimeSuffix(Type type)
    {
        auto types = _program.types;
        if (types.isInteger(type)) return types.integerOf(type).signed ? "int" : "uint";
        if (type == types.float_) return "float";
        if (type == types.bool_) return "bool";
        if (type == types.unit) return "unit";
        assert(0, "lowering only passes primitives to an intrinsic's Any");
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
        if (prim.op == PrimOp.Concat || prim.op == PrimOp.Append)
        {
            return notImplemented("`~` on `%s`".format(types.describe(operandType)), e.span);
        }

        Fragment arguments;
        string[] operands;
        foreach (ref arg; prim.args)
        {
            auto value = emitExpr(arg);
            arguments = arguments.then(value);
            operands ~= value.value;
        }

        // `()` has one value, so comparing two is a constant.
        if (operandType == types.unit) return arguments.then(Fragment.constant(prim.op == PrimOp.Equal ? "true" : "false"));
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
            case PrimOp.Concat, PrimOp.Append:
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

    private Fragment emit(const Expr e, const If)
    {
        return notImplemented("If", e.span);
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

    private Fragment emit(const Expr e, const Loop)
    {
        return notImplemented("Loop", e.span);
    }

    private Fragment emit(const Expr e, const Break)
    {
        return notImplemented("Break", e.span);
    }

    private Fragment emit(const Expr e, const Continue)
    {
        return notImplemented("Continue", e.span);
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

    private Fragment emit(const Stmt s, const Assign)
    {
        return notImplemented("Assign", s.span);
    }

    /// A Unit or Never value has no operand, so its local gets no slot.
    private Fragment emit(const Stmt s, const Let let)
    {
        auto value = emitExpr(let.value);
        if (value.value is null) return value;
        auto type = llvmType(let.local.type, s.span);
        auto slot = _function.newSlot(let.local, type);
        return value.then(slot).then(Fragment.store(type, value.value, slot.value));
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
            .then(Fragment.branch(tooDeep.value, "stack.overflow", "stack.ok"))
            .then(Fragment.label("stack.overflow"))
            .then(emitPanic(span, "Stack overflow"))
            .then(Fragment.label("stack.ok"));
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
        string escaped;
        foreach (char c; text)
        {
            if (c >= ' ' && c <= '~' && c != '"' && c != '\\') escaped ~= c;
            else escaped ~= "\\%02X".format(cast(ubyte) c);
        }
        auto name = "@.str.%s".format(_strings.length);
        _strings ~= "%s = private unnamed_addr constant [%s x i8] c\"%s\\00\"".format(name, text.length + 1, escaped);
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
        if (type == types.unit || type == types.never) return "void";
        if (type == types.bool_) return "i1";
        if (type == types.float_) return "double";
        if (types.isInteger(type)) return "i%s".format(types.integerOf(type).bits);
        return notImplemented!string("the type " ~ types.describe(type), span);
    }

    private string mangled(const Function func)
    {
        return "@\"%s.%s\"".format(func.moduleName, func.name);
    }

    private T notImplemented(T = Fragment)(string what, Span span)
    {
        throw new DiagnosticException(Diagnostic(DiagnosticCode.NotImplemented, span,
            "Not implemented in codegen yet: " ~ what));
    }
}
