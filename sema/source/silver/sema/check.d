module silver.sema.check;

import std.algorithm;
import std.array;
import std.conv;
import std.range : repeat;
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
    size_t[][][Id!Expr] updatePaths;
    ConstValue[Id!ConstDecl] constants;
    Type[Id!Expr] promotions;
    bool[Id!Expr] arrayLengths;
    const(Expr)[][Id!Expr] concatOperands;
    const(CallExpr)*[Id!Expr] methodCalls;
    Id!FunctionDecl[Id!Expr] methodCallees;
    Type[Id!TypeDecl] nominalTypes;
    Type[][Id!TypeDecl] members;
    Type[Id!Expr] constructedMembers;
    Type[Id!Pattern] patternSubjects;
    size_t[Id!Pattern] patternMembers;
    Id!TypeDecl[Id!Pattern] patternConstructors;
}

/// A pattern as coverage sees it: a head (null for one that matches anything) and what's under it.
private struct CoveragePattern
{
    string head;
    CoveragePattern[] args;
}

/// One of the shapes a type's values come in, and the types of what's inside it.
private struct PatternHead
{
    string key;
    string label;
    const(Type)[] args;

    string render(const(string)[] parts) const
    {
        return label ~ (parts.length > 0 ? "(" ~ parts.join(", ") ~ ")" : "");
    }
}

/// Where the checker is inside a function body. Passed by value, so a nested body (a lambda)
/// gets its own copy and the enclosing one is untouched when it returns.
private struct BodyContext
{
    /// What `return` checks against: the innermost enclosing function's return type.
    Type returnType;
    /// Whether this is in the body of a loop, so `break` and `continue` have one to act on.
    bool inLoop;
    /// Collects what the body returns when `returnType` is still to be inferred, or null.
    InferredReturn* inferred;
}

/// What a lambda with no known return type was found to return.
private struct InferredReturn
{
    const(Expr)[] values;
    Type[] types;
    /// Each postfix `?`, which returns `None`.
    Span[] nones;
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
    private Type[Id!AliasDecl] _aliasTypes;
    private FieldInfo[][Id!TypeDecl] _fields;
    private size_t[Id!Expr] _fieldIndexes;
    private size_t[][][Id!Expr] _updatePaths;
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
    /// The prelude's `length`, the one function sema types itself.
    private Id!FunctionDecl _arrayLength;
    private bool[Id!Expr] _arrayLengths;
    private const(CallExpr)*[Id!Expr] _methodCalls;
    private Id!FunctionDecl[Id!Expr] _methodCallees;
    private const(Expr)[][Id!Expr] _concatOperands;
    /// What each sum's values can be, in declaration order.
    private Type[][Id!TypeDecl] _members;
    /// The sum that declared each member it owns, which is what its constructor produces.
    private Type[Id!TypeDecl] _owners;
    /// For a construction that produces its owner, the member it builds on the way.
    private Type[Id!Expr] _constructedMembers;
    private Type[Id!Pattern] _patternSubjects;
    private size_t[Id!Pattern] _patternMembers;
    private Id!TypeDecl[Id!Pattern] _patternConstructors;

