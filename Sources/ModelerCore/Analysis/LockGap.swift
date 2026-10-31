/// What a finding says happened between the check and the write.
public enum InterleavingKind: String, Codable, Sendable {
    /// An `await` in an actor-isolated method.
    case await
    /// The method claimed the member (wrote it after the check) before the `await`, which keeps its own callers out,
    /// but another method of the type writes the member and may run during the `await` (roadmap 0026, M1).
    case claimedAwait
    /// The check and the write are in different `withLock` scopes, or one of them is in none, in a type that
    /// takes locks.
    case lockGap
    /// An index into a member collection, bound before an `await`, used on that member after it (roadmap 0064):
    /// ``ReentrancyFinding/checkLine`` is the binding, ``ReentrancyFinding/writeLine`` the use.
    case staleIndex

    /// The rule that reports this kind.
    public var rule: RuleID {
        switch self {
        case .await, .claimedAwait: .reentrancy
        case .lockGap: .lockGap
        case .staleIndex: .staleIndex
        }
    }
}
