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

/// The code for one expression and the operand holding its value. Fragments are values:
/// an expression's fragment is built from its children's, and the parent decides where
/// each one goes. Evaluation order is the order they're sequenced with `then`.
struct Fragment
{
    /// Hoisted to the top of the entry block, where mem2reg can promote them.
    string[] allocas;
    /// Instructions in order, already indented.
    string[] code;
    /// A temp (`%.t3`), a constant (`42`) or a global (`@.str.0`). Null for a Unit-typed
    /// expression, which has no value.
    string value;

    static Fragment constant(string operand)
    {
        return Fragment(null, null, operand);
    }

    static Fragment instruction(string text, string value = null)
    {
        return Fragment(null, ["  " ~ text], value);
    }

    /// This fragment followed by `next`, with `next`'s value.
    Fragment then(Fragment next)
    {
        return Fragment(allocas ~ next.allocas, code ~ next.code, next.value);
    }

    /// The same code, with no value (a statement) or another one.
    Fragment withValue(string newValue)
    {
        return Fragment(allocas, code, newValue);
    }
}

/// Names that are unique within one function. A fresh one per function.
final class FunctionState
{
    string[Id!Param] params;
    /// Each local's stack slot.
    string[Id!VarDecl] slots;

    private int _nextTemp;
    private int[string] _slotNameCounts;

    /// A fresh SSA name. Silver identifiers can't contain `.`, so these never clash with user names.
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
    const(FunctionDecl)*[Id!FunctionDecl] _functions;

    /// Runtime functions the program calls, in first-use order. Each gets one `declare`.
    private string[] _usedRuntime;
    private bool[string] _runtimeSeen;

    this(const Analysis analysis, Collector collector)
    {
        _analysis = analysis;
        _collector = collector;
    }

    string emitProgram(const ref Program program)
    {
        collectFunctions(program);
        string[] modules;
        foreach(module_; program.sortedModules)
        {
            modules ~= emitModule(module_);
        }

        // After the modules, so every runtime call has been seen.
        return emitDeclares() ~ modules.join("\n") ~ "\n" ~ emitLLMain();
    }

    void collectFunctions(const ref Program program)
    {
        foreach(module_; program.modules)
        {
            foreach(ref declaration; module_.declarations)
            {
                declaration.kind.match!(
                    (ref const FunctionDecl function_) {
                        _functions[function_.id] = &function_;
                        mangledNames[function_.id] = mangleFunctionName(*module_, function_.name);
                    },
                    (const _) {}
                );
            }
        }
    }

