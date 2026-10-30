internal import AemiJSON
internal import ProjectModel
public import ReportSupport
internal import SourceCorpus

#if canImport(FoundationEssentials)
    internal import FoundationEssentials
#else
    internal import Foundation
#endif

/// `check`'s output: xcode lines as before the migration, or JSON and SARIF on analyzerkit's shared models
/// (ADR-0017), and its baseline.
public enum CheckReport {
    public enum Format: String, Sendable { case xcode, json, sarif }

    /// What a run reports besides its findings.
    public struct Context: Sendable {
        public var fileCount = 0
        public var cacheHits = 0
        public var suppressed = 0
        public var baselined = 0
        public var runNotes: [RunNote] = []
        public var skippedFiles: [SkippedFile] = []
        public var timings: [String: Double]?

        public init() {}
    }

    /// The findings rendered in `format`; paths relative to `relativeTo` when given, fingerprints relative to `root`.
    public static func render(
        _ findings: [Finding], format: Format, root: String?, relativeTo: String?, context: Context
    ) throws -> String {
        func shown(_ path: String) -> String { relativeTo.map { RepositoryRoot.relativize(path, to: $0) } ?? path }
        switch format {
        case .xcode:
            return findings.map { finding in
                XcodeDiagnostic.line(
                    path: shown(finding.path), line: finding.line, column: finding.column,
                    severity: finding.severity.rawValue, rule: finding.rule.rawValue, message: finding.message) + "\n"
            }.joined()
        case .json:
            let report = JSONReport(
                fileCount: context.fileCount, cacheHits: context.cacheHits, suppressed: context.suppressed,
                baselined: context.baselined,
                findings: findings.map { finding in
                    JSONFinding(
                        rule: finding.rule.rawValue, severity: finding.severity.rawValue, path: shown(finding.path),
                        line: finding.line, column: finding.column, function: finding.function,
                        member: finding.member, message: finding.message, fingerprint: finding.fingerprint(root: root))
                })
            let envelope = ReportEnvelope(
                report, tool: ModelerTool.name, version: ModelerTool.version, runNotes: context.runNotes,
                skippedFiles: context.skippedFiles, timings: context.timings)
            return try encode(envelope)
        case .sarif:
            return try sarif(findings, root: relativeTo ?? root)
        }
    }

    private struct JSONFinding: Encodable {
        let rule: String
        let severity: String
        let path: String
        let line: Int
        let column: Int
        let function: String
        let member: String
        let message: String
        let fingerprint: String
    }

    private struct JSONReport: Encodable {
        let fileCount: Int
        let cacheHits: Int
        let suppressed: Int
        let baselined: Int
        let findings: [JSONFinding]
    }

    private static func sarif(_ findings: [Finding], root: String?) throws -> String {
        let results = findings.map { finding in
            let path = root.map { RepositoryRoot.relativize(finding.path, to: $0) } ?? finding.path
            return Sarif.Result(
                ruleId: finding.rule.rawValue, level: finding.severity.rawValue, message: Sarif.Text(finding.message),
                locations: [
                    Sarif.Location(
                        physicalLocation: Sarif.PhysicalLocation(
                            artifactLocation: Sarif.ArtifactLocation(path: path, root: root),
                            region: Sarif.Region(startLine: finding.line, startColumn: finding.column)))
                ],
                partialFingerprints: ["modeler/v1": finding.fingerprint(root: root)])
        }
        let rules = RuleID.allCases.map { rule in
            Sarif.Rule(
                id: rule.rawValue, shortDescription: Sarif.Text(rule.summary),
                fullDescription: Sarif.Text(rule.explanation),
                defaultConfiguration: ["level": rule.defaultSeverity.rawValue])
        }
        let driver = Sarif.Driver(
            name: ModelerTool.name, version: ModelerTool.version, informationUri: ModelerTool.informationURI,
            rules: rules)
        let log = Sarif.Log(runs: [
            Sarif.Run(tool: Sarif.Tool(driver: driver), invocations: nil, root: root, results: results)
        ])
        return try encode(log)
    }

    private static func encode(_ value: some Encodable) throws -> String {
        var encoder = AemiJSON.JSONEncoder()
        encoder.options.keyOrder = .sorted
        encoder.prettyPrinted = true
        return String(decoding: try encoder.encodeToBytes(value), as: UTF8.self) + "\n"
    }
}

/// The fingerprints of findings accepted as they are (analyzerkit `BaselineFile`).
public struct Baseline: Sendable, Equatable {
    public let fingerprints: Set<String>

    public init(findings: [Finding], root: String?) {
        fingerprints = Set(findings.map { $0.fingerprint(root: root) })
    }

    init(fingerprints: Set<String>) { self.fingerprints = fingerprints }

    /// Why a baseline file was not used.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func load(from path: String) throws(Failure) -> Baseline {
        let data: Data
        do { data = try BoundedFileReader.readConfiguration(path: path) } catch {
            throw Failure(description: "cannot read baseline \(path): \(error)")
        }
        do {
            let file = try AemiJSON.JSONDecoder().decode(BaselineFile.self, from: [UInt8](data))
            return Baseline(fingerprints: Set(try file.validated(requiringVersion: false).fingerprints))
        } catch {
            throw Failure(description: "invalid baseline \(path): \(error)")
        }
    }

    public func write(to path: String) throws {
        var encoder = AemiJSON.JSONEncoder()
        encoder.options.keyOrder = .sorted
        encoder.prettyPrinted = true
        let file = BaselineFile(tool: ModelerTool.name, fingerprints: fingerprints.sorted(), versioned: true)
        try Data(try encoder.encodeToBytes(file)).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// `findings` less those the baseline holds, and how many it held.
    public func filter(_ findings: [Finding], root: String?) -> (kept: [Finding], baselined: Int) {
        let kept = findings.filter { !fingerprints.contains($0.fingerprint(root: root)) }
        return (kept, findings.count - kept.count)
    }
}
