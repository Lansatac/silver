module silver.interpreter.values;

/// A Silver value while the program runs. Every Core `Expr` has a type, so the evaluator always
/// knows which of these to expect; the cases only have to keep values of different layouts apart.
///
/// - Every integer type is a `long` holding the value's 64-bit two's complement, as `IntLit`
///   stores it. The `Expr`'s type says which width and signedness the bits mean.
/// - Tuples, user types and sums, options among them, are all a `Record`.
/// - A `[UInt8]` is a `string`, as a String is, so that one can be viewed as the other without
///   copying. Written `[]` it can still arrive as an empty `ArrayValue`.
/// - A `Ref` is a `CellValue`, the one value that changes after it's built.
/// - A `Jump` isn't a Silver value. It's what evaluating a `Break`, `Continue` or `Return` gives,
///   in place of the value an expression of type `Never` hasn't got.
///
/// It's a union written by hand because `std.sumtype` gives a type that holds itself, as this
/// does through `ArrayValue`, a destructor that runs for every copy.
struct Value
{
    private enum Kind : ubyte
    {
        unit,
        boolean,
        integer,
        floating,
        text,
        array,
        record,
        closure,
        cell,
        jump,
    }

    private Kind _kind;
    private union
    {
        bool _boolean;
        long _integer;
        double _floating;
        string _text;
        ArrayValue _array;
        Record _record;
        Closure _closure;
        CellValue _cell;
        Jump _jump;
    }

    this(Unit _)
    {
    }

    this(bool value)
    {
        _kind = Kind.boolean;
        _boolean = value;
    }

    this(long value)
    {
        _kind = Kind.integer;
        _integer = value;
    }

    this(double value)
    {
        _kind = Kind.floating;
        _floating = value;
    }

    this(string value)
    {
        _kind = Kind.text;
        _text = value;
    }

    this(ArrayValue value)
    {
        _kind = Kind.array;
        _array = value;
    }

    this(Record value)
    {
        _kind = Kind.record;
        _record = value;
    }

    this(Closure value)
    {
        _kind = Kind.closure;
        _closure = value;
    }

    this(CellValue value)
    {
        _kind = Kind.cell;
        _cell = value;
    }

    this(Jump value)
    {
        _kind = Kind.jump;
        _jump = value;
    }

    /// Whether it holds a `T`.
    bool has(T)() const
    {
        return _kind == kindOf!T;
    }

    /// The `T` it holds, which the evaluator already knows it does from the `Expr`'s type.
    T as(T)()
    {
        assert(has!T, "Core's types say this value is a " ~ T.stringof);
        static if (is(T == Unit)) return Unit();
        else static if (is(T == bool)) return _boolean;
        else static if (is(T == long)) return _integer;
        else static if (is(T == double)) return _floating;
        else static if (is(T == string)) return _text;
        else static if (is(T == ArrayValue)) return _array;
        else static if (is(T == Record)) return _record;
        else static if (is(T == Closure)) return _closure;
        else static if (is(T == CellValue)) return _cell;
        else static if (is(T == Jump)) return _jump;
        else static assert(0, T.stringof ~ " is no layout of a Value");
    }

    private template kindOf(T)
    {
        static if (is(T == Unit)) enum kindOf = Kind.unit;
        else static if (is(T == bool)) enum kindOf = Kind.boolean;
        else static if (is(T == long)) enum kindOf = Kind.integer;
        else static if (is(T == double)) enum kindOf = Kind.floating;
        else static if (is(T == string)) enum kindOf = Kind.text;
        else static if (is(T == ArrayValue)) enum kindOf = Kind.array;
        else static if (is(T == Record)) enum kindOf = Kind.record;
        else static if (is(T == Closure)) enum kindOf = Kind.closure;
        else static if (is(T == CellValue)) enum kindOf = Kind.cell;
        else static if (is(T == Jump)) enum kindOf = Kind.jump;
        else static assert(0, T.stringof ~ " is no layout of a Value");
    }
}

/// The value of `()`.
struct Unit
{
}

/// `[T]`. D's slices already behave like the frontier rule: appending to a value that ends
/// where its buffer's used part does extends it in place, and anything else copies.
struct ArrayValue
{
    Value[] elements;
}

/// A tuple, an instance of a user type, or a value of a sum. For a sum or option, `tag` is which
/// member the value is and `fields` holds its payload, if it has one; for anything else `tag`
/// is 0 and `fields` are in declaration order. Never changed once built, so sharing one can't be
/// observed.
struct Record
{
    size_t tag;
    Value[] fields;
}

/// A `Ref`, which every copy of the value shares. `full` is false while an `update` holds the contents.
final class CellValue
{
    Value contents;
    bool full = true;

    this(Value contents)
    {
        this.contents = contents;
    }
}

/// A function value: the Core function `target`, and the values its captures take.
struct Closure
{
    size_t target;
    Value[] captures;
}

/// Leaves the loop named `label`, starts its body again, or leaves the function, whose frame
/// holds the value returned.
struct Jump
{
    enum Kind
    {
        break_,
        continue_,
        return_,
    }

    Kind kind;
    size_t label;
}

@("a Value holds each layout, including ones made of Values")
unittest
{
    auto point = Value(Record(0, [Value(1L), Value(2L)]));
    auto numbers = Value(ArrayValue([Value(3L), point]));
    assert(numbers.as!ArrayValue.elements[1].as!Record.fields[1].as!long == 2);
    assert(Value(true).as!bool);
    assert(Value(Unit()).has!Unit);
    assert(Value.init.has!Unit);
    auto cell = new CellValue(Value(1L));
    auto copy = Value(cell);
    cell.contents = Value(2L);
    assert(copy.as!CellValue.contents.as!long == 2);
}
