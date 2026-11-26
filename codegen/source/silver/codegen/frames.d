/// Which functions check the stack: a bound on each function's frame, read from the IR emitted for
/// it, and the chains of unchecked frames over the call graph. See `notes/runtime.md`, "Which
/// functions check the stack".
module silver.codegen.frames;

import std.algorithm : canFind, max, startsWith;
import std.string : indexOf, strip;

/// The most a chain of calls that don't check the stack may take, by `frameBound`: the runtime's
/// 1 MB margin below the last check covers it, with room left for natives and the runtime's own frames.
enum uncheckedChain = 256 * 1024;

/// The call graph, as plain data, indexed by function.
struct CallGraph
{
    /// A bound on each function's frame.
    size_t[] frames;
    /// What each function calls directly or makes a function value of.
    size_t[][] callees;
    /// Whether each function calls what the call graph can't see: a function value, a native, an
    /// intrinsic, or a comparison or hash of function values.
    bool[] opaque;
    /// Whether a call the graph can't see can land in each function: a closure's target, or what
    /// compares or hashes closures' captures.
    bool[] reached;
    /// Whether each function is on a cycle of direct calls.
    bool[] recursive;
}

/// The functions that check the stack on entry. Only recursion can overflow it, and every cycle of
/// calls passes through a function on a cycle of direct calls or one that a function value reaches
/// and that calls something in turn; one that calls nothing, as `x => x * 2` doesn't, is on no
/// cycle. Since the check is made once a function's frame exists, the margin must also cover every
/// frame below it down to the next check, so a function on no cycle checks too when the longest
/// chain of unchecked frames starting at it would pass `threshold`.
bool[] checkedFunctions(const CallGraph graph, size_t threshold = uncheckedChain)
{
    auto count = graph.frames.length;
    auto checked = graph.recursive.dup;
    size_t opaqueFrame = 0;
    foreach (i; 0 .. count)
    {
        if (!graph.reached[i]) continue;
        if (graph.opaque[i] || graph.callees[i].length > 0) checked[i] = true;
        // A call the graph can't see lands in one of these, which checks if it calls anything, so
        // its own frame is all it adds. Natives and the runtime are left to what the margin has
        // beyond the threshold.
        opaqueFrame = max(opaqueFrame, graph.frames[i]);
    }

    // Below each function that doesn't check: its frame and the longest chain under it. Those
    // functions are on no cycle, so this ends.
    auto chains = new size_t[](count);
    auto known = new bool[](count);
    size_t below(size_t f)
    {
        if (checked[f]) return graph.frames[f];
        if (known[f]) return chains[f];
        size_t deepest = graph.opaque[f] ? opaqueFrame : 0;
        foreach (next; graph.callees[f]) deepest = max(deepest, below(next));
        known[f] = true;
        chains[f] = graph.frames[f] + deepest;
        if (chains[f] <= threshold) return chains[f];
        checked[f] = true;
        return graph.frames[f];
    }

    foreach (i; 0 .. count) below(i);
    return checked;
}

/// What clang -O0 allocates for a frame besides the instructions' values: the return address, the
/// saved frame pointer and alignment.
private enum fixedFrame = 64;
/// Windows' shadow space for a call's register arguments, which the caller allocates.
private enum shadowSpace = 32;

/// A bound on the stack the function whose body is `lines` (its instructions and labels) takes at
/// -O0, given its number of scalar `parameters`, with `structs` giving the fields of each named
/// struct type. Unoptimized, clang gives every alloca its own memory and every value its own spill
/// slot, none of them shared, so the frame grows with the code rather than with what is live at
/// once. Counted: each alloca; each parameter and each value an instruction makes, a scalar's slot
/// as 8 bytes; a load of a struct at its size, and a call's struct result twice, for the memory
/// it's returned through and for its scalars; and the largest outgoing argument area. An
/// `insertvalue` adds only the scalar it inserts: the struct it builds is the operand's with one
/// field changed, and codegen builds one only to return it from the same block.
size_t frameBound(const string[] lines, size_t parameters, const(string)[][string] structs)
{
    size_t bytes = fixedFrame + 8 * parameters;
    size_t arguments = 0;
    foreach (line; lines)
    {
        auto text = line.strip;
        auto equals = text.indexOf(" = ");
        auto defines = text.startsWith("%") && equals > 0;
        auto instruction = defines ? text[equals + 3 .. $] : text;
        if (instruction.startsWith("alloca "))
        {
            auto type = instruction["alloca ".length .. $];
            size_t alignment = 8;
            auto aligned = type.indexOf(", align ");
            if (aligned >= 0)
            {
                import std.conv : to;

                alignment = max(alignment, type[aligned + ", align ".length .. $].to!size_t);
                type = type[0 .. aligned];
            }
            bytes += roundUp(bytesOf(type, structs), alignment);
            continue;
        }
        auto call = callIn(instruction);
        if (call.found)
        {
            arguments = max(arguments, call.area);
            if (defines) bytes += isAggregate(call.result) ? 2 * roundUp(bytesOf(call.result, structs), 8) : 8;
            continue;
        }
        if (!defines) continue;
        if (instruction.startsWith("load "))
        {
            auto type = instruction["load ".length .. $];
            auto comma = topLevelComma(type);
            if (comma >= 0) type = type[0 .. comma];
            bytes += roundUp(bytesOf(type.strip, structs), 8);
            continue;
        }
        bytes += 8;
    }
    return roundUp(bytes + arguments, 16);
}

