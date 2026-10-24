/// What a finding says happened between the check and the write.
public enum InterleavingKind: String, Codable, Sendable {
    /// An `await` in an actor-isolated method.
    case await
    /// The check and the write are in different `withLock` scopes, or one of them is in none, in a type that
    /// takes locks.
    case lockGap
}
