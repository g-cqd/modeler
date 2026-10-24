internal import AemiJSON

/// The machine-readable form of a corpus's model: `modeler facts`.
public struct ModelReport: Codable, Sendable {
    /// Bumped when a field is removed, renamed or changes meaning. A consumer ignores fields it does not know.
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let types: [TypeFacts]
    public let stateMachines: [StateMachine]
    public let reentrancy: [ReentrancyFinding]

    public init(_ facts: ModelFacts) {
        schemaVersion = Self.schemaVersion
        types = facts.types
        stateMachines = StateMachines.extract(from: facts)
        reentrancy = ReentrancyAnalysis.findings(in: facts)
    }

    /// The report as JSON with object keys in sorted order, so equal models give equal bytes.
    /// - Throws: an encoding error.
    public func json() throws -> [UInt8] {
        var encoder = AemiJSON.JSONEncoder()
        encoder.options.keyOrder = .sorted
        encoder.prettyPrinted = true
        return try encoder.encodeToBytes(self)
    }
}