    string emitDeclares()
    {
        return _usedRuntime.map!(name => "declare %s @%s(%s)\n".format(
            runtime[name].returnType, name, runtime[name].params.join(", "))).join;
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
                (const FunctionDecl function_) => emitFunction(function_)
            );
        }
        return topLevelStatements.join("\n");
    }

    string emitFunction(const FunctionDecl function_)
    {
        // Natives have no body; calls to them go to the runtime.
        if (function_.native) return "";

        _function = new FunctionState;
        auto signature = _analysis.signatureOf(function_.id);
        auto returnType = llvmReturnType(signature.ret);
        auto mangledName = mangledNames[function_.id];
        auto params = emitParams(function_.params);

        auto body = emitExpr(*function_.body);
        auto ret = returnType == "void" || body.value is null
            ? "  ret void"
            : "  ret %s %s".format(returnType, body.value);
        auto lines = body.allocas ~ body.code ~ ret;

        return "define %s @\"%s\"(%s) {\nentry:\n%s}\n".format(returnType, mangledName, params,
            lines.map!(line => line ~ "\n").join);
    }

    string emitParams(const(Param[]) params)
    {
        string[] generated;
        foreach (param; params)
        {
            // Params are immutable, so they're used directly as SSA values with no stack slot.
            auto name = "%" ~ param.name;
            _function.params[param.id] = name;
            generated ~= "%s %s".format(llvmType(_analysis.typeOf(param.id)), name);
        }
        return generated.join(", ");
    }

    Fragment emitExpr(const Expr expr)
    {
        return expr.kind.match!(
            (const BoolLiteral literal) => Fragment.constant(literal.value ? "true" : "false"),
            (const IntLiteral literal) => Fragment.constant(literal.value.to!string),
            (const FloatLiteral literal) => Fragment.constant(floatConstant(literal.value)),
            (const StringLiteral literal) => unsupported(expr.span, "String literals"),
            (const UnitLiteral literal) => Fragment.init,
            (const Identifier identifier) => unsupported(expr.span, "names"),
            (const UnaryExpr unary) => unsupported(expr.span, "unary operators"),
            (const BinaryExpr binary) => unsupported(expr.span, "binary operators"),
            (const CallExpr call) => emitFunctionCall(call, expr),
            (const MemberAccess access) => unsupported(expr.span, "member access"),
            (const WhileExpr while_) => unsupported(expr.span, "`while`"),
            (const IfExpr if_) => unsupported(expr.span, "`if`"),
            (const BlockExpr block) => emitBlock(block),
        );
    }

    /// A decimal literal must be exactly representable for LLVM to accept it; the bit pattern always is.
    static string floatConstant(double value)
    {
        return "0x%016X".format(*cast(ulong*) &value);
    }

    Fragment emitFunctionCall(const CallExpr call, const Expr expr)
    {
        auto callee = _analysis.calleeOf(expr.id);
        if (callee is null) return unsupported(expr.span, "calls through values");
        auto function_ = _functions[*callee];

        auto args = call.args.map!(arg => emitExpr(arg)).array;
        auto evaluated = args.fold!((sequence, arg) => sequence.then(arg))(Fragment.init);
        auto operands = args.map!(arg => arg.value).array;

        if (function_.native)
        {
            auto name = runtimeNameFor(*function_, call, expr.span);
            if (name is null) return evaluated.withValue("undef");
            return evaluated.then(callRuntime(name, operands.filter!(o => o !is null).array));
        }

        auto signature = _analysis.signatureOf(function_.id);
        auto typedOperands = zip(signature.params, operands)
            .filter!(pair => pair[1] !is null)
            .map!(pair => "%s %s".format(llvmType(pair[0]), pair[1]))
            .join(", ");
        return evaluated.then(emitCall(llvmReturnType(signature.ret),
            "@\"" ~ mangledNames[function_.id] ~ "\"", typedOperands));
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
        auto statements = block.statements.map!(statement => emitStatement(statement))
            .fold!((sequence, statement) => sequence.then(statement))(Fragment.init);
        return block.value is null ? statements : statements.then(emitExpr(*block.value));
    }

    /// A statement's fragment never has a value.
    Fragment emitStatement(const Stmt statement)
    {
        return statement.kind.match!(
            (const VarDecl var) => emitVarDecl(var),
            (const AssignStmt assign) => unsupported(statement.span, "assignment").withValue(null),
            (const ExprStmt exprStmt) => emitExpr(exprStmt.expr).withValue(null),
            (const FunctionDecl function_) => unsupported(statement.span, "nested functions").withValue(null),
            (const ReturnStmt return_) => unsupported(statement.span, "`return`").withValue(null),
        );
    }

    Fragment emitVarDecl(const VarDecl var)
    {
        auto value = emitExpr(var.value);
        if (value.value is null)
        {
            return unsupported(var.nameSpan, "Unit-typed locals").withValue(null);
        }
        auto type = llvmType(_analysis.typeOf(var.id));
        auto slot = _function.newSlot(var.name);
        _function.slots[var.id] = slot;
        return Fragment(
            value.allocas ~ "  %s = alloca %s".format(slot, type),
            value.code ~ "  store %s %s, ptr %s".format(type, value.value, slot),
            null);
    }

    string mangleFunctionName(const Module module_, string functionName)
    {
        //TODO: this, properly
        return "%s.%s".format(module_.name, functionName);
    }

    string llvmType(Type t)
    {
        return _analysis.types[t].match!(
            (const Primitive p) => primitiveName (p),
            (const OptionData _) => "ptr",//placeholder
            (const FunctionData f) => "ptr",
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
    auto generator = new Generator(analysis, collector);
    return generator.emitProgram(program);
}
