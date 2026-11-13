module silver.interpreter.values;

import std.sumtype;

/// A Silver value while the program runs. Every Core `Expr` has a type, so the evaluator always
/// knows which of these to expect; the cases only have to keep values of different layouts apart.
///
/// - Every integer type is a `long` holding the value's 64-bit two's complement, as `IntLit`
///   stores it. The `Expr`'s type says which width and signedness the bits mean.
/// - Tuples, user types and sums, options among them, are all a `Record`.
/// - A `[UInt8]` is a `string`, as a String is, so that one can be viewed as the other without
///   copying. Written `[]` it can still arrive as an empty `ArrayValue`.
/// - A `Ref` is a `CellValue`, the one value that changes after it's built.
alias Value = SumType!(Unit, bool, long, double, string, ArrayValue, Record, Closure, CellValue);

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

/// `value` as a `T`, which the evaluator already knows from the `Expr`'s type.
T as(T)(Value value)
{
    assert(value.has!T, "Core's types say this value is a " ~ T.stringof);
    return value.get!T;
}

@("a Value holds each layout, including ones made of Values")
unittest
{
    auto point = Value(Record(0, [Value(1L), Value(2L)]));
    auto numbers = Value(ArrayValue([Value(3L), point]));
    assert(numbers.as!ArrayValue.elements[1].as!Record.fields[1].as!long == 2);
    assert(Value(true).as!bool);
    assert(Value(Unit()).has!Unit);
    auto cell = new CellValue(Value(1L));
    auto copy = Value(cell);
    cell.contents = Value(2L);
    assert(copy.as!CellValue.contents.as!long == 2);
}
