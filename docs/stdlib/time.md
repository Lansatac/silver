# Dates and times

`std.time` has a type for each thing a date or time can mean, so that two that mean different things can't be mixed by accident:

| Type | Is | Printed |
| --- | --- | --- |
| `Date(year, month, day)` | a day in the calendar | `2026-11-23` |
| `Time(hour, minute, second, nanos)` | a time of day on a clock | `14:05:00.5` |
| `DateTime(date, time)` | a date and a time of day, with no zone | `2026-11-23T14:05:00` |
| `OffsetDateTime(dateTime, offset)` | a date and time read at an offset from UTC | `2026-11-23T14:05:00-08:00` |
| `Instant(seconds, nanos)` | a moment | `2026-11-23T22:05:00Z` |
| `Duration(nanos)` | an exact length of time | `1h2m3.5s` |
| `Weekday` | `Monday` to `Sunday` | `Monday` |
| `Clock` | where `now` reads the time | |
| `Stopwatch` | a start, for measuring elapsed time | |

```silver
import std.time

val d = date(2026, 11, 23)!
printl(d.addDays(10))                 // 2026-12-03
printl(weekday(d))                    // Monday
val due = DateTime(d, time(17, 0, 0)!)
val meeting = parseOffsetDateTime("2026-11-23T14:05:00-08:00")!
printl(toInstant(meeting))            // 2026-11-23T22:05:00Z
printl(since(now(), toInstant(meeting)))   // 1h12m3.25s, say
```

A `DateTime` says nothing about where: 9:00 on a day, wherever it's read. Only an `OffsetDateTime` or an `Instant` is one moment. There are no named time zones, such as `America/Los_Angeles`, only offsets.

## The calendar

- Dates follow the Gregorian calendar, extended back before 1582, and run from 0000-01-01 to 9999-12-31, the years ISO 8601 writes in four digits. Arithmetic that leaves that range panics, as integer overflow does.
- Months and days count from 1.
- There are no leap seconds: every day has 86,400 seconds, as in Unix time, and a second is 0 to 59.
- An offset is whole seconds, less than a day either way. A function given another one panics.

## Making values

`date(year, month, day)` and `time(hour, minute, second)`, or `time(hour, minute, second, nanos)`, return the value, or `None` when there's no such day or time: `date(2026, 2, 29)` is `None`. A `DateTime` and an `OffsetDateTime` are made with their constructors from values that are already right.

Durations are made with `nanoseconds`, `microseconds`, `milliseconds`, `seconds`, `minutes` and `hours`, which take an `Int`. There's no `days`, since a day in the calendar isn't always 24 hours where clocks change; days, months and years are steps in the calendar instead.

Every field is public, so the constructors can build a value that isn't right, such as `Date(2026, 2, 30)`. What the functions do with one isn't specified.

## Arithmetic

| | `Date` | `DateTime` | `OffsetDateTime` | `Instant` | `Duration` |
| --- | --- | --- | --- | --- | --- |
| `add(x, d: Duration)`, `subtract(x, d)` | | ✓ | ✓ | ✓ | ✓ |
| `since(later, earlier): Duration` | | ✓ | ✓ | ✓ | |
| `addDays`, `addMonths`, `addYears` | ✓ | ✓ | ✓ | | |
| `daysSince(later, earlier): Int` | ✓ | | | | |

- `addMonths` keeps the day, or takes the month's last when it's shorter: 2026-01-31 plus a month is 2026-02-28. `addYears` is twelve months, so 2024-02-29 plus a year is 2025-02-28.
- `since` on two `DateTime`s reads both on one clock. On `OffsetDateTime`s it's the time between their moments.
- An `OffsetDateTime` keeps its offset through arithmetic.
- A `Duration` holds about 292 years either way, and `since` panics past that.
- `negate(d)` turns a duration around, and `inSeconds(d)` is its length in seconds as a `Float`.
- `weekday(d)`, `dayOfYear(d)` (1 for the first of January), `isLeapYear(year)` and `daysInMonth(year, month)` ask about the calendar.

## Moments and offsets

- `toInstant(o)` is the moment an `OffsetDateTime` names, and `atOffset(i, offset)` the date and time at a moment on a clock that far from UTC: `atOffset(i, seconds(0))` is UTC.
- `localOffset(i)` is the system's offset from UTC at `i`, from its time zone, and `atLocalOffset(i)` is `atOffset(i, localOffset(i))`.

## Clocks

```silver
type Clock = SystemClock | FixedClock(at: Instant, offset: Duration)
```

`now(clock)` is the moment, `nowWithOffset(clock)` the date and time at the clock's offset, and `today(clock)` its date. A `SystemClock` reads the system, at its time zone's offset; a `FixedClock` always says the same. Each has a form without a clock, which reads the system, for a program that will never be tested at another time:

```silver
def greeting(clock: Clock): String =>
    if nowWithOffset(clock).dateTime.time.hour < 12 => "Good morning" else "Hello"

test "mornings" {
    val nine = parseInstant("2026-11-23T09:00:00Z")!
    expect(greeting(FixedClock(nine, seconds(0))) == "Good morning")
}
```

The system's clock can be set back or forward while a program runs, so the time between two `now()`s isn't always the time that passed. A `Stopwatch` reads a clock that only goes forward:

```silver
val watch = stopwatch()
work()
printl(elapsed(watch))    // 1.25s
```

## Equality, ordering and printing

- Every type compares structurally with `==`, and all but `Clock` and `Stopwatch` are `Ord`, in the order of time.
- Two `OffsetDateTime`s at one moment with different offsets aren't `==`. They're ordered by moment, then by date and time, so `compare` agrees with `==`. To ask whether they're the same moment, compare `toInstant`s.
- Printing writes ISO 8601's extended form, the same on every system. A fraction of a second is written only when there is one, without its trailing zeros. An offset of zero is `Z`, and one that isn't whole minutes has seconds: `-00:01:15`.
- A `Duration` is written as Go writes one: hours, minutes and seconds (`25h0m1.5s`, `1m30s`, `59s`), and below a second `ms`, `µs` or `ns` (`250ms`, `1.5µs`, `20ns`), with `-` before a negative one.

## Parsing

`parseDate`, `parseTime`, `parseDateTime`, `parseOffsetDateTime` and `parseInstant` take RFC 3339's forms and return `None` for anything else:

- What printing writes, with seconds always present: `07:32` isn't a time.
- Between the date and the time, `T`, `t` or a space. For UTC, `Z` or `z`. An offset is `+hh:mm` or `-hh:mm`, up to 23:59.
- Any number of digits of a second after a `.`, at least one. Past nine, the rest are cut off rather than rounded.
- Nothing before or after: `"2026-11-23 "` isn't a date.

`parseInstant` reads an offset date and time and gives its moment.

## Open questions

- Named time zones, with the IANA database, and how a local time that a change of clocks skips or repeats is resolved.
- Formatting and parsing in other forms, and in a language of the reader's.
- Construction private to `std.time`, once the language has it, so that only a right value can be made.
- `+` and `-` for dates and durations, if arithmetic operators become operator functions.
- A calendar amount of months and days as a value, as a `Period`.
- A `Clock` that a test can move forward.

## Current implementation

- Everything above is built, as plain Silver in `stdlib/std/time.ag` over three natives in `lang.time`: the wall clock (`nowNanos`, which `std.time` forwards), a clock that only goes forward, and the system's offset at a moment.
- `now()` reads the wall clock in nanoseconds, so it's right until 2262.
- `localOffset` for a moment outside 0000 to 9999 gives the offset at the nearer end.
