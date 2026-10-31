# modeler

Models Swift code for review and for model checking. It reads source with SwiftSyntax, extracts the types, their
members, and what each method body does to them, and writes:

| Command | Output |
| --- | --- |
| `modeler classes [--type T --depth N]` | a Mermaid class diagram: types, members, conformance, inheritance, ownership |
| `modeler states [--type T] [--output dir]` | a Mermaid state diagram for each enum-valued member the code assigns, and for each enum that assigns itself; a transition guarded before an `await` is marked `stale` |
| `modeler tla --type T [--output dir]` | a TLA+ module and TLC configuration for one type: one action per segment between `await`s, run by `Procs` callers |
| `modeler check` | a check of a member, then an `await` (rule `reentrancy`, actors) or a gap between `withLock` scopes (rule `lock-gap`, types that take locks), then a write of it with no new check; an index into a member kept across an `await` and used on it (`stale-index`); a continuation stored in a member that may still hold one (`continuation-overwrite`) |
| `modeler facts` | everything above as JSON (`schemaVersion` 1, sorted keys) |
| `modeler rules [id]`, `modeler explain id` | the rules, or one explained |

`check` takes the options arcleak, deadwood, dolly and fcheck take (analyzerkit ADR-0019): `--format xcode|json|sarif`,
`--relative-to`, `--strict`, `--baseline`, `--write-baseline`, `--report-new-since`, `--only`, `--only-from`, `--rules`,
`--verbose`, `--quiet`, `--timings`. Every command takes the input and cache options: `--config`, `--exclude-path`,
`--include-regions` and `--exclude-regions` (`test`, `generated`, `script`, …; only production code by default; a file's
region comes from its package or Xcode project first, then its content, then path conventions), `--cache-path DIR` (the
cache's root directory) and `--no-cache`. `--include-tests` is a deprecated spelling of `--include-regions
test,generated`; `--define` is accepted and has no effect yet, since modeler reads every `#if` clause.

Configuration: `.modeler.json`, or a `"modeler"` section of the shared `.swift-analyzers.json`, found as the other tools
find theirs: `{"disable": ["lock-gap"], "severity": {"reentrancy": "error"}, "exclude": ["/Generated/"]}`. A comment
`// @modeler:accept reentrancy -- reason` (or `@md:`; also `accept:this`, `accept:next`, `disable`, `enable`) suppresses a
finding.

Exit statuses (ADR-0018): `0` passed; `1` an error finding, or with `--strict` a warning (findings are warnings unless the
configuration says otherwise); `64` usage, a path that does not exist or no Swift file; `70` no file could be read; `74` a
baseline that could not be written; `78` an invalid configuration or baseline.

```sh
modeler check Sources
modeler states Sources --type Session
modeler tla Sources --type Session --output Model && tlc -config Model/SessionModel.cfg Model/SessionModel.tla
```

## Errors by default

`stale-index` and `continuation-overwrite` are errors unless the configuration says otherwise, since what they find
traps or never resumes a caller:

- `stale-index`: a local bound from `firstIndex`, `lastIndex`, `index`, `indices`, `startIndex` or `endIndex` of a
  member collection, or from `+`/`-` on one, then an `await`, then a subscript of that member with it, or a
  `remove(at:)`, `insert(_:at:)`, `replaceSubrange`, `removeSubrange` or `swapAt` on it. Binding it again after the
  `await` clears it. Actors and global-actor types, as for `reentrancy`, which does not report the same line again.
- `continuation-overwrite`: a store of a value other than `nil` into a member typed `CheckedContinuation` or
  `UnsafeContinuation` (optional or not) where no path from the method's entry checks the member, resumes it or sets it
  to `nil` first. The `with…Continuation` closure counts, since it runs at once. Continuations kept in a collection are
  not this shape. Every type.

## What the TLA+ model is

An over-approximation, so TLC can show a trace the code can follow and cannot prove the code correct.

- Each mutable stored property a method touches becomes a variable over a finite set: the enum's cases, `BOOLEAN`,
  `0..IntMax`, or `Opaque` model values for anything else.
- Each method becomes one action per segment between `await`s. An `if`, `guard` or `switch` on an enum member is the
  segment's precondition, and a failed check is a separate action that returns without changing state.
- A check made before an `await` does not constrain the segment after it. That is the point: two callers can both
  pass the check, and TLC finds the interleaving.
- For each `check` finding the module adds `NoStaleWrite_n`, an invariant that fails when the member changes between
  the check and the write.
- Control flow, arguments, other types, and effects inside closures (attributed to the enclosing segment) are not
  modelled. A write of a computed value may produce any member of the set.

A class or struct that takes no lock has no interleaving point, so each of its methods is one atomic action. One that
calls `withLock` is modelled per access: a `withLock` scope is one step, and each read or write outside a scope is
its own step, so an unlocked check then write can interleave with another caller and `check` reports it as a
`lock-gap`.

## Limits

Syntactic. `check` follows each method's control-flow graph: a check and a write pair only when one path joins them,
a loop carries a check and an `await` into its next iteration, and a write between the check and the `await` claims
the member. A claim is reported (as a claimed `reentrancy`) only when another method of the type writes the member.
The narrowings the TLA+ model and `states` use stay positional: a narrowing lasts for the block that established it.
After the `await`, a member is checked again by a read of it in a condition, by a condition that calls a method of the
type that reads it (a call that is itself awaited is not a check), by a check of a token the method wrote before the
`await` when every other writer of the member writes the token too (a generation counter), or by `Task.isCancelled` or
`try Task.checkCancellation()` when every other writer of the member cancels a task that a member holds. A lock that a
local or a parameter holds guards no member, so it does not make the type one that takes locks.
`x.append(…)`-style calls count as writes only for a fixed list of mutating names. A local variable that shares a
member's name hides the member for the whole method; `self.name` still reaches it.

## Shared code

File discovery, path canonicalization, bounded reads, content fingerprints, the build-identity-gated facts cache and the
parallel scan come from [analyzerkit](https://github.com/g-cqd/analyzerkit) (`SourceCorpus`, `CorpusScan`), as for
arcleak, dolly, deadwood and fcheck; the control-flow graph comes from its `ControlFlow`, which fcheck uses too.
Unchanged files are not parsed again. The command-line surface, configuration, baselines and suppression comments
are analyzerkit's as well.

## Develop

```sh
swift build --build-tests
TLA2TOOLS=/path/to/tla2tools.jar swift test --skip-build   # also runs TLC on a generated module
```

Swift 6.4, strict concurrency and strict memory safety, warnings as errors.
