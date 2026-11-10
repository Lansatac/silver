module silver.codegen.gen;

import std.algorithm : map;
import std.array : join;
import std.format : format;
import std.sumtype : match;

import silver.ast : Diagnostic, DiagnosticCode, DiagnosticException, SourceMap, Span;
import silver.codegen.runtime_bindings : runtime;
import silver.core;
import silver.sema : Type;

/// The LLVM IR for `program`, as text. `sources` locates spans for panic messages.
/// Throws: DiagnosticException (`NotImplemented`) at the first construct codegen doesn't handle yet.
string generate(const Program program, const SourceMap sources)
{
    return new Generator(program, sources).emitProgram();
}

/// The function being generated. Instructions are appended to it as they're emitted.
private final class FunctionState
{
    string[] lines;
    private int _nextTemp;
    private int _nextLabel;

    /// A fresh SSA name. Silver identifiers can't contain `.`, so names that start with one
    /// never clash with anything taken from source.
    string newTemp()
    {
        return "%%.t%s".format(_nextTemp++);
    }

    string newLabel(string hint)
    {
        return "%s.%s".format(hint, _nextLabel++);
    }

    void instruction(string text)
    {
        lines ~= "  " ~ text;
    }

    void label(string name)
    {
        lines ~= name ~ ":";
    }
}

private final class Generator
{
    private const Program _program;
    private const SourceMap _sources;
    private FunctionState _function;

    /// The runtime functions and intrinsics used, each declared once at the top of the module.
    private bool[string] _usedRuntime;
    private bool[string] _usedIntrinsics;
    private string[] _strings;

    this(const ref Program program, const SourceMap sources)
    {
        _program = program;
        _sources = sources;
    }

    string emitProgram()
    {
        string[] functions;
        foreach (ref func; _program.functions)
        {
            functions ~= emitFunction(func);
        }
        // After the functions, so every runtime call and string literal has been seen.
        return emitDeclares() ~ _strings.map!(s => s ~ "\n").join ~ "\n" ~ functions.join("\n") ~ "\n" ~ emitEntry();
    }

    /// `silver_main`, which the runtime calls once druntime has started.
    private string emitEntry()
    {
        auto main = _program.functions[_program.entryPoint];
        return "define void @silver_main() {\nentry:\n  call void %s()\n  ret void\n}\n".format(mangled(main));
    }

    private string emitDeclares()
    {
        string text;
        foreach (name; _usedRuntime.byKey)
        {
            auto f = runtime[name];
            text ~= "declare %s @%s(%s) %s\n".format(f.returnType, name, f.params.join(", "), f.attributes);
        }
        foreach (line; _usedIntrinsics.byKey)
        {
            text ~= line ~ "\n";
        }
        return text;
    }

    private string emitFunction(const Function func)
    {
        _function = new FunctionState;
        if (func.params.length > 0) notImplemented("parameters", func.body.span);
        auto returnType = llvmType(func.returnType, func.body.span);

        _function.label("entry");
        emitStackCheck(func.body.span);
        auto result = emitExpr(func.body);
        if (returnType == "void") _function.instruction("ret void");
        else _function.instruction("ret %s %s".format(returnType, result));

        return "define %s %s() {\n%s\n}\n".format(returnType, mangled(func), _function.lines.join("\n"));
    }

    /// Emits `e` into the current function, and returns its value as an operand: a temp, a
    /// constant or a global. Null for a value with no operand, like `()`.
    private string emitExpr(const Expr e)
    {
        return e.kind.match!(
            (const UnitLit _) => cast(string) null,
            (const Block block) => emitBlock(block),
            (other) => notImplemented(typeof(other).stringof, e.span),
        );
    }

    private string emitBlock(const Block block)
    {
        foreach (statement; block.statements)
        {
            emitStmt(statement);
        }
        return block.result is null ? null : emitExpr(*block.result);
    }

    private void emitStmt(const Stmt s)
    {
        s.kind.match!(
            (const Eval eval) { emitExpr(eval.expr); },
            (other) { notImplemented!void(typeof(other).stringof, s.span); },
        );
    }

    /// Every function checks on entry that it has room on the stack, and panics if not.
    private void emitStackCheck(Span span)
    {
        _usedIntrinsics["declare ptr @llvm.frameaddress.p0(i32 immarg)"] = true;
        _usedIntrinsics["@silver_stack_limit = external global ptr"] = true;
        auto message = cString("%s: Stack overflow".format(located(span)));
        _function.instruction("%.frame = call ptr @llvm.frameaddress.p0(i32 0)");
        _function.instruction("%.limit = load ptr, ptr @silver_stack_limit");
        _function.instruction("%.too.deep = icmp ult ptr %.frame, %.limit");
        _function.instruction("br i1 %.too.deep, label %stack.overflow, label %stack.ok");
        _function.label("stack.overflow");
        callRuntime("silver_panic", ["ptr " ~ message]);
        _function.instruction("unreachable");
        _function.label("stack.ok");
    }

    private void callRuntime(string name, string[] args)
    {
        _usedRuntime[name] = true;
        _function.instruction("call %s @%s(%s)".format(runtime[name].returnType, name, args.join(", ")));
    }

    /// A NUL-terminated global holding `text`, for the runtime's C-string parameters.
    private string cString(string text)
    {
        string escaped;
        foreach (char c; text)
        {
            if (c >= ' ' && c <= '~' && c != '"' && c != '\\') escaped ~= c;
            else escaped ~= "\\%02X".format(cast(ubyte) c);
        }
        auto name = "@.str.%s".format(_strings.length);
        _strings ~= "%s = private unnamed_addr constant [%s x i8] c\"%s\\00\"".format(name, text.length + 1, escaped);
        return name;
    }

    /// `file(line,column)`, as panic messages start.
    private string located(Span span)
    {
        auto location = _sources.locate(span);
        return "%s(%s,%s)".format(span.file, location.line, location.column);
    }

    private string llvmType(Type type, Span span)
    {
        auto types = _program.types;
        if (type == types.unit || type == types.never) return "void";
        if (type == types.bool_) return "i1";
        if (type == types.int_) return "i64";
        return notImplemented("the type " ~ types.describe(type), span);
    }

    private string mangled(const Function func)
    {
        return "@\"%s.%s\"".format(func.moduleName, func.name);
    }

    private T notImplemented(T = string)(string what, Span span)
    {
        throw new DiagnosticException(Diagnostic(DiagnosticCode.NotImplemented, span,
            "Not implemented in codegen yet: " ~ what));
    }
}
