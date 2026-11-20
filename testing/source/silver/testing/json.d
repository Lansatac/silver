/// `silver test --format json`: what a run found as one JSON document, for tools. Its shape is
/// in docs/language/testing.md, and `version` changes when a tool would have to.
module silver.testing.json;

import std.algorithm : endsWith, map, startsWith, sum;
import std.array : Appender, array;
import std.conv : to;
import std.format : format;
import std.string : indexOf, lastIndexOf;

import silver.testing.runner : FileRun, succeeded, TestBackend, TestResult;

/// What `runs` found, run on `backend`, as JSON ending in a newline. `filtered` says whether
/// `--filter` chose the tests.
string jsonReport(const FileRun[] runs, TestBackend backend, bool filtered = false)
{
    Json[] files, tests;
    size_t passed, failed, panicked, unrun, unselected;
    foreach (run; runs)
    {
        files ~= fields(["file", "problem", "diagnostics"],
            [text(run.file), optional(run.problem), list(run.diagnostics.map!(d => text(d)).array)]);
        if (run.problem !is null) unrun++;
        unselected += run.unselected;
        foreach (result; run.results)
        {
            auto status = statusOf(result);
            if (status == "passed") passed++;
            else if (status == "panicked") panicked++;
            else failed++;
            tests ~= testJson(result);
        }
    }
    auto summary = fields(["tests", "passed", "failed", "panicked", "filteredOut", "filesNotRun", "succeeded"],
        [number(passed + failed + panicked), number(passed), number(failed), number(panicked), number(unselected),
            number(unrun), boolean(succeeded(runs, filtered))]);
    auto document = fields(["version", "backend", "files", "tests", "summary"],
        [number(1), text(backend.to!string), list(files), list(tests), summary]);
    Appender!string written;
    document.write(written, 0);
    return written[] ~ "\n";
}

/// `passed`, `panicked` when a panic or a crash ended the test, and otherwise `failed`.
private string statusOf(const TestResult result)
{
    if (result.passed) return "passed";
    if (result.backends.length > 0) return "failed";
    auto kind = parseFailure(result.failures[$ - 1]).kind;
    return kind == "panic" || kind == "crash" ? "panicked" : "failed";
}

private Json testJson(const TestResult result)
{
    auto failures = result.backends.length > 0 ? [disagreement(result)]
        : result.failures.map!(f => failureJson(parseFailure(f))).array;
    return fields(["name", "file", "line", "column", "status", "failures", "output"],
        [text(result.name), text(result.file), number(result.line), number(result.column), text(statusOf(result)),
            list(failures), result.backends.length > 0 ? Json.null_ : text(result.output)]);
}

/// The one failure of a test the backends disagree on, with what each of them found.
private Json disagreement(const TestResult result)
{
    Json found(const TestResult on) => fields(["status", "failures", "output"],
        [text(statusOf(on)), list(on.failures.map!(f => failureJson(parseFailure(f))).array), text(on.output)]);
    auto failure = failureJson(Failure("disagreement", null, 0, 0, "The backends disagree."));
    failure.add("interpreter", found(result.backends[0]));
    failure.add("llvm", found(result.backends[1]));
    return failure;
}

private Json failureJson(const Failure failure)
{
    auto located = failure.file !is null;
    return fields(["kind", "file", "line", "column", "text", "message", "source", "left", "right"],
        [text(failure.kind), optional(failure.file), located ? number(failure.line) : Json.null_,
            located ? number(failure.column) : Json.null_, text(failure.text), optional(failure.message),
            optional(failure.source), optional(failure.left), optional(failure.right)]);
}

/// One failure of a test, taken apart from the text the report shows. Fields the failure
/// doesn't have are null.
struct Failure
{
    /// `expectation`, `stopped` (`?` ended the test), `panic`, `crash` or `disagreement`.
    string kind;
    /// Where it happened.
    string file;
    size_t line, column;
    /// What the report shows after the location.
    string text;
    /// The message given to `expect` or `assert`.
    string message;
    /// The condition, or for `stopped` the operand of `?`, as written.
    string source;
    /// The two sides of a failed comparison, formatted.
    string left, right;
}

/// `failure` as the runner records it, taken apart. The text is built by lowering (`lowerShown`,
/// and `?` in a test) and by the runner, and the parts are found by the markers those write. A
/// formatted value that itself contains a line starting `    right: ` can be misread.
Failure parseFailure(string failure)
{
    enum panicPrefix = "panic: ";
    if (failure.startsWith("The test crashed") || failure.startsWith("The interpreter failed"))
        return Failure("crash", null, 0, 0, failure);
    auto isPanic = failure.startsWith(panicPrefix);
    auto rest = isPanic ? failure[panicPrefix.length .. $] : failure;
    Failure parsed;
    parsed.kind = isPanic ? "panic" : "expectation";
    rest = takeLocation(rest, parsed);
    parsed.text = rest;

    enum expectation = "Expectation failed: ", assertion = "Assertion failed: ", stopped = ", so the test stopped";
    if (!isPanic && rest.startsWith(expectation)) takeCondition(rest[expectation.length .. $], parsed);
    else if (isPanic && rest.startsWith(assertion)) takeCondition(rest[assertion.length .. $], parsed);
    else if (!isPanic && rest.endsWith(stopped) && rest.startsWith("`"))
    {
        parsed.kind = "stopped";
        auto close = rest.indexOf('`', 1);
        if (close > 0) parsed.source = rest[1 .. close];
    }
    return parsed;
}

