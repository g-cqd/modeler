# The TLA+ model

`modeler tla --type T` writes a model that **over-approximates** the type, so TLC can show a trace the code can follow. It cannot
prove the code correct.

- Each mutable stored property a method touches becomes a variable over a finite set: the enum's cases, `BOOLEAN`, `0..IntMax`,
  or `Opaque` model values for anything else.
- Each method becomes one action per segment between `await`s. An `if`, `guard` or `switch` on an enum member is the segment's
  precondition, and a failed check is a separate action that returns without changing state.
- A check made before an `await` does not constrain the segment after it. That is the point: two callers can both pass the check,
  and TLC finds the interleaving.
- For each `check` finding the module adds `NoStaleWrite_n`, an invariant that fails when the member changes between the check and
  the write.
- Not modelled: control flow, arguments, other types, and effects inside closures (attributed to the enclosing segment). A write
  of a computed value may produce any member of the set.

A class or struct that takes no lock has no interleaving point, so each method is one atomic action. One that calls `withLock` is
modelled per access: a `withLock` scope is one step, and each read or write outside a scope is its own step. An unlocked check
then write can therefore interleave with another caller, and `check` reports it as a `lock-gap`.

```sh
modeler tla Sources --type Session --output Model
tlc -config Model/SessionModel.cfg Model/SessionModel.tla
```
