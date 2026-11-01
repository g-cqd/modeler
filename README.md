# modeler

Models Swift code for review and for model checking. It reads source with [swift-syntax](https://github.com/swiftlang/swift-syntax)
and extracts the types, their members, and what each method body does to them. From that it writes class and state diagrams, a TLA+
module that [TLC](https://github.com/tlaplus/tlaplus) can explore, and checks for races an `await` or a lock makes possible.

```swift
actor Session {
    var state = State.idle

    func start() async {
        guard state == .idle else { return }
        await connect()       // another caller can run here
        state = .running      // reentrancy: `state` was checked before the await and is written without a new check
    }
}
```

## What it does

| Command | Output |
| --- | --- |
| `modeler classes` | A Mermaid class diagram. |
| `modeler states` | A Mermaid state diagram for each enum-valued member the code assigns. |
| `modeler tla --type T` | A TLA+ module and TLC configuration for one type. |
| `modeler check` | Findings: `reentrancy`, `lock-gap`, `stale-index`. |
| `modeler facts` | Everything above as JSON. |

The TLA+ model over-approximates: TLC can show a trace the code can follow, and cannot prove the code correct.

## Install

Download an archive from the [releases](https://github.com/g-cqd/modeler/releases), or build with Swift 6.4 on macOS 15 or later,
or Linux:

```sh
swift build -c release
cp .build/release/modeler /usr/local/bin/
```

## Use

```sh
modeler check Sources
modeler states Sources --type Session
modeler tla Sources --type Session --output Model && tlc -config Model/SessionModel.cfg Model/SessionModel.tla
```

## Learn more

[User guide](docs/README.md): commands, the TLA+ model, configuration.

modeler is one of a family of analyzers with the same options and reports:
[arcleak](https://github.com/g-cqd/arcleak), [deadwood](https://github.com/g-cqd/deadwood), [dolly](https://github.com/g-cqd/dolly)
and [fcheck](https://github.com/g-cqd/fcheck).

[MIT](LICENSE)
