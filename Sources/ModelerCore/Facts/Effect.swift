/// What a method body does that matters to a model, in source order.
public struct Effect: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Reads the member named by ``subject``.
        case read
        /// Assigns, mutates or passes `inout` the member named by ``subject``.
        case write
        /// Calls the function named by ``subject`` on `self`.
        case call
        /// An `await` (or `for await`): the executor may run other work here. ``subject`` is the awaited expression.
        case suspend
        /// Starts unstructured concurrency (`Task {}`, `Task.detached {}`, `addTask {}`).
        case spawn
        /// Enters a `withLock` scope on the member named by ``subject``; the scope ends at the matching `release`.
        case acquire
        /// Leaves the scope the last `acquire` opened.
        case release
    }

    public let kind: Kind
    /// 1-based source line.
    public let line: Int
    public let subject: String
    /// For a write: the literal assigned, when the right-hand side is one: an enum case name (`.case`), `true`,
    /// `false`, an integer or `nil`.
    public let value: String?
    /// A read inside the condition of an `if`, `guard`, `while`, ternary or `switch` subject.
    public let isCheck: Bool
    /// How many closures enclose the effect. Zero is the method's own body.
    public let closureDepth: Int
    /// What the enclosing conditions established about enum-valued members at this point.
    public let when: [StateGuard]
    /// The `withLock` scopes that enclose the effect, outermost first.
    public let locks: [String]

    public init(
        kind: Kind, line: Int, subject: String, value: String? = nil, isCheck: Bool = false, closureDepth: Int = 0,
        when: [StateGuard] = [], locks: [String] = []
    ) {
        self.kind = kind
        self.line = line
        self.subject = subject
        self.value = value
        self.isCheck = isCheck
        self.closureDepth = closureDepth
        self.when = when
        self.locks = locks
    }
}

/// The cases a member is known to hold, from the `if`, `guard` or `switch` that encloses an effect.
public struct StateGuard: Codable, Sendable, Hashable {
    public let property: String
    /// Sorted case names.
    public let cases: [String]
    /// False once an `await` has run since the check: another task may have changed the member, so the
    /// guard no longer describes the state the code acts on.
    public let isFresh: Bool

    public init(property: String, cases: [String], isFresh: Bool) {
        self.property = property
        self.cases = cases
        self.isFresh = isFresh
    }
}
