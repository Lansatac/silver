module silver.sema.check;

import std.algorithm;
import std.array;
import std.conv;
import std.sumtype;
import std.string;


import silver.ast;
import silver.sema.constant;
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
    ConstValue[Id!ConstDecl] constants;
    Type[Id!Expr] promotions;
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
    /// Where a value becomes an option, by the option type it's wrapped into.
    private Type[Id!Expr] _promotions;
    /// Every integer literal. A literal's type can change after it's first seen, as it adapts
    /// to where it's used, so ranges are checked once all the bodies have been.
    private const(Expr)[] _intLiterals;
    private bool[Id!Expr] _negatedLiterals;
    private ConstValue[Id!ConstDecl] _constants;
    /// Constants whose initializer already has an error, which evaluating would only repeat.
    private bool[Id!ConstDecl] _unevaluable;
    /// True while a constant's dependencies are being evaluated, and false once they're done.
    private bool[Id!ConstDecl] _evaluating;
    private bool[Id!ConstDecl] _cycleReported;

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
                    (const ConstDecl c) {
                        declareConstant(c);
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
                    (const ConstDecl c) {
                        checkConstant(c);
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

        // Last, because an integer literal's type isn't final until everything's been checked.
        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const ConstDecl c) => evaluateConstant(c.id),
                    (_) {},
                );
            }
        }

        return Typing(_types, _exprTypes, _symbolTypes, _fields, _fieldIndexes, _constants, _promotions);
    }

    private void declareConstant(const ConstDecl constant)
    {
        auto type = constant.type is null ? _types.error : resolveType(*constant.type);
        // Name resolution reports any other type, so uses shouldn't report it again.
        _symbolTypes[SymbolId(constant.id)] = isConstantType(type) ? type : _types.error;
    }

    private bool isConstantType(Type type)
    {
        return _types[type].match!(
            (const Primitive p) => p.kind != Primitive.Kind.Any && p.kind != Primitive.Kind.Never,
            _ => false,
        );
    }

    private void checkConstant(const ConstDecl constant)
    {
        auto type = _symbolTypes[SymbolId(constant.id)];
        auto reported = _collector.diagnostics.length;
        if (type != _types.error && requireConstantExpr(constant.value))
        {
            // A constant expression can't contain a `return`, so nothing reads the return type.
            check(constant.value, type, BodyContext(_types.error));
        }
        if (type == _types.error || _collector.diagnostics.length > reported)
        {
            _unevaluable[constant.id] = true;
        }
    }

    /// Reports the first part of `expr` that a constant can't be built from, if there is one.
    private bool requireConstantExpr(const Expr expr)
    {
        return expr.kind.match!(
            (const BoolLiteral _) => true,
            (const IntLiteral _) => true,
            (const FloatLiteral _) => true,
            (const StringLiteral _) => true,
            (const InterpolatedString interpolated) => interpolated.parts.all!(p => requireConstantExpr(p)),
            (const UnitLiteral _) => true,
            (const UnaryExpr unary) => requireConstantExpr(*unary.operand),
            (const BinaryExpr binary) => requireConstantExpr(*binary.left) && requireConstantExpr(*binary.right),
            (const Identifier _) => requireConstantName(expr),
            (const MemberAccess _) => requireConstantName(expr),
            (_) => reportNonConstant(expr),
        );
    }

    private bool requireConstantName(const Expr name)
    {
        if (auto symbol = name.id in _resolutions.resolutions)
        {
            return (*symbol).match!(
                (const Id!ConstDecl _) => true,
                // Name resolution reports a module used as a value.
                (const Id!Module _) => true,
                (_) => reportNonConstant(name),
            );
        }
        // Name resolution reports an unknown name, but a member of a value is left to types.
        return isModulePath(name) || reportNonConstant(name);
    }

    private bool reportNonConstant(const Expr expr)
    {
        _collector.reportError(DiagnosticCode.NonConstantInitializer, expr.span,
            "A top-level constant can only be built from literals, operators and other constants");
        return false;
    }

    /// Evaluates a constant's initializer once, after the constants it names, so that any of
    /// them being unusable is settled first. That goes for a short-circuited operand as well,
    /// which is never evaluated but is still a reference, so `false && a` can't define `a`.
    private void evaluateConstant(Id!ConstDecl id)
    {
        if (id in _evaluating || id in _unevaluable) return;

        auto value = _resolutions.declarations.constants[id].value;
        _evaluating[id] = true;
        evaluateNamedConstants(value);
        _evaluating[id] = false;
        if (auto result = constantValue(value))
        {
            _constants[id] = *result;
        }
    }

    private void evaluateNamedConstants(const Expr expr)
    {
        expr.kind.match!(
            (const UnaryExpr unary) => evaluateNamedConstants(*unary.operand),
            (const BinaryExpr binary) {
                evaluateNamedConstants(*binary.left);
                evaluateNamedConstants(*binary.right);
            },
            (const InterpolatedString interpolated) {
                foreach (part; interpolated.parts)
                {
                    evaluateNamedConstants(part);
                }
            },
            (const Identifier _) => evaluateNamedConstant(expr),
            (const MemberAccess _) => evaluateNamedConstant(expr),
            (_) {},
        );
    }

    private void evaluateNamedConstant(const Expr name)
    {
        auto id = constantNamedBy(name);
        if (!id.isValid) return;

        if (!_evaluating.get(id, false))
        {
            evaluateConstant(id);
        }
        else if (id !in _cycleReported)
        {
            _cycleReported[id] = true;
            _collector.reportError(DiagnosticCode.ConstantCycle, name.span,
                "`%s` is defined in terms of itself".format(_resolutions.declarations.constants[id].name));
        }
    }

    /// The constant `name` refers to, or an invalid ID if it isn't one.
    private Id!ConstDecl constantNamedBy(const Expr name)
    {
        if (auto symbol = name.id in _resolutions.resolutions)
        {
            return (*symbol).match!(
                (const Id!ConstDecl id) => id,
                _ => Id!ConstDecl.init,
            );
        }
        return Id!ConstDecl.init;
    }

    /// The value of a constant expression, or null if it has none, which is already reported.
    private const(ConstValue)* constantValue(const Expr expr)
    {
        return expr.kind.match!(
            (const BoolLiteral literal) => boxedConstant(ConstValue(bool(literal.value))),
            (const FloatLiteral literal) => boxedConstant(ConstValue(double(literal.value))),
            (const StringLiteral literal) {
                string text = literal.value;
                return boxedConstant(ConstValue(text));
            },
            (const InterpolatedString interpolated) => interpolatedConstantValue(interpolated),
            (const UnitLiteral _) => boxedConstant(ConstValue(ConstUnit())),
            (const IntLiteral literal) => integerLiteralValue(expr, literal),
            (const Identifier _) => namedConstantValue(expr),
            (const MemberAccess _) => namedConstantValue(expr),
            (const UnaryExpr unary) => unaryConstantValue(expr, unary),
            (const BinaryExpr binary) => binaryConstantValue(expr, binary),
            (_) => assert(0, "requireConstantExpr rejected everything else"),
        );
    }

    private const(ConstValue)* interpolatedConstantValue(const InterpolatedString interpolated)
    {
        string text;
        foreach (part; interpolated.parts)
        {
            auto value = constantValue(part);
            if (value is null) return null;
            text ~= formatValue(*value);
        }
        return boxedConstant(ConstValue(text));
    }

    private static const(ConstValue)* boxedConstant(ConstValue value)
    {
        auto box = new ConstValue;
        *box = value;
        return box;
    }

    private const(ConstValue)* namedConstantValue(const Expr name)
    {
        return constantNamedBy(name) in _constants;
    }

    /// Takes in the sign of a negated literal, so that `-128` is a value even where `128` isn't.
    private const(ConstValue)* integerLiteralValue(const Expr expr, const IntLiteral literal)
    {
        auto type = _exprTypes[expr.id];
        auto negated = (expr.id in _negatedLiterals) !is null;
        if (literal.tooLarge) return null;
        if (!_types.isInteger(type))
        {
            double value = cast(double) literal.value;
            return boxedConstant(ConstValue(negated ? -value : value));
        }

        auto info = _types.integerOf(type);
        // checkLiteralRange has reported one that doesn't fit.
        auto limit = negated ? info.minMagnitude : info.maxValue;
        if ((negated && !info.signed) || literal.value > limit) return null;
        if (!info.signed) return boxedConstant(ConstValue(ConstUInt(literal.value)));
        return boxedConstant(ConstValue(ConstInt(cast(long)(negated ? 0 - literal.value : literal.value))));
    }

    private const(ConstValue)* unaryConstantValue(const Expr expr, const UnaryExpr unary)
    {
        auto operand = constantValue(*unary.operand);
        if (operand is null || unary.operand.id in _negatedLiterals) return operand;

        try
        {
            return boxedConstant(unaryValue(unary.op, *operand, integerInfoOf(*unary.operand)));
        }
        catch (ConstantFailure failure)
        {
            return reportConstantFailure(expr, failure);
        }
    }

    private const(ConstValue)* binaryConstantValue(const Expr expr, const BinaryExpr binary)
    {
        auto left = constantValue(*binary.left);
        if (left is null) return null;

        if (binary.op == BinaryOp.And || binary.op == BinaryOp.Or)
        {
            auto decided = (*left).get!(const bool) == (binary.op == BinaryOp.Or);
            return decided ? left : constantValue(*binary.right);
        }

        auto right = constantValue(*binary.right);
        if (right is null) return null;

        try
        {
            return boxedConstant(binaryValue(binary.op, *left, *right, integerInfoOf(*binary.left)));
        }
        catch (ConstantFailure failure)
        {
            return reportConstantFailure(expr, failure);
        }
    }

    /// What's known about `expr`'s type as an integer, which is nothing for any other type.
    private IntegerInfo integerInfoOf(const Expr expr)
    {
        auto type = _exprTypes[expr.id];
        return _types.isInteger(type) ? _types.integerOf(type) : IntegerInfo.init;
    }

    private const(ConstValue)* reportConstantFailure(const Expr expr, ConstantFailure failure)
    {
        _collector.reportError(DiagnosticCode.ConstantEvaluationFailed, expr.span, failure.msg);
        return null;
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
            (const OptionType option) => optionOf(resolveType(*option.inner), type.span),
            (const FunctionType func) => _types.function_(
                func.params.map!(p => resolveType(p)).array, resolveType(*func.returnType)),
            (const UnitType _) => _types.unit,
        );
    }

    /// The option holding `inner`, or `error` (reported at `span`) if there can't be one.
    private Type optionOf(Type inner, Span span)
    {
        if (inner == _types.error) return inner;
        if (inner == _types.none) return reportUntypedNone(span);
        if (inner == _types.any)
        {
            _collector.reportError(DiagnosticCode.InvalidOptionPayload, span, "An option can't hold `Any`");
            return _types.error;
        }
        return _types.option(inner);
    }

    private Type reportUntypedNone(Span span)
    {
        _collector.reportError(DiagnosticCode.UntypedNone, span,
            "This `None` has no type to take here; annotate one, as in `val x: Int? = None`");
        return _types.error;
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
        if (returnType == _types.unit)
        {
            checkDiscarded(body, ctx);
        }
        else
        {
            check(body, returnType, ctx);
        }
    }

    /// Checks an expression whose value lands where Unit is expected, so any type will do and
    /// the value is dropped: a Unit function's body, a `while` body, an `if` without an `else`.
    /// That reaches through blocks and `if` arms, so `if c => 1 else "a"` needs no common type.
    private Type checkDiscarded(const Expr expr, BodyContext ctx)
    {
        Type dropped(Type type) => type == _types.never ? type : _types.unit;

        auto type = expr.kind.match!(
            (const BlockExpr block) {
                foreach (stmt; block.statements)
                {
                    checkStmt(stmt, ctx);
                }
                return block.value is null ? valuelessBlockType(block) : dropped(checkDiscarded(*block.value, ctx));
            },
            (const IfExpr if_) {
                if (if_.falseBody is null) return synthesizeIf(if_, expr.span, ctx);
                checkIfHead(if_, ctx);
                auto thenType = checkDiscarded(*if_.trueBody, ctx);
                auto elseType = checkDiscarded(*if_.falseBody, ctx);
                return thenType == _types.never && elseType == _types.never ? _types.never : _types.unit;
            },
            (_) => synthesize(expr, ctx),
        );
        _exprTypes[expr.id] = type;
        return type;
    }

    private void checkStmt(const Stmt stmt, BodyContext ctx)
    {
        stmt.kind.match!(
            (const VarDecl var) {
                if (var.type is null)
                {
                    auto type = synthesize(var.value, ctx);
                    _symbolTypes[SymbolId(var.id)] = type == _types.none ? reportUntypedNone(var.value.span) : type;
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
            (const InterpolatedString interpolated) => synthesizeInterpolated(interpolated, ctx),
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
            (const SomeExpr some) => optionOf(synthesize(*some.value, ctx), some.value.span),
            (const NoneLiteral _) => _types.none,
            (const PropagateExpr propagate) => synthesizePropagate(propagate, expr.span, ctx),
            (const SafeMemberAccess access) => synthesizeSafeMember(expr, access, ctx),
        );
        _exprTypes[expr.id] = type;
        return type;
    }

    /// `x?`, which returns `None` from the enclosing function, so that has to return an option.
    private Type synthesizePropagate(const PropagateExpr propagate, Span span, BodyContext ctx)
    {
        auto operandType = synthesize(*propagate.operand, ctx);
        if (operandType == _types.error) return operandType;
        if (operandType == _types.none) return reportUntypedNone(propagate.operand.span);
        if (!_types.isOption(operandType))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, propagate.operand.span,
                "`?` needs an option, got `%s`".format(_types.describe(operandType)));
            return _types.error;
        }
        if (!_types.isOption(ctx.returnType))
        {
            _collector.reportError(DiagnosticCode.InvalidPropagation, span,
                "`?` returns `None` when there's no value, but this function returns `%s`"
                    .format(_types.describe(ctx.returnType)));
        }
        return _types.optionInner(operandType);
    }

    /// `a?.b`. A field that's already an option isn't wrapped again, which is what makes
    /// `a?.b?.c` one flat option: each `?.` works on the option the one before it produced.
    private Type synthesizeSafeMember(const Expr expr, const SafeMemberAccess access, BodyContext ctx)
    {
        auto objectType = synthesize(*access.object, ctx);
        if (objectType == _types.error) return objectType;
        if (objectType == _types.none) return reportUntypedNone(access.object.span);
        if (!_types.isOption(objectType))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, access.object.span,
                "`?.` needs an option, got `%s`; a field of any other value is read with `.`"
                    .format(_types.describe(objectType)));
            return _types.error;
        }

        auto fields = _types[_types.optionInner(objectType)].match!(
            (const NominalData nominal) => _fields[nominal.decl],
            (_) => FieldInfo[].init,
        );
        foreach (i, field; fields)
        {
            if (field.name == access.member)
            {
                _fieldIndexes[expr.id] = i;
                return _types.isOption(field.type) ? field.type : _types.option(field.type);
            }
        }
        _collector.reportError(DiagnosticCode.UnknownMember, expr.span,
            "Type `%s` has no member named `%s`".format(_types.describe(objectType), access.member));
        return _types.error;
    }

    /// A hole takes whatever `print` does, so its type needs no check of its own.
    private Type synthesizeInterpolated(const InterpolatedString interpolated, BodyContext ctx)
    {
        foreach (part; interpolated.parts)
        {
            if (synthesize(part, ctx) == _types.none) reportUntypedNone(part.span);
        }
        return _types.string_;
    }

    private bool isNumeric(Type t)
    {
        return _types.isInteger(t) || t == _types.float_;
    }

    private bool isOrdered(Type t)
    {
        return isNumeric(t) || t == _types.string_;
    }

    /// What `~` joins. Arrays belong here too, and `~` will then also need to `join` the two
    /// sides' types and adapt their literals.
    private bool isConcatenable(Type t)
    {
        return t == _types.string_;
    }

    /// `UInt8(x)`: a literal is checked against the target where it's written, and any other
    /// number at runtime, where one that doesn't fit panics. `String(x)` takes whatever `print` does.
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
                "`%s` converts one %s, got %s arguments".format(_types.describe(target),
                    target == _types.string_ ? "value" : "number", call.args.length));
            return target;
        }

        auto arg = call.args[0];
        if (target == _types.string_)
        {
            if (synthesize(arg, ctx) == _types.none) reportUntypedNone(arg.span);
            return target;
        }
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
            (const NoneType _) => true,
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

    /// `Some(x)` or `None`, written out, which takes its type from what it's checked against.
    private bool isOptionSyntax(const Expr expr)
    {
        return expr.kind.match!(
            (const SomeExpr _) => true,
            (const NoneLiteral _) => true,
            _ => false,
        );
    }

    /// `a ?? b`. A `b` that's written as an option, or has `a`'s type, keeps the option, and
    /// anything else has to fit `T`, so the result is `T` and the fallback is never missing.
    private Type synthesizeCoalesce(const BinaryExpr binary, BodyContext ctx)
    {
        auto optionType = synthesize(*binary.left, ctx);
        if (!_types.isOption(optionType))
        {
            synthesize(*binary.right, ctx);
            if (optionType == _types.error) return optionType;
            if (optionType == _types.none) return reportUntypedNone(binary.left.span);
            _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                "`??` needs an option on its left, got `%s`".format(_types.describe(optionType)));
            return _types.error;
        }

        auto inner = _types.optionInner(optionType);
        if (isOptionSyntax(*binary.right))
        {
            check(*binary.right, optionType, ctx);
            return optionType;
        }
        auto rightType = synthesize(*binary.right, ctx);
        if (rightType == inner) return inner;
        if (_types.isOption(rightType) || rightType == _types.none)
        {
            coerce(*binary.right, rightType, optionType);
            return optionType;
        }
        coerce(*binary.right, rightType, inner);
        return inner;
    }

    /// Synthesizes both sides of `==` or `!=`. A side written as `Some` or `None` is checked
    /// against the other one, whichever side it's on, so `x == Some(1)` adapts the literal.
    private void synthesizeCompared(const BinaryExpr binary, out Type leftType, out Type rightType, BodyContext ctx)
    {
        if (isOptionSyntax(*binary.left) && !isOptionSyntax(*binary.right))
        {
            rightType = synthesize(*binary.right, ctx);
            leftType = _types.isOption(rightType) ? check(*binary.left, rightType, ctx) : synthesize(*binary.left, ctx);
            return;
        }
        leftType = synthesize(*binary.left, ctx);
        rightType = _types.isOption(leftType) && isOptionSyntax(*binary.right)
            ? check(*binary.right, leftType, ctx)
            : synthesize(*binary.right, ctx);
    }

    /// Whether `expr`, of type `type`, can become the option `option`.
    private bool promotes(const Expr expr, Type type, Type option)
    {
        if (!_types.isOption(option) || _types.isOption(type) && !isAssignable(type, option)) return false;
        return isAssignable(type, option) || (isIntLiteral(expr) && isNumeric(innermost(option)));
    }

    private Type innermost(Type option)
    {
        while (_types.isOption(option)) option = _types.optionInner(option);
        return option;
    }

    private Type synthesizeBinary(const BinaryExpr binary, Span span, BodyContext ctx)
    {
        if (binary.op == BinaryOp.Coalesce) return synthesizeCoalesce(binary, ctx);

        Type leftType, rightType;
        if (binary.op == BinaryOp.Equal || binary.op == BinaryOp.NotEqual)
        {
            synthesizeCompared(binary, leftType, rightType, ctx);
        }
        else
        {
            leftType = synthesize(*binary.left, ctx);
            rightType = synthesize(*binary.right, ctx);
        }
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
                if (!isOrdered(leftType))  {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                        "`%s` needs a number or a String, got `%s`".format(cast(string) binary.op, _types.describe(leftType)));
                    return _types.error;
                }
                if (!isOrdered(rightType)) {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.right.span,
                        "`%s` needs a number or a String, got `%s`".format(cast(string) binary.op, _types.describe(rightType)));
                    return _types.error;
                }
                if (leftType != rightType)
                {
                    _collector.reportError(DiagnosticCode.InvalidOperand, span,
                        "`%s` can't compare `%s` and `%s`".format(cast(string) binary.op, _types.describe(leftType), _types.describe(rightType)));
                    return _types.error;
                }
                return _types.bool_;
            case BinaryOp.Concat:
                if (!isConcatenable(leftType))  {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.left.span,
                        "`~` needs a String, got `%s`".format(_types.describe(leftType)));
                    return _types.error;
                }
                if (!isConcatenable(rightType)) {
                    _collector.reportError(DiagnosticCode.InvalidOperand, binary.right.span,
                        "`~` needs a String, got `%s`".format(_types.describe(rightType)));
                    return _types.error;
                }
                return leftType;
            case BinaryOp.And:
            case BinaryOp.Or:
                requireAssignable(leftType, _types.bool_, binary.left.span);
                requireAssignable(rightType, _types.bool_, binary.right.span);
                return _types.bool_;
            case BinaryOp.Equal:
            case BinaryOp.NotEqual:
                if (leftType == _types.none && rightType == _types.none) return reportUntypedNone(binary.left.span);
                if (leftType != rightType && promotes(*binary.right, rightType, leftType))
                {
                    rightType = coerce(*binary.right, rightType, leftType);
                }
                else if (leftType != rightType && promotes(*binary.left, leftType, rightType))
                {
                    leftType = coerce(*binary.left, leftType, rightType);
                }
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
                assert(0, "handled above");
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
        checkDiscarded(*while_.body, ctx);
        return _types.unit;
    }

    /// The condition, or the binding of an `if val`.
    private void checkIfHead(const IfExpr if_, BodyContext ctx)
    {
        if (if_.binding is null)
        {
            auto condType = synthesize(*if_.condition, ctx);
            requireAssignable(condType, _types.bool_, if_.condition.span);
            return;
        }

        auto initializer = if_.binding.value;
        auto optionType = synthesize(initializer, ctx);
        auto payload = _types.error;
        if (_types.isOption(optionType))
        {
            payload = _types.optionInner(optionType);
        }
        else if (optionType == _types.none)
        {
            reportUntypedNone(initializer.span);
        }
        else if (optionType != _types.error)
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, initializer.span,
                "`if val` needs an option, got `%s`".format(_types.describe(optionType)));
        }
        _symbolTypes[SymbolId(if_.binding.id)] = payload;
    }

    private Type synthesizeIf(const IfExpr if_, Span span, BodyContext ctx)
    {
        checkIfHead(if_, ctx);
        if (if_.falseBody is null)
        {
            checkDiscarded(*if_.trueBody, ctx);
            return _types.unit;
        }

        auto thenType = synthesize(*if_.trueBody, ctx);
        auto elseType = synthesize(*if_.falseBody, ctx);
        auto joined = join(thenType, elseType, span);
        if (joined != _types.error)
        {
            coerce(*if_.trueBody, thenType, joined);
            coerce(*if_.falseBody, elseType, joined);
        }
        return joined;
    }

    /// The type that both `a` and `b` fit, or `error` (reported at `span`) if there isn't one.
    private Type join(Type a, Type b, Span span)
    {
        if (a == _types.error || b == _types.error) return _types.error;
        if (a == _types.never) return b;
        if (b == _types.never) return a;
        if (isAssignable(a, b)) return b;
        if (isAssignable(b, a)) return a;
        if (a == _types.none) return optionOf(b, span);
        if (b == _types.none) return optionOf(a, span);

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
        // A number or option is passed down, so that a literal adapts, and a value is promoted,
        // in an `if` arm or as a block's value too.
        auto isOption = _types.isOption(expected);
        if (isNumeric(expected) || isOption)
        {
            auto passedDown = expr.kind.match!(
                (const IfExpr if_) => if_.falseBody !is null,
                (const BlockExpr _) => true,
                (const SomeExpr _) => isOption,
                _ => false,
            );
            if (passedDown)
            {
                auto type = expr.kind.match!(
                    (const IfExpr if_) => checkIf(if_, expected, ctx),
                    (const BlockExpr block) => checkBlock(expr, block, expected, ctx),
                    (const SomeExpr some) {
                        check(*some.value, _types.optionInner(expected), ctx);
                        return expected;
                    },
                    (_) => assert(0, "only ifs, blocks and Some are passed down"),
                );
                _exprTypes[expr.id] = type;
                return type;
            }
        }

        return coerce(expr, synthesize(expr, ctx), expected);
    }

    /// Fits `expr`, already found to have type `type`, to `expected`: a literal adapts and a
    /// value that isn't an option yet is promoted, and anything else has to be assignable.
    private Type coerce(const Expr expr, Type type, Type expected)
    {
        if (isNumeric(expected) && isIntLiteral(expr))
        {
            return adaptLiteral(expr, expected);
        }
        if (_types.isOption(expected))
        {
            if (isIntLiteral(expr) && isNumeric(innermost(expected)))
            {
                type = adaptLiteral(expr, innermost(expected));
            }
            auto hasValue = type != _types.error && type != _types.never;
            if (hasValue && type != expected && isAssignable(type, expected))
            {
                _promotions[expr.id] = expected;
                return expected;
            }
        }
        else if (type == _types.none && expected == _types.any)
        {
            return reportUntypedNone(expr.span);
        }
        requireAssignable(type, expected, expr.span);
        return type;
    }

    private Type checkIf(const IfExpr if_, Type expected, BodyContext ctx)
    {
        checkIfHead(if_, ctx);
        auto thenType = check(*if_.trueBody, expected, ctx);
        auto elseType = check(*if_.falseBody, expected, ctx);
        return thenType == _types.never && elseType == _types.never ? _types.never : expected;
    }

    private Type checkBlock(const Expr expr, const BlockExpr block, Type expected, BodyContext ctx)
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
        // A Unit block expected to be a `Unit?` is promoted, so its own type stays Unit.
        auto type = valuelessBlockType(block);
        coerce(expr, type, expected);
        return type;
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
        if (from == _types.none) return _types.isOption(to);
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