# Configuration

modeler reads `.modeler.json`, or a `"modeler"` section of the shared `.swift-analyzers.json`
([how files are found and merged](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#configuration)).

```json
{
  "disable": ["lock-gap"],
  "severity": { "reentrancy": "error" },
  "exclude": ["/Generated/"]
}
```

## Suppression

`@modeler:` and `@md:` are the same directive:

```swift
// @modeler:accept reentrancy -- reason
// @md:accept:this
// @md:accept:next
// @md:disable lock-gap
// @md:enable lock-gap
```
