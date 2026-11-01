# Proposal: `fcheck`, a checker for obligations on every path

Status: phase 1 built in `g-cqd/fcheck` 0.1.0 (the control-flow graph in analyzerkit `ControlFlow`; rules `leak-on-exit`, `replace-not-durable`, `cut-then-decode`). The rest is still a proposal.

## 1. What each tool answers

| Tool | Question | Formalism |
|---|---|---|
| compiler, swift-format, SwiftLint | Is it well formed, typed, isolated, styled? | type system, syntax rules |
| arcleak | Can this reference graph leak or be released early? | ownership graph |
| deadwood | Is this declaration reachable? | call graph |
| dolly | Is this code a copy? | token similarity |
| **modeler** (built) | What does the code allow? | extraction: class and state diagrams, a TLA+ skeleton for TLC, two check-then-act reports |
| **fcheck** (proposed) | Does every path and every interleaving keep its obligation? | path analysis, SMT, TLC, Lean |

`modeler` describes and explores: it never says a program is wrong, only what it can do. Nothing in the list decides whether a
function keeps a promise on its error path, in what order it makes irreversible changes, or whether an index can trap. That is
the gap.

## 2. Evidence that the gap is real

The modelling of ask in `ask`'s `docs/formal/REPORT.md` found three faults that none of the six tools can see:

- a refresh that the server accepted is dropped when its save fails, and the stored token is spent (an irreversible effect, then a
  fallible commit);
- a text found across a dropped middle, and characters cut at bytes (a boundary in data and encoding).

Reading the same code for a few minutes found more of the same shape. They are candidates, not findings; none is probed.

| Candidate | Where | Shape |
|---|---|---|
| a descriptor is not closed when the lock is lost | `SessionFile.begin` | pairing on an error exit |
| a file is renamed over another without flushing its bytes | `ProjectTrust.save` (`AtomicFile` flushes first) | ordering |
| the rename is not followed by a flush of the directory, in the store that holds a single-use token | `AtomicFile.replace` (`SessionFile` does flush it) | ordering |

Counts in ask's `Sources`, by `grep`: 9 descriptor opens, 8 continuations, 4 `rename`, 4 `flock`, 53 `while` loops, 85 `try?`,
6 `String(decoding:)` over a `prefix` or `suffix`. In arcleak, dolly and deadwood: 15 `@unchecked Sendable` declarations.

## 3. One abstraction: an obligation

Every check below has the same shape, so the tool has one engine and one report:

> **when** a trigger event happens in a scope, **then** a required event must happen, on **every path** out of the scope
> (return, throw, cancellation at an `await`) or in **every interleaving** of the callers, **unless** a discharge applies.

Six shapes cover the catalogue.

| Shape | Says | Rules |
|---|---|---|
| Pairing | acquire is followed by release on every exit | `leak-on-exit`, `continuation-once` (resumed exactly once) |
| Ordering | A happens before B | `replace-not-durable`, `effect-then-fallible-commit` |
| Atomicity | check and act are not separated | `check-then-act` (await or lock gap; moves from modeler) |
| Exclusion | a lock is not held across a suspension, locks are taken in one order, shared mutable state is guarded | `lock-across-await`, `lock-order`, `unguarded-shared` |
| Bounds | an arithmetic or encoding step cannot trap or tear | `arith-trap`, `cut-then-decode`, `no-progress-loop`, `unbounded-growth` |
| Conformance | the extracted machine is within a declared one | `spec-drift` |

## 4. The catalogue

Evidence level: **L0** exact path analysis on a control-flow graph, no solver; **L1** SMT; **L2** TLC on a model from `modeler`;
**L3** Lean proof for a pure function that carries an annotation.

