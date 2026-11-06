module silver.codegen.gen;

import std.array;
import std.algorithm;
import std.conv : to;
import std.range;
import std.sumtype;
import std.string;

import silver.ast;
import silver.codegen.runtime_bindings;
import silver.sema;
import std.regex;

/// The code for one expression and the operand holding its value. Fragments are values:
/// an expression's fragment is built from its children's, and the parent decides where
/// each one goes. Evaluation order is the order they're sequenced with `then`. A fragment
/// starts in whatever block the parent places it in and ends in `endBlock`; what happens in
/// between is its own business.
struct Fragment
{
    /// Hoisted to the top of the entry block, where mem2reg can promote them.
    string[] allocas;
    /// Instructions in order, already indented.
    string[] code;
    /// A temp (`%.t3`), a constant (`42`) or a global (`@.str.0`). Null for a Unit-typed
    /// expression, which has no value.
    string value;
    /// The block control is in after `code` runs, or null when the code opened no block
    /// and so ends in the one it started in.
    string endBlock;

    static Fragment comment(string text)
    {
        return instruction("; " ~ text);
    }

    //debug block
    static Fragment traced(string name, Fragment inner)
    {
        return comment("begin " ~ name)
            .then(inner)
            .then(comment("end " ~ name ~ " with value " ~ inner.value))
            .withValue(inner.value);
    }


    static Fragment constant(string operand)
    {
        return Fragment(null, null, operand);
    }

    static Fragment instruction(string text, string value = null)
    {
        return Fragment(null, ["  " ~ text], value);
    }

    static Fragment undef()
    {
        return constant("undef");
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

    /// Ends the current block by jumping to `target`.
    static Fragment jump(string target)
    {
        return instruction("br label %" ~ target);
    }

    /// Ends the current block by branching on the `i1` operand `condition`.
    static Fragment branch(string condition, string ifTrue, string ifFalse)
    {
        return instruction("br i1 %s, label %%%s, label %%%s".format(condition, ifTrue, ifFalse));
    }

    /// `result`, which is `type`, is `value` when control came from `block`, for each pair in
    /// `incoming`. Must be the first instruction of its block.
    static Fragment phi(string result, string type, string[2][] incoming)
    {
        auto cases = incoming.map!(pair => "[ %s, %%%s ]".format(pair[0], pair[1])).join(", ");
        return instruction("%s = phi %s %s".format(result, type, cases), result);
    }

    /// Every fragment in order, with the last one's value.
    static Fragment sequence(Fragment[] fragments)
    {
        return fragments.fold!((sequenced, next) => sequenced.then(next))(Fragment.init);
    }

    /// This fragment followed by `next`, with `next`'s value.
    Fragment then(Fragment next)
    {
        return Fragment(allocas ~ next.allocas, code ~ next.code, next.value,
            next.endBlock !is null ? next.endBlock : endBlock);
    }

    /// The same code, with no value (a statement) or another one.
    Fragment withValue(string newValue)
    {
        return Fragment(allocas, code, newValue, endBlock);
    }
}

/// Names that are unique within one function. A fresh one per function.
final class FunctionState
{
    string[Id!Param] params;
    /// Each local's stack slot.
    string[Id!VarDecl] slots;

    /// The function's LLVM return type, `void` for Unit and Never.
    string returnType;

    private int _nextTemp;
    private int[string] _slotNameCounts;
    private int _nextLabel;

    string newLabel(string hint)
    {
        return "%s.%s".format(hint, _nextLabel++);
    }

    /// A fresh SSA name. Labels and values share one namespace per function. Silver identifiers
    /// can't contain `.`, so every name built from one gets a dotted suffix (`.arg`, `.addr`),
    /// leaving undotted names and `.`-prefixed temps to codegen.
    string newTemp()
    {
        return "%%.t%s".format(_nextTemp++);
    }

    /// A fresh slot name for the local `name`, unique even when sibling blocks reuse it.
    string newSlot(string name)
    {
        auto count = _slotNameCounts.get(name, 0);
        _slotNameCounts[name] = count + 1;
        return count == 0 ? "%%%s.addr".format(name) : "%%%s.%s.addr".format(name, count);
    }
}

final class Generator
{
    const Analysis _analysis;
    Collector _collector;
    /// The function being generated.
    FunctionState _function;
    string[Id!FunctionDecl] mangledNames;
    string[Id!TypeDecl] typeConstructors;
    string[Id!TypeDecl] typeEqualities;
    private const SourceMap _sources;

    /// Types compared so far whose equality function hasn't been generated, each with a place
    /// that needs it. Generating one can ask for more, for its fields' types.
    private struct PendingEquality { Id!TypeDecl type; Span span; }
    private PendingEquality[] _pendingEqualities;
    private bool[Id!TypeDecl] _equalitySeen;