    Typing checkProgram(const Program program)
    {
        auto programModules = program.sortedModules;
        foreach (mod; programModules)
        {
            if (mod.name != "prelude") continue;
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const FunctionDecl f) {
                        if (f.kind == FunctionKind.intrinsic && f.name == "length") _arrayLength = f.id;
                    },
                    (_) {},
                );
            }
        }

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

        // Before anything that can name one, and even if nothing does, so a bad target is reported.
        foreach (mod; programModules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!(
                    (const AliasDecl a) { aliasType(a.id); },
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
                    (const AliasDecl _) {},
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
                    (const AliasDecl _) {},
                    (const ImportStmt _) {},
                );
            }
        }

        checkInhabited(programModules);

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

        return Typing(_types, _exprTypes, _symbolTypes, _fields, _fieldIndexes, _updatePaths, _constants, _promotions,
            _arrayLengths, _concatOperands, _methodCalls, _methodCallees, _nominalTypes, _members, _constructedMembers,
            _patternSubjects, _patternMembers, _patternConstructors);
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
            (const ArrayType array) => arrayOf(resolveType(*array.element), type.span),
            (const FunctionType func) => _types.function_(
                func.params.map!(p => resolveType(p)).array, resolveType(*func.returnType), func.mutableParams),
            (const UnitType _) => _types.unit,
            (const TupleType tuple) => tupleOf(tuple.elements.map!(e => resolveType(e)).array, tuple.elements),
        );
    }

    /// The tuple of `elements`, or `error` if one of them is, reported at its type expression in
    /// `written` when it's `Any`. Nothing that synthesizes a tuple can give it an `Any`.
    private Type tupleOf(Type[] elements, const(TypeExpr)[] written = null)
    {
        foreach (i, element; elements)
        {
            if (element == _types.any && written.length > 0)
            {
                _collector.reportError(DiagnosticCode.InvalidTupleElement, written[i].span, "A tuple can't hold `Any`");
                elements[i] = _types.error;
            }
        }
        if (elements.canFind(_types.error)) return _types.error;
        return _types.tuple(elements);
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

    /// The array of `element`, or `error` (reported at `span`) if there can't be one.
    private Type arrayOf(Type element, Span span)
    {
        if (element == _types.error) return element;
        if (element == _types.any)
        {
            _collector.reportError(DiagnosticCode.InvalidArrayElement, span, "An array can't hold `Any`");
            return _types.error;
        }
        return _types.array(element);
    }

    private Type reportUntypedNone(Span span)
    {
        _collector.reportError(DiagnosticCode.UntypedNone, span,
            "This `None` has no type to take here; annotate one, as in `val x: Int? = None`");
        return _types.error;
    }

    private Type reportUntypedEmptyArray(Span span)
    {
        _collector.reportError(DiagnosticCode.UntypedEmptyArray, span,
            "This `[]` has no type to take here; annotate one, as in `val x: [Int] = []`");
        return _types.error;
    }

    /// Reports a value of `type` that nothing gives a type to, if it's one: a bare `None` or `[]`.
    private Type requireTyped(Type type, Span span)
    {
        if (type == _types.none) return reportUntypedNone(span);
        if (type == _types.emptyArray) return reportUntypedEmptyArray(span);
        return type;
    }

    private Type resolveNamedType(const TypeExpr typeExpr)
    {
        auto symbol = typeExpr.id in _resolutions.typeResolutions;
        if (symbol is null) return _types.error;

        return (*symbol).match!(
            (const Builtin builtIn) => builtinType(builtIn),
            (const Id!TypeDecl decl) => _nominalTypes[decl],
            (const Id!AliasDecl decl) => aliasType(decl),
        );
    }

    private Type aliasType(Id!AliasDecl id)
    {
        if (auto known = id in _aliasTypes) return *known;
        // A recursive alias, which name resolution reported, stops here.
        _aliasTypes[id] = _types.error;
        auto type = resolveType(_resolutions.declarations.aliases[id].target);
        _aliasTypes[id] = type;
        return type;
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
        auto returnType = resolveType(func.returnType);
        if (func.kind != FunctionKind.ordinary)
        {
            foreach (param; func.params.filter!(p => p.mutable))
            {
                _collector.reportError(DiagnosticCode.MutableNativeParameter, param.nameSpan, "%s function can't take a `mutable` parameter"
                    .format(func.kind == FunctionKind.native ? "A native" : "An intrinsic"));
            }
        }
        if (func.kind == FunctionKind.native)
        {
            foreach (i, param; func.params)
            {
                requireNativeType(params[i], param.type.span, false);
            }
            requireNativeType(returnType, func.returnType.span, true);
        }
        _symbolTypes[SymbolId(func.id)] = _types.function_(params, returnType, func.params.map!(p => p.mutable).array);
    }

    /// Reports a type in a native's signature that has no C equivalent.
    private void requireNativeType(Type type, Span span, bool isReturn)
    {
        if (type == _types.error || _types.isInteger(type) || type == _types.float_ || type == _types.bool_) return;
        if (isReturn && (type == _types.unit || type == _types.never)) return;
        _collector.reportError(DiagnosticCode.InvalidNativeType, span,
            "`%s` can't cross into C; a native function takes integers, `Float` and `Bool`%s".format(_types.describe(type),
                isReturn ? ", and can also return `Unit` or `Never`" : ""));
    }

    private void declareSum(const TypeDecl decl)
    {
        auto sum = _nominalTypes[decl.id];
        _fields[decl.id] = null;
        // Only its members can be built. Using the name as a value is reported where it's used.
        _symbolTypes[SymbolId(decl.id)] = _types.error;

        Type[] members;
        foreach (member; decl.members)
        {
            auto type = resolveType(member.type);
            if (type == _types.error) continue;
            string problem;
            if (type == _types.any || type == _types.never) problem = "A sum can't have `%s` as a member".format(_types.describe(type));
            else if (type == sum) problem = "A sum can't be a member of itself";
            else if (members.canFind(type)) problem = "`%s` is already a member of this sum".format(_types.describe(type));
            if (problem !is null)
            {
                _collector.reportError(DiagnosticCode.InvalidSumMember, member.type.span, problem);
                continue;
            }
            members ~= type;
            if (!member.owned) continue;
            _resolutions.typeResolutions[member.type.id].match!(
                (const Id!TypeDecl owned) { _owners[owned] = sum; },
                (_) {},
            );
        }
        _members[decl.id] = members;
    }

    private void declareConstructor(const TypeDecl decl)
    {
        if (decl.members.length > 0) return declareSum(decl);

        auto fields = decl.fields.map!(f => FieldInfo(f.name, resolveType(f.type))).array;
        _fields[decl.id] = fields;

        auto declared = _nominalTypes[decl.id];
        _symbolTypes[SymbolId(decl.id)] = fields.length == 0
            ? declared
            : _types.function_(fields.map!(f => f.type).array, declared);
    }


    /// Reports the types no value can ever have, such as `type A(a: A)`: the ones that can be built
    /// are found from those needing nothing else, and whatever's left can't finish building itself.
    private void checkInhabited(M)(M modules)
    {
        const(TypeDecl)[] decls;
        foreach (mod; modules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!((const TypeDecl t) { decls ~= t; }, (_) {});
            }
        }

        bool[Id!TypeDecl] buildable;
        bool canBuild(Type type)
        {
            return _types[type].match!(
                (const NominalData nominal) => (nominal.decl in buildable) !is null,
                (const TupleData tuple) => tuple.elements.all!(e => canBuild(e)),
                _ => true,
            );
        }
        bool canBuildDecl(const TypeDecl decl)
        {
            if (decl.members.length == 0) return _fields[decl.id].all!(f => canBuild(f.type));
            auto members = _members[decl.id];
            return members.length == 0 || members.any!(m => canBuild(m));
        }

        for (auto changed = true; changed;)
        {
            changed = false;
            foreach (decl; decls.filter!(d => d.id !in buildable))
            {
                if (!canBuildDecl(decl)) continue;
                buildable[decl.id] = true;
                changed = true;
            }
        }

        foreach (decl; decls.filter!(d => d.id !in buildable))
        {
            if (auto owner = decl.id in _owners)
            {
                if (!canBuild(*owner)) continue;
            }
            auto reason = "none of its members can be";
            if (decl.members.length == 0)
            {
                auto field = _fields[decl.id].find!(f => !canBuild(f.type)).front;
                reason = "its field `%s: %s` can't be".format(field.name, _types.describe(field.type));
            }
            _collector.reportError(DiagnosticCode.UninhabitedType, decl.nameSpan,
                "No value of `%s` can ever be built, because %s; an option or array field would end the recursion"
                    .format(decl.name, reason));
        }
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

    /// The function type of `lambda`, checking its body. `expected` supplies what it leaves out.
    private Type typeLambda(const Expr expr, const Lambda lambda, const(FunctionData)* expected)
    {
        auto wrongCount = expected !is null && expected.params.length != lambda.params.length;
        if (wrongCount)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
                "This lambda has %s parameters, where %s are expected".format(lambda.params.length, expected.params.length));
            expected = null;
        }

        Type[] params;
        bool[] mutables;
        foreach (i, param; lambda.params)
        {
            auto type = _types.error;
            if (param.annotated)
            {
                type = resolveType(param.type);
            }
            else if (expected !is null)
            {
                type = expected.params[i];
            }
            else if (!wrongCount)
            {
                _collector.reportError(DiagnosticCode.UntypedLambdaParameter, param.nameSpan,
                    "Nothing here says what type `%s` is; write `%s: Type`".format(param.name, param.name));
            }
            _symbolTypes[SymbolId(param.id)] = type;
            params ~= type;
            mutables ~= param.mutable;
        }

        Type ret = lambda.returnType !is null ? resolveType(*lambda.returnType)
            : expected !is null ? expected.ret : Type.init;
        if (ret == Type.init)
        {
            ret = inferReturn(*lambda.body);
        }
        else
        {
            if (lambda.self.isValid) _symbolTypes[SymbolId(lambda.self)] = _types.function_(params, ret, mutables);
            checkBody(*lambda.body, ret);
        }

        auto failed = wrongCount || ret == _types.error || params.canFind(_types.error);
        auto type = failed ? _types.error : _types.function_(params, ret, mutables);
        _exprTypes[expr.id] = type;
        return type;
    }

    /// The common type of everything `body` can return, each promoted to it as needed.
    private Type inferReturn(const Expr body)
    {
        InferredReturn inferred;
        auto bodyType = synthesize(body, BodyContext(_types.error, false, &inferred));
        inferred.values ~= body;
        inferred.types ~= bodyType;

        auto joined = _types.never;
        foreach (i, type; inferred.types)
        {
            joined = join(joined, type, inferred.values[i].span, "Return values");
        }
        foreach (span; inferred.nones)
        {
            joined = join(joined, _types.none, span, "Return values");
        }
        joined = requireTyped(joined, body.span);
        if (joined == _types.error) return joined;

        foreach (i, type; inferred.types)
        {
            if (type != _types.never && type != joined) coerce(inferred.values[i], type, joined);
        }
        return joined;
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
            (const MatchExpr match_) => checkDiscardedMatch(match_, expr.span, ctx),
            (_) => synthesize(expr, ctx),
        );
        _exprTypes[expr.id] = type;
        return type;
    }

    private void checkStmt(const Stmt stmt, BodyContext ctx)
    {
        stmt.kind.match!(
            (const VarDecl var) => checkBinding(var, var.value, ctx),
            (const PatternDecl decl) => checkPattern(decl.pattern, decl.value, ctx),
            (const AssignStmt assign) {
                auto lhsType = synthesize(assign.target, ctx);
                if (lhsType != _types.error) checkAssignable(assign.target);
                check(assign.value, lhsType, ctx);
            },
            // Only a block's last expression is its value, so anything else here was dropped by
            // mistake, as with `val y = x` and `-1` from a `- 1` that started a line.
            (const ExprStmt expr) {
                auto type = synthesize(expr.expr, ctx);
                if (type != _types.unit && type != _types.never && type != _types.error)
                {
                    _collector.reportError(DiagnosticCode.UnusedValue, expr.expr.span,
                        "This value of type `%s` is unused; bind it with `val`, or drop it with `_ = ...`"
                            .format(_types.describe(type)));
                }
            },
            // A nested `def` lowers to a VarDecl, and name resolution reports a nested native or intrinsic.
            (const FunctionDecl _) {},
            (const ReturnStmt ret) {
                if (ctx.inferred is null)
                {
                    check(ret.value, ctx.returnType, ctx);
                    return;
                }
                auto type = synthesize(ret.value, ctx);
                ctx.inferred.values ~= ret.value;
                ctx.inferred.types ~= type;
            },
            (const BreakStmt _) => requireLoop("break", stmt.span, ctx),
            (const ContinueStmt _) => requireLoop("continue", stmt.span, ctx),
        );
    }

    /// `val binding = value`, or a binding in a pattern given its part of a tuple literal.
    private void checkBinding(const VarDecl binding, const Expr value, BodyContext ctx)
    {
        if (binding.type is null)
        {
            // A discard keeps no value, so a `None` or `[]` needs no type to be dropped.
            auto type = synthesize(value, ctx);
            _symbolTypes[SymbolId(binding.id)] = binding.name == discardName ? type : requireTyped(type, value.span);
        }
        else
        {
            auto type = resolveType(*binding.type);
            check(value, type, ctx);
            _symbolTypes[SymbolId(binding.id)] = type;
        }
    }

    /// `val pattern = value`. A tuple literal of the pattern's size is taken apart element by
    /// element, each as its own `val`. Any other value is checked against the pattern's type when
    /// every binding has one, so literals in it still adapt, and synthesized otherwise.
    private void checkPattern(const Pattern pattern, const Expr value, BodyContext ctx)
    {
        if (auto literal = elementwise(pattern, value))
        {
            auto parts = pattern.kind.match!(
                (const TuplePattern tuple) => tuple.elements,
                (_) => assert(0, "only a tuple pattern goes element by element"),
            );
            Type[] types;
            foreach (i, element; literal.elements)
            {
                checkPattern(parts[i], element, ctx);
                types ~= _promotions.get(element.id, _exprTypes.get(element.id, _types.error));
            }
            // Never built, so only recorded for completeness; a dropped `None` leaves it untyped.
            _exprTypes[value.id] = types.canFind(_types.none) || types.canFind(_types.emptyArray)
                ? _types.error : tupleOf(types);
            return;
        }

        pattern.kind.match!(
            (const VarDecl binding) => checkBinding(binding, value, ctx),
            (const TuplePattern _) {
                auto expected = annotatedType(pattern);
                if (expected == Type.init)
                {
                    bindPattern(pattern, requireTyped(synthesize(value, ctx), value.span));
                }
                else
                {
                    check(value, expected, ctx);
                    bindPattern(pattern, expected);
                }
            },
            (_) { assert(0, "the grammar only allows names and tuples in a `val`"); },
        );
    }

    /// The type of what `pattern` takes apart, or `Type.init` if a binding in it has no annotation.
    /// Each annotated binding is given its type on the way.
    private Type annotatedType(const Pattern pattern)
    {
        return pattern.kind.match!(
            (const VarDecl binding) {
                if (binding.type is null) return Type.init;
                auto type = resolveType(*binding.type);
                _symbolTypes[SymbolId(binding.id)] = type;
                return type;
            },
            (const TuplePattern tuple) {
                // Every element, so each annotation is resolved once whatever comes after it.
                auto types = tuple.elements.map!(e => annotatedType(e)).array;
                return types.canFind(Type.init) ? Type.init : tupleOf(types);
            },
            (_) => assert(0, "the grammar only allows names and tuples in a `val`"),
        );
    }

    /// Gives each binding in `pattern` its part of a `type` value. An annotated binding already has
    /// its type, which the part has to be exactly, since a value doesn't convert.
    private void bindPattern(const Pattern pattern, Type type)
    {
        auto unknown = type == _types.error || type == _types.never;
        pattern.kind.match!(
            (const VarDecl binding) {
                if (binding.type is null)
                {
                    _symbolTypes[SymbolId(binding.id)] = type;
                    return;
                }
                auto annotated = _symbolTypes[SymbolId(binding.id)];
                if (type != annotated && !unknown && annotated != _types.error)
                {
                    _collector.reportError(DiagnosticCode.TypeMismatch, binding.type.span,
                        "This part of the value is `%s`, which doesn't convert to `%s`"
                            .format(_types.describe(type), _types.describe(annotated)));
                }
            },
            (const TuplePattern tuple) {
                auto count = tuple.elements.length;
                const(Type)[] parts;
                if (_types.isTuple(type) && _types.tupleElements(type).length == count)
                {
                    parts = _types.tupleElements(type);
                }
                else
                {
                    if (!unknown)
                    {
                        _collector.reportError(DiagnosticCode.PatternMismatch, pattern.span, _types.isTuple(type)
                            ? "This pattern takes apart %s values, but `%s` has %s"
                                .format(count, _types.describe(type), _types.tupleElements(type).length)
                            : "This pattern takes apart a tuple, but the value is `%s`".format(_types.describe(type)));
                    }
                    parts = (type == _types.never ? _types.never : _types.error).repeat(count).array;
                }
                foreach (i, element; tuple.elements)
                {
                    bindPattern(element, parts[i]);
                }
            },
            (_) { assert(0, "the grammar only allows names and tuples in a `val`"); },
        );
    }

    private void requireLoop(string keyword, Span span, BodyContext ctx)
    {
        if (ctx.inLoop) return;
        _collector.reportError(DiagnosticCode.JumpOutsideLoop, span,
            "`%s` needs to be in the body of a loop".format(keyword));
    }

    /// Reports `target` unless it's a mutable binding or a chain of fields rooted at one. `use` is
    /// what's being done to it, for the message: "assigned to", or "passed as `mutable`".
    private bool checkAssignable(const Expr target, string use = "assigned to")
    {
        return target.kind.match!(
            (const Identifier _) => checkBindingMutable(target, use),
            (const MemberAccess access) => checkAssignable(*access.object, use),
            (const IndexExpr _) {
                _collector.reportError(DiagnosticCode.InvalidAssignmentTarget, target.span,
                    "An array never changes, so its elements can't be %s; rebind the whole array".format(use));
                return false;
            },
            (_) => reportInvalidAssignment(target, use),
        );
    }

    private bool checkBindingMutable(const Expr name, string use)
    {
        auto symbol = name.id in _resolutions.resolutions;
        // A package prefix like `std` in `std.math.pow = f` has no resolution of its own.
        if (symbol is null) return reportInvalidAssignment(name, use);
        return (*symbol).match!(
            (const Id!VarDecl local) {
                auto decl = _resolutions.declarations.locals[local];
                if (decl.mutable) return true;
                _collector.reportError(DiagnosticCode.AssignToImmutable, name.span,
                    "`%s` is not mutable and cannot be %s; declare it with `mutable val`".format(decl.name, use));
                return false;
            },
            (const Id!Param param) {
                auto decl = _resolutions.declarations.params[param];
                if (decl.mutable) return true;
                _collector.reportError(DiagnosticCode.AssignToImmutable, name.span,
                    "`%s` is a parameter, which is not mutable and cannot be %s; declare it `mutable %s`"
                        .format(decl.name, use, decl.name));
                return false;
            },
            (_) => reportInvalidAssignment(name, use),
        );
    }

    private bool reportInvalidAssignment(const Expr target, string use)
    {
        _collector.reportError(DiagnosticCode.InvalidAssignmentTarget, target.span,
            "Only a `mutable val`, a `mutable` parameter or one of their fields can be %s".format(use));
        return false;
    }

    /// The place `target` names as its binding and then field names, for telling whether two
    /// writes overlap. Only called on a target `checkAssignable` accepted.
    private string[] placePath(const Expr target)
    {
        return target.kind.match!(
            (const Identifier _) => [_resolutions.resolutions[target.id].to!string],
            (const MemberAccess access) => placePath(*access.object) ~ access.member,
            (_) => assert(0, "only names and fields are places"),
        );
    }

    /// Reports each of `paths` that is, or is inside or around, one before it.
    private void reportOverlaps(const(string[])[] paths, const(Span)[] spans, string message)
    {
        foreach (i, path; paths)
        {
            foreach (earlier; paths[0 .. i])
            {
                auto shorter = min(path.length, earlier.length);
                if (path[0 .. shorter] != earlier[0 .. shorter]) continue;
                _collector.reportError(DiagnosticCode.OverlappingWrites, spans[i], message);
                break;
            }
        }
    }

    /// The declaration `expr` builds a value of, or an invalid ID if it doesn't: a constructor call,
    /// or the name of a marker.
    private Id!TypeDecl constructedDecl(const Expr expr)
    {
        if (auto type = expr.id in _resolutions.constructions) return *type;
        auto symbol = expr.id in _resolutions.resolutions;
        if (symbol is null) return Id!TypeDecl.init;
        return (*symbol).match!(
            (const Id!TypeDecl type) {
                Id!TypeDecl marker;
                if (_resolutions.declarations.types[type].fields.length == 0) marker = type;
                return marker;
            },
            _ => Id!TypeDecl.init,
        );
    }

    private const(Type)[] membersOf(Type type)
    {
        return _types[type].match!(
            (const NominalData nominal) => _members.get(nominal.decl, null),
            _ => (Type[]).init,
        );
    }

    private bool isSum(Type type)
    {
        return membersOf(type).length > 0;
    }

    private bool isOwnedMember(Type type)
    {
        return _types[type].match!((const NominalData nominal) => (nominal.decl in _owners) !is null, _ => false);
    }

    /// The type of `expr`, where nothing asks for a particular one. A constructor of a member its
    /// sum owns produces the sum.
    private Type synthesize(const Expr expr, BodyContext ctx)
    {
        auto type = synthesizeExact(expr, ctx);
        if (type == _types.error) return type;
        auto sum = constructedDecl(expr) in _owners;
        if (sum is null) return type;

        _constructedMembers[expr.id] = type;
        _exprTypes[expr.id] = *sum;
        return *sum;
    }

    private Type synthesizeExact(const Expr expr, BodyContext ctx)
    {
        // "what type is this?"
        _constructedMembers.remove(expr.id);

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
            (const BinaryExpr binary) => binary.op == BinaryOp.Concat || binary.op == BinaryOp.Append
                ? synthesizeConcat(expr, binary, ctx)
                : synthesizeBinary(binary, expr.span, ctx),
            (const CallExpr call) => expr.id in _resolutions.conversions
                ? synthesizeConversion(call, builtinType(_resolutions.conversions[expr.id]), expr.span, ctx)
                : isArrayLengthName(*call.callee)
                    ? synthesizeLength(expr, call, ctx)
                    : isMethodCall(expr.id, *call.callee)
                        ? synthesizeMethodCall(expr, call, ctx)
                        : synthesizeCall(call, expr.span, ctx),
            (const MemberAccess member) => synthesizeMemberAccess(expr, member, ctx),
            (const WithExpr with_) => synthesizeWith(expr, with_, ctx),
            (const WhileExpr while_) => synthesizeWhile(while_, expr.span, ctx),
            (const ForExpr for_) => synthesizeFor(for_, ctx),
            (const IfExpr if_) => synthesizeIf(if_, expr.span, ctx),
            (const BlockExpr block) => synthesizeBlock(block, expr.span, ctx),
            (const UnitLiteral _) => _types.unit,
            (const Identifier _) => synthesizeIdentifier(expr),
            (const SomeExpr some) => optionOf(synthesize(*some.value, ctx), some.value.span),
            (const NoneLiteral _) => _types.none,
            (const PropagateExpr propagate) => synthesizePropagate(propagate, expr.span, ctx),
            (const SafeMemberAccess access) => synthesizeSafeMember(expr, access, ctx),
            (const ArrayLiteral literal) => synthesizeArrayLiteral(literal, ctx),
            (const MapLiteral literal) => synthesizeMapLiteral(literal, expr.span, ctx),
            (const IndexExpr index) => synthesizeIndex(index, ctx),
            (const RangeExpr range) => synthesizeBareRange(range, expr.span, ctx),
            (const TupleLiteral literal) => tupleOf(literal.elements.map!(e => requireTyped(synthesize(e, ctx), e.span)).array),
            (const MatchExpr match_) => synthesizeMatch(match_, expr.span, ctx),
            (const Lambda lambda) => typeLambda(expr, lambda, null),
        );
        _exprTypes[expr.id] = type;
        return type;
    }

    private Type synthesizeArrayLiteral(const ArrayLiteral literal, BodyContext ctx)
    {
        if (literal.elements.length == 0) return _types.emptyArray;

        auto types = literal.elements.map!(e => synthesize(e, ctx)).array;
        auto joined = types[0];
        foreach (i, type; types[1 .. $])
        {
            joined = join(joined, type, literal.elements[i + 1].span, "Array elements");
        }
        joined = requireTyped(joined, literal.elements[0].span);
        if (joined == _types.error) return joined;

        foreach (i, element; literal.elements)
        {
            coerce(element, types[i], joined);
        }
        return arrayOf(joined, literal.elements[0].span);
    }

    private Type synthesizeMapLiteral(const MapLiteral literal, Span span, BodyContext ctx)
    {
        foreach (i, key; literal.keys)
        {
            synthesize(key, ctx);
            synthesize(literal.values[i], ctx);
        }
        _collector.reportError(DiagnosticCode.NotSupportedYet, span, "Maps aren't supported yet");
        return _types.error;
    }

    /// `xs[i]`, or `xs[a..b]`, whose range is part of the slice rather than a value.
    private Type synthesizeIndex(const IndexExpr index, BodyContext ctx)
    {
        auto objectType = requireTyped(synthesize(*index.object, ctx), index.object.span);
        auto range = asRange(index.index);
        if (range is null)
        {
            checkConsumedInteger(*index.index, ctx);
        }
        else
        {
            checkConsumedInteger(*range.start, ctx);
            checkConsumedInteger(*range.end, ctx);
            _exprTypes[index.index.id] = objectType;
        }
        if (objectType == _types.error) return objectType;
        if (!_types.isArray(objectType))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, index.object.span,
                "Only an array can be indexed, got `%s`".format(_types.describe(objectType)));
            return _types.error;
        }
        return range is null ? _types.arrayElement(objectType) : objectType;
    }

    /// An operand that's range-checked and doesn't affect the result's type, so any integer will do.
    private void checkConsumedInteger(const Expr expr, BodyContext ctx)
    {
        auto type = synthesize(expr, ctx);
        if (type == _types.error || type == _types.never || _types.isInteger(type)) return;
        _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
            "Expected an integer, got `%s`".format(_types.describe(type)));
    }

    private Type synthesizeBareRange(const RangeExpr range, Span span, BodyContext ctx)
    {
        synthesize(*range.start, ctx);
        synthesize(*range.end, ctx);
        _collector.reportError(DiagnosticCode.NotSupportedYet, span, "A range can only slice an array or be looped over by `for` for now");
        return _types.error;
    }

    private bool isArrayLengthName(const Expr callee)
    {
        if (!_arrayLength.isValid) return false;
        if (auto symbol = callee.id in _resolutions.resolutions)
        {
            return (*symbol).match!((const Id!FunctionDecl f) => f == _arrayLength, _ => false);
        }
        return false;
    }

    /// `checked` is how many leading arguments have been synthesized already.
    private Type synthesizeLength(const Expr expr, const CallExpr call, BodyContext ctx, size_t checked = 0)
    {
        rejectMutableArguments(call);
        _exprTypes[call.callee.id] = _symbolTypes[SymbolId(_arrayLength)];
        if (call.args.length != 1)
        {
            foreach (arg; call.args[checked .. $])
            {
                synthesize(arg, ctx);
            }
            _collector.reportError(DiagnosticCode.WrongArgumentCount, expr.span,
                "`length` takes one array, got %s arguments".format(call.args.length));
            return _types.int_;
        }

        auto arg = call.args[0];
        auto argType = requireTyped(checked > 0 ? _exprTypes[arg.id] : synthesize(arg, ctx), arg.span);
        if (argType != _types.error && !_types.isArray(argType))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, arg.span,
                "`length` needs an array, got `%s`".format(_types.describe(argType)));
        }
        _arrayLengths[expr.id] = true;
        return _types.int_;
    }

    /// `length` is typed where it's called, since no function type can say what it takes.
    private Type requireNotArrayLength(SymbolId symbol, Span span)
    {
        auto isSumName = symbol.match!(
            (const Id!TypeDecl type) => _resolutions.declarations.types[type].members.length > 0,
            _ => false,
        );
        if (isSumName)
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, span,
                "A sum type has no value of its own; build one of its members");
            return _types.error;
        }

        auto isLength = _arrayLength.isValid
            && symbol.match!((const Id!FunctionDecl f) => f == _arrayLength, _ => false);
        if (!isLength) return symbolType(symbol);
        _collector.reportError(DiagnosticCode.NotSupportedYet, span, "`length` can only be called for now");
        return _types.error;
    }

    /// An array literal, or a `~` of them: what takes its element type from what it's checked against.
    private bool isArraySyntax(const Expr expr)
    {
        return expr.kind.match!(
            (const ArrayLiteral _) => true,
            (const BinaryExpr binary) => binary.op == BinaryOp.Concat
                && isArraySyntax(*binary.left) && isArraySyntax(*binary.right),
            _ => false,
        );
    }

    private void recordConcat(const Expr expr, const BinaryExpr binary)
    {
        if (binary.op == BinaryOp.Concat)
        {
            _concatOperands[expr.id] = concatChain(*binary.left) ~ concatChain(*binary.right);
        }
    }

    private const(Expr)[] concatChain(const Expr expr)
    {
        return expr.kind.match!(
            (const BinaryExpr binary) => binary.op == BinaryOp.Concat
                ? concatChain(*binary.left) ~ concatChain(*binary.right)
                : [expr],
            _ => [expr],
        );
    }

    /// `a ~ b` or `a ~= b`. A side that's written as an array takes its element type from the other.
    private Type synthesizeConcat(const Expr expr, const BinaryExpr binary, BodyContext ctx)
    {
        recordConcat(expr, binary);
        Type leftType, rightType;
        if (isArraySyntax(*binary.left) && !isArraySyntax(*binary.right))
        {
            rightType = synthesize(*binary.right, ctx);
            leftType = _types.isArray(rightType) ? check(*binary.left, rightType, ctx) : synthesize(*binary.left, ctx);
        }
        else
        {
            leftType = synthesize(*binary.left, ctx);
            rightType = _types.isArray(leftType) && isArraySyntax(*binary.right)
                ? check(*binary.right, leftType, ctx)
                : synthesize(*binary.right, ctx);
        }
        if (leftType == _types.error || rightType == _types.error) return _types.error;
        if (leftType == _types.emptyArray && rightType == _types.emptyArray)
        {
            return reportUntypedEmptyArray(binary.left.span);
        }

        foreach (side, type; [leftType, rightType])
        {
            if (!isConcatenable(type))
            {
                _collector.reportError(DiagnosticCode.InvalidOperand, side == 0 ? binary.left.span : binary.right.span,
                    "`%s` needs a String or an array, got `%s`".format(cast(string) binary.op, _types.describe(type)));
                return _types.error;
            }
        }
        if (leftType == rightType) return leftType;
        if (isAssignable(leftType, rightType))
        {
            coerce(*binary.left, leftType, rightType);
            return rightType;
        }
        if (isAssignable(rightType, leftType))
        {
            coerce(*binary.right, rightType, leftType);
            return leftType;
        }
        _collector.reportError(DiagnosticCode.InvalidOperand, expr.span,
            "`%s` can't combine `%s` and `%s`".format(cast(string) binary.op,
                _types.describe(leftType), _types.describe(rightType)));
        return _types.error;
    }

    /// `x?`, which returns `None` from the enclosing function, so that has to return an option.
    private Type synthesizePropagate(const PropagateExpr propagate, Span span, BodyContext ctx)
    {
        auto operandType = requireTyped(synthesize(*propagate.operand, ctx), propagate.operand.span);
        if (operandType == _types.error) return operandType;
        if (!_types.isOption(operandType))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, propagate.operand.span,
                "`?` needs an option, got `%s`".format(_types.describe(operandType)));
            return _types.error;
        }
        if (ctx.inferred !is null)
        {
            ctx.inferred.nones ~= span;
        }
        else if (!_types.isOption(ctx.returnType))
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
        auto objectType = requireTyped(synthesize(*access.object, ctx), access.object.span);
        if (objectType == _types.error) return objectType;
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
            requireTyped(synthesize(part, ctx), part.span);
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

    /// What `~` joins.
    private bool isConcatenable(Type t)
    {
        return t == _types.string_ || t == _types.emptyArray || _types.isArray(t);
    }

    /// `UInt8(x)`: a literal is checked against the target where it's written, and any other
    /// number at runtime, where one that doesn't fit panics. `String(x)` takes whatever `print` does.
    private Type synthesizeConversion(const CallExpr call, Type target, Span span, BodyContext ctx)
    {
        rejectMutableArguments(call);
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
            requireTyped(synthesize(arg, ctx), arg.span);
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
            (const ArrayData array) => isComparable(array.element, visited),
            (const EmptyArrayType _) => true,
            (const FunctionData _) => false,
            (const NominalData nominal) => _fields[nominal.decl].all!(f => isComparable(f.type, visited))
                && _members.get(nominal.decl, null).all!(m => isComparable(m, visited)),
            (const TupleData tuple) => tuple.elements.all!(e => isComparable(e, visited)),
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
        if (isArraySyntax(*binary.right) || isTupleLiteral(*binary.right))
        {
            check(*binary.right, inner, ctx);
            return inner;
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

    /// A tuple written out, which takes its element types from what it's checked against.
    private bool isTupleLiteral(const Expr expr)
    {
        return expr.kind.match!((const TupleLiteral _) => true, _ => false);
    }

    /// Synthesizes both sides of `==` or `!=`. A side written as `Some`, `None` or an array is
    /// checked against the other one, whichever side it's on, so `x == Some(1)` adapts the literal.
    private void synthesizeCompared(const BinaryExpr binary, out Type leftType, out Type rightType, BodyContext ctx)
    {
        bool takesType(const Expr expr) => isOptionSyntax(expr) || isArraySyntax(expr) || isTupleLiteral(expr);
        bool givesType(Type type) => _types.isOption(type) || _types.isArray(type) || _types.isTuple(type);

        if (takesType(*binary.left) && !takesType(*binary.right))
        {
            rightType = synthesize(*binary.right, ctx);
            leftType = givesType(rightType) ? check(*binary.left, rightType, ctx) : synthesize(*binary.left, ctx);
            return;
        }
        leftType = synthesize(*binary.left, ctx);
        rightType = givesType(leftType) && takesType(*binary.right)
            ? check(*binary.right, leftType, ctx)
            : synthesize(*binary.right, ctx);
    }

    /// Whether `expr`, of type `type`, can become `target` when compared with it: an option, or
    /// the array a `[]` takes on.
    private bool promotes(const Expr expr, Type type, Type target)
    {
        if (isSum(target)) return isAssignable(type, target) || (isIntLiteral(expr) && membersOf(target).any!(m => isNumeric(m)));
        if (type == _types.emptyArray && _types.isArray(target)) return true;
        if (!_types.isOption(target) || _types.isOption(type) && !isAssignable(type, target)) return false;
        return isAssignable(type, target) || (isIntLiteral(expr) && isNumeric(innermost(target)));
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
            auto isShift = binary.op == ShiftLeft || binary.op == ShiftRight;
            if (adaptsTo(leftType) && isIntLiteral(*binary.right) && !isIntLiteral(*binary.left))
            {
                rightType = adaptLiteral(*binary.right, leftType);
            }
            else if (!isShift && adaptsTo(rightType) && isIntLiteral(*binary.left) && !isIntLiteral(*binary.right))
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
                if (binary.op != BinaryOp.ShiftLeft && binary.op != BinaryOp.ShiftRight && leftType != rightType)
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
            case BinaryOp.And:
            case BinaryOp.Or:
                requireAssignable(leftType, _types.bool_, binary.left.span);
                requireAssignable(rightType, _types.bool_, binary.right.span);
                return _types.bool_;
            case BinaryOp.Equal:
            case BinaryOp.NotEqual:
                if (leftType == _types.none && rightType == _types.none) return reportUntypedNone(binary.left.span);
                if (leftType == _types.emptyArray && rightType == _types.emptyArray)
                {
                    return reportUntypedEmptyArray(binary.left.span);
                }
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
            case BinaryOp.Concat:
            case BinaryOp.Append:
                assert(0, "handled above");
        }
    }

    private Type synthesizeCall(const CallExpr call, Span span, BodyContext ctx)
    {
        return applyCallee(synthesize(*call.callee, ctx), call, span, ctx);
    }

    /// `checked` is how many leading arguments have already been checked.
    private Type applyCallee(Type calleeType, const CallExpr call, Span span, BodyContext ctx, size_t checked = 0)
    {
        // Each argument is checked against its parameter when there is one, and synthesized
        // otherwise, so even a wrong call gives every argument a type and its own errors.
        void synthesizeArgs()
        {
            foreach (arg; call.args[checked .. $])
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
                string[][] places;
                Span[] placeSpans;
                foreach (i, arg; call.args)
                {
                    if (i < checked) continue;
                    if (!call.isMutable(i))
                    {
                        if (funcData.isMutable(i))
                        {
                            _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                                "This parameter is `mutable`, so the call can change the argument; write `mutable` before it");
                        }
                        check(arg, funcData.params[i], ctx);
                        continue;
                    }
                    if (!funcData.isMutable(i))
                    {
                        synthesize(arg, ctx);
                        _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                            "This parameter isn't `mutable`, so the argument can't be passed as `mutable`");
                        continue;
                    }
                    if (checkMutableArgument(arg, funcData.params[i], ctx))
                    {
                        places ~= placePath(arg);
                        placeSpans ~= arg.span;
                    }
                }
                reportOverlaps(places, placeSpans,
                    "This overlaps a `mutable` argument before it, and one call can't change a place through two");
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

    /// Whether `object.f(...)` is on a value and some declaration could be `f`.
    private bool isMethodCall(Id!Expr call, const Expr callee)
    {
        if ((call in _resolutions.methodLookups) is null) return false;
        return callee.kind.match!(
            (const MemberAccess access) => !isModulePath(*access.object),
            _ => false,
        );
    }

    /// `object.f(args)`. A field named `f` comes first; otherwise it's `f(object, args)`, with the
    /// `f` a plain name finds at module level. The receiver has to be exactly the first
    /// parameter's type, since it was already synthesized to look for the field.
    private Type synthesizeMethodCall(const Expr expr, const CallExpr call, BodyContext ctx)
    {
        auto access = (*call.callee).kind.match!(
            (const MemberAccess m) => m,
            (_) => assert(0, "isMethodCall only accepts a member access"),
        );
        auto objectType = synthesize(*access.object, ctx);

        Type asField()
        {
            auto calleeType = fieldOf(*call.callee, access, objectType);
            _exprTypes[call.callee.id] = calleeType;
            return applyCallee(calleeType, call, expr.span, ctx);
        }

        if (objectType == _types.error || hasField(objectType, access.member)) return asField();

        auto lookup = _resolutions.methodLookups[expr.id];
        if (lookup.found.length > 1)
        {
            _collector.reportError(DiagnosticCode.AmbiguousName, call.callee.span,
                "'%s' is defined in more than one imported module (%s); call it qualified, e.g. '%s.%s(...)'"
                    .format(access.member, lookup.owners.join(", "), lookup.owners[0], access.member));
            return applyCallee(_types.error, call, expr.span, ctx);
        }
        Id!FunctionDecl function_;
        lookup.found[0].match!((const Id!FunctionDecl f) { function_ = f; }, (_) {});
        if (!function_.isValid) return asField();

        auto arguments = (cast(Expr*) access.object)[0 .. 1] ~ cast(Expr[]) call.args;
        auto mutables = call.mutableArgs.length > 0 ? false ~ call.mutableArgs.dup : null;
        auto rewritten = new const CallExpr(cast(Expr*) call.callee, arguments, mutables);
        auto functionType = _symbolTypes[SymbolId(function_)];
        _exprTypes[call.callee.id] = functionType;
        _methodCalls[expr.id] = rewritten;
        _methodCallees[expr.id] = function_;
        if (function_ == _arrayLength) return synthesizeLength(expr, *rewritten, ctx, 1);

        auto valid = receiverFits(access, function_, functionType, requireTyped(objectType, access.object.span), call.callee.span);
        return applyCallee(valid ? functionType : _types.error, *rewritten, expr.span, ctx, 1);
    }

    /// Whether a receiver of type `receiver` can be `function_`'s first argument, reporting why not.
    private bool receiverFits(const MemberAccess access, Id!FunctionDecl function_, Type functionType, Type receiver, Span calleeSpan)
    {
        if (receiver == _types.error) return false;
        auto signature = _types[functionType].match!(
            (const FunctionData data) => data,
            (_) => assert(0, "a function's type is a function type"),
        );
        if (signature.params.length == 0)
        {
            _collector.reportError(DiagnosticCode.WrongArgumentCount, calleeSpan,
                "`%s` takes no arguments, so it can't be called on a value".format(access.member));
            return false;
        }
        if (signature.isMutable(0))
        {
            _collector.reportError(DiagnosticCode.MutabilityMismatch, access.object.span,
                "`%s` changes its first argument, so the write has to show at the call; write `%s(mutable ...)`"
                    .format(access.member, access.member));
            return false;
        }
        if (receiver != signature.params[0] && signature.params[0] != _types.any)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, access.object.span,
                "`%s` takes `%s` first, but this is `%s`, and a receiver isn't converted; write `%s(...)`"
                    .format(access.member, _types.describe(signature.params[0]), _types.describe(receiver), access.member));
            return false;
        }
        return true;
    }

    private bool hasField(Type type, string name)
    {
        return _types[type].match!(
            (const NominalData nominal) => _fields[nominal.decl].canFind!(f => f.name == name),
            (_) => false,
        );
    }

    /// A `mutable` argument is written back when the call returns, so it must be a place of exactly
    /// the parameter's type. Whether it's one that can be overlap-checked.
    private bool checkMutableArgument(const Expr arg, Type param, BodyContext ctx)
    {
        auto type = synthesize(arg, ctx);
        if (type == _types.error) return false;
        if (!checkAssignable(arg, "passed as `mutable`")) return false;
        if (type == param) return true;
        _collector.reportError(DiagnosticCode.TypeMismatch, arg.span,
            "A `mutable` argument is written back, so it has to be exactly `%s`, not `%s`"
                .format(_types.describe(param), _types.describe(type)));
        return false;
    }

    /// For the calls that aren't to a function, which can't take a `mutable` argument.
    private void rejectMutableArguments(const CallExpr call)
    {
        foreach (i, arg; call.args)
        {
            if (!call.isMutable(i)) continue;
            _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                "This parameter isn't `mutable`, so the argument can't be passed as `mutable`");
        }
    }

    /// `object with (a = 1, b.c = 2)`: a copy of `object`, so it has `object`'s type, and each value
    /// is checked as an assignment to that field would be.
    private Type synthesizeWith(const Expr expr, const WithExpr with_, BodyContext ctx)
    {
        auto objectType = requireTyped(synthesize(*with_.object, ctx), with_.object.span);

        size_t[][] indexes;
        string[][] paths;
        Span[] spans;
        foreach (ref update; with_.updates)
        {
            size_t[] steps;
            auto fieldType = updatedField(objectType, update, steps);
            check(update.value, fieldType, ctx);
            indexes ~= steps;
            if (fieldType == _types.error) continue;
            paths ~= update.path.dup;
            spans ~= update.span;
        }
        reportOverlaps(paths, spans, "This overlaps an update before it, and one `with` can't change a place twice");
        _updatePaths[expr.id] = indexes;
        return objectType;
    }

    /// The type of the field `update` writes, reached from `object`, with the field index of each
    /// step of its path in `steps`.
    private Type updatedField(Type object, const FieldUpdate update, out size_t[] steps)
    {
        auto type = object;
        foreach (name; update.path)
        {
            if (type == _types.error) return type;
            auto fields = _types[type].match!(
                (const NominalData nominal) => _fields[nominal.decl],
                (_) => FieldInfo[].init,
            );
            auto index = fields.countUntil!(f => f.name == name);
            if (index < 0)
            {
                _collector.reportError(DiagnosticCode.UnknownMember, update.span,
                    "Type `%s` has no field named `%s`".format(_types.describe(type), name));
                return _types.error;
            }
            steps ~= index;
            type = fields[index].type;
        }
        return type;
    }

    private Type synthesizeMemberAccess(const Expr expr, const MemberAccess member, BodyContext ctx)
    {
        // `std.math.pow`: resolution already found the declaration.
        if (auto symbol = expr.id in _resolutions.resolutions)
        {
            return requireNotArrayLength(*symbol, expr.span);   // the same lookup synthesizeIdentifier uses
        }
        // `std.math.nope` or `std.nope`: resolution reported it.
        if (isModulePath(*member.object)) return _types.error;

        return fieldOf(expr, member, synthesize(*member.object, ctx));
    }

    /// The field `member` names on a value of `objectType`, reported if there's none.
    private Type fieldOf(const Expr expr, const MemberAccess member, Type objectType)
    {
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
        if (while_.binding is null)
        {
            auto condType = synthesize(*while_.condition, ctx);
            requireAssignable(condType, _types.bool_, while_.condition.span);
        }
        else
        {
            checkOptionBinding(*while_.binding, "while val", ctx);
        }
        checkLoopBody(*while_.body, ctx);
        return _types.unit;
    }

    private Type synthesizeFor(const ForExpr for_, BodyContext ctx)
    {
        auto iterable = &for_.binding.value;
        auto range = asRange(iterable);
        _symbolTypes[SymbolId(for_.binding.id)] = range is null
            ? synthesizeForArray(*iterable, ctx)
            : synthesizeForRange(*iterable, *range, ctx);
        checkLoopBody(*for_.body, ctx);
        return _types.unit;
    }

    /// The element type of what a `for` loops over, which isn't a range.
    private Type synthesizeForArray(const Expr iterable, BodyContext ctx)
    {
        auto type = requireTyped(synthesize(iterable, ctx), iterable.span);
        if (_types.isArray(type)) return _types.arrayElement(type);
        if (type == _types.error || type == _types.never) return type;
        _collector.reportError(DiagnosticCode.InvalidOperand, iterable.span,
            "`for` needs an array or a range, got `%s`".format(_types.describe(type)));
        return _types.error;
    }

    /// The type of a `for` range's bounds, which is also its own type and that of each value.
    /// Only integers count, and a literal takes the type of the number beside it.
    private Type synthesizeForRange(const Expr expr, const RangeExpr range, BodyContext ctx)
    {
        auto startType = synthesize(*range.start, ctx);
        auto endType = synthesize(*range.end, ctx);
        if (_types.isInteger(startType) && isIntLiteral(*range.end) && !isIntLiteral(*range.start))
        {
            endType = adaptLiteral(*range.end, startType);
        }
        else if (_types.isInteger(endType) && isIntLiteral(*range.start) && !isIntLiteral(*range.end))
        {
            startType = adaptLiteral(*range.start, endType);
        }

        auto type = join(startType, endType, expr.span, "Range bounds");
        if (type != _types.error && type != _types.never && !_types.isInteger(type))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, expr.span,
                "`for` needs a range of integers, got `%s`".format(_types.describe(type)));
            type = _types.error;
        }
        _exprTypes[expr.id] = type;
        return type;
    }

    /// `break` and `continue` act on the loop whose body holds them, so a condition or what a
    /// `for` loops over isn't part of this and they belong to any loop around it.
    private void checkLoopBody(const Expr body, BodyContext ctx)
    {
        ctx.inLoop = true;
        checkDiscarded(body, ctx);
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

        checkOptionBinding(*if_.binding, "if val", ctx);
    }

    /// The binding of an `if val` or `while val`, which holds the payload of its initializer.
    private void checkOptionBinding(const VarDecl binding, string keyword, BodyContext ctx)
    {
        auto initializer = binding.value;
        auto optionType = requireTyped(synthesize(initializer, ctx), initializer.span);
        auto payload = _types.error;
        if (_types.isOption(optionType))
        {
            payload = _types.optionInner(optionType);
        }
        else if (optionType != _types.error)
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, initializer.span,
                "`%s` needs an option, got `%s`".format(keyword, _types.describe(optionType)));
        }
        _symbolTypes[SymbolId(binding.id)] = payload;
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
        auto joined = join(thenType, elseType, span, "Branches");
        if (joined != _types.error)
        {
            coerce(*if_.trueBody, thenType, joined);
            coerce(*if_.falseBody, elseType, joined);
        }
        return joined;
    }

    /// The type that both `a` and `b` fit, or `error` (reported at `span`) if there isn't one.
    /// `what` names the things that have these types, for the error.
    private Type join(Type a, Type b, Span span, string what)
    {
        if (a == _types.error || b == _types.error) return _types.error;
        if (a == _types.never) return b;
        if (b == _types.never) return a;
        if (isAssignable(a, b)) return b;
        if (isAssignable(b, a)) return a;
        if (a == _types.none) return optionOf(b, span);
        if (b == _types.none) return optionOf(a, span);

        _collector.reportError(DiagnosticCode.TypeMismatch, span,
            "%s have different types `%s` and `%s`".format(what, _types.describe(a), _types.describe(b)));
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
            (const BreakStmt _) => true,
            (const ContinueStmt _) => true,
            (const ExprStmt e) => _exprTypes.get(e.expr.id, _types.error) == _types.never,
            _ => false,
        );
    }

    private Type synthesizeIdentifier(const Expr expr)
    {
        if (auto symbol = expr.id in _resolutions.resolutions)
        {
            return requireNotArrayLength(*symbol, expr.span);
        }
        // Name resolution couldn't find it and has already reported that.
        return _types.error;
    }

    /// Whether a constructor of `member`, which `owner` owns, should build the member itself.
    private bool wantsMember(Type member, Type owner, Type expected)
    {
        if (expected == member) return true;
        if (_types.isOption(expected)) return wantsMember(member, owner, _types.optionInner(expected));
        return expected != owner && membersOf(expected).canFind(member);
    }

    /// The one member of `sum` that the option, array or tuple written out as `expr` can be, or
    /// `Type.init` if `expr` isn't one of those or there's no single member.
    private Type memberForSyntax(const Expr expr, Type sum)
    {
        auto candidates = expr.kind.match!(
            (const SomeExpr _) => membersOf(sum).filter!(m => _types.isOption(m)).array,
            (const NoneLiteral _) => membersOf(sum).filter!(m => _types.isOption(m)).array,
            (const ArrayLiteral _) => membersOf(sum).filter!(m => _types.isArray(m)).array,
            (const BinaryExpr _) => isArraySyntax(expr) ? membersOf(sum).filter!(m => _types.isArray(m)).array : null,
            (const TupleLiteral literal) => membersOf(sum)
                .filter!(m => _types.isTuple(m) && _types.tupleElements(m).length == literal.elements.length).array,
            _ => (const(Type)[]).init,
        );
        return candidates.length == 1 ? candidates[0] : Type.init;
    }

    private Type check(const Expr expr, Type expected, BodyContext ctx)
    {
        if (isLambda(expr) && _types.isFunction(expected))
        {
            auto data = _types[expected].match!(
                (const FunctionData f) => f,
                (_) => assert(0, "checked above"),
            );
            auto lambda = expr.kind.match!(
                (const Lambda l) => l,
                (_) => assert(0, "checked above"),
            );
            return coerce(expr, typeLambda(expr, lambda, &data), expected);
        }
        auto constructed = constructedDecl(expr);
        if (auto owner = constructed in _owners)
        {
            auto member = _nominalTypes[constructed];
            if (wantsMember(member, *owner, expected)) return coerce(expr, synthesizeExact(expr, ctx), expected);
        }
        if (isSum(expected))
        {
            auto member = memberForSyntax(expr, expected);
            if (member != Type.init)
            {
                check(expr, member, ctx);
                _promotions[expr.id] = expected;
                return expected;
            }
        }

        // A number, option, array or tuple is passed down, so that a literal adapts, and a value is
        // promoted, in an `if` arm or as a block's value too.
        auto isOption = _types.isOption(expected);
        auto isArray = _types.isArray(expected);
        auto isTuple = _types.isTuple(expected);
        // An array or tuple written out against an option is checked against what it holds, then promoted.
        if (isOption && (isArraySyntax(expr) || isTupleLiteral(expr) || isLambda(expr)))
        {
            check(expr, _types.optionInner(expected), ctx);
            _promotions[expr.id] = expected;
            return expected;
        }
        if (isNumeric(expected) || isOption || isArray || isTuple || isSum(expected) || isOwnedMember(expected)
            || _types.isFunction(expected))
        {
            auto passedDown = expr.kind.match!(
                (const IfExpr if_) => if_.falseBody !is null,
                (const BlockExpr _) => true,
                (const SomeExpr _) => isOption,
                (const ArrayLiteral _) => isArray,
                (const BinaryExpr _) => isArray && isArraySyntax(expr),
                (const TupleLiteral literal) => isTuple && literal.elements.length == _types.tupleElements(expected).length,
                (const MatchExpr match_) => match_.origin != MatchOrigin.IfVal,
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
                    (const ArrayLiteral literal) {
                        foreach (element; literal.elements)
                        {
                            check(element, _types.arrayElement(expected), ctx);
                        }
                        return expected;
                    },
                    (const BinaryExpr binary) {
                        recordConcat(expr, binary);
                        check(*binary.left, expected, ctx);
                        check(*binary.right, expected, ctx);
                        return expected;
                    },
                    (const TupleLiteral literal) {
                        foreach (i, element; literal.elements)
                        {
                            check(element, _types.tupleElements(expected)[i], ctx);
                        }
                        return expected;
                    },
                    (const MatchExpr match_) => checkMatch(match_, expected, expr.span, ctx),
                    (_) => assert(0, "only ifs, blocks, matches, Some, arrays and tuples are passed down"),
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
        if (isSum(expected))
        {
            auto hasValue = type != _types.error && type != _types.never;
            if (hasValue && type != expected)
            {
                if (isIntLiteral(expr)) return injectLiteral(expr, expected);
                if (isAssignable(type, expected))
                {
                    _promotions[expr.id] = expected;
                    return expected;
                }
            }
        }
        else if (_types.isOption(expected))
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
        else if (expected == _types.any)
        {
            type = requireTyped(type, expr.span);
        }
        else if (type == _types.emptyArray && _types.isArray(expected))
        {
            _promotions[expr.id] = expected;
            return expected;
        }
        requireAssignable(type, expected, expr.span);
        return type;
    }

    /// An integer literal in a sum takes the type of its only integer member, or else of a Float one.
    private Type injectLiteral(const Expr expr, Type sum)
    {
        auto integers = membersOf(sum).filter!(m => _types.isInteger(m)).array;
        if (integers.length > 1)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
                "`%s` has more than one integer member; convert this to the one you mean, as in `%s(...)`"
                    .format(_types.describe(sum), _types.describe(integers[0])));
            return _types.error;
        }
        auto numbers = integers.length == 1 ? integers : membersOf(sum).filter!(m => m == _types.float_).array;
        if (numbers.length == 1)
        {
            adaptLiteral(expr, numbers[0]);
            _promotions[expr.id] = sum;
            return sum;
        }
        auto hint = membersOf(sum).any!(m => _types.isOption(m) && isNumeric(innermost(m))) ? "; write `Some(...)`" : "";
        _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
            "An integer isn't a member of `%s`%s".format(_types.describe(sum), hint));
        return _types.error;
    }

    /// The subject and every pattern of a `match`, then whether the arms cover it. Bindings have
    /// their types once this returns, so the arms can be checked.
    private void checkMatchHead(const MatchExpr match_, Span span, BodyContext ctx)
    {
        auto subject = requireTyped(synthesize(*match_.subject, ctx), match_.subject.span);
        auto reported = _collector.diagnostics.length;
        auto patterns = match_.arms.map!(arm => checkArmPattern(arm.pattern, subject, ctx)).array;
        if (match_.origin != MatchOrigin.Match || subject == _types.error || subject == _types.never) return;
        // A pattern that's already wrong would only be reported again as a gap in the coverage.
        if (_collector.diagnostics.length > reported) return;
        checkCoverage(match_, patterns, subject, span);
    }

    private Type synthesizeMatch(const MatchExpr match_, Span span, BodyContext ctx)
    {
        if (match_.origin == MatchOrigin.IfVal)
        {
            checkDiscardedMatch(match_, span, ctx);
            return _types.unit;
        }
        checkMatchHead(match_, span, ctx);
        auto types = match_.arms.map!(arm => synthesize(arm.body, ctx)).array;
        auto joined = _types.never;
        foreach (i, type; types)
        {
            joined = join(joined, type, match_.arms[i].body.span, "Match arms");
        }
        if (joined == _types.error) return joined;
        foreach (i, arm; match_.arms)
        {
            coerce(arm.body, types[i], joined);
        }
        return joined;
    }

    private Type checkMatch(const MatchExpr match_, Type expected, Span span, BodyContext ctx)
    {
        checkMatchHead(match_, span, ctx);
        auto types = match_.arms.map!(arm => check(arm.body, expected, ctx)).array;
        return types.all!(t => t == _types.never) ? _types.never : expected;
    }

    private Type checkDiscardedMatch(const MatchExpr match_, Span span, BodyContext ctx)
    {
        checkMatchHead(match_, span, ctx);
        auto types = match_.arms.map!(arm => checkDiscarded(arm.body, ctx)).array;
        return types.all!(t => t == _types.never) ? _types.never : _types.unit;
    }

    private bool isUnknown(Type type)
    {
        return type == _types.error || type == _types.never;
    }

    private CoveragePattern reportPattern(Span span, string message)
    {
        _collector.reportError(DiagnosticCode.PatternMismatch, span, message);
        return CoveragePattern.init;
    }

    /// Checks `pattern` against a value of `subject`, giving each binding its type.
    private CoveragePattern checkArmPattern(const Pattern pattern, Type subject, BodyContext ctx)
    {
        _patternSubjects[pattern.id] = subject;
        return pattern.kind.match!(
            (const VarDecl binding) => checkArmBinding(pattern, binding, subject),
            (const TuplePattern tuple) => checkArmTuple(pattern, tuple, subject, ctx),
            (const ConstructorPattern constructor) => checkArmConstructor(pattern, constructor, subject, ctx),
            (const SomePattern some) {
                if (_types.isOption(subject))
                {
                    return CoveragePattern("some", [checkArmPattern(*some.inner, _types.optionInner(subject), ctx)]);
                }
                checkArmPattern(*some.inner, _types.error, ctx);
                if (isUnknown(subject)) return CoveragePattern.init;
                return reportPattern(pattern.span, "`Some` needs an option, but the value is `%s`".format(_types.describe(subject)));
            },
            (const NonePattern _) {
                if (_types.isOption(subject)) return CoveragePattern("none");
                if (isUnknown(subject)) return CoveragePattern.init;
                return reportPattern(pattern.span, "`None` needs an option, but the value is `%s`".format(_types.describe(subject)));
            },
            (const LiteralPattern literal) {
                if (isOrdered(subject) || subject == _types.bool_)
                {
                    check(*literal.value, subject, ctx);
                    return CoveragePattern(printExpr(*literal.value));
                }
                synthesize(*literal.value, ctx);
                if (isUnknown(subject)) return CoveragePattern.init;
                return reportPattern(pattern.span, "A literal can't match a value of type `%s`".format(_types.describe(subject)));
            },
        );
    }

    /// Wildcards for what's inside a `member` that a pattern didn't take apart.
    private CoveragePattern[] wildcardsFor(Type member)
    {
        auto fields = _types[member].match!((const NominalData nominal) => _fields[nominal.decl], _ => FieldInfo[].init);
        return new CoveragePattern[fields.length];
    }

    /// Records that `pattern` tests for `member` of the sum `subject`, reporting it if there's no such member.
    private bool recordMember(const Pattern pattern, Type member, Type subject, out string key)
    {
        auto index = membersOf(subject).countUntil(member);
        if (index < 0)
        {
            reportPattern(pattern.span, "`%s` can't be a `%s`".format(_types.describe(subject), _types.describe(member)));
            return false;
        }
        _patternMembers[pattern.id] = index;
        key = "member%s".format(index);
        return true;
    }

    private CoveragePattern checkArmBinding(const Pattern pattern, const VarDecl binding, Type subject)
    {
        if (binding.type is null)
        {
            _symbolTypes[SymbolId(binding.id)] = subject;
            return CoveragePattern.init;
        }
        auto type = resolveType(*binding.type);
        _symbolTypes[SymbolId(binding.id)] = type;
        if (type == _types.error || isUnknown(subject) || type == subject) return CoveragePattern.init;

        string key;
        if (!recordMember(pattern, type, subject, key)) return CoveragePattern.init;
        return CoveragePattern(key, wildcardsFor(type));
    }

    private CoveragePattern checkArmTuple(const Pattern pattern, const TuplePattern tuple, Type subject, BodyContext ctx)
    {
        if (_types.isTuple(subject) && _types.tupleElements(subject).length == tuple.elements.length)
        {
            auto parts = _types.tupleElements(subject);
            CoveragePattern[] args;
            foreach (i, element; tuple.elements)
            {
                args ~= checkArmPattern(element, parts[i], ctx);
            }
            return CoveragePattern("tuple", args);
        }
        foreach (element; tuple.elements)
        {
            checkArmPattern(element, _types.error, ctx);
        }
        if (isUnknown(subject)) return CoveragePattern.init;
        return reportPattern(pattern.span, _types.isTuple(subject)
            ? "This pattern takes apart %s values, but `%s` has %s".format(tuple.elements.length,
                _types.describe(subject), _types.tupleElements(subject).length)
            : "This pattern takes apart a tuple, but the value is `%s`".format(_types.describe(subject)));
    }

    private CoveragePattern checkArmConstructor(const Pattern pattern, const ConstructorPattern constructor,
        Type subject, BodyContext ctx)
    {
        void checkArgumentsAsUnknown()
        {
            foreach (argument; constructor.arguments)
            {
                checkArmPattern(argument, _types.error, ctx);
            }
        }

        Id!TypeDecl decl;
        if (auto symbol = constructor.type.id in _resolutions.typeResolutions)
        {
            expandAlias(*symbol, _resolutions.declarations.aliases, _resolutions.typeResolutions)
                .match!((const Id!TypeDecl type) { decl = type; }, (_) {});
        }
        else
        {
            // Name resolution reported it.
            checkArgumentsAsUnknown();
            return CoveragePattern.init;
        }
        if (!decl.isValid || _resolutions.declarations.types[decl].members.length > 0)
        {
            checkArgumentsAsUnknown();
            return reportPattern(pattern.span, "`%s` has no constructor; bind a value of it with `name: %s`"
                .format(printTypeExpr(constructor.type), printTypeExpr(constructor.type)));
        }

        auto type = _nominalTypes[decl];
        auto fields = _fields[decl];
        _patternConstructors[pattern.id] = decl;
        if (constructor.arguments.length != fields.length)
        {
            checkArgumentsAsUnknown();
            return reportPattern(pattern.span, "`%s` has %s fields, but this pattern takes apart %s; use `_` for a field you don't need"
                .format(_types.describe(type), fields.length, constructor.arguments.length));
        }

        CoveragePattern[] args;
        foreach (i, argument; constructor.arguments)
        {
            args ~= checkArmPattern(argument, fields[i].type, ctx);
        }
        if (isUnknown(subject)) return CoveragePattern.init;
        if (type == subject) return CoveragePattern("product", args);

        string key;
        if (!recordMember(pattern, type, subject, key)) return CoveragePattern.init;
        return CoveragePattern(key, args);
    }

    /// Every shape `type`'s values come in, or nothing if there are too many to list, as for an integer.
    private PatternHead[] headsOf(Type type)
    {
        if (type == _types.bool_) return [PatternHead("false", "false"), PatternHead("true", "true")];
        return _types[type].match!(
            (const OptionData option) => [PatternHead("none", "None"), PatternHead("some", "Some", [option.inner])],
            (const TupleData tuple) => [PatternHead("tuple", "", tuple.elements)],
            (const NominalData nominal) {
                auto members = _members.get(nominal.decl, null);
                if (members.length == 0)
                {
                    return [PatternHead("product", _types.describe(type), _fields[nominal.decl].map!(f => f.type).array)];
                }
                PatternHead[] heads;
                foreach (i, member; members)
                {
                    auto fields = _types[member].match!((const NominalData inner) => _fields[inner.decl], _ => FieldInfo[].init);
                    heads ~= PatternHead("member%s".format(i), _types.describe(member), fields.map!(f => f.type).array);
                }
                return heads;
            },
            _ => PatternHead[].init,
        );
    }

    private static CoveragePattern[][] specialize(CoveragePattern[][] rows, string key, size_t arity)
    {
        CoveragePattern[][] result;
        foreach (row; rows)
        {
            if (row[0].head is null) result ~= new CoveragePattern[arity] ~ row[1 .. $].dup;
            else if (row[0].head == key) result ~= row[0].args.dup ~ row[1 .. $].dup;
        }
        return result;
    }

    private static CoveragePattern[][] defaults(CoveragePattern[][] rows)
    {
        return rows.filter!(row => row[0].head is null).map!(row => row[1 .. $].dup).array;
    }

    private static bool usesAll(const PatternHead[] heads, CoveragePattern[][] rows)
    {
        return heads.length > 0 && heads.all!(h => rows.any!(row => row[0].head == h.key));
    }

    /// Whether `row` matches a value no row of `rows` does. Each is a list of patterns for values of `types`.
    private bool isUseful(CoveragePattern[][] rows, CoveragePattern[] row, const(Type)[] types)
    {
        if (types.length == 0) return rows.length == 0;

        auto heads = headsOf(types[0]);
        auto rest = types[1 .. $];
        if (row[0].head !is null)
        {
            auto found = heads.find!(h => h.key == row[0].head);
            const(Type)[] inner = found.empty ? null : found.front.args;
            return isUseful(specialize(rows, row[0].head, row[0].args.length), row[0].args ~ row[1 .. $], inner ~ rest);
        }
        if (usesAll(heads, rows))
        {
            foreach (head; heads)
            {
                auto wildcards = new CoveragePattern[head.args.length];
                if (isUseful(specialize(rows, head.key, head.args.length), wildcards ~ row[1 .. $], head.args ~ rest)) return true;
            }
            return false;
        }
        return isUseful(defaults(rows), row[1 .. $], rest);
    }

    /// Finds values of `types` that no row matches, written as patterns in `witness`.
    private bool findUncovered(CoveragePattern[][] rows, const(Type)[] types, out string[] witness)
    {
        if (types.length == 0) return rows.length == 0;

        auto heads = headsOf(types[0]);
        auto rest = types[1 .. $];
        if (usesAll(heads, rows))
        {
            foreach (head; heads)
            {
                string[] parts;
                if (!findUncovered(specialize(rows, head.key, head.args.length), head.args ~ rest, parts)) continue;
                witness = head.render(parts[0 .. head.args.length]) ~ parts[head.args.length .. $];
                return true;
            }
            return false;
        }

        string[] after;
        if (!findUncovered(defaults(rows), rest, after)) return false;
        auto unused = heads.find!(h => !rows.any!(row => row[0].head == h.key));
        auto first = unused.empty || rows.all!(row => row[0].head is null)
            ? "_" : unused.front.render("_".repeat(unused.front.args.length).array);
        witness = first ~ after;
        return true;
    }

    private void checkCoverage(const MatchExpr match_, CoveragePattern[] patterns, Type subject, Span span)
    {
        const(Type)[] types = [subject];
        CoveragePattern[][] rows;
        foreach (i, pattern; patterns)
        {
            if (!isUseful(rows, [pattern], types))
            {
                _collector.reportError(DiagnosticCode.UnreachableArm, match_.arms[i].pattern.span,
                    "This arm can never run, because the arms before it cover everything it matches");
            }
            rows ~= [pattern];
        }

        string[] missing;
        auto heads = headsOf(subject);
        foreach (head; heads)
        {
            string[] parts;
            if (findUncovered(specialize(rows, head.key, head.args.length), head.args, parts)) missing ~= head.render(parts);
        }
        if (heads.length == 0)
        {
            string[] witness;
            if (findUncovered(rows, types, witness)) missing = witness;
        }
        if (missing.length == 0) return;
        _collector.reportError(DiagnosticCode.NonExhaustiveMatch, span,
            "This `match` doesn't cover %-(`%s`%|, %); add %s, or a `_` arm".format(missing, missing.length > 1 ? "them" : "it"));
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
    private bool isLambda(const Expr expr)
    {
        return expr.kind.match!((const Lambda _) => true, _ => false);
    }

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
        return _types[to].match!(
            // T -> T?, but not through a sum, since promotion is one step.
            (const OptionData o) => isSum(o.inner) ? from == o.inner : isAssignable(from, o.inner),
            (const NominalData _) => membersOf(to).canFind(from),
            // Both have the layout of an array with no elements, so no conversion hides here.
            (const ArrayData a) => from == _types.emptyArray
                || (_types.isArray(from) && _types.arrayElement(from) == _types.never),
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