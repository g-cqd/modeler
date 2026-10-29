import AnalyzerCLI
import ArgumentParser
import ModelerCore
import ProjectModel
import SystemPackage

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Reports a check of a member that an await, or a gap between locks, can invalidate before the write that relies on it."
    )

    @OptionGroup var corpus: CorpusOptions

    @Flag(name: .long, help: "Exit 1 when anything is reported.")
    var strict = false

    func run() async throws {
        let findings = ReentrancyAnalysis.findings(in: try await corpus.load())
        for finding in findings {
            let head = "\(finding.file):\(finding.writeLine):1: warning:"
            switch finding.kind {
            case .await:
                write(
                    "\(head) [reentrancy] \(finding.type).\(finding.method) checks '\(finding.property)' at line "
                        + "\(finding.checkLine), awaits \(finding.awaited) at line \(finding.suspendLine), then writes it "
                        + "without checking again; another call may have changed it\n", to: .standardOutput)
            case .lockGap:
                write(
                    "\(head) [lock-gap] \(finding.type).\(finding.method) checks '\(finding.property)' at line "
                        + "\(finding.checkLine) and writes it at line \(finding.writeLine) without one lock held across "
                        + "both; another thread may have changed it\n", to: .standardOutput)
            }
        }
        // Every modeler finding is a warning (ADR-0018: it fails the run under --strict).
        if RunOutcome.fails(findings.map { _ in .warning }, strict: strict) {
            throw ExitCode(ExitStatus.findings.rawValue)
        }
    }
}