    /// Runtime functions the program calls, in first-use order. Each gets one `declare`.
    private string[] _usedRuntime;
    private bool[string] _runtimeSeen;
    /// One private global per string literal.
    private string[] _strings;

    this(const Analysis analysis, Collector collector, const SourceMap sources)
    {
        _analysis = analysis;
        _collector = collector;
        _sources = sources;
    }

    string emitProgram(const ref Program program)
    {
        collectFunctions(program);
        string[] modules;
        foreach(module_; program.sortedModules)
        {
            modules ~= emitModule(module_);
        }
        while (!_pendingEqualities.empty)
        {
            auto pending = _pendingEqualities.front;
            _pendingEqualities.popFront();
            modules ~= emitTypeEquality(pending);
        }

        // After the modules, so every runtime call and string literal has been seen.
        return emitDeclares() ~ _strings.map!(s => s ~ "\n").join ~ modules.join("\n") ~ "\n" ~ emitLLMain();
    }

    void collectFunctions(const ref Program program)
    {
        foreach(module_; program.modules)
        {
            foreach(ref declaration; module_.declarations)
            {
                declaration.kind.match!(
                    (const FunctionDecl function_) {
                        mangledNames[function_.id] = mangleFunctionName(*module_, function_.name);
                    },
                    (const TypeDecl typeDecl) {
                        typeConstructors[typeDecl.id] = mangleTypeConstructor(*module_, typeDecl.name);
                        typeEqualities[typeDecl.id] = "%s.%s_eq".format(module_.name, typeDecl.name);
                    },
                    (const _) {}
                );
            }
        }
    }

    string emitDeclares()
    {
        return _usedRuntime.map!(name => "declare %s @%s(%s) %s\n".format(
            runtime[name].returnType, name, runtime[name].params.join(", "), runtime[name].attributes)).join;
    }

    /// `silver_main`, which the runtime's D `main` calls once druntime has started.
    string emitLLMain()
    {
        if(_analysis.entryPoint is null) return "";
        auto mainName = mangledNames[*_analysis.entryPoint];

        return "define void @silver_main() {\nentry:\n  call void @\"%s\"()\n  ret void\n}\n".format(mainName);
    }

    string emitModule(const Module module_)
    {
        string[] topLevelStatements;
        foreach(declaration; module_.declarations)
        {
            topLevelStatements ~= declaration.kind.match!(
                (const ImportStmt _) => "",
                (const TypeDecl type) => emitTypeConstructor(type),
                (const FunctionDecl function_) => emitFunction(function_)
            );
        }
        return topLevelStatements.join("\n");
    }

    string emitTypeConstructor(const TypeDecl type)
    {
        if (type.fields.length == 0)
            return "@\"%s\" = private unnamed_addr constant i8 0\n".format(typeConstructors[type.id]);   // a marker has no constructor
        if (!hasLayout(type.id)) return "";

        _function = new FunctionState;
        _function.returnType = "ptr";

        auto fields = _analysis.fieldsOf(type.id);
        auto types = fields.map!(f => f.type).array;
        auto operands = fields.map!(f => paramOperand(f.name, f.type)).array;
        auto layout = llvmStruct(type.id);

        auto allocated = alloc(layout);
        auto body = allocated;
        foreach (i, field; fields)
        {
            if (operands[i] is null) continue;
            auto pointer = fieldPointer(layout, allocated.value, llvmFieldIndex(type.id, i));
            body = body.then(pointer).then(Fragment.store(llvmType(field.type), operands[i], pointer.value));
        }
        auto lines = body.code ~ ("  " ~ returnInstruction(allocated.value));

        return "define ptr @\"%s\"(%s) {\nentry:\n%s}\n".format(typeConstructors[type.id],
            typedOperands(types, operands), lines.map!(line => line ~ "\n").join);
    }

    /// Whether compiled code can hold `type`'s values. Declaring one that can't is fine;
    /// only building or reading a value is reported.
    bool hasLayout(Id!TypeDecl type)
    {
        return _analysis.fieldsOf(type).all!(f => f.type != _analysis.types.any && f.type != _analysis.types.never);
    }

    /// The literal struct type of `type`'s values. Unit fields have no value, so they take no space.
    string llvmStruct(Id!TypeDecl type)
    {
        auto stored = _analysis.fieldsOf(type)
            .filter!(f => f.type != _analysis.types.unit)
            .map!(f => llvmType(f.type));
        return "{ %-(%s, %) }".format(stored);
    }

    /// Where field `fieldIndex` of `fieldsOf(type)` is in `llvmStruct(type)`.
    size_t llvmFieldIndex(Id!TypeDecl type, size_t fieldIndex)
    {
        return _analysis.fieldsOf(type)[0 .. fieldIndex].count!(f => f.type != _analysis.types.unit);
    }

    Fragment load(string type, string pointer)
    {
        auto result = _function.newTemp();
        return Fragment.instruction("%s = load %s, ptr %s".format(result, type, pointer), result);
    }

