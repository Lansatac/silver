module silver.sema.entry;

import silver.ast;

/// Reports a program that doesn't have exactly one top-level `main` across all its modules.
void checkEntryPoint(const ref Program program, Collector collector)
{
    import std.algorithm : map;
    import std.array : join;

    auto mains = mainFunctions(program);
    if (mains.length == 0)
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
        program.ids = new NodeIds;
        foreach (name, source; sources)
        {
            auto file = name ~ ".ag";
            program.sources.add(file, source);
            program.modules[name] = new Module;
            *program.modules[name] = parse(source, name, program.ids, file);
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