| Rule | Property | Why the six miss it | Level | ask evidence | Priority |
|---|---|---|---|---|---|
| `leak-on-exit` | each `open`, `flock`, `Process`, `Task` handle is closed, released or awaited on every exit, `defer` included | the compiler cannot see a raw descriptor; arcleak is about references | L0 | `SessionFile.begin` (candidate) | 1 |
| `replace-not-durable` | write, flush, rename, flush the directory, in that order | no tool knows the syscall order | L0 | `ProjectTrust.save`, `AtomicFile.replace` (candidates) | 1 |
| `cut-then-decode` | no `String(decoding:)` on a byte prefix or suffix of text | invisible to all | L0 | `OutputBuffer.text`, `Compaction.clipped` (confirmed) | 1 |
| `effect-then-fallible-commit` | after a declared irreversible effect, a fallible step must not drop its result | needs the declaration, then a path check | L0 + declared effects | `ClaudeAccess`, `CodexAccess` (confirmed) | 1 |
| `check-then-act` | no `await` or lock gap between a check and the write that relies on it | same | L0, L2 for the trace | arcleak `SILConfirmationSession` (found by modeler) | 1, exists |
| `continuation-once` | each continuation is resumed exactly once, cancellation included | the compiler checks it at run time, by trapping | L0, L2 | 8 sites in ask; `Job.wait` read as sound | 2 |
| `unguarded-shared` | a mutable stored property of an `@unchecked Sendable` type is behind a lock | `@unchecked` turns the compiler's check off | L0 | 0 in ask, 15 declarations in the tools | 2 |
| `lock-order`, `lock-across-await` | no cycle in the lock graph; a file lock is not held over a suspension without a bound | invisible to all | L0 graph, L2 for protocols | `CredentialLock` by design | 2 |
| `arith-trap` | no divide or modulo by a value that can be zero, no overflow, no index out of range | the compiler traps at run time | L1 | `OutputBuffer` `% keeping`, unreachable today | 3 |
| `no-progress-loop` | each iteration changes the loop's measure, or the loop is bounded | invisible to all | L0 template, L1 | 53 loops in ask | 3 |
| `unbounded-growth` | input read from a stream or file is bounded before it is stored | invisible to all | L0 | not counted | 3 |
| `spec-drift` | extracted transitions are a subset of a declared table | invisible to all | L0 | ADR-0040 and 0041 describe tables | 3 |
| `secret-flow` | a value of a type marked secret does not reach a description, log or error | needs types and flow | L0 | tests assert it by hand today | 4 |

Not proposed: proving a whole program in Lean, or generating a faithful TLA+ model of syscalls. The first is a research project and
the second is what the hand-written ask spec does at a fraction of the effort. Lean stays for annotated pure functions
(`OutputBuffer` took three theorems and one counter-example).

## 5. Where TLC, TLA+ and Lean fit

- **L0 needs none of them** and carries most of the value: a control-flow graph with every exit and every `await` as a branch,
  and a check that each path through it satisfies an automaton. This is exact for the paths it sees and says so.
- **L2 (TLC)** is for what a path cannot show: interleavings. `modeler tla` already builds the model and the stale-write monitor. `fcheck prove`
  runs it on a finding and returns the counterexample trace, or "no violation up to these bounds". Apalache (symbolic, unbounded
  integers) would remove the `IntMax` bound.
- **L1 (SMT, Z3 or cvc5)** is for arithmetic and index rules. It is an optional external binary.
- **L3 (Lean)** is for a pure function the author annotates. `fcheck` writes the Lean statement skeleton from the signature and the rule
  (`bounded`, `accounts`, `whole`, as in `OutputBuffer.lean`); a person writes the proof.
- **Alloy** would suit the structural invariants of `SessionTree` (acyclic, one root, fork copies the active branch). One model
  could be written by hand; it is not worth a rule.
- **Trace validation** (replaying a recorded run against a TLA+ spec, as Microsoft did for CCF) could use ask's session logs. Worth a
  later look; it needs a spec first.

## 6. The surface

```
fcheck analyze [PATHS...]                       default: the current directory
    --rules ID,ID | --pack durability,resources,concurrency,bounds
    --format xcode|json|sarif    --strict    --config FILE (.fcheck.json)
    --baseline FILE   --write-baseline FILE   --only FILE   --only-from FILE   --relative-to DIR
    --cache-path FILE | --no-cache   --evidence l0|l1|l2        (highest level to spend; default l0)
fcheck rules                                    the catalogue: id, shape, level, severity, one line
fcheck explain ID                               the obligation, the usual fix, one passing and one failing example
fcheck prove FINDING                            escalate one finding to SMT or TLC; prints the witness or the bounds
fcheck obligations                              built-in and project-declared triggers, requirements and discharges
```

The flags, exit codes (`0` clean, `1` with `--strict` on warning or error, `64` usage, `70` internal), report schema
(`schemaVersion`, shared with `ReportSchema`), baseline fingerprints, `--only` semantics and `// @fc:accept RULE -- reason`
suppression (`accept:this`, `accept:next`, `disable`, `enable`) are the ones arcleak, dolly and deadwood use, so one CI step runs all four.