    /// Room on the heap for one `layout`; the operand is its address.
    Fragment alloc(string layout)
    {
        return callRuntime("silver_alloc",
            ["ptrtoint (ptr getelementptr (%s, ptr null, i32 1) to i64)".format(layout)]);
    }

    /// The address of the field at `index` of the struct `object` points to.
    Fragment fieldPointer(string layout, string object, size_t index)
    {
        auto pointer = _function.newTemp();
        return Fragment.instruction("%s = getelementptr %s, ptr %s, i32 0, i32 %s".format(
            pointer, layout, object, index), pointer);
    }

    string emitFunction(const FunctionDecl function_)
    {
        // Natives have no body; calls to them go to the runtime.
        if (function_.native) return "";

        _function = new FunctionState;
        auto signature = _analysis.signatureOf(function_.id);
        auto returnType = llvmReturnType(signature.ret);
        _function.returnType = returnType;
        auto mangledName = mangledNames[function_.id];
        auto params = emitParams(function_.params);

        auto body = emitExpr(*function_.body);
        auto lines = body.allocas ~ body.code ~ ("  " ~ returnInstruction(body.value));

        return "define %s @\"%s\"(%s) {\nentry:\n%s}\n".format(returnType, mangledName, params,
            lines.map!(line => line ~ "\n").join);
    }

    /// `ret` for `value` from the current function. No value in a non-void function means
    /// control never gets here (the body ended in a `return`), so the operand is never read.
    string returnInstruction(string value)
    {
        auto type = _function.returnType;
        if (type == "void") return "ret void";
        return "ret %s %s".format(type, value is null ? "undef" : value);
    }

    /// `"i64 %a, ptr %b"`, leaving out Units, whose operand is null.
    string typedOperands(const(Type)[] types, const(string)[] operands)
    {
        return zip(types, operands)
            .filter!(pair => pair[1] !is null)
            .map!(pair => "%s %s".format(llvmType(pair[0]), pair[1]))
            .join(", ");
    }

    /// The operand for a param called `name`, or null for Unit, which has none.
    /// Params are immutable, so they're used directly as SSA values with no stack slot.
    string paramOperand(string name, Type type)
    {
        return type == _analysis.types.unit ? null : "%" ~ name ~ ".arg";
    }

    string emitParams(const(Param[]) params)
    {
        auto types = params.map!(p => _analysis.typeOf(p.id)).array;
        string[] operands;
        foreach (i, param; params)
        {
            operands ~= paramOperand(param.name, types[i]);
            _function.params[param.id] = operands[i];
        }
        return typedOperands(types, operands);
    }

    Fragment emitExpr(const Expr expr)
    {
        return expr.kind.match!(
            (const BoolLiteral literal) => Fragment.constant(literal.value ? "true" : "false"),
            (const IntLiteral literal) => 
                _analysis.typeOf(expr.id) == _analysis.types.float_
                    ? Fragment.constant(floatConstant(literal.value))
                    : Fragment.constant(literal.value.to!string),
            (const FloatLiteral literal) => Fragment.constant(floatConstant(literal.value)),
            (const StringLiteral literal) => emitStringLiteral(literal.value),
            (const UnitLiteral literal) => Fragment.init,
            (const Identifier _) => emitIdentifier(expr),
            (const UnaryExpr unary) => emitUnary(expr, unary),
            (const BinaryExpr binary) => emitBinaryExpr(binary, expr),
            (const CallExpr call) => emitFunctionCall(call, expr),
            (const MemberAccess access) => emitMemberAccess(access, expr),
            (const WhileExpr while_) => emitWhile(while_),
            (const IfExpr if_) => emitIfExpr(expr, if_),
            (const BlockExpr block) => emitBlock(block),
        );
    }

    Fragment emitMemberAccess(const MemberAccess access, const Expr expr)
    {
        // `geo.pow` names a declaration, rather than reading a field.
        if (_analysis.resolutionOf(expr.id) !is null) return emitIdentifier(expr);

        auto object = emitExpr(*access.object);
        auto type = declOf(*access.object);
        if (!hasLayout(type)) return unsupported(expr.span, "types with `Any` or `Never` fields");

        auto index = _analysis.fieldIndexOf(expr.id);
        auto fieldType = _analysis.fieldsOf(type)[index].type;
        if (fieldType == _analysis.types.unit) return object.withValue(null);

        auto pointer = fieldPointer(llvmStruct(type), object.value, llvmFieldIndex(type, index));
        return object.then(pointer).then(load(llvmType(fieldType), pointer.value));
    }

    /// The declaration of the type `object` has, for an expression whose fields are being used.
    Id!TypeDecl declOf(const Expr object)
    {
        return _analysis.types[_analysis.typeOf(object.id)].match!(
            (const NominalData nominal) => nominal.decl,
            (_) => assert(0, "sema only finds fields on a declared type"),
        );
    }

