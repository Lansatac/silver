module silver.sema.check;

import std.algorithm;
import std.array;
import std.conv;
import std.sumtype;
import std.string;


import silver.ast;
import silver.sema.type;
import silver.sema.resolve;

// Type checking for Silver programs.

package struct Typing
{
    TypeTable types;
    Type[Id!Expr] exprTypes;
    Type[SymbolId] symbolTypes;
    FieldInfo[][Id!TypeDecl] fields;
    size_t[Id!Expr] fieldIndexes;
}

/// Where the checker is inside a function body. Passed by value, so a nested body (a lambda)
/// gets its own copy and the enclosing one is untouched when it returns.
private struct BodyContext
{
    /// What `return` checks against: the innermost enclosing function's return type.
    Type returnType;
}

struct FieldInfo { string name; Type type; }

private final class TypeChecker
{
    this(const Resolution resolutions, Collector collector)
    {
        _types = new TypeTable();
        _collector = collector;
        _resolutions = resolutions;
    }

    private TypeTable _types;
    private Collector _collector;
    private const Resolution _resolutions;
    private Type[Id!Expr] _exprTypes;
    private Type[SymbolId] _symbolTypes;
    private Type[Id!TypeDecl] _nominalTypes;
    private FieldInfo[][Id!TypeDecl] _fields;
    private size_t[Id!Expr] _fieldIndexes;
    /// Every integer literal. A literal's type can change after it's first seen, as it adapts
    /// to where it's used, so ranges are checked once all the bodies have been.
    private const(Expr)[] _intLiterals;
    private bool[Id!Expr] _negatedLiterals;

