internal import SourceCorpus
internal import Suppression
internal import SwiftParser
internal import SwiftSyntax

/// `// @modeler:` and `// @md:` comments (analyzerkit's shared grammar): `accept [rules] [-- reason]` on the line and
/// the next, `accept:this`, `accept:next`, `disable [rules]` … `enable [rules]`.
///
/// Read only from the files that have findings, when `check` runs, so the cached facts stay what they were.
enum Suppressions {
    static let namespaces = ["modeler:", "md:"]
    private static let grammar = DirectiveGrammar(namespaces: namespaces)

    /// For each finding not suppressed, nil; for a suppressed one, the reason the comment gave (or an empty reason).
    static func split(_ findings: [Finding]) -> (kept: [Finding], suppressed: [(Finding, String?)]) {
        var tables: [String: SuppressionTable<RuleID>] = [:]
        var kept: [Finding] = []
        var suppressed: [(Finding, String?)] = []
        for finding in findings {
            let table = tables[finding.path] ?? table(for: finding.path)
            tables[finding.path] = table
            if let reason = table.suppression(for: finding.rule, line: finding.line) {
                suppressed.append((finding, reason))
            } else {
                kept.append(finding)
            }
        }
        return (kept, suppressed)
    }

    private static func table(for path: String) -> SuppressionTable<RuleID> {
        guard let bytes = try? BoundedFileReader.read(path: path, cap: BoundedFileReader.sourceByteCap),
            grammar.containsMarker(String(decoding: bytes, as: UTF8.self))
        else { return SuppressionTable(directives: []) }
        let tree = Parser.parse(source: String(decoding: bytes, as: UTF8.self))
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let directives = grammar.scan(tree: tree, converter: converter) { comment, line in
            grammar.parse(comment: comment, line: line, rule: RuleID.init(rawValue:))
        }
        return SuppressionTable(directives: directives)
    }
}

/// What `check` found in a model.
public struct CheckResult: Sendable {
    /// Not suppressed, in report order.
    public let findings: [Finding]
    public let suppressed: [(finding: Finding, reason: String?)]

    /// The findings of the rules `configuration` keeps, with its severities, less those a comment suppresses.
    public init(_ facts: ModelFacts, configuration: Configuration) {
        let all = ReentrancyAnalysis.findings(in: facts).map { finding in
            Finding(finding, severity: configuration.severity(of: finding.kind.rule))
        }
        .filter { configuration.isEnabled($0.rule) }
        .sorted(by: Finding.ordered)
        let split = Suppressions.split(all)
        findings = split.kept
        suppressed = split.suppressed.map { (finding: $0.0, reason: $0.1) }
    }
}