A finding carries the rule, the obligation it breaks, the **witness path** as source lines, and its evidence level:

```
Sources/Session/SessionFile+Opening.swift:41:9: warning: [leak-on-exit] descriptor from writeExclusively is not closed
  when SessionLock.adopt throws at line 42 (L0, exact on this path)
```

`.fcheck.json` declares what the code cannot say for itself:

```json
{ "obligations": [
    { "id": "rotating-token",  "irreversible": ["ClaudeAuthClient.refresh", "CodexAuthClient.refresh"],
      "commit": ["CredentialFile.saveClaude", "CredentialFile.saveCodex"], "on-commit-failure": "retry-or-report" },
    { "id": "fd",              "acquire": ["open", "FileDescriptor.open", "Darwin.open"], "release": ["close", "FileDescriptor.close"] } ],
  "durable-replace": { "sinks": ["rename"], "flush": ["fsync", "F_FULLFSYNC", "PosixFile.sync"] } }
```

## 7. Architecture

```
analyzerkit  SourceCorpus, CorpusScan, ReportSupport, ProjectModel     exist
analyzerkit  ControlFlow   a CFG per function: exits are return, throw and every await; defer unwinding;
                           closures and Task spawns are edges with a kind; withLock scopes are regions     new
analyzerkit  Obligations   the six shapes as automata over a CFG, with a witness path                     planned; in 0.1.0 each rule
                                                                                                              queries the graph and the
                                                                                                              solver directly, inside fcheck
modeler      uses ControlFlow for segments instead of its own collector; keeps diagrams, TLA+, Lean skeleton
fcheck        rules, packs, config, evidence escalation, report
```

Facts per file are cached by `CorpusScan` as for the other tools. The two tools never duplicate extraction: `modeler` explains what
the code can do and `fcheck` decides whether it keeps its promises. Its `check` command becomes `fcheck analyze --pack concurrency`,
with `modeler check` kept as an alias for one release.

## 8. Plan

1. `ControlFlow` and `Obligations` in analyzerkit; `fcheck analyze` with `leak-on-exit`, `replace-not-durable`, `cut-then-decode`.
   **Exit criterion:** against the ask revision of 2026-10-24 it flags `SessionFile.begin`, `ProjectTrust.save`, `AtomicFile.replace`,
   `OutputBuffer.text` and `Compaction.clipped`, and does not flag `ConfigurationFileReader.read` or `SessionFile.rewrite`.
2. `effect-then-fallible-commit` with declared effects; `check-then-act` moved from modeler; `continuation-once`. **Exit criterion:**
   it flags `ClaudeAccess` and `CodexAccess`, and passes `Job.wait`.
3. `unguarded-shared`, `lock-order`. **Exit criterion:** the 15 `@unchecked Sendable` declarations are each explained or flagged.
4. `fcheck prove` with TLC through `modeler`, then an SMT backend for `arith-trap` and `no-progress-loop`.
5. Lean skeletons, `spec-drift`, `secret-flow`.

Each step ships with its tests, run against fixtures that fail first, and with a number: findings on ask, arcleak, dolly and
deadwood, and how many were real.

## 9. Risks

- **False positives** decide whether it is used. L0 is exact on a graph, but the graph over-approximates (a `catch` that swallows,
  an `await` that never suspends). Every finding shows its witness path, and `--strict` is off by default for new rules.
- **Declared effects are names.** A rename silently disables a rule, so `fcheck obligations` lists any declared name that matches
  nothing in the corpus.
- **Solvers are optional.** Without Z3 or Java the L1 and L2 rules say "not run", never "passed".
- **What each level claims:** L0 is exact for the paths it models and says nothing about the rest; L1 holds under the stated
  preconditions; L2 holds up to the bounds it prints; L3 holds for the annotated function and nothing else.

## 10. What was verified for this document

Verified by running: the three ask faults and their models (TLC 2.19, Lean 4.35, Swift Testing); the counts above; that the
reentrancy and lock-gap reports run on four corpora. Established by reading only: the three candidates in section 2, the claim that
`Job.wait` is sound, and every "invisible to all" in the catalogue, which is a judgment about the six tools' documented scope, not a
test of each.
