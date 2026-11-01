# Commands

```sh
modeler check Sources
modeler states Sources --type Session
modeler tla Sources --type Session --output Model && tlc -config Model/SessionModel.cfg Model/SessionModel.tla
```

| Command | Output |
| --- | --- |
| `modeler classes [--type T --depth N]` | A Mermaid class diagram: types, members, conformance, inheritance, ownership. |
| `modeler states [--type T] [--output dir]` | A Mermaid state diagram for each enum-valued member the code assigns, and each enum that assigns itself. A transition guarded before an `await` is marked `stale`. |
| `modeler tla --type T [--output dir]` | A TLA+ module and TLC configuration for one type: one action per segment between `await`s, run by `Procs` callers. |
| `modeler check` | The findings below. |
| `modeler facts` | Everything above as JSON (`schemaVersion` 1, sorted keys). |
| `modeler rules [id]`, `modeler explain id` | The rules, or one explained. |

`check` takes the options of the other analyzers: `--format xcode|json|sarif`, `--relative-to`, `--strict`, `--baseline`,
`--write-baseline`, `--report-new-since`, `--only`, `--only-from`, `--rules`, `--verbose`, `--quiet`, `--timings`. Every command
takes `--config`, `--exclude-path`, `--include-regions`, `--exclude-regions`, `--cache-path` and `--no-cache`; only production code
is read unless a region is included ([regions](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#regions)). `--define` is accepted and ignored, since modeler reads every `#if`
clause. Exit codes are [shared](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#exit-codes): findings are warnings unless the configuration says otherwise.

## What `check` finds

| Rule | Finds |
| --- | --- |
| `reentrancy` | In an actor, a member checked, then an `await`, then written with no new check. |
| `lock-gap` | In a type that takes locks, a member checked in one `withLock` scope and written in another. |
| `stale-index` | An index into a member collection that is kept across an `await` and used on it. An **error** by default, since it can trap. |

`stale-index` reports a local bound from `firstIndex`, `lastIndex`, `index`, `indices`, `startIndex` or `endIndex` of a member
collection, or from `+` or `-` on one; then an `await`; then a subscript of that member with it, or a `remove(at:)`, `insert(_:at:)`,
`replaceSubrange`, `removeSubrange` or `swapAt`. Binding it again after the `await` clears it. It covers actors and global-actor
types, and does not repeat a line `reentrancy` reports.

## Limits

`check` is syntactic. It follows each method's control-flow graph: a check and a write pair only when one path joins them, a loop
carries a check and an `await` into its next iteration, and a write between the check and the `await` claims the member. A claim is
reported (as a claimed `reentrancy`) only when another method of the type writes the member.

After an `await`, a member counts as checked again by:

- a read of it in a condition;
- a condition that calls a method of the type that reads it (a call that is itself awaited is not a check);
- a check of a token the method wrote before the `await`, when every other writer writes the token too (a generation counter);
- `Task.isCancelled` or `try Task.checkCancellation()`, when every other writer cancels a task that a member holds.

A lock held by a local or a parameter guards no member. `x.append(…)`-style calls count as writes only for a fixed list of mutating
names. A local that shares a member's name hides the member for the whole method; `self.name` still reaches it. The narrowings that
the TLA+ model and `states` use are positional: a narrowing lasts for the block that established it.
