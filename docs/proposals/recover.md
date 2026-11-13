# Proposal: recovering from a panic

**Status: proposed, to be explored further.** Nothing here is implemented or decided beyond the direction. The treatment of `Ref` is the main worry. It builds on [errors](../language/errors.md).

## Summary

A panic stops the program. `recover` is a boundary that turns a panic underneath it into a value, for a program that has to keep running:

```silver
type Panic(message: String, location: String)

intrinsic def recover<T>(work: () -> T): T ! Panic
```

```silver
def main(): Unit ! IoError {
    while val line = read()? {
        match recover(() => run(line)) {
            Ok(output) => printl(output)
            Error(bug) => printl("internal error at {bug.location}: {bug.message}")
        }
    }
}
```

An overflow, a bad index or a failed `assert` anywhere inside `run` arrives in the second arm, and the loop reads the next line.

## Motivation

A panic is for a bug, and a bug in one command shouldn't have to end a shell, a server or a plugin host. Today nothing a program can write survives one:

```silver
for command in ["ok", "index", "ok"] {
    printl("{command}: {run(command)}")       // the second command indexes out of range
}
```

```
ok: 1
panic: loop.ag(2,36): Index is out of range
```

The test runner already recovers from a panic in each test, on both backends. This offers the same thing to programs.

## The design

`recover(work)` calls `work`. If it returns, the result is its value. If it panics, at any depth and for any reason except running out of memory, the result is `Error(Panic(...))` and the program carries on.

- **It's for the edge of a unit of work**: one command, one request, one plugin, one test. It isn't for control flow, and what comes back is a message and a location, never a typed value to branch on.
- **Out of memory still ends the program.** Reporting a panic needs memory.

### What a recovered panic leaves behind

Catching a failure is unsafe in most languages because shared state may be half-changed. Silver has little state to leave that way:

- `work` is a lambda, and a lambda can't capture a `mutable val` or a mutable parameter. So no variable outside it is half-updated.
- Values are immutable and copied, memory is collected, and there are no destructors, locks or mutable globals.

Three things remain, and each needs a rule:

- **A `mutable` argument.** A call that panics hasn't returned, so it writes nothing back. After a recovered panic, the caller's variable is what it was before the call.
- **A `Ref`.** A cell changed before the panic stays changed. A cell that was in the middle of an `update` is empty, since `update` moves the contents out while `change` runs. Proposed: the cell gets its old contents back. See "Open questions".
- **The outside world.** Text already printed, input already read, and whatever a native function did stay done.

## Alternatives considered

- **No boundary**, so a bug ends the program, as in Midori, where it ends a process. Silver has no processes to end, so the unit of failure would be the whole program.
- **A block form**, `recover { ... } else panic { ... }`. It could reach the enclosing function's `mutable val`s, which a lambda can't, so it would need those restored when a panic is recovered. A function taking a lambda gets that for nothing.
- **Rolling back everything the work changed**, including every `Ref`, as the failure-contexts proposal did. It makes "carry on" fully safe, and costs a log of `Ref` writes whenever a boundary is active.
- **Catching by kind**, so a program could recover from an overflow and not from a failed `assert`. That makes `recover` better at control flow, which it's meant to be bad at.

## Open questions

- **`Ref` and the memory plan.** Giving a cell its contents back means keeping them alive during `update`, which is exactly what stops `update` changing them in place. Both backends copy today, so it's free now. Under the planned count-based memory strategy, either `update` copies whenever a boundary is active, so its cost depends on who called it, or an abandoned cell stays empty and every later use of it panics. Neither is good.
- **Skipped frames.** A recovered panic jumps over the frames between it and the boundary. That's safe while memory is collected and nothing runs when a frame ends. Under counts, those frames never give up what they held, so each recovered panic leaks it.
- **Natives.** A panic raised while C frames are on the stack would jump over them.
- **What a `Panic` holds.** A message and a location, or also the call chain.
- **Whether `silver test` becomes a user of `recover`**, and whether the designed `panics { ... }` is still wanted beside it.
- **Nesting.** A boundary inside a boundary recovers the inner one only.
