/// The functions a declared type's module writes in place of what every type has already:
/// `opEquals` for `==`, `opHash` for the hash a dictionary finds keys by, and `opString` for the
/// printed form.
module silver.sema.hooks;

import silver.ast;
import silver.sema.resolve : Resolution, SymbolId;
import silver.sema.type;
import silver.sema.typing : Typing;

import std.algorithm : all, any, canFind, find;
import std.range : empty, front, iota;
import std.format : format;
import std.sumtype : match;

private struct Shape
{
    string name;
    size_t arity;
    string what;
    string example;
}

private immutable shapes = [
    Shape("opEquals", 2, "what `==` means for a declared type, so it takes two values of that type and returns a `Bool`",
        "def opEquals(a: Point, b: Point): Bool"),
    Shape("opHash", 1, "the hash a declared type's values are found by as keys, so it takes one and returns a `UInt`",
        "def opHash(p: Point): UInt"),
    Shape("opString", 1, "how a declared type's values print, so it takes one and returns a `String`",
        "def opString(p: Point): String"),
];

/// Finds each module-level `opEquals`, `opHash` and `opString`, records it in `typing` for the
/// declared type it's written for, and reports one that isn't the type's own module's, hasn't the
/// shape, or is an `opEquals` without an `opHash` or the reverse.
package void checkTypeHooks(Modules)(Modules modules, ref Typing typing, const ref Resolution resolution, Collector collector)
{
    auto types = typing.types;
    Id!TypeDecl[] paired;

    void check(const FunctionDecl f, string moduleName)
    {
        auto named = shapes.find!(s => s.name == f.name);
        if (named.empty || f.invariantOf.isValid || f.testName !is null || f.kind == FunctionKind.required) return;
        auto shape = named.front;
        auto declared = SymbolId(f.id) in typing.symbolTypes;
        if (declared is null) return;
        auto isFunction = types[*declared].match!((const FunctionData _) => true, _ => false);
        if (!isFunction) return;
        auto signature = types[*declared].match!((const FunctionData data) => data, _ => assert(0));
        if (types.mentionsError(*declared)) return;

        bool nominal(Type type, out NominalData data)
        {
            return types[type].match!(
                (const NominalData n) {
                    data = n;
                    return true;
                },
                _ => false,
            );
        }

        auto isHash = f.name == "opHash";
        NominalData data;

        void wrong()
        {
            collector.reportError(DiagnosticCode.InvalidTypeFunction, f.nameSpan,
                "`%s` is %s, as in `%s`".format(f.name, shape.what, shape.example));
        }

        if (f.kind != FunctionKind.ordinary || signature.params.length != shape.arity) return wrong();
        auto self = signature.params[0];
        auto result = isHash ? types.uint_ : f.name == "opEquals" ? types.bool_ : types.string_;
        if (!nominal(self, data) || !signature.params.all!(p => p == self) || signature.ret != result
            || iota(signature.params.length).any!(i => signature.isMutable(i))) return wrong();

        auto whole = typing.nominalTypes[data.decl];
        if (resolution.declarations.typeModules[data.decl] != moduleName)
        {
            collector.reportError(DiagnosticCode.InvalidTypeFunction, f.nameSpan,
                "`%s` for `%s` belongs to the module that declares the type, `%s`; here, a function with a name of its own does this"
                    .format(f.name, types.describe(whole), resolution.declarations.typeModules[data.decl]));
            return;
        }

        // For every instance of the type: its arguments are the function's type parameters, each once.
        auto params = resolution.typeParamsOf(f.id);
        Id!TypeParam[] own;
        foreach (arg; data.args)
        {
            types[arg].match!(
                (const TypeParamData p) {
                    if (params.any!(q => q.id == p.param) && !own.canFind(p.param)) own ~= p.param;
                },
                (_) {},
            );
        }
        if (own.length != data.args.length || own.length != params.length
            || params.any!(p => p.bounds.length > 0))
        {
            collector.reportError(DiagnosticCode.InvalidTypeFunction, f.nameSpan,
                "`%s` is for every `%s`, so it takes the type with type parameters of its own, each once and none with a bound"
                    .format(f.name, types.describe(whole)));
            return;
        }

        auto table = isHash ? &typing.hashFunctions : f.name == "opEquals" ? &typing.equalsFunctions : &typing.stringFunctions;
        // A second one for the type is reported as a repeated overload.
        if (data.decl in *table) return;
        (*table)[data.decl] = f.id;
        if (f.name != "opString" && !paired.canFind(data.decl)) paired ~= data.decl;
    }

    // An arithmetic operator function that takes only built-in numbers could never be called by
    // its operator, which is built in for them.
    void checkArithmetic(const FunctionDecl f)
    {
        auto arity = f.name == "opNeg" ? 1 : ["opAdd", "opSub", "opMul", "opDiv", "opRem"].canFind(f.name) ? 2 : 0;
        if (arity == 0 || f.invariantOf.isValid || f.testName !is null || f.kind != FunctionKind.ordinary) return;
        auto declared = SymbolId(f.id) in typing.symbolTypes;
        if (declared is null || types.mentionsError(*declared)) return;
        auto params = types[*declared].match!((const FunctionData data) => data.params, _ => null);
        if (params.length != arity || !params.all!(p => types.isInteger(p) || p == types.float_)) return;
        collector.reportError(DiagnosticCode.InvalidOperatorFunction, f.nameSpan,
            "`%s` takes only built-in numbers, so the operator on them is built in and could never call it; an operator function is for a type of your own"
                .format(f.name));
    }

    foreach (mod; modules)
    {
        foreach (decl; mod.declarations)
        {
            decl.kind.match!(
                (const FunctionDecl f) {
                    check(f, mod.name);
                    checkArithmetic(f);
                },
                (_) {},
            );
        }
    }

    foreach (decl; paired)
    {
        auto equals = decl in typing.equalsFunctions;
        auto hash = decl in typing.hashFunctions;
        if (equals !is null && hash !is null) continue;
        auto written = equals !is null ? *equals : *hash;
        collector.reportError(DiagnosticCode.InvalidTypeFunction, resolution.declarations.functions[written].nameSpan,
            "`%s` has %s and no `%s`: values that are equal have to hash alike, so a type that writes one writes both".format(
                types.describe(typing.nominalTypes[decl]), equals !is null ? "an `opEquals`" : "an `opHash`",
                equals !is null ? "opHash" : "opEquals"));
    }
}
