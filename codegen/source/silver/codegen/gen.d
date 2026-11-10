module silver.codegen.gen;

import std.algorithm : map;
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

/// The function being generated. Instructions are appended to it as they're emitted.
private final class FunctionState
{
    string[] lines;
    private int _nextTemp;
    private int _nextLabel;

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

    void instruction(string text)
    {
        lines ~= "  " ~ text;
    }

    /// Starts block `name`: everything emitted after this is in it.
    void label(string name)
    {
        lines ~= name ~ ":";
    }

    /// Emits `text` as an instruction whose result goes in a new temp, or in `name` if given,
    /// and returns it.
    string result(string text, string name = null)
    {
        if (name is null) name = newTemp();
        instruction(name ~ " = " ~ text);
        return name;
    }

    string load(string type, string pointer)
    {
        return result("load %s, ptr %s".format(type, pointer));
    }

    void store(string type, string value, string pointer)
    {
        instruction("store %s %s, ptr %s".format(type, value, pointer));
    }

    /// `value` of `from` converted to `to` by the cast instruction `op`, e.g. `sext` or `trunc`.
    string convert(string op, string from, string value, string to)
    {
        return result("%s %s %s to %s".format(op, from, value, to));
    }

    /// Element `index` of `aggregate`, a value of the struct type `type`.
    string extract(string type, string aggregate, size_t index)
    {
        return result("extractvalue %s %s, %s".format(type, aggregate, index));
    }

    /// Calls `callee` with `arguments`, each already written with its type (`i64 %x`), and returns
    /// the result's temp, or null for a `void` function. `convention` is written before the
    /// return type when given.
    string call(string returnType, string callee, const string[] arguments, string convention = null)
    {
        auto text = "call %s%s %s(%s)".format(convention is null ? "" : convention ~ " ", returnType, callee,
            arguments.join(", "));
        if (returnType == "void")
        {
            instruction(text);
            return null;
        }
        return result(text);
    }

    /// Ends the current block by branching on the `i1` operand `condition`.
    void branch(string condition, string ifTrue, string ifFalse)
    {
        instruction("br i1 %s, label %%%s, label %%%s".format(condition, ifTrue, ifFalse));
    }

    /// Ends the current block, which control can't reach the end of.
    void unreachable()
    {
        instruction("unreachable");
    }

    /// Returns `value`, which is `type`; a `void` function returns nothing.
    void ret(string type, string value)
    {
        instruction(type == "void" ? "ret void" : "ret %s %s".format(type, value));
    }

    string[const Local] slots;
    string[] allocas;
    private int[string] _slotNames;

    /// A new stack slot for `local`, allocated in the entry block so it's made once per call.
    string slotFor(const Local local, string type)
    {
        auto count = _slotNames.require(local.name, 0);
        _slotNames[local.name] = count + 1;
        auto slot = count == 0 ? "%%%s.addr".format(local.name) : "%%%s.addr.%s".format(local.name, count);
        slots[local] = slot;
        allocas ~= "  %s = alloca %s".format(slot, type);
        return slot;
    }

    /// Makes `pointer`, which already points at a slot of `local`'s type, its slot.
    void bindSlot(const Local local, string pointer)
    {
        slots[local] = pointer;
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

        _function.label("entry");
        emitStackCheck(func.body.span);
        string[] params;
        foreach (param; func.params)
        {
            auto type = paramType(param, func.body.span);
            if (type is null) continue;
            auto incoming = "%" ~ param.name;
            params ~= type ~ " " ~ incoming;
            // A mutable param is a pointer to the caller's slot, so reads and writes go through it.
            if (param.mutable) _function.bindSlot(param, incoming);
            else _function.store(type, incoming, _function.slotFor(param, type));
        }
        _function.ret(returnType, emitExpr(func.body));

        // The allocas go at the top of the entry block, so each slot is made once per call.
        auto lines = _function.lines[0 .. 1] ~ _function.allocas ~ _function.lines[1 .. $];
        return "define %s %s(%s) {\n%s\n}\n".format(returnType, mangled(func), params.join(", "), lines.join("\n"));
    }

    /// Emits `e` into the current function, and returns its value as an operand: a temp, a
    /// constant or a global. Null for a value with no operand, like `()`.
    private string emitExpr(const Expr e)
    {
        return e.kind.match!(kind => emit(e, kind));
    }

