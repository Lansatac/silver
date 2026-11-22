module silver.sema.entry;

import silver.ast;
import silver.sema.typing : Typing;
import silver.sema.resolve : Resolution, SymbolId;
import silver.sema.type : FunctionData;

/// Reports a program that doesn't have exactly one top-level `main` across all its modules, though
/// with `testing` it needn't have one. Returns that `main`, or an invalid ID if there isn't exactly one.
Id!FunctionDecl checkEntryPoint(const ref Program program, Collector collector, bool testing = false)
{
    import std.algorithm : map;
    import std.array : join;

    auto mains = mainFunctions(program);
    if (mains.length == 0 && !testing)
    {
        collector.reportError(DiagnosticCode.MissingMain, Span.init,
            "No module defines `def main(): Unit`");
    }
    else if (mains.length > 1)
    {
        auto owners = mains.map!(m => m.moduleName).join(", ");
        foreach (main; mains)
        {
            collector.reportError(DiagnosticCode.MultipleMains, main.nameSpan,
                "`main` is defined in more than one module: " ~ owners);
        }
    }
    if(mains.length == 1)
    {
        checkEntryPointShape(program, collector, mains[0]);
        return mains[0].id;
    }
    return Id!FunctionDecl.init;
}

//assumes main is already validated
void checkEntryPointShape(const ref Program program, Collector collector, const MainFunction main)
{
    import std.algorithm : find;
    import std.array : array;
    import std.sumtype : match;
    import std.range : empty;

    auto mainModule = program.modules[main.moduleName];
    foreach (decl; mainModule.declarations)
    {
        decl.kind.match!(
            (const FunctionDecl f) {
                if (f.name == "main")
                {
                    if (f.params.length > 1)
                    {
                        collector.reportError(DiagnosticCode.MainInvalidDefinition, f.params[1].nameSpan,
                            "`main` takes no parameters, or one, the program's arguments, as `main(args: [String])`");
                    }
                    else if (f.params.length == 1 && f.params[0].mutable)
                    {
                        collector.reportError(DiagnosticCode.MainInvalidDefinition, f.params[0].nameSpan,
                            "`main`'s arguments can't be `mutable`, since nothing reads them back");
                    }
                    if (!f.typeParams.empty)
                    {
                        collector.reportError(DiagnosticCode.MainInvalidDefinition, f.typeParams[0].span,
                            "`main` can't take type parameters, since nothing calls it with type arguments");
                    }
                }
            },
            (_) {},
        );
    }
}

/// Separate from the shape check because it needs the resolved types: `main`'s parameter and return
/// types can be written as aliases.
package void checkEntryPointSignature(Id!FunctionDecl entryPoint, const ref Resolution resolution, ref Typing typing,
    Collector collector)
{
    import std.sumtype : match;

    if (!entryPoint.isValid) return;
    auto types = typing.types;
    auto signature = types[typing.symbolTypes[SymbolId(entryPoint)]].match!(
        (const FunctionData f) => f,
        _ => FunctionData(null, types.error),
    );
    auto decl = resolution.declarations.functions[entryPoint];
    // A generic `main` is reported already, and its parameter's type would only repeat that.
    if (signature.params.length == 1 && decl.typeParams.length == 0)
    {
        auto param = signature.params[0];
        immutable arguments = types.isArray(param) && types.arrayElement(param) == types.string_;
        if (!arguments && !types.mentionsError(param))
        {
            collector.reportError(DiagnosticCode.MainInvalidDefinition, decl.params[0].type.span,
                "`main`'s parameter is the program's arguments, a `[String]`, not `" ~ types.describe(param) ~ "`");
        }
    }
    auto returnType = signature.ret;
    auto fallible = types.isErrorUnion(returnType) && types.successOf(returnType) == types.unit;
    if (returnType != types.unit && returnType != types.error && !fallible)
    {
        collector.reportError(DiagnosticCode.MainInvalidDefinition, decl.nameSpan,
            "`main` must return `Unit`, or `Unit ! E` for an error type `E`");
    }
}

version (unittest)
{
    import fluent.asserts;
    import std.array : array;
    import silver.syntax.parse : parse;

    /// A program made of `sources`, by module name, parsed without touching the disk.
    Program programOf(string[string] sources)
    {
        Program program;
        program.sources = new SourceMap;
        foreach (name, source; sources)
        {
            auto file = name ~ ".ag";
            program.sources.add(file, source);
            program.modules[name] = new Module;
            *program.modules[name] = parse(source, name, new NodeIds(ModuleKey.of(name, source)), file);
        }
        return program;
    }

    const(Diagnostic)[] entryPointErrors(string[string] sources)
    {
        auto collector = new Collector;
        auto program = programOf(sources);
        checkEntryPoint(program, collector);
        return collector.errors.array;
    }
}

@("checkEntryPoint accepts main in the only module")
unittest
{
    entryPointErrors(["app": "def main(): Unit => ()"]).length.should.equal(0);
}

@("checkEntryPoint accepts main in a module other than the one the program started from")
unittest
{
    entryPointErrors(["script": "import app", "app": "module app\ndef main(): Unit => ()"])
        .length.should.equal(0);
}

@("checkEntryPoint returns the one main's ID")
unittest
{
    import std.sumtype : match;

    auto program = programOf(["app": "def helper(): Unit => ()\ndef main(): Unit => ()"]);
    auto main = program.modules["app"].declarations[1].kind.match!(
        (const FunctionDecl f) => f.id,
        _ => Id!FunctionDecl.init,
    );
    checkEntryPoint(program, new Collector).should.equal(main);
}

@("checkEntryPoint returns an invalid ID unless there's exactly one main")
unittest
{
    auto none = programOf(["app": "def f(): Unit => ()"]);
    checkEntryPoint(none, new Collector).isValid.should.equal(false);
    auto two = programOf(["a": "def main(): Unit => ()", "b": "def main(): Unit => ()"]);
    checkEntryPoint(two, new Collector).isValid.should.equal(false);
}

@("checkEntryPoint reports a program without main, with no location")
unittest
{
    auto errors = entryPointErrors(["app": "def f(): Unit => ()", "lib": "def g(): Unit => ()"]);
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.MissingMain);
    errors[0].span.should.equal(Span.init);
}

@("checkEntryPoint reports every main when more than one module defines it")
unittest
{
    import std.algorithm : map;

    auto errors = entryPointErrors(["b": "def main(): Unit => ()", "a": "def main(): Unit => ()"]);
    errors.length.should.equal(2);
    errors.map!(e => e.code).array.should.equal([DiagnosticCode.MultipleMains, DiagnosticCode.MultipleMains]);
    errors.map!(e => e.span.file).array.should.equal(["a.ag", "b.ag"]);
    errors[0].message.should.contain("a, b");
}

@("checkEntryPoint ignores a main that isn't at a module's top level")
unittest
{
    auto errors = entryPointErrors(["app": "def run(): Unit {\n    def main(): Unit => ()\n}"]);
    errors.length.should.equal(1);
    errors[0].code.should.equal(DiagnosticCode.MissingMain);
}

@("checkEntryPoint accepts main with no parameter or one, and reports two or a mutable one")
unittest
{
    entryPointErrors(["app": "def main(args: [String]): Unit {}"]).length.should.equal(0);
    foreach (source; ["def main(a: [String], b: [String]): Unit {}", "def main(mutable a: [String]): Unit {}"])
    {
        auto errors = entryPointErrors(["app": source]);
        errors.length.should.equal(1);
        errors[0].code.should.equal(DiagnosticCode.MainInvalidDefinition);
    }
}