/// `text` after the `file(line,column): ` it starts with, setting where `failure` happened.
/// Without one, `text` itself.
private string takeLocation(string text, ref Failure failure)
{
    import std.ascii : isDigit;
    import std.algorithm : all;

    auto end = text.indexOf("): ");
    auto newline = text.indexOf('\n');
    if (end < 0 || (newline >= 0 && newline < end)) return text;
    auto open = text[0 .. end].lastIndexOf('(');
    auto comma = text[0 .. end].lastIndexOf(',');
    if (open <= 0 || comma < open) return text;
    auto line = text[open + 1 .. comma], column = text[comma + 1 .. end];
    if (line.length == 0 || column.length == 0 || !line.all!isDigit || !column.all!isDigit) return text;
    failure.file = text[0 .. open];
    failure.line = line.to!size_t;
    failure.column = column.to!size_t;
    return text[end + 3 .. $];
}

/// Takes apart what follows `Expectation failed: ` or `Assertion failed: `: the message and the
/// condition, or the condition alone, then the values of a comparison.
private void takeCondition(string text, ref Failure failure)
{
    enum leftMarker = "\n    left: ", rightMarker = "\n    right: ", conditionMarker = "\n    condition: ";
    auto right = text.lastIndexOf(rightMarker);
    if (right >= 0)
    {
        auto left = text[0 .. right].lastIndexOf(leftMarker);
        if (left >= 0)
        {
            failure.left = text[left + leftMarker.length .. right];
            failure.right = text[right + rightMarker.length .. $];
            text = text[0 .. left];
        }
    }
    auto condition = text.lastIndexOf(conditionMarker);
    if (condition >= 0)
    {
        failure.message = text[0 .. condition];
        failure.source = text[condition + conditionMarker.length .. $];
    }
    else failure.source = text;
}

/// A JSON value whose object members keep the order they were added in.
private struct Json
{
    /// The written form of a scalar. An array or object has none.
    string scalar;
    bool isObject;
    string[] keys;
    Json[] values;

    static Json null_() => Json("null");

    void add(string key, Json value)
    {
        keys ~= key;
        values ~= value;
    }

    void write(ref Appender!string out_, size_t depth) const
    {
        if (scalar !is null)
        {
            out_ ~= scalar;
            return;
        }
        out_ ~= isObject ? "{" : "[";
        foreach (i, value; values)
        {
            out_ ~= i == 0 ? "\n" : ",\n";
            indent(out_, depth + 1);
            if (isObject) out_ ~= quoted(keys[i]) ~ ": ";
            value.write(out_, depth + 1);
        }
        if (values.length > 0)
        {
            out_ ~= "\n";
            indent(out_, depth);
        }
        out_ ~= isObject ? "}" : "]";
    }

    private static void indent(ref Appender!string out_, size_t depth)
    {
        foreach (_; 0 .. depth) out_ ~= "  ";
    }
}

private Json text(string value) => Json(quoted(value));
private Json optional(string value) => value is null ? Json.null_ : text(value);
private Json number(size_t value) => Json(value.to!string);
private Json boolean(bool value) => Json(value ? "true" : "false");
private Json list(Json[] values) => Json(null, false, null, values);

private Json fields(string[] keys, Json[] values)
{
    assert(keys.length == values.length);
    return Json(null, true, keys, values);
}

/// `value` as a JSON string. Bytes that aren't UTF-8 become U+FFFD, since a test's output can
/// hold anything.
private string quoted(string value)
{
    import std.utf : decode, UseReplacementDchar;

    Appender!string out_;
    out_ ~= '"';
    size_t i = 0;
    while (i < value.length)
    {
        auto c = decode!(UseReplacementDchar.yes)(value, i);
        switch (c)
        {
            case '"': out_ ~= `\"`; break;
            case '\\': out_ ~= `\\`; break;
            case '\n': out_ ~= `\n`; break;
            case '\r': out_ ~= `\r`; break;
            case '\t': out_ ~= `\t`; break;
            default:
                if (c < 0x20 || c == 0x7F) out_ ~= format(`\u%04X`, cast(uint) c);
                else out_ ~= c;
        }
    }
    out_ ~= '"';
    return out_[];
}