    /// A decimal literal must be exactly representable for LLVM to accept it; the bit pattern always is.
    static string floatConstant(double value)
    {
        return "0x%016X".format(*cast(ulong*) &value);
    }

    /// A NUL-terminated private global; the operand is its address.
    Fragment emitStringLiteral(string text)
    {
        auto name = "@.str.%s".format(_strings.length);
        _strings ~= "%s = private unnamed_addr constant [%s x i8] c\"%s\\00\"".format(
            name, text.length + 1, llvmStringBytes(text));
        return Fragment.constant(name);
    }

    /// The body of an LLVM `c"..."`: printable ASCII as is, every other byte as `\XX`.
    static string llvmStringBytes(string text)
    {
        string result;
        foreach (ubyte b; cast(const(ubyte)[]) text)
        {
            auto plain = b >= 0x20 && b < 0x7F && b != '"' && b != '\\';
            result ~= plain ? "" ~ cast(char) b : "\\%02X".format(b);
        }
        return result;
    }

    Fragment emitIdentifier(const Expr expr)
    {
        auto resolved = _analysis.resolutionOf(expr.id);
        if(resolved == null)
        {
            _collector.reportError(DiagnosticCode.InternalError, expr.span, "couldn't resolve expr");
            return Fragment.undef();
        }
        auto fragment = (*resolved).match!(
            (const Id!FunctionDecl decl) {
                if (_analysis.declarationOf(decl).native) return unsupported(expr.span, "native functions as values");
                auto name = mangledNames[decl];
                return Fragment.constant("@\"%s\"".format(name));
            },
            (const Id!Param param) => Fragment.constant(_function.params[param]),
            (const Id!VarDecl decl) {
                if (_analysis.typeOf(decl) == _analysis.types.unit) return Fragment.init;
                return load(llvmType(_analysis.typeOf(decl)), _function.slots[decl]);
                },
            (const Id!Module module_) {
                 _collector.reportError(DiagnosticCode.InternalError, expr.span, "trying to emit a module");
                return Fragment.undef();
            },
            (const Id!TypeDecl type) {
                if (!hasLayout(type)) return unsupported(expr.span, "types with `Any` or `Never` fields");
                return Fragment.constant("@\"%s\"".format(typeConstructors[type]));
            },
        );

        return fragment;
    }

    Fragment emitBinaryExpr(const BinaryExpr binary, const Expr expr)
    {
        auto lhs = emitExpr(*binary.left);
        auto rhs = emitExpr(*binary.right);
        auto type = _analysis.typeOf(binary.left.id);
        switch(binary.op)
        {
            case BinaryOp.And:
                return emitConditional(lhs, "i1",
                    rhs, Fragment.constant("false"), "and");
            case BinaryOp.Or:
                return emitConditional(lhs, "i1",
                    Fragment.constant("true"), rhs, "or");
            case BinaryOp.Power:
            {
                auto name = type == _analysis.types.float_ ? "silver_pow_float" : "silver_pow_int";
                return lhs.then(rhs).then(callRuntime(name, [lhs.value, rhs.value]));
            }
            case BinaryOp.Equal:
            case BinaryOp.NotEqual:
                if (comparesWithInstruction(type)) goto default;
                return emitStructuralComparison(binary.op, type, lhs, rhs, expr.span);
            default:
                auto llOp = llBinaryOp(binary.op, type);
                if (llOp is null) return unsupported(expr.span, "`" ~ binary.op ~ "`");

                auto llType = llvmType(type);
                auto isIntDivision = type == _analysis.types.int_
                    && (binary.op == BinaryOp.Divide || binary.op == BinaryOp.Modulo);
                auto check = isIntDivision ? emitDivisionByZeroCheck(rhs.value, expr.span) : Fragment.init;
                auto result = _function.newTemp();
                return
                        lhs
                    .then(rhs)
                    .then(check)
                    .then(Fragment.instruction(
                        "%s = %s %s %s, %s".format(result, llOp, llType, lhs.value, rhs.value),
                        result));
        }
    }

    /// Panics if the Int operand `divisor` is zero. `sdiv` and `srem` by zero are undefined
    /// behaviour, not a trap to rely on.
    Fragment emitDivisionByZeroCheck(string divisor, Span span)
    {
        auto location = _sources.locate(span);
        auto message = emitStringLiteral("%s(%s,%s): Division by zero".format(
            span.file, location.line, location.column));
        auto isZero = _function.newTemp();
        auto zeroLabel = _function.newLabel("div.zero");
        auto okLabel = _function.newLabel("div.ok");
        return Fragment.instruction("%s = icmp eq i64 %s, 0".format(isZero, divisor))
            .then(Fragment.branch(isZero, zeroLabel, okLabel))
            .then(Fragment.label(zeroLabel))
            .then(callRuntime("silver_panic", [message.value]))
            .then(Fragment.instruction("unreachable"))
            .then(Fragment.label(okLabel));
    }

