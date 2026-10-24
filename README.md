# modeler

Models Swift code for review and for model checking. It reads source with SwiftSyntax, extracts the types, their
members, and what each method body does to them, and writes:

| Command | Output |
| --- | --- |
| `modeler classes [--type T --depth N]` | a Mermaid class diagram: types, members, conformance, inheritance, ownership |
| `modeler states [--type T] [--output dir]` | a Mermaid state diagram for each enum-valued member the code assigns, and for each enum that assigns itself; a transition guarded before an `await` is marked `stale` |
| `modeler tla --type T [--output dir]` | a TLA+ module and TLC configuration for one type: one action per segment between `await`s, run by `Procs` callers |
| `modeler check [--strict]` | actor methods that check a member, `await`, then write it without checking again |
| `modeler facts` | everything above as JSON (`schemaVersion` 1, sorted keys) |

```sh
modeler check Sources
modeler states Sources --type Session
modeler tla Sources --type Session --output Model && tlc -config Model/SessionModel.cfg Model/SessionModel.tla
```

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

A class or struct has no suspension point, so each of its methods is one atomic action. That is wrong for code that
takes locks piecewise; extend the model by hand.

## Limits

Syntactic and path-insensitive: a check in one branch and a write in another can pair. A narrowing lasts for the block
that established it. `x.append(…)`-style calls count as writes only for a fixed list of mutating names. A local
variable that shares a member's name hides the member for the whole method; `self.name` still reaches it.

## Shared code

File discovery, path canonicalization, bounded reads, content fingerprints, the build-identity-gated facts cache and the
parallel scan come from [analyzerkit](https://github.com/g-cqd/analyzerkit) (`SourceCorpus`, `CorpusScan`), the same
code arcleak, dolly and deadwood use. Unchanged files are not parsed again.

## Develop

```sh
swift build --build-tests
TLA2TOOLS=/path/to/tla2tools.jar swift test --skip-build   # also runs TLC on a generated module
```

Swift 6.4, strict concurrency and strict memory safety, warnings as errors.
