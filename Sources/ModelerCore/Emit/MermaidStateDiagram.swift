/// A Mermaid `stateDiagram-v2` of one ``StateMachine``.
public enum MermaidStateDiagram {
    /// One edge per transition, labelled with the writing method and line. A transition guarded before an
    /// `await` is labelled `stale`: the member may have changed since the guard. A write with no guard starts
    /// at the pseudo-state `any`.
    /// - Complexity: O(*c* + *t*) in cases and transitions.
    public static func render(_ machine: StateMachine) -> String {
        var lines = ["stateDiagram-v2", "    %% \(machine.owner).\(machine.property): \(machine.stateType)"]
        if machine.opaqueWrites > 0 || machine.transitions.contains(where: { $0.from == nil }) {
            lines.append("    state \"any state\" as any")
        }
        for name in machine.cases { lines.append("    \(identifier(name))") }
        if let initial = machine.initial { lines.append("    [*] --> \(identifier(initial))") }
        for transition in machine.transitions {
            let label = "\(transition.method) L\(transition.line)\(transition.isStale ? " (stale)" : "")"
            for source in transition.from.map({ $0.map(identifier) }) ?? ["any"] {
                lines.append("    \(source) --> \(identifier(transition.to)) : \(label)")
            }
        }
        if machine.opaqueWrites > 0 {
            lines.append("    note right of any : \(machine.opaqueWrites) write(s) of a computed value, not drawn")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func identifier(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        // `state` and `note` are Mermaid keywords.
        return ["state", "note", "end"].contains(cleaned) ? cleaned + "_" : cleaned
    }
}
