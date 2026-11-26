/// Where calls keep their locals: frames taken from large blocks and given back in order, since a
/// frame never outlives its call, rather than an array allocated for each call.
module silver.interpreter.frames;

import silver.interpreter.values : Value;

struct FrameStack
{
    /// Each block is allocated once and never moves, so a frame stays where it is while calls
    /// above it take and give back theirs. The collector scans them, as they hold Values.
    private Value[][] blocks;
    private size_t block;
    /// How much of `blocks[block]` is in use.
    private size_t top;

    private enum blockLength = 64 * 1024;

    /// Where the stack was before a frame was taken, to go back to.
    struct Mark
    {
        private size_t block;
        private size_t top;
    }

    /// The current position, which `release` goes back to.
    Mark mark() const
    {
        return Mark(block, top);
    }

    /// `length` Values for a call, each `Value.init`.
    Value[] take(size_t length)
    {
        if (blocks.length == 0 || top + length > blocks[block].length)
        {
            auto next = blocks.length == 0 ? 0 : block + 1;
            // A block past the current one is unused, so one too small for this frame is replaced.
            auto room = length > blockLength ? length : blockLength;
            if (next == blocks.length) blocks ~= new Value[room];
            else if (blocks[next].length < length) blocks[next] = new Value[room];
            block = next;
            top = 0;
        }
        auto frame = blocks[block][top .. top + length];
        top += length;
        return frame;
    }

    /// Gives back every frame taken since `mark`, clearing them, so what they held can be collected.
    /// Frames are given back in the order opposite to how they were taken, except when a panic
    /// abandons several at once, which this also handles.
    void release(Mark mark)
    {
        if (blocks.length == 0) return;
        while (block > mark.block)
        {
            blocks[block][0 .. top] = Value.init;
            block--;
            top = blocks[block].length;
        }
        blocks[block][mark.top .. top] = Value.init;
        top = mark.top;
    }
}

@("frames come back cleared, and a frame too large for a block gets one of its own")
unittest
{
    import silver.interpreter.values : Unit;

    FrameStack stack;
    auto start = stack.mark;
    auto a = stack.take(3);
    a[0] = Value(1L);
    auto inner = stack.mark;
    auto b = stack.take(FrameStack.blockLength);
    b[$ - 1] = Value(2L);
    auto c = stack.take(5);
    c[4] = Value(3L);
    assert(a.ptr !is b.ptr && b.ptr !is c.ptr);
    stack.release(inner);
    assert(b[$ - 1].has!Unit && c[4].has!Unit);
    assert(a[0].as!long == 1);
    auto d = stack.take(2);
    assert(d.ptr is a.ptr + 3);
    stack.release(start);
    assert(a[0].has!Unit);
}