    Fragment emitIfExpr(const Expr expr, const IfExpr if_)
    {
        auto type = _analysis.typeOf(expr.id);
        auto hasValue = type != _analysis.types.unit && type != _analysis.types.never;
        return emitConditional(emitExpr(*if_.condition), hasValue ? llvmType(type) : null,
            emitExpr(*if_.trueBody),
            if_.falseBody is null ? Fragment.init : emitExpr(*if_.falseBody),
            "if");
    }

    /// `condition ? thenArm : elseArm`, evaluating only the arm taken. A null `resultType`
    /// means the arms have no value, so there's no phi.
    Fragment emitConditional(Fragment condition, string resultType,
        Fragment thenArm, Fragment elseArm, string labelHint)
    {
        auto thenLabel = _function.newLabel(labelHint ~ ".then");
        auto elseLabel = _function.newLabel(labelHint ~ ".else");
        auto joinLabel = _function.newLabel(labelHint ~ ".join");

        auto thenBlock = Fragment.label(thenLabel)
            .then(thenArm)
            .then(Fragment.jump(joinLabel));

        auto elseBlock = Fragment.label(elseLabel)
            .then(elseArm)
            .then(Fragment.jump(joinLabel));

        auto branches = condition
            .then(Fragment.branch(condition.value, thenLabel, elseLabel))
            .then(thenBlock)
            .then(elseBlock)
            .then(Fragment.label(joinLabel));
        if (resultType is null) return branches;

        // An arm without a value never reaches the join (it returned), so its operand is never read.
        auto result = _function.newTemp();
        return branches.then(Fragment.phi(result, resultType, [
            [thenArm.value is null ? "undef" : thenArm.value, thenBlock.endBlock],
            [elseArm.value is null ? "undef" : elseArm.value, elseBlock.endBlock]]));
    }

    /// Unit-valued. The condition is re-evaluated before every iteration, so its code lives in
    /// its own block, which the body jumps back to.
    Fragment emitWhile(const WhileExpr while_)
    {
        auto condLabel = _function.newLabel("while.cond");
        auto bodyLabel = _function.newLabel("while.body");
        auto endLabel = _function.newLabel("while.end");
        auto condition = emitExpr(*while_.condition);
        return Fragment.jump(condLabel)
            .then(Fragment.label(condLabel))
            .then(condition)
            .then(Fragment.branch(condition.value, bodyLabel, endLabel))
            .then(Fragment.label(bodyLabel))
            .then(emitExpr(*while_.body))
            .then(Fragment.jump(condLabel))
            .then(Fragment.label(endLabel));
    }

    /// Whether a single `icmp` or `fcmp` compares two values of `type`.
    bool comparesWithInstruction(Type type)
    {
        return type == _analysis.types.int_ || type == _analysis.types.float_ || type == _analysis.types.bool_;
    }

    /// `==` and `!=` on values that aren't a single number: their contents are compared.
    Fragment emitStructuralComparison(BinaryOp op, Type type, Fragment lhs, Fragment rhs, Span span)
    {
        auto equal = lhs.then(rhs).then(emitEquals(type, lhs.value, rhs.value, span));
        if (op == BinaryOp.Equal) return equal;
        auto result = _function.newTemp();
        return equal.then(Fragment.instruction("%s = xor i1 %s, true".format(result, equal.value), result));
    }

    /// Whether the operands `lhs` and `rhs`, of `type`, are equal, as an `i1`.
    Fragment emitEquals(Type type, string lhs, string rhs, Span span)
    {
        if (comparesWithInstruction(type))
        {
            auto result = _function.newTemp();
            return Fragment.instruction("%s = %s %s %s, %s".format(
                result, llBinaryOp(BinaryOp.Equal, type), llvmType(type), lhs, rhs), result);
        }
        if (type == _analysis.types.string_) return callRuntime("silver_string_equals", [lhs, rhs]);

        return _analysis.types[type].match!(
            // Unit has one value and no operand. A Never operand means this is never reached.
            (const Primitive _) => Fragment.constant("true"),
            (const NominalData nominal) {
                if (!hasLayout(nominal.decl)) return unsupported(span, "types with `Any` or `Never` fields");
                if (nominal.decl !in _equalitySeen)
                {
                    _equalitySeen[nominal.decl] = true;
                    _pendingEqualities ~= PendingEquality(nominal.decl, span);
                }
                return emitCall("i1", "@\"%s\"".format(typeEqualities[nominal.decl]),
                    "ptr %s, ptr %s".format(lhs, rhs));
            },
            (const OptionData _) => unsupported(span, "comparing options"),
            (_) => assert(0, "sema only allows comparing comparable types"),
        );
    }

