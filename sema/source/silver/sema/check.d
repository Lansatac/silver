module silver.sema.check;

import std.algorithm;
import std.array;
import std.conv;
import std.range : iota, repeat;
import std.sumtype;
import std.string;


import silver.ast;
import silver.sema.constant_eval;
import silver.sema.coverage;
import silver.sema.declare;
import silver.sema.type;
import silver.sema.resolve;
import silver.sema.typing;

// Type checking for Silver programs.

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


private final class TypeChecker
{
    this(const Resolution resolutions, Collector collector)
    {
        _types = new TypeTable();
        _typing.types = _types;
        _collector = collector;
        _resolutions = resolutions;
        _declarer = new Declarer(_types, &_typing, resolutions, collector);
    }

    private TypeTable _types;
    private Collector _collector;
    private const Resolution _resolutions;
    /// What checking produces, built up in place.
    private Typing _typing;
    private Declarer _declarer;
    /// Every integer literal. A literal's type can change after it's first seen, as it adapts
    /// to where it's used, so ranges are checked once all the bodies have been.
    private const(Expr)[] _intLiterals;
    private bool[Id!Expr] _negatedLiterals;
    /// Constants whose initializer already has an error, which evaluating would only repeat.
    private bool[Id!ConstDecl] _unevaluable;

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
                        _typing.nominalTypes[t.id] = _types.nominal(t.id, t.name, t.typeParams.map!(p => _declarer.parameterType(p)).array);
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
                    (const AliasDecl a) { _declarer.aliasType(a.id); },
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
                        _declarer.declareSignature(f);
                    },
                    (const TypeDecl decl) {
                        _declarer.declareConstructor(decl);
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
            checkOverloads(mod);
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

        _declarer.checkInhabited(programModules);

        foreach (literal; _intLiterals)
        {
            checkLiteralRange(literal);
        }

        // Last, because an integer literal's type isn't final until everything's been checked.
        _typing.constants = evaluateConstants(programModules, _types, _typing.exprTypes, _resolutions, _unevaluable,
            _negatedLiterals, _collector);

        return _typing;
    }

    private void declareConstant(const ConstDecl constant)
    {
        auto type = constant.type is null ? _types.error : _declarer.resolveType(*constant.type);
        // Name resolution reports any other type, so uses shouldn't report it again.
        _typing.symbolTypes[SymbolId(constant.id)] = isConstantType(type) ? type : _types.error;
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
        auto type = _typing.symbolTypes[SymbolId(constant.id)];
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
        auto type = _typing.exprTypes[expr.id];
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

    private void checkFunction(const FunctionDecl func)
    {
        auto returnType = _types[_typing.symbolTypes[SymbolId(func.id)]].match!(
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
                type = _declarer.resolveType(param.type);
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
            _typing.symbolTypes[SymbolId(param.id)] = type;
            params ~= type;
            mutables ~= param.mutable;
        }

        Type ret = lambda.returnType !is null ? _declarer.resolveType(*lambda.returnType)
            : expected !is null ? expected.ret : Type.init;
        if (ret == Type.init)
        {
            ret = inferReturn(*lambda.body);
        }
        else
        {
            if (lambda.self.isValid) _typing.symbolTypes[SymbolId(lambda.self)] = _types.function_(params, ret, mutables);
            checkBody(*lambda.body, ret);
        }

        auto failed = wrongCount || ret == _types.error || params.canFind(_types.error);
        auto type = failed ? _types.error : _types.function_(params, ret, mutables);
        _typing.exprTypes[expr.id] = type;
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
        joined = _declarer.requireTyped(joined, body.span);
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
        _typing.exprTypes[expr.id] = type;
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
            _typing.symbolTypes[SymbolId(binding.id)] = binding.name == discardName ? type : _declarer.requireTyped(type, value.span);
        }
        else
        {
            auto type = _declarer.resolveType(*binding.type);
            check(value, type, ctx);
            _typing.symbolTypes[SymbolId(binding.id)] = type;
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
                types ~= _typing.promotions.get(element.id, _typing.exprTypes.get(element.id, _types.error));
            }
            // Never built, so only recorded for completeness; a dropped `None` leaves it untyped.
            _typing.exprTypes[value.id] = types.canFind(_types.none) || types.canFind(_types.emptyArray)
                ? _types.error : _declarer.tupleOf(types);
            return;
        }

        pattern.kind.match!(
            (const VarDecl binding) => checkBinding(binding, value, ctx),
            (const TuplePattern _) {
                auto expected = annotatedType(pattern);
                if (expected == Type.init)
                {
                    bindPattern(pattern, _declarer.requireTyped(synthesize(value, ctx), value.span));
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
                auto type = _declarer.resolveType(*binding.type);
                _typing.symbolTypes[SymbolId(binding.id)] = type;
                return type;
            },
            (const TuplePattern tuple) {
                // Every element, so each annotation is resolved once whatever comes after it.
                auto types = tuple.elements.map!(e => annotatedType(e)).array;
                return types.canFind(Type.init) ? Type.init : _declarer.tupleOf(types);
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
                    _typing.symbolTypes[SymbolId(binding.id)] = type;
                    return;
                }
                auto annotated = _typing.symbolTypes[SymbolId(binding.id)];
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

    /// The type of `expr`, where nothing asks for a particular one. A constructor of a member its
    /// sum owns produces the sum.
    private Type synthesize(const Expr expr, BodyContext ctx)
    {
        auto type = synthesizeExact(expr, ctx);
        // A use of a generic one has already decided what it builds.
        if (type == _types.error || genericUse(expr).found) return type;
        auto sum = _declarer.ownerOf(constructedDecl(expr));
        if (sum is null) return type;

        _typing.constructedMembers[expr.id] = type;
        _typing.exprTypes[expr.id] = *sum;
        return *sum;
    }

    /// `expected`, when there is one, is only for inferring the type arguments of a generic use.
    private Type synthesizeExact(const Expr expr, BodyContext ctx, Type expected = Type.init)
    {
        // "what type is this?"
        _typing.constructedMembers.remove(expr.id);

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
                ? synthesizeConversion(call, _declarer.builtinType(_resolutions.conversions[expr.id]), expr.span, ctx)
                : isMethodCall(expr.id, *call.callee)
                    ? synthesizeMethodCall(expr, call, ctx, expected)
                    : synthesizeCall(expr, call, ctx, expected),
            (const MemberAccess member) => synthesizeMemberAccess(expr, member, ctx, expected),
            (const WithExpr with_) => synthesizeWith(expr, with_, ctx),
            (const WhileExpr while_) => synthesizeWhile(while_, expr.span, ctx),
            (const ForExpr for_) => synthesizeFor(for_, ctx),
            (const IfExpr if_) => synthesizeIf(if_, expr.span, ctx),
            (const BlockExpr block) => synthesizeBlock(block, expr.span, ctx),
            (const UnitLiteral _) => _types.unit,
            (const Identifier _) => synthesizeIdentifier(expr, expected),
            (const SomeExpr some) => _declarer.optionOf(synthesize(*some.value, ctx), some.value.span),
            (const NoneLiteral _) => _types.none,
            (const PropagateExpr propagate) => synthesizePropagate(propagate, expr.span, ctx),
            (const SafeMemberAccess access) => synthesizeSafeMember(expr, access, ctx),
            (const ArrayLiteral literal) => synthesizeArrayLiteral(literal, ctx),
            (const MapLiteral literal) => synthesizeMapLiteral(literal, expr.span, ctx),
            (const IndexExpr index) => synthesizeIndex(index, ctx),
            (const RangeExpr range) => synthesizeBareRange(range, expr.span, ctx),
            (const TupleLiteral literal) => _declarer.tupleOf(literal.elements.map!(e => _declarer.requireTyped(synthesize(e, ctx), e.span)).array),
            (const MatchExpr match_) => synthesizeMatch(match_, expr.span, ctx),
            (const Lambda lambda) => typeLambda(expr, lambda, null),
        );
        _typing.exprTypes[expr.id] = type;
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
        joined = _declarer.requireTyped(joined, literal.elements[0].span);
        if (joined == _types.error) return joined;

        foreach (i, element; literal.elements)
        {
            coerce(element, types[i], joined);
        }
        return _declarer.arrayOf(joined, literal.elements[0].span);
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
        auto objectType = _declarer.requireTyped(synthesize(*index.object, ctx), index.object.span);
        auto range = asRange(index.index);
        if (range is null)
        {
            checkConsumedInteger(*index.index, ctx);
        }
        else
        {
            checkConsumedInteger(*range.start, ctx);
            checkConsumedInteger(*range.end, ctx);
            _typing.exprTypes[index.index.id] = objectType;
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

    /// The type of a name used as a value, reporting the declarations that have none.
    private Type symbolValue(SymbolId symbol, Span span)
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

        auto isIntrinsic = symbol.match!(
            (const Id!FunctionDecl f) => _resolutions.declarations.functions[f].kind == FunctionKind.intrinsic,
            _ => false,
        );
        if (!isIntrinsic) return symbolType(symbol);
        _collector.reportError(DiagnosticCode.NotSupportedYet, span,
            "`%s` is built into the compiler, so it can only be called for now".format(symbolName(symbol)));
        return _types.error;
    }

    private string symbolName(SymbolId symbol)
    {
        return symbol.match!(
            (const Id!FunctionDecl f) => _resolutions.declarations.functions[f].name,
            (const Id!TypeDecl t) => _resolutions.declarations.types[t].name,
            _ => "this",
        );
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
            _typing.concatOperands[expr.id] = concatChain(*binary.left) ~ concatChain(*binary.right);
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
            return _declarer.reportUntypedEmptyArray(binary.left.span);
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
        auto operandType = _declarer.requireTyped(synthesize(*propagate.operand, ctx), propagate.operand.span);
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
        auto objectType = _declarer.requireTyped(synthesize(*access.object, ctx), access.object.span);
        if (objectType == _types.error) return objectType;
        if (!_types.isOption(objectType))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, access.object.span,
                "`?.` needs an option, got `%s`; a field of any other value is read with `.`"
                    .format(_types.describe(objectType)));
            return _types.error;
        }

        auto fields = _declarer.fieldsOf(_types.optionInner(objectType));
        foreach (i, field; fields)
        {
            if (field.name == access.member)
            {
                _typing.fieldIndexes[expr.id] = i;
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
            auto type = _declarer.requireTyped(synthesize(part, ctx), part.span);
            if (_types.mentionsParameter(type)) reportOpaque(part.span, type, "it can't go in a string hole", "show: (%s) -> String");
        }
        return _types.string_;
    }

    /// Reports that generic code can't do `what` with a value of `type`, which mentions a type
    /// parameter. `example` is the function parameter that would, with `%s` for the type.
    private Type reportOpaque(Span span, Type type, string what, string example)
    {
        auto subject = _types.isParameter(type)
            ? "`%s` could be any type".format(_types.describe(type))
            : "`%s` holds a type parameter, which could be any type".format(_types.describe(type));
        auto hint = example is null ? ""
            : "; for now, take a function that does it as a parameter, as in `%s`".format(example.replace("%s", _types.describe(type)));
        _collector.reportError(DiagnosticCode.OpaqueTypeParameter, span, "%s, so %s%s".format(subject, what, hint));
        return _types.error;
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
        _typing.exprTypes[call.callee.id] = target;
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
            auto type = _declarer.requireTyped(synthesize(arg, ctx), arg.span);
            if (_types.mentionsParameter(type)) reportOpaque(arg.span, type, "it can't be converted to a `String`", "show: (%s) -> String");
            return target;
        }
        if (isIntLiteral(arg))
        {
            check(arg, target, ctx);
            return target;
        }
        auto argType = synthesize(arg, ctx);
        if (_types.mentionsParameter(argType))
        {
            reportOpaque(arg.span, argType, "it can't be converted to `%s`".format(_types.describe(target)), null);
        }
        else if (argType != _types.error && !isNumeric(argType))
        {
            _collector.reportError(DiagnosticCode.InvalidOperand, arg.span,
                "`%s` can only convert a number, got `%s`".format(_types.describe(target), _types.describe(argType)));
        }
        return target;
    }

    /// Whether `==` can compare two values of `type`. Nothing is known about a type parameter's
    /// values, so a type that mentions one can't be compared.
    private bool isComparable(Type type)
    {
        if (_types.mentionsParameter(type)) return false;
        bool[Id!TypeDecl] visited;
        return isComparable(type, visited);
    }

    /// A declared type is comparable when its fields and members are, with its own type parameters
    /// counting as comparable, and its type arguments are too. A type can contain itself through an
    /// option field, so one already visited counts as comparable: only a type that really can't be
    /// compared can make the answer false.
    private bool isComparable(Type type, ref bool[Id!TypeDecl] visited)
    {
        bool declared(Id!TypeDecl decl)
        {
            if (decl in visited) return true;
            visited[decl] = true;
            return _typing.fields[decl].all!(f => isComparable(f.type, visited))
                && _typing.members.get(decl, null).all!(m => isComparable(m, visited));
        }

        return _types[type].match!(
            (const Primitive primitive) => primitive.kind != Primitive.Kind.Any,
            (const OptionData option) => isComparable(option.inner, visited),
            (const ArrayData array) => isComparable(array.element, visited),
            (const EmptyArrayType _) => true,
            (const FunctionData _) => false,
            (const NominalData nominal) => nominal.args.all!(a => isComparable(a, visited)) && declared(nominal.decl),
            (const TupleData tuple) => tuple.elements.all!(e => isComparable(e, visited)),
            (const NoneType _) => true,
            (const ErrorType _) => true,
            (const TypeParamData _) => true,
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
            if (optionType == _types.none) return _declarer.reportUntypedNone(binary.left.span);
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
        bool takesType(const Expr expr) => isOptionSyntax(expr) || isArraySyntax(expr) || isTupleLiteral(expr)
            || genericUse(expr).found;
        bool givesType(Type type) => _types.isOption(type) || _types.isArray(type) || _types.isTuple(type)
            || declOf(type).isValid;

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
        if (_declarer.isSum(target)) return isAssignable(type, target) || (isIntLiteral(expr) && _declarer.membersOf(target).any!(m => isNumeric(m)));
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
                foreach (side, sideType; [leftType, rightType])
                {
                    if (!_types.mentionsParameter(sideType)) continue;
                    return reportOpaque(side == 0 ? binary.left.span : binary.right.span, sideType,
                        "its values can't be ordered with `%s`".format(cast(string) binary.op), "less: (%s, %s) -> Bool");
                }
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
                if (leftType == _types.none && rightType == _types.none) return _declarer.reportUntypedNone(binary.left.span);
                if (leftType == _types.emptyArray && rightType == _types.emptyArray)
                {
                    return _declarer.reportUntypedEmptyArray(binary.left.span);
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
                if (_types.mentionsParameter(leftType))
                {
                    return reportOpaque(span, leftType, "its values can't be compared with `%s`".format(cast(string) binary.op),
                        "same: (%s, %s) -> Bool");
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

    private Type synthesizeCall(const Expr expr, const CallExpr call, BodyContext ctx, Type expected)
    {
        Type[] typed;
        if (auto candidates = call.callee.id in _resolutions.overloads)
        {
            typed = new Type[call.args.length];
            auto chosen = chooseFunction(*call.callee, spelling(*call.callee), typeArgsOf(*call.callee), *candidates,
                call, typed, false, ctx);
            if (!chosen.isValid)
            {
                _typing.exprTypes[call.callee.id] = _types.error;
                typeUnchosen(call, typed, ctx);
                return _types.error;
            }
            _typing.chosenSymbols[call.callee.id] = SymbolId(chosen);
            _typing.chosenCallees[expr.id] = chosen;
        }
        auto generic = genericUse(expr);
        if (generic.found) return applyGeneric(expr, generic, call, expected, ctx, typed);
        // A function named directly is called, not used as a value, so an intrinsic can be.
        if (auto function_ = calleeOf(expr.id))
        {
            rejectTypeArguments(typeArgsOf(*call.callee), spelling(*call.callee), call.callee.span);
            auto calleeType = symbolType(SymbolId(*function_));
            _typing.exprTypes[call.callee.id] = calleeType;
            return applyCallee(calleeType, call, expr.span, ctx, typed);
        }
        return applyCallee(synthesize(*call.callee, ctx), call, expr.span, ctx);
    }

    /// Whether `expr` names an overloaded function or calls one, which are chosen as they're checked.
    private bool isOverloadedUse(const Expr expr)
    {
        if (expr.id in _resolutions.overloads) return true;
        return expr.kind.match!((const CallExpr call) => (call.callee.id in _resolutions.overloads) !is null, _ => false);
    }

    private const(SymbolId)* resolutionOf(Id!Expr name)
    {
        if (auto chosen = name in _typing.chosenSymbols) return chosen;
        return name in _resolutions.resolutions;
    }

    private const(Id!FunctionDecl)* calleeOf(Id!Expr call)
    {
        if (auto chosen = call in _typing.chosenCallees) return chosen;
        return call in _resolutions.callees;
    }

    /// How well an argument fits a parameter, worst first.
    private enum Fit { none, converted, exact }

    /// One candidate of an overloaded call, tried against its arguments.
    private struct Trial
    {
        Id!FunctionDecl func;
        Fit[] fits;
        /// Why it doesn't fit, or null when it does.
        string problem;

        bool fitsAll() const => problem is null;
    }

    /// Chooses which of `candidates` a call of `name` invokes, reporting it when none or several
    /// do. Each argument with a type of its own is synthesized first, once, and its type is left
    /// in `typed`; the rest only have to have the right shape, and are checked once one is chosen.
    private Id!FunctionDecl chooseFunction(const Expr name, string spelled, const(TypeExpr)[] written,
        const Candidates candidates, const CallExpr call, Type[] typed, bool hasReceiver, BodyContext ctx)
    {
        auto args = call.args;
        Trial[][] groups;
        foreach (group; candidates.groups)
        {
            groups ~= group.map!(f => arityTrial(f, args.length, written.length)).array;
        }
        auto plausible = groups.joiner.filter!(t => t.fitsAll).array;
        // One candidate is called as a lone function is, so its arguments can adapt to it.
        if (plausible.length == 1) return plausible[0].func;
        if (plausible.length == 0)
        {
            reportNoOverload(name.span, spelled, groups);
            return Id!FunctionDecl.init;
        }

        foreach (i, arg; args)
        {
            if (typed[i] == Type.init && (call.isMutable(i) || !isShaped(arg))) typed[i] = synthesize(arg, ctx);
        }
        auto writtenTypes = written.map!(w => quietlyResolved(w)).array;
        foreach (ref group; groups)
        {
            foreach (ref trial; group)
            {
                if (trial.fitsAll) fitTrial(trial, call, typed, writtenTypes, hasReceiver);
            }
        }
        // An argument whose type is already an error fits anything, so it would only add to it.
        auto reportable = !typed.any!(t => t != Type.init && _types.mentionsError(t));

        auto own = groups[0].filter!(t => t.fitsAll).array;
        if (own.length > 0) return bestTrial(own, name.span, spelled, reportable);
        auto imported = groups[1 .. $].map!(g => g.filter!(t => t.fitsAll).array).filter!(g => g.length > 0).array;
        if (imported.length == 1) return bestTrial(imported[0], name.span, spelled, reportable);
        if (imported.length > 1)
        {
            if (reportable) reportImportedOverloads(name.span, spelled, imported.map!(g => g[0].func).array);
            return Id!FunctionDecl.init;
        }
        if (reportable) reportNoOverload(name.span, spelled, groups);
        return Id!FunctionDecl.init;
    }

    /// `f` as a candidate for a call with `count` arguments and `written` type arguments, failed
    /// already if those can't fit it.
    private Trial arityTrial(Id!FunctionDecl f, size_t count, size_t written)
    {
        auto trial = Trial(f);
        auto params = signatureOf(f).params.length;
        auto typeParams = _resolutions.declarations.functions[f].typeParams.length;
        if (params != count)
        {
            trial.problem = "takes %s argument%s".format(params, params == 1 ? "" : "s");
        }
        else if (written > 0 && typeParams != written)
        {
            trial.problem = typeParams == 0 ? "isn't generic" : "takes %s type arguments".format(typeParams);
        }
        return trial;
    }

    /// Fills in how well each argument fits `trial`'s function, or why one doesn't.
    private void fitTrial(ref Trial trial, const CallExpr call, const(Type)[] typed, const(Type)[] written, bool hasReceiver)
    {
        auto params = _resolutions.declarations.functions[trial.func].typeParams;
        auto signature = signatureOf(trial.func);
        Substitution bound;
        foreach (i, type; written) bound[params[i].id] = type;
        foreach (i, type; typed)
        {
            if (type != Type.init && !isIntLiteral(call.args[i])) bindParams(signature.params[i], type, params, bound);
        }

        string argument(size_t i) => hasReceiver && i == 0 ? "the receiver" : "argument %s".format(hasReceiver ? i : i + 1);
        trial.fits = new Fit[call.args.length];
        foreach (i, arg; call.args)
        {
            if (call.isMutable(i) != signature.isMutable(i))
            {
                trial.problem = call.isMutable(i)
                    ? "%s is passed as `mutable`, and its parameter isn't".format(argument(i))
                    : "%s has to be passed as `mutable`".format(argument(i));
                return;
            }
            auto param = _types.substitute(signature.params[i], bound);
            // A literal receiver has been synthesized to look for a field, but still adapts.
            auto byShape = typed[i] == Type.init || isIntLiteral(arg);
            auto fit = byShape ? shapeFit(arg, param, params) : typedFit(typed[i], param, params, call.isMutable(i));
            if (fit == Fit.none)
            {
                auto type = typed[i] == Type.init ? literalType(arg) : typed[i];
                trial.problem = type == Type.init
                    ? "%s can't be `%s`".format(argument(i), _types.describe(param))
                    : "%s is `%s`, not `%s`".format(argument(i), _types.describe(type), _types.describe(param));
                return;
            }
            trial.fits[i] = fit;
        }
    }

    /// How well an argument of type `actual` fits `param`, which may still mention some of the
    /// candidate's own `params`.
    private Fit typedFit(Type actual, Type param, const(TypeParam)[] params, bool mutable)
    {
        if (actual == _types.error || actual == _types.never || _types.mentionsError(param)) return Fit.exact;
        if (mentionsAny(param, params)) return couldBe(param, actual, params) ? Fit.exact : Fit.none;
        if (actual == param) return Fit.exact;
        if (mutable) return Fit.none;
        return isAssignable(actual, param) ? Fit.converted : Fit.none;
    }

    private bool mentionsAny(Type type, const(TypeParam)[] params)
    {
        return params.any!(p => _types.mentionsParameter(type, p.id));
    }

    /// Whether `declared`, in which any of `params` could be any type, could take a value of `actual`.
    private bool couldBe(Type declared, Type actual, const(TypeParam)[] params)
    {
        if (actual == _types.error || actual == _types.never) return true;
        if (!mentionsAny(declared, params)) return isAssignable(actual, declared);
        auto data = _types[actual];
        return _types[declared].match!(
            (const TypeParamData _) => true,
            (const OptionData o) => (_types.isOption(actual) && couldBe(o.inner, _types.optionInner(actual), params))
                || couldBe(o.inner, actual, params),
            (const ArrayData a) => actual == _types.emptyArray
                || _types.isArray(actual) && couldBe(a.element, _types.arrayElement(actual), params),
            (const TupleData t) => data.match!(
                (const TupleData u) => u.elements.length == t.elements.length
                    && t.elements.length.iota.all!(i => couldBe(t.elements[i], u.elements[i], params)),
                _ => false,
            ),
            (const FunctionData f) => data.match!(
                (const FunctionData g) => g.params.length == f.params.length && g.mutables == f.mutables
                    && f.params.length.iota.all!(i => couldBe(f.params[i], g.params[i], params))
                    && couldBe(f.ret, g.ret, params),
                _ => false,
            ),
            (const NominalData n) => data.match!(
                (const NominalData m) => m.decl == n.decl
                    ? n.args.length.iota.all!(i => couldBe(n.args[i], m.args[i], params))
                    : _typing.members.get(n.decl, null).any!(member => declOf(member) == m.decl),
                _ => false,
            ),
            _ => false,
        );
    }

    /// An argument that isn't synthesized to choose an overload, because its type depends on where
    /// it goes, or because it can be compared with a parameter as it's written: a literal, `None`,
    /// `[]`, a lambda, a generic or overloaded name, or an array, tuple or `Some` of those.
    private bool isShaped(const Expr arg)
    {
        if (isUntyped(arg)) return true;
        return arg.kind.match!(
            (const BoolLiteral _) => true,
            (const FloatLiteral _) => true,
            (const StringLiteral _) => true,
            (const UnitLiteral _) => true,
            (const ArrayLiteral literal) => literal.elements.all!(e => isShaped(e)),
            (const TupleLiteral literal) => literal.elements.all!(e => isShaped(e)),
            (const SomeExpr some) => isShaped(*some.value),
            _ => false,
        );
    }

    /// How well `arg`, one that `isShaped`, fits `param`, which may still mention `params`.
    private Fit shapeFit(const Expr arg, Type param, const(TypeParam)[] params)
    {
        if (_types.mentionsError(param)) return Fit.exact;
        if (param == _types.any) return Fit.converted;
        auto bare = _types[param].match!((const TypeParamData p) => params.canFind!(q => q.id == p.param), _ => false);
        auto members = _declarer.membersOf(param);
        bool sumHas(bool delegate(Type) test) => members.any!(m => test(m));
        // Inside an option, a fit is at best a conversion, since the value is promoted.
        Fit inOption(Fit delegate(Type) inner)
        {
            if (!_types.isOption(param)) return inner(param);
            return min(inner(_types.optionInner(param)), Fit.converted);
        }

        if (isIntLiteral(arg))
        {
            if (bare || param == _types.int_) return Fit.exact;
            auto inner = _types.isOption(param) ? innermost(param) : param;
            auto numeric = isNumeric(inner) || params.canFind!(p => inner == _declarer.parameterType(p))
                || sumHas(m => isNumeric(m));
            return numeric ? Fit.converted : Fit.none;
        }
        if (isLambda(arg))
        {
            auto lambda = arg.kind.match!((const Lambda l) => l, (_) => Lambda.init);
            if (bare) return lambda.params.all!(p => p.annotated) ? Fit.exact : Fit.none;
            bool annotationsFit(const FunctionData f)
            {
                foreach (i, p; lambda.params)
                {
                    if (!p.annotated) continue;
                    auto annotated = quietlyResolved(p.type);
                    auto fits = mentionsAny(f.params[i], params) ? couldBe(f.params[i], annotated, params) : annotated == f.params[i];
                    if (!fits && annotated != _types.error) return false;
                }
                return true;
            }
            return inOption((Type t) => _types[t].match!(
                (const FunctionData f) => f.params.length == lambda.params.length && annotationsFit(f) ? Fit.exact : Fit.none,
                _ => Fit.none,
            ));
        }
        if (auto candidates = arg.id in _resolutions.overloads)
        {
            if (bare) return Fit.none;
            return inOption((Type t) => _types[t].match!(
                (const FunctionData f) => candidates.groups.joiner.any!(c => signatureOf(c).params.length == f.params.length)
                    ? Fit.exact : Fit.none,
                _ => Fit.none,
            ));
        }
        auto generic = isUntyped(arg) ? genericNamed(arg) : Generic.init;
        if (generic.found)
        {
            if (bare) return Fit.converted;
            return inOption((Type t) {
                if (_types.isFunction(generic.type)) return _types.isFunction(t)
                    && signatureOf(t).params.length == signatureOf(generic.type).params.length ? Fit.exact : Fit.none;
                auto decl = declOf(t);
                return decl == declOf(generic.member) || generic.owner != Type.init && decl == declOf(generic.owner)
                    ? Fit.exact : Fit.none;
            });
        }
        return arg.kind.match!(
            (const NoneLiteral _) => bare || _types.isOption(param) || sumHas(m => _types.isOption(m)) ? Fit.converted : Fit.none,
            (const ArrayLiteral literal) {
                if (literal.elements.length == 0)
                {
                    auto array = _types.isArray(param) || _types.isOption(param) && _types.isArray(_types.optionInner(param));
                    return bare || array || sumHas(m => _types.isArray(m)) ? Fit.converted : Fit.none;
                }
                if (bare) return Fit.exact;
                if (sumHas(m => _types.isArray(m))) return Fit.converted;
                return inOption((Type t) => _types.isArray(t)
                    ? literal.elements.map!(e => shapeFit(e, _types.arrayElement(t), params)).fold!min(Fit.exact)
                    : Fit.none);
            },
            (const TupleLiteral literal) {
                if (bare) return Fit.exact;
                if (sumHas(m => _types.isTuple(m))) return Fit.converted;
                return inOption((Type t) {
                    if (!_types.isTuple(t) || _types.tupleElements(t).length != literal.elements.length) return Fit.none;
                    auto elements = _types.tupleElements(t);
                    return literal.elements.length.iota.map!(i => shapeFit(literal.elements[i], elements[i], params))
                        .fold!min(Fit.exact);
                });
            },
            (const SomeExpr some) {
                if (bare) return Fit.exact;
                if (_types.isOption(param)) return shapeFit(*some.value, _types.optionInner(param), params);
                return sumHas(m => _types.isOption(m)) ? Fit.converted : Fit.none;
            },
            _ => literalType(arg) != Type.init ? typedFit(literalType(arg), param, params, false)
                : assert(0, "only an argument that isShaped is fitted by its shape"),
        );
    }

    /// The type of a literal that has only one, or `Type.init` for anything else.
    private Type literalType(const Expr arg)
    {
        return arg.kind.match!(
            (const BoolLiteral _) => _types.bool_,
            (const FloatLiteral _) => _types.float_,
            (const StringLiteral _) => _types.string_,
            (const UnitLiteral _) => _types.unit,
            _ => Type.init,
        );
    }

    /// The one of `trials` that beats each of the others, reporting it when there isn't one.
    private Id!FunctionDecl bestTrial(const(Trial)[] trials, Span span, string spelled, bool reportable)
    {
        auto winners = trials.filter!(t => trials.all!(u => u.func == t.func || beats(t, u))).array;
        if (winners.length == 1) return winners[0].func;
        if (!reportable) return Id!FunctionDecl.init;
        auto tied = trials.filter!(t => !trials.any!(u => beats(u, t))).map!(t => "`" ~ overloadLabel(t.func) ~ "`").array;
        _collector.reportError(DiagnosticCode.AmbiguousOverload, span,
            "This call fits more than one `%s` equally well: %s; convert an argument, or annotate it, to choose one"
                .format(spelled, tied.join(" and ")));
        return Id!FunctionDecl.init;
    }

    /// Whether `a` fits a call better than `b`: at least as well for every argument and better for
    /// one, or, when they fit every argument alike, by being the more specific function.
    private bool beats(const Trial a, const Trial b)
    {
        bool better, worse;
        foreach (i; 0 .. a.fits.length)
        {
            if (a.fits[i] > b.fits[i]) better = true;
            if (a.fits[i] < b.fits[i]) worse = true;
        }
        if (better || worse) return better && !worse;
        auto aGeneric = isGenericFunction(a.func), bGeneric = isGenericFunction(b.func);
        if (aGeneric != bGeneric) return bGeneric;
        return aGeneric && accepts(b.func, a.func) && !accepts(a.func, b.func);
    }

    private bool isGenericFunction(Id!FunctionDecl f)
    {
        return _resolutions.declarations.functions[f].typeParams.length > 0;
    }

    /// Whether the generic `wider` takes every list of arguments that `narrower` does: its type
    /// parameters can be bound so its parameters are exactly `narrower`'s.
    private bool accepts(Id!FunctionDecl wider, Id!FunctionDecl narrower)
    {
        auto widerParams = signatureOf(wider).params;
        auto narrowerParams = signatureOf(narrower).params;
        auto typeParams = _resolutions.declarations.functions[wider].typeParams;
        Substitution bound;
        foreach (i, param; widerParams) bindParams(param, narrowerParams[i], typeParams, bound);
        return widerParams.length.iota.all!(i => _types.substitute(widerParams[i], bound) == narrowerParams[i]);
    }

    /// `type` resolved without reporting anything, to look ahead at a type that's resolved again,
    /// and reported, where it's checked.
    private Type quietlyResolved(const TypeExpr type)
    {
        auto collector = _collector;
        _collector = new Collector;
        scope (exit) _collector = collector;
        return _declarer.resolveType(type);
    }

    private FunctionData signatureOf(Id!FunctionDecl f)
    {
        return signatureOf(_typing.symbolTypes[SymbolId(f)]);
    }

    private FunctionData signatureOf(Type functionType)
    {
        return _types[functionType].match!((const FunctionData data) => data, _ => FunctionData.init);
    }

    /// `f(Int, String)`, or `lib.f<T>(mutable T)` for a function of another module.
    private string overloadLabel(Id!FunctionDecl f, bool qualified = false)
    {
        auto decl = _resolutions.declarations.functions[f];
        auto signature = signatureOf(f);
        auto params = signature.params.length.iota
            .map!(i => (signature.isMutable(i) ? "mutable " : "") ~ _types.describe(signature.params[i])).join(", ");
        auto typeParams = decl.typeParams.length == 0 ? "" : "<" ~ decl.typeParams.map!(p => p.name).join(", ") ~ ">";
        auto owner = qualified ? _resolutions.declarations.functionModules[f] ~ "." : "";
        return owner ~ decl.name ~ typeParams ~ "(" ~ params ~ ")";
    }

    private void reportNoOverload(Span span, string spelled, const(Trial[])[] groups)
    {
        string[] lines;
        foreach (g, group; groups)
        {
            foreach (trial; group) lines ~= "%s %s".format(overloadLabel(trial.func, g > 0), trial.problem);
        }
        _collector.reportError(DiagnosticCode.NoMatchingOverload, span,
            "No `%s` takes these arguments:\n    %-(%s\n    %)".format(spelled, lines));
    }

    /// Reports a call that functions of more than one imported module fit, one from each of `fits`.
    private void reportImportedOverloads(Span span, string spelled, const(Id!FunctionDecl)[] fits)
    {
        auto modules = fits.map!(f => _resolutions.declarations.functionModules[f]).array;
        _collector.reportError(DiagnosticCode.AmbiguousName, span,
            "This call fits a `%s` in more than one imported module (%s); qualify it, as in `%s.%s(...)`"
                .format(spelled, modules.join(", "), modules[0], spelled));
    }

    /// Gives each argument of a call that couldn't be chosen a type, without reporting it again.
    private void typeUnchosen(const CallExpr call, const(Type)[] typed, BodyContext ctx)
    {
        foreach (i, arg; call.args)
        {
            if (typed[i] == Type.init) checkArgument(arg, _types.error, ctx);
        }
    }

    /// An overloaded function used as a value, chosen by the function type it's expected to be.
    private Type overloadedValue(const Expr name, const Candidates candidates, Type expected)
    {
        auto spelled = spelling(name);
        if (expected == _types.error) return _types.error;
        if (expected == Type.init || !_types.isFunction(expected))
        {
            reportOverloadedValue(name);
            return _types.error;
        }

        const(Id!FunctionDecl)[][] matching;
        foreach (group; candidates.groups)
        {
            matching ~= group.filter!(f => valueFits(f, typeArgsOf(name), expected)).array;
        }
        const(Id!FunctionDecl)[] fits = matching[0];
        if (fits.length == 0)
        {
            auto imported = matching[1 .. $].filter!(g => g.length > 0).array;
            if (imported.length > 1)
            {
                auto modules = imported.map!(g => _resolutions.declarations.functionModules[g[0]]).array;
                _collector.reportError(DiagnosticCode.AmbiguousName, name.span,
                    "A `%s` in more than one imported module (%s) is a `%s`; qualify it, as in `%s.%s`"
                        .format(spelled, modules.join(", "), _types.describe(expected), modules[0], spelled));
                return _types.error;
            }
            if (imported.length == 1) fits = imported[0];
        }
        // A function that isn't generic is more specific than one that is.
        if (fits.length > 1 && fits.any!(f => !isGenericFunction(f))) fits = fits.filter!(f => !isGenericFunction(f)).array;
        if (fits.length != 1)
        {
            auto all = candidates.groups.joiner.map!(f => "`" ~ overloadLabel(f) ~ "`").array;
            _collector.reportError(fits.length == 0 ? DiagnosticCode.NoMatchingOverload : DiagnosticCode.AmbiguousOverload,
                name.span, "%s `%s` is a `%s`; there are %s".format(fits.length == 0 ? "No" : "More than one", spelled,
                    _types.describe(expected), all.join(", ")));
            return _types.error;
        }
        _typing.chosenSymbols[name.id] = SymbolId(fits[0]);
        return namedValue(name, SymbolId(fits[0]), expected);
    }

    /// Whether the function `f`, given the type arguments `written`, can be a value of `expected`.
    private bool valueFits(Id!FunctionDecl f, const(TypeExpr)[] written, Type expected)
    {
        auto params = _resolutions.declarations.functions[f].typeParams;
        auto type = _typing.symbolTypes[SymbolId(f)];
        if (written.length > 0 && written.length != params.length) return false;
        Substitution bound;
        if (written.length > 0)
        {
            foreach (i, param; params) bound[param.id] = quietlyResolved(written[i]);
        }
        else
        {
            bindParams(type, expected, params, bound);
            if (params.any!(p => p.id !in bound)) return false;
        }
        return _types.substitute(type, bound) == expected;
    }

    private void reportOverloadedValue(const Expr name)
    {
        auto spelled = spelling(name);
        auto first = (name.id in _resolutions.overloads).groups.joiner.front;
        _collector.reportError(DiagnosticCode.AmbiguousOverload, name.span,
            "`%s` is overloaded, so as a value it needs a function type to choose by, as in `val f: %s = %s`"
                .format(spelled, _types.describe(_typing.symbolTypes[SymbolId(first)]), spelled));
    }

    /// Reports two functions of one name in `mod` that take the same parameters, and notes which
    /// functions are overloaded.
    private void checkOverloads(const Module mod)
    {
        Id!FunctionDecl[][string] seen;
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl f) {
                    // A second `main` is reported by name resolution.
                    if (f.name == "main") return;
                    auto earlier = seen.get(f.name, null);
                    seen[f.name] ~= f.id;
                    if (earlier.length == 0) return;
                    _typing.overloaded[f.id] = true;
                    foreach (e; earlier) _typing.overloaded[e] = true;
                    foreach (e; earlier)
                    {
                        if (reportDuplicateOverload(e, f)) break;
                    }
                },
                (_) {},
            );
        }
    }

    /// Reports `later` if it can't be told apart from `earlier`, an overload declared before it.
    private bool reportDuplicateOverload(Id!FunctionDecl earlier, const FunctionDecl later)
    {
        auto first = _resolutions.declarations.functions[earlier];
        string problem;
        if (first.kind == FunctionKind.intrinsic && later.kind == FunctionKind.intrinsic)
        {
            problem = "`%s` is already an intrinsic, and an intrinsic's name says which one it is";
        }
        else if (first.kind == FunctionKind.native && later.kind == FunctionKind.native && first.symbol == later.symbol)
        {
            problem = "`%s` already binds the C symbol `" ~ later.symbol ~ "`; give this one another with `native(\"...\")`";
        }
        else if (sameParameters(earlier, later.id))
        {
            auto a = signatureOf(earlier), b = signatureOf(later.id);
            problem = "`%s` already takes `" ~ overloadLabel(earlier)[first.name.length .. $] ~ "`; overloads need different parameter types"
                ~ (a.mutables == b.mutables ? "" : ", and `mutable` alone doesn't make one");
        }
        if (problem is null) return false;
        _collector.reportError(DiagnosticCode.DuplicateOverload, later.nameSpan, problem.format(later.name));
        return true;
    }

    /// Whether `a` and `b` take the same parameter types, apart from what they name their type
    /// parameters and which parameters are `mutable`.
    private bool sameParameters(Id!FunctionDecl a, Id!FunctionDecl b)
    {
        auto aParams = signatureOf(a).params;
        auto bParams = signatureOf(b).params;
        if (aParams.length != bParams.length) return false;
        auto aTypeParams = _resolutions.declarations.functions[a].typeParams;
        auto bTypeParams = _resolutions.declarations.functions[b].typeParams;
        Id!TypeParam[Id!TypeParam] renamed;
        return aParams.length.iota.all!(i => sameUpToRenaming(aParams[i], bParams[i], aTypeParams, bTypeParams, renamed));
    }

    private bool sameUpToRenaming(Type a, Type b, const(TypeParam)[] aParams, const(TypeParam)[] bParams,
        ref Id!TypeParam[Id!TypeParam] renamed)
    {
        if (a == b) return true;
        bool same(Type x, Type y) => sameUpToRenaming(x, y, aParams, bParams, renamed);
        bool allSame(const(Type)[] xs, const(Type)[] ys) => xs.length == ys.length && xs.length.iota.all!(i => same(xs[i], ys[i]));
        auto other = _types[b];
        return _types[a].match!(
            (const TypeParamData p) => other.match!(
                (const TypeParamData q) {
                    if (!aParams.canFind!(t => t.id == p.param) || !bParams.canFind!(t => t.id == q.param)) return false;
                    if (auto existing = p.param in renamed) return *existing == q.param;
                    if (renamed.byValue.canFind(q.param)) return false;
                    renamed[p.param] = q.param;
                    return true;
                },
                _ => false,
            ),
            (const OptionData o) => _types.isOption(b) && same(o.inner, _types.optionInner(b)),
            (const ArrayData x) => _types.isArray(b) && same(x.element, _types.arrayElement(b)),
            (const TupleData t) => _types.isTuple(b) && allSame(t.elements, _types.tupleElements(b)),
            (const FunctionData f) => other.match!(
                (const FunctionData g) => f.mutables == g.mutables && allSame(f.params, g.params) && same(f.ret, g.ret),
                _ => false,
            ),
            (const NominalData n) => other.match!(
                (const NominalData m) => n.decl == m.decl && allSame(n.args, m.args),
                _ => false,
            ),
            _ => false,
        );
    }

    /// A use of a generic function or constructor: what it has to find, and what it is in terms of
    /// that.
    private struct Generic
    {
        /// The name the use is written with, which may give the type arguments.
        Id!Expr name;
        Span span;
        string spelled;
        const(TypeExpr)[] written;
        /// The function's type parameters, or those of the type a constructor names, which
        /// `written` gives.
        const(TypeParam)[] params;
        /// The function's type, or a constructor's or marker's, in terms of `params`.
        Type type;
        /// For a constructor of a member a generic sum owns: the sum, and its parameters, which
        /// include `params`.
        Type owner;
        const(TypeParam)[] ownerParams;
        /// The type a constructor names, in terms of `params`.
        Type member;

        bool found() const => type != Type.init;
    }

    /// What `expr` uses generically, if it's a call or value of a generic function or constructor.
    private Generic genericUse(const Expr expr)
    {
        return expr.kind.match!(
            (const CallExpr call) => expr.id in _resolutions.conversions || isMethodCall(expr.id, *call.callee)
                ? Generic.init : genericNamed(*call.callee),
            (const Identifier _) => genericNamed(expr),
            (const MemberAccess _) => genericNamed(expr),
            _ => Generic.init,
        );
    }

    private Generic genericNamed(const Expr name)
    {
        auto symbol = resolutionOf(name.id);
        if (symbol is null) return Generic.init;
        Generic g;
        g.name = name.id;
        g.span = name.span;
        g.spelled = spelling(name);
        g.written = typeArgsOf(name);
        auto found = (*symbol).match!(
            (const Id!FunctionDecl f) {
                auto decl = _resolutions.declarations.functions[f];
                if (decl.typeParams.length == 0) return false;
                g.params = decl.typeParams;
                g.type = _typing.symbolTypes[SymbolId(f)];
                return true;
            },
            (const Id!TypeDecl t) {
                auto decl = _resolutions.declarations.types[t];
                if (decl.members.length > 0) return false;
                if (auto owner = _declarer.ownerOf(t))
                {
                    if (_types.mentionsParameter(*owner))
                    {
                        g.owner = *owner;
                        g.ownerParams = _declarer.typeParamsOf(declOf(*owner));
                    }
                }
                if (decl.typeParams.length == 0 && g.owner == Type.init) return false;
                g.params = decl.typeParams;
                g.type = _typing.symbolTypes[SymbolId(t)];
                g.member = _typing.nominalTypes[t];
                return true;
            },
            _ => false,
        );
        return found ? g : Generic.init;
    }

    private static const(TypeExpr)[] typeArgsOf(const Expr name)
    {
        return name.kind.match!(
            (const Identifier id) => id.typeArgs,
            (const MemberAccess access) => access.typeArgs,
            _ => (const(TypeExpr)[]).init,
        );
    }

    /// `name` as written, for a message: `f`, or `a.b.f` when the object is a module path.
    private static string spelling(const Expr name)
    {
        return name.kind.match!(
            (const Identifier id) => id.name,
            (const MemberAccess access) => access.object.kind.match!(
                (const Identifier _) => spelling(*access.object) ~ "." ~ access.member,
                (const MemberAccess _) => spelling(*access.object) ~ "." ~ access.member,
                _ => access.member,
            ),
            _ => "this",
        );
    }

    private Id!TypeDecl declOf(Type type)
    {
        return _types[type].match!((const NominalData n) => n.decl, _ => Id!TypeDecl.init);
    }

    /// Reports type arguments written on `name`, which isn't generic.
    private void rejectTypeArguments(const(TypeExpr)[] written, string name, Span span)
    {
        if (written.length == 0) return;
        _declarer.resolveTypeArguments(written);
        _collector.reportError(DiagnosticCode.WrongTypeArgumentCount, span,
            "`%s` isn't generic, so it takes no type arguments".format(name));
    }

    /// Whether a use of `g` that's expected to be `expected` builds the member it names rather than
    /// the sum that owns it.
    private bool buildsMember(const Generic g, Type expected)
    {
        if (expected == Type.init || expected == _types.error) return false;
        auto member = declOf(g.member);
        auto owner = declOf(g.owner);
        bool wanted(Type type)
        {
            if (_types.isOption(type)) return wanted(_types.optionInner(type));
            auto decl = declOf(type);
            if (decl == member) return true;
            return decl.isValid && decl != owner && _declarer.membersOf(type).any!(m => declOf(m) == member);
        }
        return wanted(expected);
    }

    /// `type` with `result` for its result: a function's return type, or a marker itself.
    private Type withResult(Type type, Type result)
    {
        return _types[type].match!(
            (const FunctionData f) => _types.function_(f.params, result, f.mutables),
            _ => result,
        );
    }

    /// Binds what each parameter in `params` that `declared` mentions has to be for `declared` to be
    /// `actual`. Nothing is reported, and a parameter that's already bound is left alone.
    private void bindParams(Type declared, Type actual, const(TypeParam)[] params, ref Substitution bound)
    {
        if (actual == _types.error || actual == _types.never || actual == _types.none || actual == _types.emptyArray
            || actual == _types.any) return;
        auto data = _types[actual];
        _types[declared].match!(
            (const TypeParamData p) {
                if (params.canFind!(q => q.id == p.param) && p.param !in bound) bound[p.param] = actual;
            },
            (const OptionData o) => bindParams(o.inner, _types.isOption(actual) ? _types.optionInner(actual) : actual,
                params, bound),
            (const ArrayData a) {
                if (_types.isArray(actual)) bindParams(a.element, _types.arrayElement(actual), params, bound);
            },
            (const TupleData t) => data.match!(
                (const TupleData u) {
                    if (u.elements.length != t.elements.length) return;
                    foreach (i, element; t.elements) bindParams(element, u.elements[i], params, bound);
                },
                (_) {},
            ),
            (const FunctionData f) => data.match!(
                (const FunctionData g) {
                    if (g.params.length != f.params.length) return;
                    foreach (i, param; f.params) bindParams(param, g.params[i], params, bound);
                    bindParams(f.ret, g.ret, params, bound);
                },
                (_) {},
            ),
            (const NominalData n) => data.match!(
                (const NominalData m) {
                    if (m.decl != n.decl) return;
                    foreach (i, arg; n.args) bindParams(arg, m.args[i], params, bound);
                },
                (_) {},
            ),
            (_) {},
        );
    }

    /// Binds from where a use's result is expected to land: inside an option the result isn't, and
    /// at the member of a sum that the result names.
    private void bindExpected(Type result, Type expected, const(TypeParam)[] params, ref Substitution bound)
    {
        if (expected == Type.init || expected == _types.error) return;
        if (_types.isOption(expected) && !_types.isOption(result)) expected = _types.optionInner(expected);
        auto decl = declOf(result);
        if (decl.isValid && declOf(expected).isValid && declOf(expected) != decl)
        {
            auto member = _declarer.membersOf(expected).find!(m => declOf(m) == decl);
            if (!member.empty) expected = member.front;
        }
        bindParams(result, expected, params, bound);
    }

    private bool isBound(Type declared, const(TypeParam)[] params, const Substitution bound)
    {
        return !params.any!(p => p.id !in bound && _types.mentionsParameter(declared, p.id));
    }

    /// Binds what `g.written` gives, reporting it unless it gives every one of `g.params`.
    private void bindWritten(const Generic g, ref Substitution bound)
    {
        auto args = _declarer.resolveTypeArguments(g.written);
        if (args.length == g.params.length)
        {
            foreach (i, param; g.params) bound[param.id] = args[i];
            return;
        }
        _collector.reportError(DiagnosticCode.WrongTypeArgumentCount, g.span, g.params.length == 0
            ? "`%s` isn't generic, so it takes no type arguments".format(g.spelled)
            : "`%s` takes %s type arguments, got %s; write all of them or none".format(g.spelled, g.params.length, args.length));
        foreach (param; g.params ~ g.ownerParams) bound[param.id] = _types.error;
    }

    /// An argument whose type depends on where it goes: an integer literal, a lambda, `None` or
    /// `[]`, and as with `None`, a generic name with no type arguments that isn't called, like `Nil`.
    private bool isUntyped(const Expr expr)
    {
        if (expr.id in _resolutions.overloads) return true;
        auto genericName = expr.kind.match!(
            (const Identifier id) => id.typeArgs.length == 0,
            (const MemberAccess access) => access.typeArgs.length == 0,
            _ => false,
        );
        if (genericName && genericNamed(expr).found) return true;
        return isIntLiteral(expr) || isLambda(expr) || expr.kind.match!(
            (const NoneLiteral _) => true,
            (const ArrayLiteral literal) => literal.elements.length == 0,
            _ => false,
        );
    }

    /// What a lambda passed for a parameter of type `declared` is checked against, when each of its
    /// parameters is annotated or known by now. An unknown return type is left to infer.
    private const(FunctionData)* lambdaExpectation(const Lambda lambda, Type declared, const(TypeParam)[] params,
        const Substitution bound)
    {
        return _types[declared].match!(
            (const FunctionData f) {
                if (f.params.length != lambda.params.length) return null;
                foreach (i, param; f.params)
                {
                    if (!lambda.params[i].annotated && !isBound(param, params, bound)) return null;
                }
                auto ret = isBound(f.ret, params, bound) ? _types.substitute(f.ret, bound) : Type.init;
                return new const FunctionData(f.params.map!(p => _types.substitute(p, bound)).array.idup, ret, f.mutables);
            },
            _ => null,
        );
    }

    /// A call of `g` with `call`'s arguments, whose type arguments are written or inferred. With a
    /// `receiver`, the first argument is a method call's, already synthesized.
    /// `pretyped` is as for `applyCallee`. `hasReceiver` says the first argument is the `x` of `x.f()`.
    private Type applyGeneric(const Expr expr, const Generic g, const CallExpr call, Type expected, BodyContext ctx,
        const(Type)[] pretyped = null, bool hasReceiver = false)
    {
        auto args = call.args;
        auto sum = g.owner != Type.init && !buildsMember(g, expected);
        auto params = sum ? g.ownerParams : g.params;
        auto shape = sum ? withResult(g.type, g.owner) : g.type;
        auto typed = new Type[args.length];
        auto checked = new bool[args.length];
        foreach (i, type; pretyped) typed[i] = type;
        void typeTheRest()
        {
            _declarer.resolveTypeArguments(g.written);
            foreach (i, arg; args)
            {
                if (typed[i] == Type.init) synthesize(arg, ctx);
            }
        }

        if (!_types.isFunction(shape))
        {
            typeTheRest();
            _collector.reportError(DiagnosticCode.NotCallable, expr.span,
                "`%s` is a value, not a function, so it can't be called".format(g.spelled));
            return _types.error;
        }
        auto signature = _types[shape].match!((const FunctionData f) => f, (_) => FunctionData.init);
        if (signature.params.length != args.length)
        {
            typeTheRest();
            _collector.reportError(DiagnosticCode.WrongArgumentCount, expr.span,
                "Expected %s arguments, got %s".format(signature.params.length, args.length));
            return _types.error;
        }

        Substitution bound;
        bool known(size_t i) => !signature.isMutable(i) && !call.isMutable(i) && isBound(signature.params[i], params, bound);
        if (g.written.length > 0)
        {
            bindWritten(g, bound);
            bindExpected(signature.ret, expected, params, bound);
        }
        else
        {
            foreach (i, arg; args)
            {
                if (typed[i] != Type.init)
                {
                    bindParams(signature.params[i], typed[i], params, bound);
                    continue;
                }
                if (!call.isMutable(i) && isUntyped(arg)) continue;
                if (known(i))
                {
                    check(arg, _types.substitute(signature.params[i], bound), ctx);
                    checked[i] = true;
                    continue;
                }
                typed[i] = synthesize(arg, ctx);
                bindParams(signature.params[i], typed[i], params, bound);
            }
            if (params.any!(p => p.id !in bound)) bindExpected(signature.ret, expected, params, bound);
            // A lambda that can't be typed yet may be once a later argument binds what it needs.
            for (auto progress = true; progress;)
            {
                progress = false;
                foreach (i, arg; args)
                {
                    if (typed[i] != Type.init || checked[i]) continue;
                    if (known(i))
                    {
                        check(arg, _types.substitute(signature.params[i], bound), ctx);
                        checked[i] = progress = true;
                    }
                    else if (isIntLiteral(arg))
                    {
                        typed[i] = synthesize(arg, ctx);
                        bindParams(signature.params[i], typed[i], params, bound);
                        progress = true;
                    }
                    else if (isLambda(arg))
                    {
                        auto lambda = arg.kind.match!((const Lambda l) => l, (_) => Lambda.init);
                        auto expectation = lambdaExpectation(lambda, signature.params[i], params, bound);
                        // Against a bare parameter, a lambda is its own type when it says all of it.
                        auto annotated = !_types.isFunction(signature.params[i]) && lambda.params.all!(p => p.annotated);
                        if (expectation is null && !annotated) continue;
                        typed[i] = typeLambda(arg, lambda, expectation);
                        bindParams(signature.params[i], typed[i], params, bound);
                        progress = true;
                    }
                }
            }
        }
        reportUnbound(expr, g, params, sum, signature, args, typed, hasReceiver, bound);

        auto paramTypes = signature.params.map!(p => _types.substitute(p, bound)).array;
        string[][] places;
        Span[] placeSpans;
        foreach (i, arg; args)
        {
            if (!call.isMutable(i))
            {
                if (signature.isMutable(i))
                {
                    _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                        "This parameter is `mutable`, so the call can change the argument; write `mutable` before it");
                }
                if (checked[i]) continue;
                if (typed[i] != Type.init) coerce(arg, typed[i], paramTypes[i]);
                else checkArgument(arg, paramTypes[i], ctx);
                continue;
            }
            if (!signature.isMutable(i))
            {
                if (typed[i] == Type.init) synthesize(arg, ctx);
                _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                    "This parameter isn't `mutable`, so the argument can't be passed as `mutable`");
                continue;
            }
            if (checkMutableArgument(arg, paramTypes[i], ctx, typed[i]))
            {
                places ~= placePath(arg);
                placeSpans ~= arg.span;
            }
        }
        reportOverlaps(places, placeSpans,
            "This overlaps a `mutable` argument before it, and one call can't change a place through two");

        _typing.exprTypes[g.name] = _types.substitute(shape, bound);
        _typing.typeArguments[g.name] = params.map!(p => bound[p.id]).array;
        if (sum) _typing.constructedMembers[expr.id] = _types.substitute(g.member, bound);
        return _types.substitute(signature.ret, bound);
    }

    /// Checks an argument against `type`, which is an error type when what it needed couldn't be
    /// found, and a lambda then has nothing more to say.
    private void checkArgument(const Expr arg, Type type, BodyContext ctx)
    {
        if (isLambda(arg) && !_types.isFunction(type) && _types.mentionsError(type))
        {
            auto lambda = arg.kind.match!((const Lambda l) => l, (_) => Lambda.init);
            auto unknown = FunctionData(_types.error.repeat(lambda.params.length).array.idup, _types.error);
            typeLambda(arg, lambda, &unknown);
            return;
        }
        check(arg, type, ctx);
    }

    /// Reports the first of `params` that nothing bound, as the argument that didn't fit when one
    /// should have bound it, and binds each to `error`.
    private void reportUnbound(const Expr expr, const Generic g, const(TypeParam)[] params, bool sum,
        const FunctionData signature, const(Expr)[] args, const(Type)[] typed, bool hasReceiver, ref Substitution bound)
    {
        auto reported = false;
        foreach (param; params)
        {
            if (param.id in bound) continue;
            scope (exit) bound[param.id] = _types.error;
            if (reported) continue;
            reported = true;

            bool mentions(size_t i) => _types.mentionsParameter(signature.params[i], param.id);
            auto culprit = args.length.iota.filter!(i => typed[i] != Type.init && mentions(i));
            if (!culprit.empty)
            {
                auto i = culprit.front;
                if (typed[i] == _types.none) _declarer.reportUntypedNone(args[i].span);
                else if (typed[i] == _types.emptyArray) _declarer.reportUntypedEmptyArray(args[i].span);
                else if (_types.mentionsError(typed[i]) || typed[i] == _types.never) continue;
                else
                {
                    _collector.reportError(DiagnosticCode.TypeMismatch, args[i].span,
                        "`%s` takes `%s` %s, but this is `%s`".format(g.spelled, _types.describe(signature.params[i]),
                            hasReceiver && i == 0 ? "first" : "here", _types.describe(typed[i])));
                }
                continue;
            }
            auto untyped = args.length.iota.filter!(i => mentions(i) && typed[i] == Type.init && !isLambda(args[i])
                && !isIntLiteral(args[i]));
            if (!untyped.empty)
            {
                auto arg = args[untyped.front];
                arg.kind.match!(
                    (const NoneLiteral _) { _declarer.reportUntypedNone(arg.span); },
                    (const ArrayLiteral _) { _declarer.reportUntypedEmptyArray(arg.span); },
                    (_) {
                        if (arg.id in _resolutions.overloads) reportOverloadedValue(arg);
                        else reportUninferredValue(arg, genericNamed(arg), true);
                    },
                );
                continue;
            }
            if (sum && !g.params.canFind!(p => p.id == param.id))
            {
                auto owner = _resolutions.declarations.types[declOf(g.owner)].name;
                _collector.reportError(DiagnosticCode.CannotInferTypeArgument, expr.span,
                    "This builds a `%s`, but nothing here says what `%s` is; annotate the type it's used as, as in `val x: %s = ...`"
                        .format(_types.describe(g.owner), param.name, _declarer.example(owner, g.ownerParams.length, "")));
                continue;
            }
            _collector.reportError(DiagnosticCode.CannotInferTypeArgument, expr.span,
                "Nothing in this call says what `%s` is; write the type arguments, as in `%s`"
                    .format(param.name, _declarer.example(g.spelled, g.params.length, args.length == 0 ? "()" : "(...)")));
        }
    }

    /// Reports a use of `g` as a value that nothing gives its type arguments. `sum` says it's a marker
    /// that builds its generic sum.
    private void reportUninferredValue(const Expr expr, const Generic g, bool sum)
    {
        if (sum && g.owner != Type.init)
        {
            auto owner = _resolutions.declarations.types[declOf(g.owner)].name;
            _collector.reportError(DiagnosticCode.CannotInferTypeArgument, expr.span,
                "This `%s` has no type to take here; annotate one, as in `val x: %s = %s`"
                    .format(g.spelled, _declarer.example(owner, g.ownerParams.length, ""), g.spelled));
            return;
        }
        _collector.reportError(DiagnosticCode.CannotInferTypeArgument, expr.span,
            "`%s` is generic, so as a value it needs its type arguments, as in `%s`, or a type to take them from"
                .format(g.spelled, _declarer.example(g.spelled, g.params.length, "")));
    }

    /// A generic function, constructor or marker used as a value, which has one type: from its
    /// written type arguments, or the function type it's expected to be.
    private Type instantiateValue(const Expr expr, const Generic g, Type expected)
    {
        auto sum = !_types.isFunction(g.type) && g.owner != Type.init && !buildsMember(g, expected);
        auto params = sum ? g.ownerParams : g.params;
        auto shape = sum ? g.owner : g.type;
        Substitution bound;
        if (g.written.length > 0) bindWritten(g, bound);
        if (params.any!(p => p.id !in bound)) bindExpected(shape, expected, params, bound);
        if (params.any!(p => p.id !in bound))
        {
            // An expected type that's already wrong has been reported.
            if (expected == Type.init || !_types.mentionsError(expected)) reportUninferredValue(expr, g, sum);
            foreach (param; params) bound.require(param.id, _types.error);
        }
        _typing.typeArguments[g.name] = params.map!(p => bound[p.id]).array;
        if (sum) _typing.constructedMembers[expr.id] = _types.substitute(g.member, bound);
        return _types.substitute(shape, bound);
    }

    /// `typed` has the type of each argument that has already been given one, and is otherwise
    /// `Type.init`, or empty when none has.
    private Type applyCallee(Type calleeType, const CallExpr call, Span span, BodyContext ctx, const(Type)[] typed = null)
    {
        Type typeOf(size_t i) => i < typed.length ? typed[i] : Type.init;
        // Each argument is checked against its parameter when there is one, and synthesized
        // otherwise, so even a wrong call gives every argument a type and its own errors.
        void synthesizeArgs()
        {
            foreach (i, arg; call.args)
            {
                if (typeOf(i) == Type.init) synthesize(arg, ctx);
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
                    auto type = typeOf(i);
                    if (!call.isMutable(i))
                    {
                        if (funcData.isMutable(i))
                        {
                            _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                                "This parameter is `mutable`, so the call can change the argument; write `mutable` before it");
                        }
                        if (type == Type.init) check(arg, funcData.params[i], ctx);
                        else coerce(arg, type, funcData.params[i]);
                        continue;
                    }
                    if (!funcData.isMutable(i))
                    {
                        if (type == Type.init) synthesize(arg, ctx);
                        _collector.reportError(DiagnosticCode.MutabilityMismatch, arg.span,
                            "This parameter isn't `mutable`, so the argument can't be passed as `mutable`");
                        continue;
                    }
                    if (checkMutableArgument(arg, funcData.params[i], ctx, type))
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
    /// `f` a plain name finds at module level. The receiver was synthesized to look for the field,
    /// so it's an argument that already has its type.
    private Type synthesizeMethodCall(const Expr expr, const CallExpr call, BodyContext ctx, Type expected)
    {
        auto access = (*call.callee).kind.match!(
            (const MemberAccess m) => m,
            (_) => assert(0, "isMethodCall only accepts a member access"),
        );
        auto objectType = synthesize(*access.object, ctx);

        Type asField()
        {
            rejectTypeArguments(access.typeArgs, access.member, call.callee.span);
            auto calleeType = fieldOf(*call.callee, access, objectType);
            _typing.exprTypes[call.callee.id] = calleeType;
            return applyCallee(calleeType, call, expr.span, ctx);
        }

        if (objectType == _types.error || hasField(objectType, access.member)) return asField();

        auto lookup = _resolutions.methodLookups[expr.id];
        auto arguments = (cast(Expr*) access.object)[0 .. 1] ~ cast(Expr[]) call.args;
        auto mutables = call.mutableArgs.length > 0 ? false ~ call.mutableArgs.dup : null;
        auto rewritten = new const CallExpr(cast(Expr*) call.callee, arguments, mutables);
        _typing.methodCalls[expr.id] = rewritten;
        auto receiver = _declarer.requireTyped(objectType, access.object.span);
        auto typed = new Type[arguments.length];
        typed[0] = receiver;

        Id!FunctionDecl function_;
        if (lookup.count == 1)
        {
            function_ = lookup.groups.joiner.front;
        }
        else if (receiver != _types.error)
        {
            function_ = chooseFunction(*call.callee, access.member, access.typeArgs, lookup, *rewritten, typed, true, ctx);
        }
        if (!function_.isValid)
        {
            _typing.exprTypes[call.callee.id] = _types.error;
            typeUnchosen(*rewritten, typed, ctx);
            return _types.error;
        }
        auto functionType = _typing.symbolTypes[SymbolId(function_)];
        _typing.exprTypes[call.callee.id] = functionType;
        _typing.methodCallees[expr.id] = function_;

        auto decl = _resolutions.declarations.functions[function_];
        if (!receiverFits(access, functionType, receiver, call.callee.span))
        {
            return applyCallee(_types.error, *rewritten, expr.span, ctx, typed);
        }
        if (decl.typeParams.length > 0)
        {
            Generic g;
            g.name = call.callee.id;
            g.span = call.callee.span;
            g.spelled = access.member;
            g.written = access.typeArgs;
            g.params = decl.typeParams;
            g.type = functionType;
            return applyGeneric(expr, g, *rewritten, expected, ctx, typed, true);
        }
        rejectTypeArguments(access.typeArgs, access.member, call.callee.span);
        return applyCallee(functionType, *rewritten, expr.span, ctx, typed);
    }

    /// Whether a receiver of type `receiver` can be the first argument of a function of type
    /// `functionType`, reporting why not. Its type is checked as any argument's is.
    private bool receiverFits(const MemberAccess access, Type functionType, Type receiver, Span calleeSpan)
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
        return true;
    }

    private bool hasField(Type type, string name)
    {
        return _declarer.fieldsOf(type).canFind!(f => f.name == name);
    }

    /// A `mutable` argument is written back when the call returns, so it must be a place of exactly
    /// the parameter's type. Whether it's one that can be overlap-checked. `type` is the argument's,
    /// when it's been synthesized already.
    private bool checkMutableArgument(const Expr arg, Type param, BodyContext ctx, Type type = Type.init)
    {
        if (type == Type.init) type = synthesize(arg, ctx);
        if (type == _types.error) return false;
        if (!checkAssignable(arg, "passed as `mutable`")) return false;
        if (type == param || _types.mentionsError(param)) return true;
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
        auto objectType = _declarer.requireTyped(synthesize(*with_.object, ctx), with_.object.span);

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
        _typing.updatePaths[expr.id] = indexes;
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
            auto fields = _declarer.fieldsOf(type);
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

    private Type synthesizeMemberAccess(const Expr expr, const MemberAccess member, BodyContext ctx, Type expected)
    {
        // `std.math.pow`: resolution already found the declaration, or the functions it could be.
        if (auto candidates = expr.id in _resolutions.overloads) return overloadedValue(expr, *candidates, expected);
        if (auto symbol = expr.id in _resolutions.resolutions) return namedValue(expr, *symbol, expected);
        // `std.math.nope` or `std.nope`: resolution reported it.
        if (isModulePath(*member.object)) return _types.error;

        rejectTypeArguments(member.typeArgs, member.member, expr.span);
        return fieldOf(expr, member, synthesize(*member.object, ctx));
    }

    /// The field `member` names on a value of `objectType`, reported if there's none.
    private Type fieldOf(const Expr expr, const MemberAccess member, Type objectType)
    {
        if (objectType == _types.error) return _types.error;

        auto fields = _declarer.fieldsOf(objectType);
        foreach (i, field; fields)
        {
            if (field.name == member.member)
            {
                _typing.fieldIndexes[expr.id] = i;
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
        if (auto type = symbol in _typing.symbolTypes) return *type;
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
        _typing.symbolTypes[SymbolId(for_.binding.id)] = range is null
            ? synthesizeForArray(*iterable, ctx)
            : synthesizeForRange(*iterable, *range, ctx);
        checkLoopBody(*for_.body, ctx);
        return _types.unit;
    }

    /// The element type of what a `for` loops over, which isn't a range.
    private Type synthesizeForArray(const Expr iterable, BodyContext ctx)
    {
        auto type = _declarer.requireTyped(synthesize(iterable, ctx), iterable.span);
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
        _typing.exprTypes[expr.id] = type;
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
        auto optionType = _declarer.requireTyped(synthesize(initializer, ctx), initializer.span);
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
        _typing.symbolTypes[SymbolId(binding.id)] = payload;
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
        if (a == _types.none) return _declarer.optionOf(b, span);
        if (b == _types.none) return _declarer.optionOf(a, span);

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
            (const ExprStmt e) => _typing.exprTypes.get(e.expr.id, _types.error) == _types.never,
            _ => false,
        );
    }

    private Type synthesizeIdentifier(const Expr expr, Type expected)
    {
        if (auto candidates = expr.id in _resolutions.overloads) return overloadedValue(expr, *candidates, expected);
        if (auto symbol = expr.id in _resolutions.resolutions) return namedValue(expr, *symbol, expected);
        // Name resolution couldn't find it and has already reported that.
        return _types.error;
    }

    /// What `name`, which resolution found to be `symbol`, is as a value.
    private Type namedValue(const Expr name, SymbolId symbol, Type expected)
    {
        auto isIntrinsic = symbol.match!(
            (const Id!FunctionDecl f) => _resolutions.declarations.functions[f].kind == FunctionKind.intrinsic,
            _ => false,
        );
        auto generic = genericNamed(name);
        if (generic.found && !isIntrinsic) return instantiateValue(name, generic, expected);
        if (generic.found) _declarer.resolveTypeArguments(generic.written);
        else rejectTypeArguments(typeArgsOf(name), spelling(name), name.span);
        return symbolValue(symbol, name.span);
    }

    /// Whether a constructor of `member`, which `owner` owns, should build the member itself.
    private bool wantsMember(Type member, Type owner, Type expected)
    {
        if (expected == member) return true;
        if (_types.isOption(expected)) return wantsMember(member, owner, _types.optionInner(expected));
        return expected != owner && _declarer.membersOf(expected).canFind(member);
    }

    /// The one member of `sum` that the option, array or tuple written out as `expr` can be, or
    /// `Type.init` if `expr` isn't one of those or there's no single member.
    private Type memberForSyntax(const Expr expr, Type sum)
    {
        auto candidates = expr.kind.match!(
            (const SomeExpr _) => _declarer.membersOf(sum).filter!(m => _types.isOption(m)).array,
            (const NoneLiteral _) => _declarer.membersOf(sum).filter!(m => _types.isOption(m)).array,
            (const ArrayLiteral _) => _declarer.membersOf(sum).filter!(m => _types.isArray(m)).array,
            (const BinaryExpr _) => isArraySyntax(expr) ? _declarer.membersOf(sum).filter!(m => _types.isArray(m)).array : null,
            (const TupleLiteral literal) => _declarer.membersOf(sum)
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
        // What's expected can say what a generic use's type arguments are.
        auto isMethod = expr.kind.match!((const CallExpr call) => isMethodCall(expr.id, *call.callee), _ => false);
        if (isMethod || genericUse(expr).found || isOverloadedUse(expr))
        {
            return coerce(expr, synthesizeExact(expr, ctx, expected), expected);
        }
        auto constructed = constructedDecl(expr);
        if (auto owner = _declarer.ownerOf(constructed))
        {
            auto member = _typing.nominalTypes[constructed];
            if (wantsMember(member, *owner, expected)) return coerce(expr, synthesizeExact(expr, ctx), expected);
        }
        if (_declarer.isSum(expected))
        {
            auto member = memberForSyntax(expr, expected);
            if (member != Type.init)
            {
                check(expr, member, ctx);
                _typing.promotions[expr.id] = expected;
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
            _typing.promotions[expr.id] = expected;
            return expected;
        }
        if (isNumeric(expected) || isOption || isArray || isTuple || _declarer.isSum(expected) || _declarer.isOwnedMember(expected)
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
                _typing.exprTypes[expr.id] = type;
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
        if (_declarer.isSum(expected))
        {
            auto hasValue = type != _types.error && type != _types.never;
            if (hasValue && type != expected)
            {
                if (isIntLiteral(expr)) return injectLiteral(expr, expected);
                if (isAssignable(type, expected))
                {
                    _typing.promotions[expr.id] = expected;
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
                _typing.promotions[expr.id] = expected;
                return expected;
            }
        }
        else if (expected == _types.any)
        {
            type = _declarer.requireTyped(type, expr.span);
            if (_types.mentionsParameter(type))
            {
                return reportOpaque(expr.span, type, "it can't be printed or go where any value is taken", "show: (%s) -> String");
            }
        }
        else if (type == _types.emptyArray && _types.isArray(expected))
        {
            _typing.promotions[expr.id] = expected;
            return expected;
        }
        requireAssignable(type, expected, expr.span);
        return type;
    }

    /// An integer literal in a sum takes the type of its only integer member, or else of a Float one.
    private Type injectLiteral(const Expr expr, Type sum)
    {
        auto integers = _declarer.membersOf(sum).filter!(m => _types.isInteger(m)).array;
        if (integers.length > 1)
        {
            _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
                "`%s` has more than one integer member; convert this to the one you mean, as in `%s(...)`"
                    .format(_types.describe(sum), _types.describe(integers[0])));
            return _types.error;
        }
        auto numbers = integers.length == 1 ? integers : _declarer.membersOf(sum).filter!(m => m == _types.float_).array;
        if (numbers.length == 1)
        {
            adaptLiteral(expr, numbers[0]);
            _typing.promotions[expr.id] = sum;
            return sum;
        }
        auto hint = _declarer.membersOf(sum).any!(m => _types.isOption(m) && isNumeric(innermost(m))) ? "; write `Some(...)`" : "";
        _collector.reportError(DiagnosticCode.TypeMismatch, expr.span,
            "An integer isn't a member of `%s`%s".format(_types.describe(sum), hint));
        return _types.error;
    }

    /// The subject and every pattern of a `match`, then whether the arms cover it. Bindings have
    /// their types once this returns, so the arms can be checked.
    private void checkMatchHead(const MatchExpr match_, Span span, BodyContext ctx)
    {
        auto subject = _declarer.requireTyped(synthesize(*match_.subject, ctx), match_.subject.span);
        auto reported = _collector.diagnostics.length;
        auto patterns = match_.arms.map!(arm => checkArmPattern(arm.pattern, subject, ctx)).array;
        if (match_.origin != MatchOrigin.Match || subject == _types.error || subject == _types.never) return;
        // A pattern that's already wrong would only be reported again as a gap in the coverage.
        if (_collector.diagnostics.length > reported) return;
        checkCoverage(match_, patterns, subject, span, _types, _declarer, _collector);
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
        _typing.patternSubjects[pattern.id] = subject;
        if (_types.isParameter(subject))
        {
            auto bound = pattern.kind.match!(
                (const VarDecl binding) {
                    auto type = binding.type is null ? subject : _declarer.resolveType(*binding.type);
                    _typing.symbolTypes[SymbolId(binding.id)] = type;
                    return type == subject || type == _types.error;
                },
                (_) {
                    checkArmPattern(pattern, _types.error, ctx);
                    _typing.patternSubjects[pattern.id] = subject;
                    return false;
                },
            );
            if (!bound) reportOpaque(pattern.span, subject, "a pattern on it can only bind it to a name", null);
            return CoveragePattern.init;
        }
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
        auto fields = _declarer.fieldsOf(member);
        return new CoveragePattern[fields.length];
    }

    /// Records that `pattern` tests for `member` of the sum `subject`, reporting it if there's no such member.
    private bool recordMember(const Pattern pattern, Type member, Type subject, out string key)
    {
        auto index = _declarer.membersOf(subject).countUntil(member);
        if (index < 0)
        {
            reportPattern(pattern.span, "`%s` can't be a `%s`".format(_types.describe(subject), _types.describe(member)));
            return false;
        }
        _typing.patternMembers[pattern.id] = index;
        key = "member%s".format(index);
        return true;
    }

    private CoveragePattern checkArmBinding(const Pattern pattern, const VarDecl binding, Type subject)
    {
        if (binding.type is null)
        {
            _typing.symbolTypes[SymbolId(binding.id)] = subject;
            return CoveragePattern.init;
        }
        auto type = _declarer.resolveType(*binding.type);
        _typing.symbolTypes[SymbolId(binding.id)] = type;
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

        // A generic type takes the arguments of the instance the subject is or holds.
        auto type = _typing.nominalTypes[decl];
        if (_declarer.typeParamsOf(decl).length > 0)
        {
            auto instance = (declOf(subject) == decl ? [subject] : _declarer.membersOf(subject).filter!(m => declOf(m) == decl).array);
            Substitution unknown;
            foreach (param; _declarer.typeParamsOf(decl)) unknown[param.id] = _types.error;
            type = instance.length > 0 ? instance[0] : _types.substitute(type, unknown);
        }
        auto fields = _declarer.fieldsOf(type);
        _typing.patternConstructors[pattern.id] = decl;
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
        _typing.exprTypes[expr.id] = type;
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
            (const OptionData o) => _declarer.isSum(o.inner) ? from == o.inner : isAssignable(from, o.inner),
            (const NominalData _) => _declarer.membersOf(to).canFind(from),
            // Both have the layout of an array with no elements, so no conversion hides here.
            (const ArrayData a) => from == _types.emptyArray
                || (_types.isArray(from) && _types.arrayElement(from) == _types.never),
            _ => false,
        );
    }

    private void requireAssignable(Type from, Type to, Span span)
    {
        if (isAssignable(from, to) || _types.mentionsError(from) || _types.mentionsError(to)) return;
        auto opaque = _types.isParameter(to)
            ? ", which could be any type; only a value of type `%s` is one".format(_types.describe(to)) : "";
        _collector.reportError(DiagnosticCode.TypeMismatch, span,
            "Type `%s` is not assignable to type `%s`%s".format(_types.describe(from), _types.describe(to), opaque));
    }

}

package Typing checkTypes(const ref Program program, const ref Resolution resolution, Collector collector)
{
    auto typeChecker = new TypeChecker(resolution, collector);
    return typeChecker.checkProgram(program);
}