    private string emit(const Expr e, const UnitLit)
    {
        return null;
    }

    private string emit(const Expr e, const BoolLit literal)
    {
        return literal.value ? "true" : "false";
    }

    /// Signed, since a negative literal is its two's complement and LLVM accepts a negative
    /// constant for an integer of any width; an unsigned one is zero-extended, so it's unchanged.
    private string emit(const Expr e, const IntLit literal)
    {
        import std.conv : to;

        return (cast(long) literal.value).to!string;
    }

    /// As its bits, since a decimal constant has to be exact in LLVM.
    private string emit(const Expr e, const FloatLit literal)
    {
        double value = literal.value;
        return "0x%016X".format(*cast(ulong*) &value);
    }

    /// A local's value, loaded from its slot. A local with no operand, like a Unit one, has no slot.
    private string emit(const Expr e, const LocalRef use)
    {
        auto slot = use.local in _function.slots;
        if (slot is null) return null;
        return _function.load(llvmType(use.local.type, e.span), *slot);
    }

    private string emit(const Expr e, const Call call)
    {
        auto func = _program.functions[call.target];
        string[] args;
        foreach (i, ref arg; call.args)
        {
            auto param = func.params[i];
            auto type = paramType(param, arg.span);
            if (param.mutable)
            {
                // Core passes a mutable local here, and the callee writes through its slot.
                auto local = arg.kind.match!((const LocalRef use) => use.local, _ => cast(const(Local)) null);
                assert(local !is null, "lowering passes a local to a mutable param");
                if (type !is null) args ~= type ~ " " ~ _function.slots[local];
                continue;
            }
            // Evaluated even when it has no operand, for what it does.
            auto value = emitExpr(arg);
            if (type !is null) args ~= type ~ " " ~ value;
        }
        auto result = _function.call(llvmType(func.returnType, e.span), mangled(func), args);
        if (func.returnType == _program.types.never) emitNoReturn();
        return result;
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
    private void emitNoReturn()
    {
        _function.unreachable();
        _function.label(_function.newLabel("after.noreturn"));
    }

    /// A call to the C function `call.symbol`, declared from the types at the call.
    private string emit(const Expr e, const ForeignCall call)
    {
        auto returnType = cType(e.type, e.span);
        string[] params;
        string[] operands;
        foreach (ref arg; call.args)
        {
            auto param = cType(arg.type, arg.span);
            params ~= param;
            operands ~= param ~ " " ~ emitExpr(arg);
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

        auto result = _function.call(returnType, "@" ~ call.symbol, operands, "ccc");
        if (e.type == _program.types.never) emitNoReturn();
        return result;
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
    private string emit(const Expr e, const IntrinsicCall call)
    {
        import std.conv : to;

        auto types = _program.types;
        if (call.intrinsic == Intrinsic.panic) return notImplemented("panic", e.span);
        if (e.type == types.string_ || types.isOption(e.type))
        {
            return notImplemented("an intrinsic returning `%s`".format(types.describe(e.type)), e.span);
        }

        auto name = "silver_" ~ call.intrinsic.to!string;
        string[] operands;
        foreach (i, ref arg; call.args)
        {
            if (arg.type == types.string_) return notImplemented("passing a String to an intrinsic", arg.span);
            auto value = emitExpr(arg);
            if (call.anyArgs[i])
            {
                name ~= "_" ~ runtimeSuffix(arg.type);
                if (types.isInteger(arg.type)) value = widened(arg.type, value, arg.span);
            }
            if (value !is null) operands ~= value;
        }

        if (name !in runtime) return notImplemented("the intrinsic " ~ name, e.span);
        return callRuntime(name, operands);
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
    private string widened(Type type, string value, Span span)
    {
        auto info = _program.types.integerOf(type);
        if (info.bits == 64) return value;
        return _function.convert(info.signed ? "sext" : "zext", llvmType(type, span), value, "i64");
    }

    /// A Prim's operands share one type, except a shift's amount, so the first one's type says
    /// which instruction each operation is.
    private string emit(const Expr e, const Prim prim)
    {
        auto types = _program.types;
        auto operandType = prim.args[0].type;
        if (prim.op == PrimOp.Concat || prim.op == PrimOp.Append)
        {
            return notImplemented("`~` on `%s`".format(types.describe(operandType)), e.span);
        }

        string[] operands;
        foreach (ref arg; prim.args)
        {
            operands ~= emitExpr(arg);
        }

        // `()` has one value, so comparing two is a constant.
        if (operandType == types.unit) return prim.op == PrimOp.Equal ? "true" : "false";

        auto type = llvmType(operandType, e.span);
        auto isFloat = operandType == types.float_;
        auto isInteger = types.isInteger(operandType);
        auto signed = isInteger && types.integerOf(operandType).signed;
        /// `op` on the operands, written after it, into a new temp.
        string instruction(string op, string operands)
        {
            return _function.result("%s %s %s".format(op, type, operands));
        }
        auto both = operands.length == 2 ? operands[0] ~ ", " ~ operands[1] : null;

        final switch (prim.op)
        {
            case PrimOp.Add, PrimOp.Subtract, PrimOp.Multiply:
                if (!isFloat) return emitChecked(prim.op, operandType, operands[0], operands[1], e.span);
                return instruction(prim.op == PrimOp.Add ? "fadd" : prim.op == PrimOp.Subtract ? "fsub" : "fmul", both);
            case PrimOp.Divide, PrimOp.Modulo:
                auto isDivide = prim.op == PrimOp.Divide;
                if (isFloat) return instruction(isDivide ? "fdiv" : "frem", both);
                emitDivisionChecks(operandType, operands[0], operands[1], e.span);
                return instruction(isDivide ? (signed ? "sdiv" : "udiv") : (signed ? "srem" : "urem"), both);
            case PrimOp.Negate:
                // `fneg` rather than `fsub -0.0, x`, which gets -0.0 wrong.
                if (!isFloat) return emitChecked(PrimOp.Subtract, operandType, "0", operands[0], e.span);
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
                auto count = emitShiftAmount(operandType, prim.args[1].type, operands[1], e.span);
                return instruction(prim.op == PrimOp.ShiftLeft ? "shl" : signed ? "ashr" : "lshr",
                    operands[0] ~ ", " ~ count);
            // `!=` is unordered so that comparing with NaN is true, as IEEE says it is.
            case PrimOp.Equal, PrimOp.NotEqual, PrimOp.Less, PrimOp.LessEqual, PrimOp.Greater, PrimOp.GreaterEqual:
                auto predicate = comparison(prim.op, isFloat, isInteger && !signed);
                return instruction((isFloat ? "fcmp " : "icmp ") ~ predicate, both);
            case PrimOp.Concat, PrimOp.Append:
                assert(0, "handled above");
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
    private string emitChecked(PrimOp op, Type type, string lhs, string rhs, Span span)
    {
        auto llType = llvmType(type, span);
        auto name = op == PrimOp.Add ? "add" : op == PrimOp.Subtract ? "sub" : "mul";
        auto intrinsic = "llvm.%s%s.with.overflow.%s".format(_program.types.integerOf(type).signed ? "s" : "u", name, llType);
        auto pairType = "{ %s, i1 }".format(llType);
        useIntrinsic("declare %s @%s(%s, %s)".format(pairType, intrinsic, llType, llType));

        auto pair = _function.call(pairType, "@" ~ intrinsic, [llType ~ " " ~ lhs, llType ~ " " ~ rhs]);
        auto value = _function.extract(pairType, pair, 0);
        auto overflowed = _function.extract(pairType, pair, 1);
        emitPanicIf(overflowed, span, "Integer overflow");
        return value;
    }

    /// Dividing by zero, and the most negative value by -1, are undefined in LLVM, so both panic first.
    private void emitDivisionChecks(Type type, string lhs, string rhs, Span span)
    {
        auto info = _program.types.integerOf(type);
        auto llType = llvmType(type, span);
        auto isZero = _function.result("icmp eq %s %s, 0".format(llType, rhs));
        emitPanicIf(isZero, span, "Division by zero");
        if (!info.signed) return;

        auto isMin = _function.result("icmp eq %s %s, -%s".format(llType, lhs, info.minMagnitude));
        auto isMinusOne = _function.result("icmp eq %s %s, -1".format(llType, rhs));
        auto overflows = _function.result("and i1 %s, %s".format(isMin, isMinusOne));
        emitPanicIf(overflows, span, "Integer overflow");
    }

    /// The amount can be of any integer type, so it's checked at 64 bits, unsigned: a negative
    /// amount sign-extends to a huge one and fails the same check. Then it's made `type`'s width.
    private string emitShiftAmount(Type type, Type amountType, string amount, Span span)
    {
        auto bits = _program.types.integerOf(type).bits;
        auto wide = widened(amountType, amount, span);
        auto tooFar = _function.result("icmp uge i64 %s, %s".format(wide, bits));
        emitPanicIf(tooFar, span, "Shift amount is out of range");
        if (bits == 64) return wide;
        return _function.convert("trunc", "i64", wide, llvmType(type, span));
    }

    /// Panics with `message` and the location of `span` if the `i1` operand `condition` is true.
    private void emitPanicIf(string condition, Span span, string message)
    {
        auto panicLabel = _function.newLabel("panic");
        auto okLabel = _function.newLabel("ok");
        _function.branch(condition, panicLabel, okLabel);
        _function.label(panicLabel);
        emitPanic(span, message);
        _function.label(okLabel);
    }

    /// Panics with `message` and the location of `span`, ending the current block.
    private void emitPanic(Span span, string message)
    {
        callRuntime("silver_panic", [cString("%s: %s".format(located(span), message))]);
        _function.unreachable();
    }

    private string emit(const Expr e, const If)
    {
        return notImplemented("If", e.span);
    }

    private string emit(const Expr e, const Block block)
    {
        foreach (statement; block.statements)
        {
            emitStmt(statement);
        }
        return block.result is null ? null : emitExpr(*block.result);
    }

    private string emit(const Expr e, const Loop)
    {
        return notImplemented("Loop", e.span);
    }

    private string emit(const Expr e, const Break)
    {
        return notImplemented("Break", e.span);
    }

    private string emit(const Expr e, const Continue)
    {
        return notImplemented("Continue", e.span);
    }

    private void emitStmt(const Stmt s)
    {
        s.kind.match!(kind => emit(s, kind));
    }

    private void emit(const Stmt s, const Eval eval)
    {
        emitExpr(eval.expr);
    }

    private void emit(const Stmt s, const Assign)
    {
        notImplemented!void("Assign", s.span);
    }

    private void emit(const Stmt s, const Let let)
    {
        auto value = emitExpr(let.value);
        if (value is null) return;            // Unit or Never: no slot
        auto type = llvmType(let.local.type, s.span);
        _function.store(type, value, _function.slotFor(let.local, type));
    }

    /// Every function checks on entry that it has room on the stack, and panics if not. Its
    /// names are fixed, since each function has one, so it uses none of the numbered temps.
    private void emitStackCheck(Span span)
    {
        useIntrinsic("declare ptr @llvm.frameaddress.p0(i32 immarg)");
        useIntrinsic("@silver_stack_limit = external global ptr");
        auto frame = _function.result("call ptr @llvm.frameaddress.p0(i32 0)", "%.frame");
        auto limit = _function.result("load ptr, ptr @silver_stack_limit", "%.limit");
        auto tooDeep = _function.result("icmp ult ptr %s, %s".format(frame, limit), "%.too.deep");
        _function.branch(tooDeep, "stack.overflow", "stack.ok");
        _function.label("stack.overflow");
        emitPanic(span, "Stack overflow");
        _function.label("stack.ok");
    }

    /// Declares an LLVM intrinsic, or another module-level line, once at the top of the module.
    private void useIntrinsic(string declaration)
    {
        _usedIntrinsics[declaration] = true;
    }

    /// Calls the runtime function `name` with `operands`, typed from its binding. Returns the
    /// result's temp, or null for a void function.
    private string callRuntime(string name, string[] operands)
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
        return notImplemented("the type " ~ types.describe(type), span);
    }

    private string mangled(const Function func)
    {
        return "@\"%s.%s\"".format(func.moduleName, func.name);
    }

    private T notImplemented(T = string)(string what, Span span)
    {
        throw new DiagnosticException(Diagnostic(DiagnosticCode.NotImplemented, span,
            "Not implemented in codegen yet: " ~ what));
    }
}