    /// The function comparing two values of `type`, field by field, stopping at the first
    /// difference. Generated once for each type the program compares.
    string emitTypeEquality(PendingEquality pending)
    {
        _function = new FunctionState;
        _function.returnType = "i1";

        enum left = "%left.arg", right = "%right.arg";
        auto type = pending.type;
        auto fields = _analysis.fieldsOf(type);
        auto layout = llvmStruct(type);

        // Built from the last field back: each comparison's true arm is the rest of them.
        auto body = Fragment.constant("true");
        foreach_reverse (i, field; fields)
        {
            if (field.type == _analysis.types.unit) continue;
            auto fieldLlvmType = llvmType(field.type);
            auto leftPointer = fieldPointer(layout, left, llvmFieldIndex(type, i));
            auto leftField = load(fieldLlvmType, leftPointer.value);
            auto rightPointer = fieldPointer(layout, right, llvmFieldIndex(type, i));
            auto rightField = load(fieldLlvmType, rightPointer.value);
            auto comparison = leftPointer.then(leftField).then(rightPointer).then(rightField)
                .then(emitEquals(field.type, leftField.value, rightField.value, pending.span));
            body = emitConditional(comparison, "i1", body, Fragment.constant("false"), "field");
        }
        auto lines = body.code ~ ("  " ~ returnInstruction(body.value));

        return "define private i1 @\"%s\"(ptr %s, ptr %s) {\nentry:\n%s}\n".format(
            typeEqualities[type], left, right, lines.map!(line => line ~ "\n").join);
    }

    Fragment emitUnary(const Expr expr, const UnaryExpr unary)
    {
        auto operand = emitExpr(*unary.operand);
        if (unary.op == UnaryOp.Plus) return operand;

        auto isFloat = _analysis.typeOf(unary.operand.id) == _analysis.types.float_;
        auto result = _function.newTemp();
        // `fneg` rather than `fsub -0.0, x`, which gets -0.0 wrong.
        auto text = unary.op == UnaryOp.Not
            ? "%s = xor i1 %s, true".format(result, operand.value)
            : isFloat
                ? "%s = fneg double %s".format(result, operand.value)
                : "%s = sub i64 0, %s".format(result, operand.value);
        return operand.then(Fragment.instruction(text, result));
    }

    /// The LLVM opcode, with its predicate for comparisons, for `op` on two operands of
    /// `operandType`. Null when there is no single instruction: `&&`/`||` short-circuit, `^`
    /// and `??` take several, and String comparison can't be a pointer compare.
    string llBinaryOp(BinaryOp op, Type operandType)
    {
        auto kind = _analysis.types[operandType].match!(
            (const Primitive p) => p.kind,
            (_) => Primitive.Kind.Any);
        if (kind == Primitive.Kind.String) return null;
        auto isFloat = kind == Primitive.Kind.Float;

        // `!=` is unordered so that comparing with NaN is true, as IEEE says it is.
        final switch (op)
        {
            case BinaryOp.Add: return isFloat ? "fadd" : "add";
            case BinaryOp.Subtract: return isFloat ? "fsub" : "sub";
            case BinaryOp.Multiply: return isFloat ? "fmul" : "mul";
            case BinaryOp.Divide: return isFloat ? "fdiv" : "sdiv";
            case BinaryOp.Modulo: return isFloat ? "frem" : "srem";
            case BinaryOp.Equal: return isFloat ? "fcmp oeq" : "icmp eq";
            case BinaryOp.NotEqual: return isFloat ? "fcmp une" : "icmp ne";
            case BinaryOp.Less: return isFloat ? "fcmp olt" : "icmp slt";
            case BinaryOp.LessEqual: return isFloat ? "fcmp ole" : "icmp sle";
            case BinaryOp.Greater: return isFloat ? "fcmp ogt" : "icmp sgt";
            case BinaryOp.GreaterEqual: return isFloat ? "fcmp oge" : "icmp sge";
            case BinaryOp.And:
            case BinaryOp.Or:
            case BinaryOp.Power:
            case BinaryOp.Coalesce:
                return null;
        }
    }

    Fragment emitFunctionCall(const CallExpr call, const Expr expr)
    {
        if (auto type = _analysis.constructionOf(expr.id))
        {
            if (!hasLayout(*type)) return unsupported(expr.span, "types with `Any` or `Never` fields");
            return emitCallTo(call, Fragment.constant("@\"%s\"".format(typeConstructors[*type])));
        }

        auto callee = _analysis.calleeOf(expr.id);
        if (callee is null)
        {
            if (calleeSignature(call).params.canFind(_analysis.types.any))
                return unsupported(expr.span, "calling a value that takes `Any`");
            return emitCallTo(call, emitExpr(*call.callee));
        }
        auto function_ = _analysis.declarationOf(*callee);

        if (function_.native) return emitNativeCall(*function_, call, expr);
        return emitCallTo(call, Fragment.constant("@\"%s\"".format(mangledNames[function_.id])));
    }

