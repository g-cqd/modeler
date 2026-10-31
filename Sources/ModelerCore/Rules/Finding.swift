public import ProjectModel
internal import SourceCorpus

/// One thing `check` reports: a ``ReentrancyFinding`` with its rule, severity and the message the report prints.
public struct Finding: Codable, Sendable, Hashable {
    public let rule: RuleID
    public let severity: Severity
    /// The file that declares the method.
    public let path: String
    /// The line of the write.
    public let line: Int
    public let column: Int
    /// The method, as `Type.name(labels:)`.
    public let function: String
    /// The member checked and written.
    public let member: String
    public let message: String

    public init(_ finding: ReentrancyFinding, severity: Severity) {
        rule = finding.kind.rule
        self.severity = severity
        path = finding.file
        line = finding.writeLine
        column = 1
        function = "\(finding.type).\(finding.method)"
        member = finding.property
        switch finding.kind {
        case .await:
            message =
                "\(function) checks '\(finding.property)' at line \(finding.checkLine), awaits \(finding.awaited) at "
                + "line \(finding.suspendLine), then writes it without checking again; another call may have changed it"
        case .claimedAwait:
            message =
                "\(function) checks '\(finding.property)' at line \(finding.checkLine) and claims it at line "
                + "\(finding.claimLine ?? finding.checkLine), awaits \(finding.awaited) at line \(finding.suspendLine), then "
                + "writes it; \(Self.writers(finding.writers ?? [])) and may run during the await"
        case .lockGap:
            message =
                "\(function) checks '\(finding.property)' at line \(finding.checkLine) and writes it at line "
                + "\(finding.writeLine) without one lock held across both; another thread may have changed it"
        case .staleIndex:
            message =
                "\(function) takes an index into '\(finding.property)' at line \(finding.checkLine), awaits "
                + "\(finding.awaited) at line \(finding.suspendLine), then uses it on '\(finding.property)'; another "
                + "call may have moved its elements, so it may name another element or trap: look it up again"
        }
    }

    /// `reset() also writes it`, `a(), b() and c() also write it`, and past three, `a(), b(), c() and 5 other methods`.
    private static func writers(_ names: [String]) -> String {
        switch names.count {
        case 0: return "another method also writes it"
        case 1: return "\(names[0]) also writes it"
        case 2...3: return names.dropLast().joined(separator: ", ") + " and \(names[names.count - 1]) also write it"
        default:
            return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) other methods also write it"
        }
    }

    /// A hash that identifies the finding across runs and machines: the rule, the path relative to the repository (or
    /// the absolute path outside one), the method and the member. No line, not even through the message, so moving
    /// code does not make a baselined finding new.
    public func fingerprint(root: String?) -> String {
        let shown = root.map { RepositoryRoot.relativize(path, to: $0) } ?? path
        return ContentFingerprint.of(Array("\(rule.rawValue)|\(shown)|\(function)|\(member)".utf8))
    }

    /// Sorted by path, line, column, then rule.
    public static func ordered(_ lhs: Finding, _ rhs: Finding) -> Bool {
        (lhs.path, lhs.line, lhs.column, lhs.rule.rawValue) < (rhs.path, rhs.line, rhs.column, rhs.rule.rawValue)
    }
}
