public import ProjectModel

/// modeler's rules: what `check` reports.
public enum RuleID: String, CaseIterable, Codable, Sendable {
    case reentrancy
    case lockGap = "lock-gap"

    public var defaultSeverity: Severity { .warning }

    /// One line, for the catalogue.
    public var summary: String {
        switch self {
        case .reentrancy:
            "An actor method checks a member, awaits, then writes the member without checking it again."
        case .lockGap:
            "A method checks a member and writes it without one lock held across both, in a type that takes locks."
        }
    }

    /// What the rule requires and how to satisfy it.
    public var explanation: String {
        switch self {
        case .reentrancy:
            """
            An actor (or a global-actor type) runs a method without interruption only between suspension points. \
            When an `await` returns, other calls may have run and changed the member the method checked before it, \
            so the write that follows rests on a check that may no longer hold.

            Check the member again after the `await`, or move the check and the write to the same side of it, or \
            claim the state before suspending (set a phase, then await).
            """
        case .lockGap:
            """
            A type that guards its state with a lock checks a member under one acquisition, or none, and writes it \
            under another. Between the two, another thread may take the lock and change the member, so the write \
            rests on a check that may no longer hold.

            Hold one lock across the check and the write (`lock.withLock { if !ready { ready = true } }`), or check \
            again inside the scope that writes.
            """
        }
    }
}