    /// A call of the function `callee` holds. LLVM pointers are untyped, so the same code calls
    /// a named function and a function value; the callee is evaluated first, then the arguments.
    Fragment emitCallTo(const CallExpr call, Fragment callee)
    {
        auto signature = calleeSignature(call);

        auto args = call.args.map!(arg => emitExpr(arg)).array;
        auto evaluated = callee.then(Fragment.sequence(args));
        auto operands = args.map!(arg => arg.value).array;

        return evaluated.then(emitCall(llvmReturnType(signature.ret),
            callee.value, typedOperands(signature.params, operands)));
    }

    FunctionData calleeSignature(const CallExpr call)
    {
        return _analysis.types[_analysis.typeOf(call.callee.id)].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "sema only lets a function type be called"),
        );
    }

    Fragment emitNativeCall(const FunctionDecl native, const CallExpr call, const Expr expr)
    {
        auto args = call.args.map!(arg => emitExpr(arg)).array;
        auto evaluated = Fragment.sequence(args);
        auto operands = args.map!(arg => arg.value).array;

        auto name = runtimeNameFor(native, call, expr.span);
        if (name is null) return evaluated.withValue("undef");
        return evaluated.then(callRuntime(name, operands.filter!(o => o !is null).array));
    }


    /// The runtime function implementing a call to `native`: `silver_<name>`, with a suffix
    /// for each `Any` parameter naming the argument's actual type. Null if an argument has a
    /// type the runtime can't take, which is reported.
    string runtimeNameFor(const FunctionDecl native, const CallExpr call, Span span)
    {
        auto name = "silver_" ~ native.name;
        auto signature = _analysis.signatureOf(native.id);
        foreach (i, paramType; signature.params)
        {
            if (paramType != _analysis.types.any) continue;
            auto suffix = runtimeSuffix(_analysis.typeOf(call.args[i].id));
            if (suffix is null)
            {
                unsupported(span, "passing this type to a native");
                return null;
            }
            name ~= "_" ~ suffix;
        }
        return name;
    }

    string runtimeSuffix(Type type)
    {
        return _analysis.types[type].match!(
            (const Primitive p) => p.kind.to!string.toLower,
            (_) => cast(string) null,
        );
    }

    /// A call to runtime function `name`, which gets a `declare`.
    Fragment callRuntime(string name, string[] operands)
    {
        auto binding = name in runtime;
        assert(binding !is null, "no binding for " ~ name);
        if (name !in _runtimeSeen)
        {
            _runtimeSeen[name] = true;
            _usedRuntime ~= name;
        }

        auto typedOperands = zip(binding.params, operands).map!(pair => pair[0] ~ " " ~ pair[1]).join(", ");
        return emitCall(binding.returnType, "@" ~ name, typedOperands);
    }

    /// A call whose value is a fresh temp, or nothing when `returnType` is void.
    Fragment emitCall(string returnType, string callee, string typedOperands)
    {
        if (returnType == "void")
        {
            return Fragment.instruction("call void %s(%s)".format(callee, typedOperands));
        }
        auto result = _function.newTemp();
        return Fragment.instruction("%s = call %s %s(%s)".format(result, returnType, callee, typedOperands), result);
    }

    /// Reports that the backend can't compile `what` yet and returns a placeholder operand,
    /// so generation carries on and reports everything unsupported in one pass.
    Fragment unsupported(Span span, string what)
    {
        _collector.reportError(DiagnosticCode.InternalError, span,
            "The LLVM backend doesn't support " ~ what ~ " yet");
        return Fragment.constant("undef");
    }

    Fragment emitBlock(const BlockExpr block)
    {
        auto statements = Fragment.sequence(block.statements.map!(statement => emitStatement(statement)).array);
        return block.value is null ? statements : statements.then(emitExpr(*block.value));
    }

    /// A statement's fragment never has a value.
    Fragment emitStatement(const Stmt statement)
    {
        return statement.kind.match!(
            (const VarDecl var) => emitVarDecl(var),
            (const AssignStmt assign) => emitAssign(assign),
            (const ExprStmt exprStmt) => emitExpr(exprStmt.expr).withValue(null),
            (const FunctionDecl function_) => unsupported(statement.span, "nested functions").withValue(null),
            (const ReturnStmt return_) => emitReturn(return_),
        );
    }

    /// `ret`, then a fresh block for whatever follows it, which LLVM drops as unreachable.
    Fragment emitReturn(const ReturnStmt return_)
    {
        auto value = emitExpr(return_.value);
        return value
            .then(Fragment.instruction(returnInstruction(value.value)))
            .then(Fragment.label(_function.newLabel("dead")));
    }

    Fragment emitVarDecl(const VarDecl var)
    {
        auto value = emitExpr(var.value);
        // Unit has no operand, so a Unit local has no slot: only its initializer's effects remain.
        if (value.value is null) return value.withValue(null);
        auto type = llvmType(_analysis.typeOf(var.id));
        auto slot = _function.newSlot(var.name);
        _function.slots[var.id] = slot;
        return Fragment(
            value.allocas ~ "  %s = alloca %s".format(slot, type),
            value.code ~ "  store %s %s, ptr %s".format(type, value.value, slot),
            null);
    }

    /// A store to the target. Reads are always fresh loads, so later uses see it.
    Fragment emitAssign(const AssignStmt assign)
    {
        auto value = emitExpr(assign.value);
        if (value.value is null) return value.withValue(null);
        return assignTo(assign.target, value);
    }

    /// `value`, then a store of it to `target`. Objects never change, so a field is written by
    /// building a copy of its object and assigning that to the object in turn, up to the local.
    Fragment assignTo(const Expr target, Fragment value)
    {
        return target.kind.match!(
            (const MemberAccess access) {
                auto type = declOf(*access.object);
                if (!hasLayout(type)) return unsupported(target.span, "types with `Any` or `Never` fields").withValue(null);

                auto layout = llvmStruct(type);
                auto object = emitExpr(*access.object);
                auto index = _analysis.fieldIndexOf(target.id);
                auto fieldType = llvmType(_analysis.fieldsOf(type)[index].type);
                auto contents = load(layout, object.value);

                auto updated = _function.newTemp();
                auto insert = Fragment.instruction(
                    "%s = insertvalue %s %s, %s %s, %s".format(
                        updated, layout, contents.value, fieldType, value.value, llvmFieldIndex(type, index)),
                    updated);
                auto newAlloc = alloc(layout);

                auto rebuilt = value.then(object).then(contents).then(insert).then(newAlloc)
                    .then(Fragment.store(layout, updated, newAlloc.value))
                    .withValue(newAlloc.value);
                return assignTo(*access.object, rebuilt);
            },
            (const Identifier _) => value
                .then(Fragment.store(llvmType(_analysis.typeOf(target.id)), value.value, slotOf(target)))
                .withValue(null),
            (_) => assert(0, "sema only allows names and fields as assignment targets"),
        );
    }

    /// The stack slot of the local `target` names. Sema only allows assigning to mutable locals.
    string slotOf(const Expr target)
    {
        return (*_analysis.resolutionOf(target.id)).match!(
            (const Id!VarDecl decl) => _function.slots[decl],
            (_) => assert(0, "sema only allows assigning to locals"),
        );
    }

    string mangleTypeConstructor(const Module module_, string typeName)
    {
        return "%s.%s_ctor".format(module_.name, typeName);
    }

    string mangleFunctionName(const Module module_, string functionName)
    {
        return "%s.%s".format(module_.name, functionName);
    }

    string llvmType(Type t)
    {
        return _analysis.types[t].match!(
            (const Primitive p) => primitiveName (p),
            (const OptionData _) => "ptr",//placeholder
            (const FunctionData f) => "ptr",
            (const NominalData nd) => "ptr",
            (const ErrorType _) {
                _collector.reportError(DiagnosticCode.InternalError, Span.init, "Unknown type!");
                return "UNKNOWN";
                },
        );
    }


    string llvmReturnType(Type t)
    {
        return _analysis.types[t].match!(
            (const Primitive p) => primitiveReturnName (p),
            (const OptionData _) => "ptr",//placeholder
            (const FunctionData f) => "ptr",
            (const NominalData nd) => "ptr",
            (const ErrorType _) {
                _collector.reportError(DiagnosticCode.InternalError, Span.init, "Unknown type!");
                return "UNKNOWN";
                },
        );
    }

    string primitiveName(Primitive primitive)
    {
        final switch ( primitive.kind )
        {
            case Primitive.Kind.Bool: return "i1";
            case Primitive.Kind.Int: return "i64";
            case Primitive.Kind.Float: return "double";
            case Primitive.Kind.String: return "ptr";

            case Primitive.kind.Never:
            case Primitive.kind.Unit:
            case Primitive.kind.Any:
                assert(0);
        }
    }

    string primitiveReturnName(Primitive primitive)
    {
        final switch ( primitive.kind )
        {
            case Primitive.Kind.Bool: return "i1";
            case Primitive.Kind.Int: return "i64";
            case Primitive.Kind.Float: return "double";
            case Primitive.Kind.String: return "ptr";

            case Primitive.kind.Never:
            case Primitive.kind.Unit:
            return "void";
            case Primitive.kind.Any:
                assert(0);
        }
    }

}

/// Textual LLVM IR for `program`, which must have passed sema without errors.
/// Anything the backend can't compile yet is reported to `collector` as an internal error.
string generate(const ref Program program, const Analysis analysis, Collector collector)
{
    auto generator = new Generator(analysis, collector, program.sources);
    return generator.emitProgram(program);
}
