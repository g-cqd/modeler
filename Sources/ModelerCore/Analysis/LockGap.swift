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
}
