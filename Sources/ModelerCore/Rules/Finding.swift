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
        rule = finding.kind == .await ? .reentrancy : .lockGap
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
        case .lockGap:
            message =
                "\(function) checks '\(finding.property)' at line \(finding.checkLine) and writes it at line "
                + "\(finding.writeLine) without one lock held across both; another thread may have changed it"
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
