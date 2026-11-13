/// The program's declared types and signatures: turning written types into checker types, and
/// what each declared type is made of.
module silver.sema.declare;

import std.algorithm;
import std.array;
import std.range : repeat;
import std.sumtype;
import std.string;

import silver.ast;
import silver.sema.resolve;
import silver.sema.type;
import silver.sema.typing;

package final class Declarer
{
    /// What it learns goes into `typing`, which the checker shares.
    this(TypeTable types, Typing* typing, const Resolution resolutions, Collector collector)
    {
        _types = types;
        _typing = typing;
        _resolutions = resolutions;
        _collector = collector;
    }

    package TypeTable _types;
    package Typing* _typing;
    package const Resolution _resolutions;
    package Collector _collector;
    package Type[Id!AliasDecl] _aliasTypes;
    /// The sum that declared each member it owns, which is what its constructor produces.
    package Type[Id!TypeDecl] _owners;

    /// The sum that owns the member `decl`, or null if no sum does.
    const(Type)* ownerOf(Id!TypeDecl decl) const
    {
        return decl in _owners;
    }

    package Type resolveType(const TypeExpr type)
    {
        return type.kind.match!(
            (const NamedType _) => resolveNamedType(type),
            (const OptionType option) => optionOf(resolveType(*option.inner), type.span),
            (const ErrorUnionType u) => errorUnionOf(resolveType(*u.success), u.errors),
            (const ArrayType array) => arrayOf(resolveType(*array.element), type.span),
            (const FunctionType func) => _types.function_(
                func.params.map!(p => resolveType(p)).array, resolveType(*func.returnType), func.mutableParams),
            (const UnitType _) => _types.unit,
            (const TupleType tuple) => tupleOf(tuple.elements.map!(e => resolveType(e)).array, tuple.elements),
        );
    }

    /// The tuple of `elements`, or `error` if one of them is, reported at its type expression in
    /// `written` when it's `Any`. Nothing that synthesizes a tuple can give it an `Any`.
    package Type tupleOf(Type[] elements, const(TypeExpr)[] written = null)
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
    package Type optionOf(Type inner, Span span)
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

    /// `success ! errors`, or `error` if a listed type is repeated or can't be an error, which is
    /// reported at the type as written.
    package Type errorUnionOf(Type success, const(TypeExpr)[] written)
    {
        auto failed = success == _types.error;
        Type[] errors;
        foreach (w; written)
        {
            auto type = resolveType(w);
            if (type == _types.error)
            {
                failed = true;
            }
            else if (type == _types.never || type == _types.any)
            {
                _collector.reportError(DiagnosticCode.InvalidErrorType, w.span,
                    "`%s` can't be an error".format(_types.describe(type)));
                failed = true;
            }
            else if (errors.canFind(type))
            {
                _collector.reportError(DiagnosticCode.InvalidErrorType, w.span,
                    "`%s` is already listed".format(_types.describe(type)));
                failed = true;
            }
            errors ~= type;
        }
        if (success == _types.any)
        {
            _collector.reportError(DiagnosticCode.InvalidOptionPayload, written[0].span, "An error union can't hold `Any`");
            failed = true;
        }
        return failed ? _types.error : _types.errorUnion(success, _types.errorList(errors));
    }

    /// The array of `element`, or `error` (reported at `span`) if there can't be one.
    package Type arrayOf(Type element, Span span)
    {
        if (element == _types.error) return element;
        if (element == _types.any)
        {
            _collector.reportError(DiagnosticCode.InvalidArrayElement, span, "An array can't hold `Any`");
            return _types.error;
        }
        return _types.array(element);
    }

    package Type reportUntypedNone(Span span)
    {
        _collector.reportError(DiagnosticCode.UntypedNone, span,
            "This `None` has no type to take here; annotate one, as in `val x: Int? = None`");
        return _types.error;
    }

    /// `constructor` is `Ok` or `Error`.
    package Type reportUntypedErrorUnion(string constructor, Span span)
    {
        _collector.reportError(DiagnosticCode.UntypedErrorUnion, span,
            "This `%s` has no error union to take its type from; annotate one, as in `val x: Int ! E = %s(...)`"
                .format(constructor, constructor));
        return _types.error;
    }

    package Type reportUntypedEmptyArray(Span span)
    {
        _collector.reportError(DiagnosticCode.UntypedEmptyArray, span,
            "This `[]` has no type to take here; annotate one, as in `val x: [Int] = []`");
        return _types.error;
    }

    /// Reports a value of `type` that nothing gives a type to, if it's one: a bare `None` or `[]`.
    package Type requireTyped(Type type, Span span)
    {
        if (type == _types.none) return reportUntypedNone(span);
        if (type == _types.emptyArray) return reportUntypedEmptyArray(span);
        if (_types.isFailure(type)) return reportUntypedErrorUnion("Error", span);
        return type;
    }

    package Type resolveNamedType(const TypeExpr typeExpr)
    {
        if (auto hidden = typeExpr.id in _resolutions.sugarParams)
        {
            return parameterType(*_resolutions.declarations.typeParams[*hidden]);
        }
        auto symbol = typeExpr.id in _resolutions.typeResolutions;
        if (symbol is null) return _types.error;
        auto named = typeExpr.kind.match!((const NamedType n) => n, (_) => assert(0, "only a named type resolves to a symbol"));

        Type withoutArguments(Type type)
        {
            if (named.args.length == 0) return type;
            foreach (arg; named.args) resolveType(arg);
            _collector.reportError(DiagnosticCode.WrongTypeArgumentCount, typeExpr.span,
                "`%s` isn't generic, so it takes no type arguments".format(named.path.join(".")));
            return _types.error;
        }

        return (*symbol).match!(
            (const Builtin builtIn) => withoutArguments(builtinType(builtIn)),
            (const Id!TypeDecl decl) => instanceType(decl, named, typeExpr.span),
            (const Id!AliasDecl decl) => withoutArguments(aliasType(decl)),
            (const Id!TypeParam param) => withoutArguments(parameterType(*_resolutions.declarations.typeParams[param])),
            // Name resolution only lets an interface through as a bound, which isn't resolved as a type.
            (const Id!InterfaceDecl _) => _types.error,
        );
    }

    /// What each bound of each of `params` names, for `typing.bounds`.
    package void declareBounds(const(TypeParam)[] params)
    {
        foreach (param; params)
        {
            Bound[] bounds;
            foreach (written; param.bounds) bounds ~= resolveBound(written);
            if (bounds.length > 0) _typing.bounds[param.id] = bounds;
        }
    }

    /// The interface and type arguments `written` names, or a bound that isn't valid when name
    /// resolution didn't find an interface, which it reported.
    private Bound resolveBound(const TypeExpr written)
    {
        auto symbol = written.id in _resolutions.typeResolutions;
        auto decl = symbol is null ? Id!InterfaceDecl.init
            : (*symbol).match!((const Id!InterfaceDecl i) => i, _ => Id!InterfaceDecl.init);
        if (!decl.isValid) return Bound.init;
        auto named = written.kind.match!((const NamedType n) => n, (_) => assert(0, "a bound is written as a named type"));
        auto interface_ = _resolutions.declarations.interfaces[decl];
        auto args = resolveTypeArguments(named.args);
        auto wanted = interface_.typeParams.length;
        if (args.length != wanted)
        {
            auto name = named.path.join(".");
            _collector.reportError(DiagnosticCode.WrongTypeArgumentCount, written.span, wanted == 0
                ? "`%s` takes no type arguments".format(name)
                : args.length == 0
                    ? "`%s` needs its type arguments, as in `%s`".format(name, example(name, wanted, ""))
                    : "`%s` takes %s type arguments, got %s".format(name, wanted, args.length));
            args = _types.error.repeat(wanted).array;
        }
        return Bound(decl, args);
    }

    /// What `bound`'s interface calls each of its type parameters and `Self`, when `self` conforms.
    package Substitution substitutionOf(const Bound bound, Type self)
    {
        auto interface_ = _resolutions.declarations.interfaces[bound.decl];
        Substitution substitution;
        substitution[interface_.self.id] = self;
        foreach (i, param; interface_.typeParams) substitution[param.id] = bound.args[i];
        return substitution;
    }

    /// `Json`, or `Range<Int>`.
    package string describe(const Bound bound)
    {
        auto name = _resolutions.declarations.interfaces[bound.decl].name;
        return bound.args.length == 0 ? name : "%s<%-(%s, %)>".format(name, bound.args.map!(a => _types.describe(a)));
    }

    /// The signature of each function a bound of `func` supplies inside it: the interface's, for
    /// the type parameter with the bound. Every interface's functions have their signatures by now.
    package void declareBoundFunctions(Id!FunctionDecl func)
    {
        foreach (supplied; _resolutions.boundFunctions.get(func, null))
        {
            auto requirement = _resolutions.requirements[supplied];
            auto bound = _typing.bounds[requirement.param][requirement.bound];
            auto self = parameterType(*_resolutions.declarations.typeParams[requirement.param]);
            _typing.symbolTypes[SymbolId(supplied)] = _types.substitute(_typing.symbolTypes[SymbolId(requirement.declared)],
                substitutionOf(bound, self));
        }
    }

    /// Declares the signatures of `interface_`'s functions, reporting what the first version of
    /// interfaces leaves out.
    package void declareInterface(const InterfaceDecl interface_)
    {
        foreach (param; interface_.typeParams)
        {
            if (param.bounds.length == 0) continue;
            _collector.reportError(DiagnosticCode.InvalidBound, param.bounds[0].span,
                "An interface's type parameter can't have a bound; put it on the function that uses `%s`".format(interface_.name));
        }
        foreach (i, func; interface_.functions)
        {
            declareSignature(func);
            auto params = _types[_typing.symbolTypes[SymbolId(func.id)]].match!((const FunctionData f) => f.params, _ => null);
            auto repeated = interface_.functions[0 .. i].canFind!(earlier => earlier.name == func.name
                && _types[_typing.symbolTypes[SymbolId(earlier.id)]].match!((const FunctionData f) => f.params == params, _ => false));
            if (repeated)
            {
                _collector.reportError(DiagnosticCode.DuplicateOverload, func.nameSpan,
                    "`%s` already declares a `%s` that takes these parameter types".format(interface_.name, func.name));
            }
            if (params.canFind(_types.error) || params.any!(p => _types.mentionsParameter(p, interface_.self.id))) continue;
            _collector.reportError(DiagnosticCode.InvalidBound, func.nameSpan,
                ("`%s` has to take a `Self`, since a function is found by what it's given; for one that only "
                    ~ "returns a `Self`, take `of: Of<Self>` to say which type is meant").format(func.name));
        }
    }

    /// `decl` with the type arguments `named` gives it, which have to be all of them.
    package Type instanceType(Id!TypeDecl decl, const NamedType named, Span span)
    {
        auto params = typeParamsOf(decl);
        auto name = named.path.join(".");
        auto args = resolveTypeArguments(named.args);
        if (params.length == 0 && args.length == 0) return _typing.nominalTypes[decl];
        if (args.length != params.length)
        {
            _collector.reportError(DiagnosticCode.WrongTypeArgumentCount, span, params.length == 0
                ? "`%s` isn't generic, so it takes no type arguments".format(name)
                : args.length == 0
                    ? "`%s` is generic, so it needs its type arguments, as in `%s`".format(name, example(name, params.length, ""))
                    : "`%s` takes %s type arguments, got %s".format(name, params.length, args.length));
            return _types.error;
        }
        if (args.canFind(_types.error)) return _types.error;
        return _types.nominal(decl, _resolutions.declarations.types[decl].name, args);
    }

    /// The types `written` names, each reported if it can't be a type argument.
    package Type[] resolveTypeArguments(const(TypeExpr)[] written)
    {
        Type[] args;
        foreach (arg; written)
        {
            auto type = resolveType(arg);
            if (type == _types.any)
            {
                _collector.reportError(DiagnosticCode.InvalidTypeArgument, arg.span,
                    "`Any` can't be a type argument, since no value has it as its type");
                type = _types.error;
            }
            args ~= type;
        }
        return args;
    }

    /// `name<Int, Int>` followed by `call`, to show where type arguments go.
    package static string example(string name, size_t count, string call)
    {
        return "%s<%-(%s, %)>%s".format(name, "Int".repeat(count), call);
    }

    package Type parameterType(const TypeParam param)
    {
        return _types.parameter(param.id, param.name);
    }

    package const(TypeParam)[] typeParamsOf(Id!TypeDecl decl)
    {
        return _resolutions.declarations.types[decl].typeParams;
    }

    /// What the type parameters of the declared type `type` stand for in it.
    package Substitution substitutionOf(Type type)
    {
        return _types[type].match!(
            (const NominalData nominal) {
                Substitution substitution;
                foreach (i, param; typeParamsOf(nominal.decl))
                {
                    if (i < nominal.args.length) substitution[param.id] = nominal.args[i];
                }
                return substitution;
            },
            _ => Substitution.init,
        );
    }

    /// The fields of `type` with its type arguments filled in, or none if it isn't a declared type.
    /// An intrinsic type has none, though its constructor has parameters.
    package FieldInfo[] fieldsOf(Type type)
    {
        return _types[type].match!(
            (const NominalData nominal) {
                if (isIntrinsic(nominal.decl)) return FieldInfo[].init;
                auto declared = _typing.fields.get(nominal.decl, null);
                if (nominal.args.length == 0) return declared;
                auto substitution = substitutionOf(type);
                return declared.map!(f => FieldInfo(f.name, _types.substitute(f.type, substitution))).array;
            },
            _ => FieldInfo[].init,
        );
    }

    /// Whether `decl` is an `intrinsic type`.
    package bool isIntrinsic(Id!TypeDecl decl)
    {
        return _resolutions.declarations.types[decl].intrinsic;
    }

    package Type aliasType(Id!AliasDecl id)
    {
        if (auto known = id in _aliasTypes) return *known;
        // A recursive alias, which name resolution reported, stops here.
        _aliasTypes[id] = _types.error;
        auto type = resolveType(_resolutions.declarations.aliases[id].target);
        _aliasTypes[id] = type;
        return type;
    }

    package Type builtinType(Builtin builtin)
    {
        final switch (builtin)
        {
            case Builtin.Never: return _types.never;
            case Builtin.Unit: return _types.unit;
            case Builtin.Bool: return _types.bool_;
            case Builtin.Int: return _types.int_;
            case Builtin.Float: return _types.float_;
            case Builtin.String: return _types.string_;
            case Builtin.Char: return _types.char_;
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

    package void declareSignature(const FunctionDecl func)
    {
        auto params = func.params.map!(p => resolveType(p.type)).array;
        foreach (i, param; func.params)
        {
            _typing.symbolTypes[SymbolId(param.id)] = params[i];
        }
        auto returnType = resolveType(func.returnType);
        if (func.kind == FunctionKind.native || func.kind == FunctionKind.intrinsic)
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
        _typing.symbolTypes[SymbolId(func.id)] = _types.function_(params, returnType, func.params.map!(p => p.mutable).array);
    }

    /// Reports a type in a native's signature that has no C equivalent.
    package void requireNativeType(Type type, Span span, bool isReturn)
    {
        if (type == _types.error || _types.isInteger(type) || type == _types.float_ || type == _types.bool_) return;
        if (isReturn && (type == _types.unit || type == _types.never)) return;
        _collector.reportError(DiagnosticCode.InvalidNativeType, span,
            "`%s` can't cross into C; a native function takes integers, `Float` and `Bool`%s".format(_types.describe(type),
                isReturn ? ", and can also return `Unit` or `Never`" : ""));
    }

    package void declareSum(const TypeDecl decl)
    {
        auto sum = _typing.nominalTypes[decl.id];
        _typing.fields[decl.id] = null;
        // Only its members can be built. Using the name as a value is reported where it's used.
        _typing.symbolTypes[SymbolId(decl.id)] = _types.error;

        Type[] members;
        foreach (member; decl.members)
        {
            auto type = resolveType(member.type);
            if (type == _types.error) continue;
            string problem;
            if (type == _types.any || type == _types.never) problem = "A sum can't have `%s` as a member".format(_types.describe(type));
            else if (type == sum) problem = "A sum can't be a member of itself";
            else if (members.canFind(type)) problem = "`%s` is already a member of this sum".format(_types.describe(type));
            else if (_types.isParameter(type))
            {
                problem = "A type parameter can't be a member by itself yet; wrap it, as in `Just(value: %s)`"
                    .format(_types.describe(type));
            }
            else if (members.any!(m => couldCoincide(m, type)))
            {
                problem = "`%s` and `%s` would be the same member in some instances of `%s`"
                    .format(_types.describe(members.find!(m => couldCoincide(m, type)).front), _types.describe(type),
                        _types.describe(sum));
            }
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
        _typing.members[decl.id] = members;
    }

    /// Whether some type arguments make `a` and `b` one type. Only a type parameter can stand for
    /// another type, and each one is free to.
    package bool couldCoincide(Type a, Type b)
    {
        if (!_types.mentionsParameter(a) && !_types.mentionsParameter(b)) return false;
        Substitution bound;

        Type resolved(Type t)
        {
            while (_types.isParameter(t))
            {
                auto param = _types[t].match!((const TypeParamData p) => p.param, (_) => Id!TypeParam.init);
                auto next = param in bound;
                if (next is null) break;
                t = *next;
            }
            return t;
        }

        bool unify(Type x, Type y)
        {
            x = resolved(x);
            y = resolved(y);
            if (x == y) return true;
            foreach (pair; [[x, y], [y, x]])
            {
                if (!_types.isParameter(pair[0])) continue;
                auto param = _types[pair[0]].match!((const TypeParamData p) => p.param, (_) => Id!TypeParam.init);
                if (_types.mentionsParameter(_types.substitute(pair[1], bound), param)) return false;
                bound[param] = pair[1];
                return true;
            }
            bool all(const(Type)[] xs, const(Type)[] ys)
            {
                if (xs.length != ys.length) return false;
                foreach (i; 0 .. xs.length)
                {
                    if (!unify(xs[i], ys[i])) return false;
                }
                return true;
            }
            auto yData = _types[y];
            return _types[x].match!(
                (const OptionData o) => yData.match!((const OptionData p) => unify(o.inner, p.inner), _ => false),
                (const ErrorUnionData u) => yData.match!(
                    (const ErrorUnionData p) => unify(u.success, p.success) && unify(u.error, p.error), _ => false),
                (const ErrorListData l) => yData.match!((const ErrorListData p) => all(l.members, p.members), _ => false),
                (const ArrayData a) => yData.match!((const ArrayData p) => unify(a.element, p.element), _ => false),
                (const TupleData t) => yData.match!((const TupleData p) => all(t.elements, p.elements), _ => false),
                (const FunctionData f) => yData.match!(
                    (const FunctionData p) => f.mutables == p.mutables && all(f.params ~ f.ret, p.params ~ p.ret),
                    _ => false),
                (const NominalData n) => yData.match!(
                    (const NominalData p) => n.decl == p.decl && all(n.args, p.args),
                    _ => false),
                _ => false,
            );
        }

        return unify(a, b);
    }

    package void declareConstructor(const TypeDecl decl)
    {
        if (decl.members.length > 0) return declareSum(decl);

        auto fields = decl.fields.map!(f => FieldInfo(f.name, resolveType(f.type))).array;
        _typing.fields[decl.id] = fields;

        auto declared = _typing.nominalTypes[decl.id];
        _typing.symbolTypes[SymbolId(decl.id)] = fields.length == 0
            ? declared
            : _types.function_(fields.map!(f => f.type).array, declared);
    }


    /// Reports the types no value can ever have, such as `type A(a: A)`: the ones that can be built
    /// are found from those needing nothing else, and whatever's left can't finish building itself.
    /// A generic type is buildable when certain of its parameters are, so what's found for each is
    /// the sets of its parameters, by index, any one of which is enough. At the declaration every
    /// parameter counts as buildable, so a type with at least one such set can be built.
    package void checkInhabited(M)(M modules)
    {
        const(TypeDecl)[] decls;
        foreach (mod; modules)
        {
            foreach (decl; mod.declarations)
            {
                decl.kind.match!((const TypeDecl t) { decls ~= t; }, (_) {});
            }
        }

        // Each set is a bit mask of parameter indexes; no sets at all means it can't be built.
        ulong[][Id!TypeDecl] needs;
        static ulong[] minimal(ulong[] sets)
        {
            ulong[] kept;
            foreach (set; sets.sort.uniq)
            {
                if (!kept.any!(k => (k & set) == k)) kept ~= set;
            }
            return kept;
        }
        static ulong[] both(const(ulong)[] a, const(ulong)[] b)
        {
            ulong[] sets;
            foreach (x; a)
            {
                foreach (y; b) sets ~= x | y;
            }
            return minimal(sets);
        }
        ulong[] canBuild(Type type, const TypeDecl within)
        {
            return _types[type].match!(
                (const TypeParamData p) {
                    auto index = within.typeParams.countUntil!(q => q.id == p.param);
                    return index < 0 ? [0UL] : [1UL << index];
                },
                (const TupleData tuple) => tuple.elements.fold!((sets, e) => both(sets, canBuild(e, within)))([0UL]),
                (const NominalData nominal) {
                    ulong[] sets;
                    foreach (set; needs.get(nominal.decl, null))
                    {
                        ulong[] met = [0UL];
                        foreach (i, arg; nominal.args)
                        {
                            if (set & (1UL << i)) met = both(met, canBuild(arg, within));
                        }
                        sets ~= met;
                    }
                    return minimal(sets);
                },
                _ => [0UL],
            );
        }
        ulong[] canBuildDecl(const TypeDecl decl)
        {
            if (decl.members.length == 0) return _typing.fields[decl.id].fold!((sets, f) => both(sets, canBuild(f.type, decl)))([0UL]);
            auto members = _typing.members[decl.id];
            if (members.length == 0) return [0UL];
            return minimal(members.map!(m => canBuild(m, decl)).join);
        }

        for (auto changed = true; changed;)
        {
            changed = false;
            foreach (decl; decls)
            {
                auto found = canBuildDecl(decl);
                if (found == needs.get(decl.id, null)) continue;
                needs[decl.id] = found;
                changed = true;
            }
        }

        bool buildable(Id!TypeDecl decl) => needs.get(decl, null).length > 0;
        foreach (decl; decls.filter!(d => !buildable(d.id)))
        {
            if (auto owner = decl.id in _owners)
            {
                if (!buildable(_types[*owner].match!((const NominalData n) => n.decl, (_) => Id!TypeDecl.init))) continue;
            }
            auto reason = "none of its members can be";
            if (decl.members.length == 0)
            {
                auto field = _typing.fields[decl.id].find!(f => canBuild(f.type, decl).length == 0).front;
                reason = "its field `%s: %s` can't be".format(field.name, _types.describe(field.type));
            }
            _collector.reportError(DiagnosticCode.UninhabitedType, decl.nameSpan,
                "No value of `%s` can ever be built, because %s; an option or array field would end the recursion"
                    .format(decl.name, reason));
        }
    }


    /// What the sum `type` can be, with its type arguments filled in.
    package const(Type)[] membersOf(Type type)
    {
        return _types[type].match!(
            (const NominalData nominal) {
                auto declared = _typing.members.get(nominal.decl, null);
                if (nominal.args.length == 0) return declared;
                auto substitution = substitutionOf(type);
                return declared.map!(m => _types.substitute(m, substitution)).array;
            },
            (const ErrorListData list) => list.members.dup,
            _ => (Type[]).init,
        );
    }

    package bool isSum(Type type)
    {
        return membersOf(type).length > 0;
    }

    package bool isOwnedMember(Type type)
    {
        return _types[type].match!((const NominalData nominal) => (nominal.decl in _owners) !is null, _ => false);
    }

}