/// The result type of the call `instruction` makes, if it is one, and the outgoing argument area it
/// needs: Windows' shadow space and 8 bytes an argument. An inline `asm`'s operands are in
/// registers, so it needs none.
private auto callIn(string instruction)
{
    struct Call
    {
        bool found;
        string result;
        size_t area;
    }

    foreach (prefix; ["call ", "tail call ", "musttail call ", "notail call "])
    {
        if (!instruction.startsWith(prefix)) continue;
        auto rest = instruction[prefix.length .. $];
        // Return attributes, such as `zeroext` or `noalias`, come before the type.
        while (true)
        {
            auto space = rest.indexOf(' ');
            if (space < 0) break;
            auto word = rest[0 .. space];
            if (!["zeroext", "signext", "noalias", "noundef", "nonnull", "inreg", "fastcc", "ccc"].canFind(word)) break;
            rest = rest[space + 1 .. $];
        }
        auto typeEnd = typeLength(rest);
        auto result = rest[0 .. typeEnd];
        auto callee = rest[typeEnd .. $].strip;
        if (callee.startsWith("asm ")) return Call(true, result, 0);
        auto open = callee.indexOf('(');
        if (open < 0) return Call(true, result, shadowSpace);
        size_t depth = 0, count = 0;
        bool any = false;
        foreach (c; callee[open + 1 .. $])
        {
            if (c == '(' || c == '{' || c == '[' || c == '<') depth++;
            else if (c == ')' || c == '}' || c == ']' || c == '>')
            {
                if (depth == 0) break;
                depth--;
            }
            else if (c == ',' && depth == 0) count++;
            else if (c != ' ') any = true;
        }
        return Call(true, result, shadowSpace + 8 * (any ? count + 1 : 0));
    }
    return Call(false, null, 0);
}

/// How long the LLVM type that `text` starts with is: a word, or a braced literal struct.
private size_t typeLength(string text)
{
    if (text.startsWith("{") || text.startsWith("<{") || text.startsWith("["))
    {
        size_t depth = 0;
        foreach (i, c; text)
        {
            if (c == '{' || c == '[' || c == '<') depth++;
            else if (c == '}' || c == ']' || c == '>')
            {
                depth--;
                if (depth == 0) return i + 1;
            }
        }
        return text.length;
    }
    auto space = text.indexOf(' ');
    return space < 0 ? text.length : space;
}

private ptrdiff_t topLevelComma(string text)
{
    size_t depth = 0;
    foreach (i, c; text)
    {
        if (c == '{' || c == '[' || c == '<' || c == '(') depth++;
        else if (c == '}' || c == ']' || c == '>' || c == ')') depth--;
        else if (c == ',' && depth == 0) return i;
    }
    return -1;
}

private bool isAggregate(string type)
{
    return type.startsWith("%") || type.startsWith("{") || type.startsWith("<{") || type.startsWith("[");
}

/// The size of a value of the LLVM type `type` as LLVM lays it out in memory: a scalar, a named
/// struct (`structs` gives its fields), a literal struct or an array.
size_t bytesOf(string type, const(string)[][string] structs)
{
    type = type.strip;
    if (auto fields = type in structs) return layout(*fields, structs);
    if (type.startsWith("{") && type.endsWith("}"))
    {
        return layout(splitFields(type[1 .. $ - 1]), structs);
    }
    if (type.startsWith("["))
    {
        import std.conv : to;

        auto x = type.indexOf(" x ");
        return type[1 .. x].strip.to!size_t * bytesOf(type[x + 3 .. $ - 1], structs);
    }
    switch (type)
    {
        case "void": return 0;
        case "i1", "i8": return 1;
        case "i16": return 2;
        case "i32", "float": return 4;
        default: return 8;
    }
}

private size_t layout(const string[] fields, const(string)[][string] structs)
{
    size_t at = 0, alignment = 1;
    foreach (field; fields)
    {
        auto size = bytesOf(field, structs);
        auto fieldAlignment = field in structs || field.strip.startsWith("{") ? 8 : max(size, 1);
        at = roundUp(at, fieldAlignment) + size;
        alignment = max(alignment, fieldAlignment);
    }
    return roundUp(at, alignment);
}

private string[] splitFields(string text)
{
    string[] fields;
    while (text.strip.length > 0)
    {
        auto comma = topLevelComma(text);
        if (comma < 0)
        {
            fields ~= text.strip;
            break;
        }
        fields ~= text[0 .. comma].strip;
        text = text[comma + 1 .. $];
    }
    return fields;
}

private size_t roundUp(size_t n, size_t to) => (n + to - 1) / to * to;