@("a failure's text comes apart into its location, condition, message and values")
unittest
{
    auto compared = parseFailure("a.ag(14,5): Expectation failed: doubling 2\n    condition: double(2) == 5\n    left: 4\n    right: 5");
    assert(compared == Failure("expectation", "a.ag", 14, 5,
        "Expectation failed: doubling 2\n    condition: double(2) == 5\n    left: 4\n    right: 5",
        "doubling 2", "double(2) == 5", "4", "5"));
    assert(parseFailure("a.ag(15,5): Expectation failed: x > 2 && true")
        == Failure("expectation", "a.ag", 15, 5, "Expectation failed: x > 2 && true", null, "x > 2 && true"));
    assert(parseFailure("panic: dir/a(1).ag(23,12): Index is out of range")
        == Failure("panic", "dir/a(1).ag", 23, 12, "Index is out of range"));
    assert(parseFailure("panic: a.ag(47,5): Assertion failed: f(3) == 7\n    left: 6\n    right: 7")
        == Failure("panic", "a.ag", 47, 5, "Assertion failed: f(3) == 7\n    left: 6\n    right: 7", null, "f(3) == 7", "6", "7"));
    assert(parseFailure("panic: Out of memory") == Failure("panic", null, 0, 0, "Out of memory"));
    assert(parseFailure("a.ag(32,19): `lookup(\"b\")` was None, so the test stopped")
        == Failure("stopped", "a.ag", 32, 19, "`lookup(\"b\")` was None, so the test stopped", null, "lookup(\"b\")"));
    assert(parseFailure("The test crashed, with signal 11").kind == "crash");
    auto multiline = parseFailure("a.ag(2,1): Expectation failed: s == \"x\"\n    left: one\ntwo\n    right: x");
    assert(multiline.left == "one\ntwo" && multiline.right == "x");
}

@("JSON strings escape what they have to, and bytes that aren't UTF-8 are replaced")
unittest
{
    assert(quoted("a\"b\\c\nd\te\x01é") == `"a\"b\\c\nd\te\u0001é"`);
    assert(quoted("\xFF") == "\"�\"");
}

@("the JSON report lists every file and test, then a summary")
unittest
{
    auto run = FileRun("a.ag", [TestResult("ok", "a.ag", 1, 6),
        TestResult("bad", "a.ag", 2, 6, ["a.ag(3,5): Expectation failed: x == 1\n    left: 2\n    right: 1", "panic: a.ag(4,5): boom"], "out\n")], null, null, 2);
    assert(jsonReport([run, FileRun("b.ag", null, ["b.ag(1,1): Error"], "it has errors")], TestBackend.interpreter) == `{
  "version": 1,
  "backend": "interpreter",
  "files": [
    {
      "file": "a.ag",
      "problem": null,
      "diagnostics": []
    },
    {
      "file": "b.ag",
      "problem": "it has errors",
      "diagnostics": [
        "b.ag(1,1): Error"
      ]
    }
  ],
  "tests": [
    {
      "name": "ok",
      "file": "a.ag",
      "line": 1,
      "column": 6,
      "status": "passed",
      "failures": [],
      "output": ""
    },
    {
      "name": "bad",
      "file": "a.ag",
      "line": 2,
      "column": 6,
      "status": "panicked",
      "failures": [
        {
          "kind": "expectation",
          "file": "a.ag",
          "line": 3,
          "column": 5,
          "text": "Expectation failed: x == 1\n    left: 2\n    right: 1",
          "message": null,
          "source": "x == 1",
          "left": "2",
          "right": "1"
        },
        {
          "kind": "panic",
          "file": "a.ag",
          "line": 4,
          "column": 5,
          "text": "boom",
          "message": null,
          "source": null,
          "left": null,
          "right": null
        }
      ],
      "output": "out\n"
    }
  ],
  "summary": {
    "tests": 2,
    "passed": 1,
    "failed": 0,
    "panicked": 1,
    "filteredOut": 2,
    "filesNotRun": 1,
    "succeeded": false
  }
}
`);
}

@("a test the backends disagree on has one failure saying what each found")
unittest
{
    import std.algorithm : canFind;

    auto interpreted = TestResult("t", "a.ag", 1, 6, null, "x\n");
    auto compiled = TestResult("t", "a.ag", 1, 6, ["panic: a.ag(2,5): boom"], "x\n");
    auto both = TestResult("t", "a.ag", 1, 6, ["The backends disagree.", "Interpreted, it passed", "Compiled:"], null,
        [interpreted, compiled]);
    auto json = jsonReport([FileRun("a.ag", [both])], TestBackend.both);
    assert(json.canFind(`"status": "failed",
      "failures": [
        {
          "kind": "disagreement",
          "file": null,
          "line": null,
          "column": null,
          "text": "The backends disagree.",
          "message": null,
          "source": null,
          "left": null,
          "right": null,
          "interpreter": {
            "status": "passed",
            "failures": [],
            "output": "x\n"
          },
          "llvm": {
            "status": "panicked",
            "failures": [
              {
                "kind": "panic",
                "file": "a.ag",`), json);
    assert(json.canFind(`      "output": null
    }`), json);
}
