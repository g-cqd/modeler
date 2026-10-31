public import ProjectModel

/// modeler's rules: what `check` reports.
public enum RuleID: String, CaseIterable, Codable, Sendable {
    case reentrancy
    case lockGap = "lock-gap"
    case staleIndex = "stale-index"
    case continuationOverwrite = "continuation-overwrite"

    /// The two rules whose finding traps or never resumes a caller are errors; the interleavings are warnings.
    public var defaultSeverity: Severity {
        switch self {
        case .reentrancy, .lockGap: .warning
        case .staleIndex, .continuationOverwrite: .error
        }
    }

    /// One line, for the catalogue.
    public var summary: String {
        switch self {
        case .reentrancy:
            "An actor method checks a member, awaits, then writes the member without checking it again."
        case .lockGap:
            "A method checks a member and writes it without one lock held across both, in a type that takes locks."
        case .staleIndex:
            "An actor method takes an index into a member collection, awaits, then uses the index on that member."
        case .continuationOverwrite:
            "A method stores a continuation in a member that may still hold one that was never resumed."
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
        case .staleIndex:
            """
            An index found before an `await` (`firstIndex`, `lastIndex`, `indices`, or arithmetic on one) says where \
            an element was. While the method is suspended, other calls may insert, remove or replace elements, so \
            after the `await` the index may name another element, or none: a subscript or `replaceSubrange` with it \
            then changes the wrong element or traps.

            Look the index up again by identity after the `await` (`firstIndex(where: { $0.id == id })`), and leave \
            when it is gone.
            """
        case .continuationOverwrite:
            """
            A continuation must be resumed exactly once. Storing a new one in a member that may still hold an \
            earlier one drops the earlier one: its caller never resumes, and the next resume reaches the wrong \
            caller.

            Check that the member is nil first and fail the new caller, or resume the old one before replacing it, \
            or keep the continuations under a key of their own.
            """
        }
    }
}