private bool endsWith(string text, string suffix) => text.length >= suffix.length && text[$ - suffix.length .. $] == suffix;

@("a frame's bound counts its allocas, every value, a struct result twice and the largest argument area")
unittest
{
    const(string)[][string] structs = ["%T.0": ["i64", "i8", "ptr"]];
    assert(bytesOf("%T.0", structs) == 24);
    assert(bytesOf("{ i64, i32 }", structs) == 16);
    assert(bytesOf("[100 x i8]", structs) == 100);
    // 64 fixed, two parameters, 24 + 8 + 112 of allocas, two values of 8, the struct result twice,
    // the struct loaded, and the call with three arguments after 32 bytes of shadow space.
    auto lines = [".entry:", "  %x.addr = alloca %T.0", "  %n.addr = alloca i1", "  %.c0 = alloca [100 x i8], align 16",
        "  %.t0 = add i64 %n, 1", "  %.t1 = icmp eq i64 %.t0, 0", "  %.t2 = call %T.0 @\"main.f\"(i64 %.t0, ptr %x.addr, i1 %.t1)",
        "  call void @silver_panic(ptr @a, ptr @b)", "  %.t3 = load %T.0, ptr %x.addr", "  ret i64 0"];
    assert(frameBound(lines, 2, structs) == roundUp(64 + 16 + 24 + 8 + 112 + 8 + 8 + 48 + 24 + (32 + 24), 16));
    // An inline asm passes nothing on the stack, and a call without arguments only the shadow space.
    assert(frameBound(["  call void asm sideeffect \"\", \"r,r\"(ptr %a, ptr %b)"], 0, structs) == 64);
    assert(frameBound(["  %.t0 = call ptr @llvm.frameaddress.p0(i32 0)", "  call void @g()"], 0, structs) == roundUp(64 + 8 + 40, 16));
    assert(frameBound(["  %.t0 = call zeroext i1 @h(i64 1)"], 0, structs) == roundUp(64 + 8 + 40, 16));
}

@("a phi takes two slots, its own and the copy made for it where each arm ends")
unittest
{
    // Measured with clang -O0 on Windows and Linux: a function passing eight 64-scalar products
    // that are each `if n > i => B(...) else B(...)` of constants has 512 phis and a frame of
    // 8,912 bytes, 16 a phi, against a bound of 5,320.
    auto lines = ["  %.t0 = phi i64 [ 1, %.then.0 ], [ 2, %.else.1 ]", "  %.t1 = phi i64 [ 3, %.then.0 ], [ 4, %.else.1 ]"];
    assert(frameBound(lines, 0, null) == 64 + 2 * 16);
}

@("a function on no cycle checks the stack only where the chain of unchecked frames below it passes the threshold")
unittest
{
    CallGraph graph(size_t[] frames, size_t[][] callees)
    {
        auto count = frames.length;
        return CallGraph(frames, callees, new bool[](count), new bool[](count), new bool[](count));
    }

    // A chain 0 -> 1 -> ... -> 9 of 30 bytes each, under a threshold of 100: from the bottom, 6's
    // chain is the first to pass it, then 3's and 0's, each starting again above the last check.
    auto chain = graph([30, 30, 30, 30, 30, 30, 30, 30, 30, 30], [[1], [2], [3], [4], [5], [6], [7], [8], [9], []]);
    assert(checkedFunctions(chain, 100) == [true, false, false, true, false, false, true, false, false, false]);

    // A diamond counts the deeper side once: 0 calls 1 and 2, which both call 3.
    auto diamond = graph([10, 50, 20, 45], [[1, 2], [3], [3], []]);
    assert(checkedFunctions(diamond, 104) == [true, false, false, false]);
    assert(checkedFunctions(diamond, 105) == [false, false, false, false]);

    // A checked function in the middle adds only its frame: 1 is on a cycle with itself.
    auto cycle = graph([60, 60, 60], [[1], [1, 2], []]);
    cycle.recursive[1] = true;
    assert(checkedFunctions(cycle, 120) == [false, true, false]);
    assert(checkedFunctions(cycle, 119) == [true, true, false]);
}

@("a call the call graph can't see adds the biggest frame a function value reaches")
unittest
{
    // 0 calls a function value; 1 and 2 are targets of one, 1 calling nothing and 2 calling 3.
    auto graph = CallGraph([10, 70, 20, 50], [[], [], [3], []], [true, false, false, false],
        [false, true, true, false], [false, false, false, false]);
    // 2 is reached and calls something, so it checks; 1 calls nothing and doesn't.
    assert(checkedFunctions(graph, 1000) == [false, false, true, false]);
    // 0's chain is its frame and the biggest a function value reaches, 70.
    assert(checkedFunctions(graph, 79) == [true, false, true, false]);
    assert(checkedFunctions(graph, 80) == [false, false, true, false]);
    // A native or intrinsic call with no function value anywhere adds nothing.
    auto alone = CallGraph([10, 70], [[], []], [true, false], [false, false], [false, false]);
    assert(checkedFunctions(alone, 70) == [false, false]);
}