    Typing checkProgram(const Program program)
    {
        auto programModules = program.sortedModules;
        // phase 1: all declared types; phase 2: all signatures; phase 3: all bodies
        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const TypeDecl t) {
                        _nominalTypes[t.id] = _types.nominal(t.id, t.name);
                    },
                    (_) {},
                );
            }
        }

        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const FunctionDecl f) {
                        declareSignature(f);
                    },
                    (const TypeDecl decl) {
                        declareConstructor(decl);
                    },
                    (const ImportStmt _) {},
                );
            }
        }

        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const FunctionDecl f) {
                        checkFunction(f);
                    },
                    (const TypeDecl _) {},
                    (const ImportStmt _) {},
                );
            }
        }

        foreach (literal; _intLiterals)
        {
            checkLiteralRange(literal);
        }

        return Typing(_types, _exprTypes, _symbolTypes, _fields, _fieldIndexes);
    }

    private void checkLiteralRange(const Expr expr)
    {
        auto literal = expr.kind.match!(
            (const IntLiteral l) => l,
            (_) => assert(0, "only integer literals are recorded"),
        );
        if (literal.tooLarge)
        {
            _collector.reportError(DiagnosticCode.LiteralOutOfRange, expr.span,
                "This integer literal doesn't fit in 64 bits");
            return;
        }
        auto type = _exprTypes[expr.id];
        if (!_types.isInteger(type)) return;

        auto info = _types.integerOf(type);
        auto negated = (expr.id in _negatedLiterals) !is null;
        if (negated && !info.signed)
        {
            _collector.reportError(DiagnosticCode.LiteralOutOfRange, expr.span,
                "`%s` can't hold a negative value".format(_types.describe(type)));
        }
        else if (literal.value > (negated ? info.minMagnitude : info.maxValue))
        {
            _collector.reportError(DiagnosticCode.LiteralOutOfRange, expr.span,
                "`%s%s` doesn't fit in `%s`".format(negated ? "-" : "", literal.value, _types.describe(type)));
        }
    }

    private Type resolveType(const TypeExpr type)
    {
        return type.kind.match!(
            (const NamedType _) => resolveNamedType(type),
            (const OptionType option) => _types.option(resolveType(*option.inner)),
            (const FunctionType func) => _types.function_(
                func.params.map!(p => resolveType(p)).array, resolveType(*func.returnType)),
            (const UnitType _) => _types.unit,
        );
    }

    private Type resolveNamedType(const TypeExpr typeExpr)
    {
        auto symbol = typeExpr.id in _resolutions.typeResolutions;
        if (symbol is null) return _types.error;

        return (*symbol).match!(
            (const Builtin builtIn) => builtinType(builtIn),
            (const Id!TypeDecl decl) => _nominalTypes[decl],
        );
    }

    private Type builtinType(Builtin builtin)
    {
        final switch (builtin)
        {
            case Builtin.Never: return _types.never;
            case Builtin.Unit: return _types.unit;
            case Builtin.Bool: return _types.bool_;
            case Builtin.Int: return _types.int_;
            case Builtin.Float: return _types.float_;
            case Builtin.String: return _types.string_;
            case Builtin.Any: return _types.any;
            case Builtin.Int8: return _types.int8;
            case Builtin.Int16: return _types.int16;
            case Builtin.Int32: return _types.int32;
            case Builtin.Int64: return _types.int_;
            case Builtin.UInt: return _types.uint_;
            case Builtin.UInt8: return _types.uint8;
            case Builtin.UInt16: return _types.uint16;
            case Builtin.UInt32: return _types.uint32;
            case Builtin.UInt64: return _types.uint_;
        }
    }

    private void declareSignature(const FunctionDecl func)
    {
        auto params = func.params.map!(p => resolveType(p.type)).array;
        foreach (i, param; func.params)
        {
            _symbolTypes[SymbolId(param.id)] = params[i];
        }
        _symbolTypes[SymbolId(func.id)] = _types.function_(params, resolveType(func.returnType));
    }

    private void declareConstructor(const TypeDecl decl)
    {
        auto fields = decl.fields.map!(f => FieldInfo(f.name, resolveType(f.type))).array;
        _fields[decl.id] = fields;

        auto declared = _nominalTypes[decl.id];
        _symbolTypes[SymbolId(decl.id)] = fields.length == 0
            ? declared
            : _types.function_(fields.map!(f => f.type).array, declared);
    }


    private void checkFunction(const FunctionDecl func)
    {
        auto returnType = _types[_symbolTypes[SymbolId(func.id)]].match!(
            (const FunctionData fd)=>fd.ret,
            (_)=>_types.error
            );
        if (func.body !is null)
        {
            checkBody(*func.body, returnType);
        }
    }

    /// Checks a function or lambda body in a fresh context, against its return type.
    private void checkBody(const Expr body, Type returnType)
    {
        auto ctx = BodyContext(returnType);
        check(body, returnType, ctx);
    }

    private void checkStmt(const Stmt stmt, BodyContext ctx)
    {
        stmt.kind.match!(
            (const VarDecl var) {
                if (var.type is null)
                {
                    _symbolTypes[SymbolId(var.id)] = synthesize(var.value, ctx);
                }
                else
                {
                    auto type = resolveType(*var.type);
                    check(var.value, type, ctx);
                    _symbolTypes[SymbolId(var.id)] = type;
                }
            },
            (const AssignStmt assign) {
                auto lhsType = synthesize(assign.target, ctx);
                if (lhsType != _types.error) checkAssignable(assign.target);
                check(assign.value, lhsType, ctx);
            },
            (const ExprStmt expr) {
                synthesize(expr.expr, ctx);
            },
            // Name resolution reports nested functions as unsupported.
            (const FunctionDecl _) {},
            (const ReturnStmt ret) {
                check(ret.value, ctx.returnType, ctx);
            },
        );
    }

    /// Reports `target` unless it's a mutable binding or a chain of fields rooted at one.
    private void checkAssignable(const Expr target)
    {
        target.kind.match!(
            (const Identifier _) => checkBindingMutable(target),
            (const MemberAccess access) => checkAssignable(*access.object),
            (_) => reportInvalidAssignment(target),
        );
    }

    private void checkBindingMutable(const Expr name)
    {
        auto symbol = name.id in _resolutions.resolutions;
        // A package prefix like `std` in `std.math.pow = f` has no resolution of its own.
        if (symbol is null)
        {
            reportInvalidAssignment(name);
            return;
        }
        (*symbol).match!(
            (const Id!VarDecl local) {
                auto decl = _resolutions.declarations.locals[local];
                if (!decl.mutable)
                {
                    _collector.reportError(DiagnosticCode.AssignToImmutable, name.span,
                        "`%s` is not mutable and cannot be assigned to; declare it with `mutable val`".format(decl.name));
                }
            },
            (const Id!Param param) {
                _collector.reportError(DiagnosticCode.AssignToImmutable, name.span,
                    "`%s` is a parameter, which is not mutable and cannot be assigned to"
                        .format(_resolutions.declarations.params[param].name));
            },
            (_) => reportInvalidAssignment(name),
        );
    }

    private void reportInvalidAssignment(const Expr target)
    {
        _collector.reportError(DiagnosticCode.InvalidAssignmentTarget, target.span,
            "Only a `mutable val` or one of its fields can be assigned to");
    }

    private Type synthesize(const Expr expr, BodyContext ctx)
    {
        // "what type is this?"
        
        auto type = expr.kind.match!(
            (const BoolLiteral _) => _types.bool_,
            (const IntLiteral _) {
                _intLiterals ~= expr;
                return _types.int_;
            },
            (const FloatLiteral _) => _types.float_,
            (const StringLiteral _) => _types.string_,
            (const UnaryExpr unary) => synthesizeUnary(unary, expr.span, ctx),
            (const BinaryExpr binary) => synthesizeBinary(binary, expr.span, ctx),
            (const CallExpr call) => expr.id in _resolutions.conversions
                ? synthesizeConversion(call, builtinType(_resolutions.conversions[expr.id]), expr.span, ctx)
                : synthesizeCall(call, expr.span, ctx),
            (const MemberAccess member) => synthesizeMemberAccess(expr, member, ctx),
            (const WhileExpr while_) => synthesizeWhile(while_, expr.span, ctx),
            (const IfExpr if_) => synthesizeIf(if_, expr.span, ctx),
            (const BlockExpr block) => synthesizeBlock(block, expr.span, ctx),
            (const UnitLiteral _) => _types.unit,
            (const Identifier _) => synthesizeIdentifier(expr),
        );
        _exprTypes[expr.id] = type;
        return type;
    }

    private bool isNumeric(Type t)
    {
        return _types.isInteger(t) || t == _types.float_;
    }

    /// `UInt8(x)`: a literal is checked against the target where it's written, and any other
    /// number at runtime, where one that doesn't fit panics.
    private Type synthesizeConversion(const CallExpr call, Type target, Span span, BodyContext ctx)
    {
        _exprTypes[call.callee.id] = target;
        if (call.args.length != 1)
        {
            foreach (arg; call.args)
            {
                synthesize(arg, ctx);
            }
            _collector.reportError(DiagnosticCode.WrongArgumentCount, span,
                "`%s` converts one number, got %s arguments".format(_types.describe(target), call.args.length));
            return target;
        }

        auto arg = call.args[0];
        if (isIntLiteral(arg))
        {
            check(arg, target, ctx);
            return target;
        }
        auto argType = synthesize(arg, ctx);
        if (argType != _types.error && !isNumeric(argType))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, arg.span,
                "`%s` can only convert a number, got `%s`".format(_types.describe(target), _types.describe(argType)));
        }
        return target;
    }

    private bool isComparable(Type type)
    {
        bool[Type] visited;
        return isComparable(type, visited);
    }

    /// A type can contain itself through an option field, so one already visited counts as
    /// comparable: only a type that really can't be compared can make the answer false.
    private bool isComparable(Type type, ref bool[Type] visited)
    {
        if (type in visited) return true;
        visited[type] = true;

        return _types[type].match!(
            (const Primitive primitive) => primitive.kind != Primitive.Kind.Any,
            (const OptionData option) => isComparable(option.inner, visited),
            (const FunctionData _) => false,
            (const NominalData nominal) => _fields[nominal.decl].all!(f => isComparable(f.type, visited)),
            (const ErrorType _) => true,
        );
    }

    private Type synthesizeUnary(const UnaryExpr unary, Span span, BodyContext ctx)
    {
        auto operandType = synthesize(*unary.operand, ctx);
        final switch (unary.op)
        {
            case UnaryOp.Minus:
                auto isLiteral = (*unary.operand).kind.match!((const IntLiteral _) => true, _ => false);
                if (isLiteral)
                {
                    _negatedLiterals[unary.operand.id] = true;
                }
                else if (_types.isInteger(operandType) && !_types.integerOf(operandType).signed)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, unary.operand.span,
                        "`%s` can't be negated".format(_types.describe(operandType)));
                    return _types.error;
                }
                goto case;
            case UnaryOp.Plus:
                if (operandType == _types.error) return _types.error;
                if (!isNumeric(operandType))
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, unary.operand.span,
                        "`%s` needs a number, got `%s`".format(unary.op, _types.describe(operandType)));
                    return _types.error;
                }
                return operandType;
            case UnaryOp.BitNot:
                if (operandType == _types.error) return _types.error;
                if (!_types.isInteger(operandType))
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, unary.operand.span,
                        "`%s` needs an integer, got `%s`".format(unary.op, _types.describe(operandType)));
                    return _types.error;
                }
                return operandType;
            case UnaryOp.Not:
                requireAssignable(operandType, _types.bool_, unary.operand.span);
                return _types.bool_;
        }
    }

    private Type synthesizeBinary(const BinaryExpr binary, Span span, BodyContext ctx)
    {
        auto leftType = synthesize(*binary.left, ctx);
        auto rightType = synthesize(*binary.right, ctx);
        if (leftType == _types.error || rightType == _types.error) return _types.error;
        // An integer literal takes the type of the number beside it, so `x * 2` and `x == 0` work.
        // Not a Float beside an integer-only operator, or the error would blame the literal.
        with (BinaryOp)
        {
            auto integerOnly = [BitAnd, BitOr, BitXor, ShiftLeft, ShiftRight,
                WrappingAdd, WrappingSubtract, WrappingMultiply].canFind(binary.op);
            bool adaptsTo(Type t) => integerOnly ? _types.isInteger(t) : isNumeric(t);
            if (adaptsTo(leftType) && isIntLiteral(*binary.right) && !isIntLiteral(*binary.left))
            {
                rightType = adaptLiteral(*binary.right, leftType);
            }
            else if (adaptsTo(rightType) && isIntLiteral(*binary.left) && !isIntLiteral(*binary.right))
            {
                leftType = adaptLiteral(*binary.left, rightType);
            }
        }
        final switch (binary.op)
        {
            case BinaryOp.BitAnd:
            case BinaryOp.BitOr:
            case BinaryOp.BitXor:
            case BinaryOp.ShiftLeft:
            case BinaryOp.ShiftRight:
            case BinaryOp.WrappingAdd:
            case BinaryOp.WrappingSubtract:
            case BinaryOp.WrappingMultiply:
                if (!_types.isInteger(leftType))  {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                        "`%s` needs an integer, got `%s`".format(binary.op, _types.describe(leftType)));
                    return _types.error;
                }
                if (!_types.isInteger(rightType)) {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.right.span,
                        "`%s` needs an integer, got `%s`".format(binary.op, _types.describe(rightType)));
                    return _types.error;
                }
                if (leftType != rightType)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't combine `%s` and `%s`".format(binary.op, _types.describe(leftType), _types.describe(rightType)));
                    return _types.error;
                }
                return leftType;
            case BinaryOp.Add:
            case BinaryOp.Subtract:
            case BinaryOp.Multiply:
            case BinaryOp.Divide:
            case BinaryOp.Modulo:
                if (!isNumeric(leftType))  {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                        "`%s` needs a number, got `%s`".format(binary.op, _types.describe(leftType)));
                    return _types.error;
                }
                if (!isNumeric(rightType)) {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.right.span,
                        "`%s` needs a number, got `%s`".format(binary.op, _types.describe(rightType)));
                    return _types.error;
                }
                if (leftType != rightType)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't combine `%s` and `%s`".format(binary.op, _types.describe(leftType), _types.describe(rightType)));
                    return _types.error;
                }
                return leftType;
            case BinaryOp.Less:
            case BinaryOp.LessEqual:
            case BinaryOp.Greater:
            case BinaryOp.GreaterEqual:
                if (!isNumeric(leftType))  {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                        "`%s` needs a number, got `%s`".format(binary.op, _types.describe(leftType)));
                    return _types.error;
                }
                if (!isNumeric(rightType)) {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.right.span,
                        "`%s` needs a number, got `%s`".format(binary.op, _types.describe(rightType)));
                    return _types.error;
                }
                if (leftType != rightType)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't compare `%s` and `%s`".format(binary.op, _types.describe(leftType), _types.describe(rightType)));
                    return _types.error;
                }
                return _types.bool_;
            case BinaryOp.And:
            case BinaryOp.Or:
                requireAssignable(leftType, _types.bool_, binary.left.span);
                requireAssignable(rightType, _types.bool_, binary.right.span);
                return _types.bool_;
            case BinaryOp.Equal:
            case BinaryOp.NotEqual:
                if (leftType != rightType)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't compare `%s` and `%s`".format(binary.op, _types.describe(leftType), _types.describe(rightType)));
                    return _types.error;
                }
                if (!isComparable(leftType))
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't compare values of type `%s`".format(binary.op, _types.describe(leftType)));
                    return _types.error;
                }
                return _types.bool_;
            case BinaryOp.Coalesce:
                _collector.reportError(DiagnosticCode.InternalError, span, "`??` isn't supported yet");
                return _types.error;
        }
    }

    private Type synthesizeCall(const CallExpr call, Span span, BodyContext ctx)
    {
        auto calleeType = synthesize(*call.callee, ctx);
        // Each argument is checked against its parameter when there is one, and synthesized
        // otherwise, so even a wrong call gives every argument a type and its own errors.
        void synthesizeArgs()
        {
            foreach (arg; call.args)
            {
                synthesize(arg, ctx);
            }
        }
        if (calleeType == _types.error)
        {
            synthesizeArgs();
            return _types.error;
        }
        return _types[calleeType].match!(
            (const FunctionData funcData) {
                if (funcData.params.length != call.args.length)
                {
                    synthesizeArgs();
                    _collector.reportError(DiagnosticCode.WrongArgumentCount, span,
                        "Expected %s arguments, got %s".format(funcData.params.length, call.args.length));
                    return _types.error;
                }
                foreach (i, arg; call.args)
                {
                    check(arg, funcData.params[i], ctx);
                }
                return funcData.ret;
            },
            (_) {
                synthesizeArgs();
                _collector.reportError(DiagnosticCode.NotCallable, span,
                    "Expression of type `%s` is not function-like and cannot be called".format(_types.describe(calleeType)));
                return _types.error;
            },
        );
    }

    private Type synthesizeMemberAccess(const Expr expr, const MemberAccess member, BodyContext ctx)
    {
        // `std.math.pow`: resolution already found the declaration.
        if (auto symbol = expr.id in _resolutions.resolutions)
        {
            return symbolType(*symbol);   // the same lookup synthesizeIdentifier uses
        }
        // `std.math.nope` or `std.nope`: resolution reported it.
        if (isModulePath(*member.object)) return _types.error;

        auto objectType = synthesize(*member.object, ctx);
        if (objectType == _types.error) return _types.error;

        auto fields = _types[objectType].match!(
            (const NominalData nominal) => _fields[nominal.decl],
            (_) => FieldInfo[].init,
        );
        foreach (i, field; fields)
        {
            if (field.name == member.member)
            {
                _fieldIndexes[expr.id] = i;
                return field.type;
            }
        }
        _collector.reportError(DiagnosticCode.UnknownMember, expr.span,
            "Type `%s` has no member named `%s`".format(_types.describe(objectType), member.member));
        return _types.error;
    }

    private bool isModulePath(const Expr expr)
    {
        if (auto symbol = expr.id in _resolutions.resolutions)
        {
            return (*symbol).match!(
                (const Id!Module _) => true,
                _ => false,
            );
        }
        return expr.kind.match!(
            // A package prefix like `std`, or an unknown name.
            (const Identifier _) => true,
            // `a.b` with no resolution is a module path only if `a` is one; otherwise it's a member of a value.
            (const MemberAccess access) => isModulePath(*access.object),
            _ => false,
        );
    }

    private Type symbolType(SymbolId symbol)
    {
        if (auto type = symbol in _symbolTypes) return *type;
        // A module used as a value; name resolution has already reported it.
        if (symbol.match!((const Id!Module _) => true, _ => false)) return _types.error;
        // This should never happen: every symbol that can be resolved should have a type.
        _collector.reportError(DiagnosticCode.InternalError, Span.init,
            "No type found for symbol %s".format(symbol.to!string));
        return _types.error;
    }

    private Type synthesizeWhile(const WhileExpr while_, Span span, BodyContext ctx)
    {
        auto condType = synthesize(*while_.condition, ctx);
        requireAssignable(condType, _types.bool_, while_.condition.span);
        check(*while_.body, _types.unit, ctx);
        return _types.unit;
    }

    private Type synthesizeIf(const IfExpr if_, Span span, BodyContext ctx)
    {
        auto condType = synthesize(*if_.condition, ctx);
        requireAssignable(condType, _types.bool_, if_.condition.span);
        auto thenType = synthesize(*if_.trueBody, ctx);
        if (if_.falseBody !is null)
        {
            auto elseType = synthesize(*if_.falseBody, ctx);
            return join(thenType, elseType, span);
        }

        return _types.unit;
    }

    /// The type that both `a` and `b` fit, or `error` (reported at `span`) if there isn't one.
    private Type join(Type a, Type b, Span span)
    {
        if (a == _types.error || b == _types.error) return _types.error;
        if (a == _types.never) return b;
        if (b == _types.never) return a;
        if (isAssignable(a, b)) return b;
        if (isAssignable(b, a)) return a;
        
        _collector.reportError(DiagnosticCode.TypeMismatch, span,
            "Branches have different types `%s` and `%s`".format(_types.describe(a), _types.describe(b)));
        return _types.error;
    }

    private Type synthesizeBlock(const BlockExpr block, Span span, BodyContext ctx)
    {
        foreach (stmt; block.statements)
        {
            checkStmt(stmt, ctx);
        }
        if (block.value !is null)
        {
            return synthesize(*block.value, ctx);
        }
        return valuelessBlockType(block);
    }

    /// The type of a block with no value expression, after its statements have been checked.
    private Type valuelessBlockType(const BlockExpr block)
    {
        if (block.statements.length > 0 && alwaysExits(block.statements[$ - 1]))
        {
            return _types.never;
        }
        return _types.unit;
    }

    /// Whether control never continues past `stmt`, so a block ending in it has type Never.
    private bool alwaysExits(const Stmt stmt)
    {
        return stmt.kind.match!(
            (const ReturnStmt _) => true,
            (const ExprStmt e) => _exprTypes.get(e.expr.id, _types.error) == _types.never,
            _ => false,
        );
    }

    private Type synthesizeIdentifier(const Expr expr)
    {
        if (auto symbol = expr.id in _resolutions.resolutions)
        {
            return symbolType(*symbol);
        }
        // Name resolution couldn't find it and has already reported that.
        return _types.error;
    }

    private Type check(const Expr expr, Type expected, BodyContext ctx)
    {
        // A number is passed down, so that a literal adapts in an `if` arm or as a block's value too.
        if (isNumeric(expected))
        {
            auto passedDown = expr.kind.match!(
                (const IfExpr if_) => if_.falseBody !is null,
                (const BlockExpr _) => true,
                _ => false,
            );
            if (passedDown)
            {
                auto type = expr.kind.match!(
                    (const IfExpr if_) => checkIf(if_, expected, ctx),
                    (const BlockExpr block) => checkBlock(block, expected, expr.span, ctx),
                    (_) => assert(0, "only ifs and blocks are passed down"),
                );
                _exprTypes[expr.id] = type;
                return type;
            }
        }

        auto type = synthesize(expr, ctx);
        if (isNumeric(expected) && isIntLiteral(expr))
        {
            return adaptLiteral(expr, expected);
        }
        requireAssignable(type, expected, expr.span);
        return type;
    }

    private Type checkIf(const IfExpr if_, Type expected, BodyContext ctx)
    {
        auto condType = synthesize(*if_.condition, ctx);
        requireAssignable(condType, _types.bool_, if_.condition.span);
        auto thenType = check(*if_.trueBody, expected, ctx);
        auto elseType = check(*if_.falseBody, expected, ctx);
        return thenType == _types.never && elseType == _types.never ? _types.never : expected;
    }

    private Type checkBlock(const BlockExpr block, Type expected, Span span, BodyContext ctx)
    {
        foreach (stmt; block.statements)
        {
            checkStmt(stmt, ctx);
        }
        if (block.value !is null)
        {
            auto type = check(*block.value, expected, ctx);
            return type == _types.never ? type : expected;
        }
        auto type = valuelessBlockType(block);
        requireAssignable(type, expected, span);
        return type == _types.never ? type : expected;
    }

    /// An integer literal, possibly signed: the only integer that takes the type expected of it.
    /// Number values never convert implicitly; only literals adapt to where they're used.
    private bool isIntLiteral(const Expr expr)
    {
        return expr.kind.match!(
            (const IntLiteral _) => true,
            (const UnaryExpr unary) => (unary.op == UnaryOp.Minus || unary.op == UnaryOp.Plus)
                && isIntLiteral(*unary.operand),
            _ => false,
        );
    }

    /// Re-records an integer literal (and any sign on it) as `type`.
    private Type adaptLiteral(const Expr expr, Type type)
    {
        expr.kind.match!(
            (const UnaryExpr unary) { adaptLiteral(*unary.operand, type); },
            (_) {},
        );
        _exprTypes[expr.id] = type;
        return type;
    }

    private bool isAssignable(Type from, Type to)
    {
        if (from == to) return true;
        if (from == _types.error || to == _types.error) return true;  // already reported
        if (from == _types.never) return true;                         // no value ever arrives
        if (to == _types.any) return true;                             // print's placeholder
        // T -> T?
        return _types[to].match!(
            (const OptionData o) => isAssignable(from, o.inner),
            _ => false,
        );
    }

    private void requireAssignable(Type from, Type to, Span span)
    {
        if(!isAssignable(from, to)) _collector.reportError(DiagnosticCode.TypeMismatch, span,
            "Type `%s` is not assignable to type `%s`".format(_types.describe(from), _types.describe(to)));
    }

}

package Typing checkTypes(const ref Program program, const ref Resolution resolution, Collector collector)
{
    auto typeChecker = new TypeChecker(resolution, collector);
    return typeChecker.checkProgram(program);
}