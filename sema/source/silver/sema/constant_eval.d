/// Evaluating top-level constants, once every body is checked, since a literal's type isn't
/// final until then. What would panic at runtime is reported here instead.
module silver.sema.constant_eval;

import std.format : format;
import std.sumtype;

import silver.ast;
import silver.sema.constant;
import silver.sema.resolve;
import silver.sema.type;

/// The value of each constant in `modules` that has one. `unevaluable` are the constants whose
/// initializers already have errors, and `negatedLiterals` the integer literals under a `-`.
package ConstValue[Id!ConstDecl] evaluateConstants(M)(M modules, TypeTable types, const Type[Id!Expr] exprTypes,
    const Resolution resolutions, const bool[Id!ConstDecl] unevaluable, const bool[Id!Expr] negatedLiterals,
    Collector collector)
{
    auto evaluator = ConstantEvaluator(types, exprTypes, resolutions, unevaluable, negatedLiterals, collector);
    foreach (mod; modules)
    {
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const ConstDecl c) => evaluator.evaluateConstant(c.id),
                (_) {},
            );
        }
    }
    return evaluator._constants;
}

private struct ConstantEvaluator
{
    private TypeTable _types;
    private const Type[Id!Expr] _exprTypes;
    private const Resolution _resolutions;
    private const bool[Id!ConstDecl] _unevaluable;
    private const bool[Id!Expr] _negatedLiterals;
    private Collector _collector;
    private ConstValue[Id!ConstDecl] _constants;
    /// True while a constant's dependencies are being evaluated, and false once they're done.
    private bool[Id!ConstDecl] _evaluating;
    private bool[Id!ConstDecl] _cycleReported;

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

}
