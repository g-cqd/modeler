import AnalyzerCLI
import ArgumentParser
import ModelerCore
import ProjectModel
import ReportSupport
import SourceCorpus
import SystemPackage

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// `modeler check`, on analyzerkit's shared option groups (ADR-0019): Input, Output, Rules, Cache, in that order.
struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Reports a check of a member that an await, or a gap between locks, can invalidate before the write that relies on it."
    )

    @OptionGroup var corpus: CorpusOptions
    @OptionGroup(title: OptionGroupTitle.output) var output: OutputOptions
    @OptionGroup(title: OptionGroupTitle.rules) var rules: RuleOptions

    func validate() throws {
        // Without a scope every finding is already reported, so there is nothing to promote (ADR-0028).
        if output.reportNewSince != nil, corpus.input.only.isEmpty, corpus.input.onlyFrom == nil {
            throw ValidationError("--report-new-since requires --only or --only-from")
        }
    }

    func run() async throws {
        // Read before the analysis, so a bad path fails with 78 without the analysis cost.
        let newSince = try output.reportNewSince.map(loadBaseline)
        var configuration = try corpus.configuration(verbose: output.verbose, quiet: output.quiet)
        if let wanted = rules.rules {
            var ids: [RuleID] = []
            for name in wanted {
                guard let rule = RuleID(rawValue: name) else {
                    write(
                        "\(ModelerTool.name): no rule named \(name); `modeler rules` lists them\n", to: .standardError)
                    throw ExitCode(ExitStatus.usage.rawValue)
                }
                ids.append(rule)
            }
            configuration.disable = RuleID.allCases.filter { !ids.contains($0) }
        }
        let started = ContinuousClock.now
        let loaded = try await corpus.load(configuration, verbose: output.verbose, quiet: output.quiet)
        let checked = CheckResult(loaded.facts, configuration: configuration)
        var findings = checked.findings
        let root = RepositoryRoot.common(of: findings.map(\.path)) ?? RepositoryRoot.common(of: corpus.input.paths)
        let fingerprint = { (finding: Finding) in finding.fingerprint(root: root) }

        var promoted: Set<String> = []
        var baselineMatchesNothing = false
        if let scope = try scopedFiles() {
            let inScope = findings.filter { scope.contains($0.path) }
            let outOfScope = findings.filter { !scope.contains($0.path) }
            findings = inScope
            if let newSince {
                baselineMatchesNothing = NewSince.matchesNothing(
                    inScope + outOfScope, in: newSince.fingerprints, fingerprint: fingerprint)
                let promotion = NewSince.promote(
                    inScope: inScope, outOfScope: outOfScope, notIn: newSince.fingerprints, fingerprint: fingerprint)
                findings = promotion.reported.sorted(by: Finding.ordered)
                promoted = promotion.promoted
            }
        }
        if let path = output.writeBaseline {
            do { try Baseline(findings: findings, root: root).write(to: path) } catch {
                write("\(ModelerTool.name): cannot write baseline \(path): \(error)\n", to: .standardError)
                throw ExitCode(ExitStatus.outputFailure.rawValue)
            }
            note("\(ModelerTool.name): wrote a baseline of \(findings.count) finding(s) to \(path)")
            return
        }
        var context = CheckReport.Context()
        if let path = output.baseline {
            (findings, context.baselined) = try loadBaseline(path).filter(findings, root: root)
        }
        var notes: [RunNote] = loaded.cacheNote.map { [RunNote(code: "cache", severity: "note", message: $0)] } ?? []
        let relative = output.relativeTo.map(SourcePath.canonical)
        func shown(_ path: String) -> String { relative.map { RepositoryRoot.relativize(path, to: $0) } ?? path }
        notes += loaded.classificationIssues.map { issue in
            RunNote(
                code: issue.code, severity: "note", message: issue.message, paths: issue.paths.map(shown),
                verbose: output.verbose)
        }
        if let path = output.reportNewSince {
            // Counted after --baseline, so the note states what the report shows.
            let count = findings.count { promoted.contains(fingerprint($0)) }
            for message in NewSince.notes(promoted: count, matchesNothing: baselineMatchesNothing, baseline: path) {
                notes.append(RunNote(code: "report-new-since", severity: "note", message: message))
                note(message)
            }
        }
        context.fileCount = loaded.fileCount
        context.cacheHits = loaded.cacheHits
        context.suppressed = checked.suppressed.count
        context.runNotes = notes
        context.skippedFiles =
            loaded.unreadable.keys.sorted().map { SkippedFile(path: shown($0), reason: .unreadable) }
            + loaded.degraded.keys.sorted().map { SkippedFile(path: shown($0), reason: .degraded) }
        var timings = loaded.timings
        timings["rules"] = Self.seconds(ContinuousClock.now - started) - timings.values.reduce(0, +)
        if output.timings { context.timings = timings }

        write(
            try CheckReport.render(
                findings, format: CheckReport.Format(rawValue: output.format.rawValue) ?? .xcode, root: root,
                relativeTo: relative, context: context),
            to: .standardOutput)
        if output.timings {
            for (phase, seconds) in timings.sorted(by: { $0.key < $1.key }) {
                note("\(ModelerTool.name): timing: \(phase) \(Int((seconds * 1000).rounded())) ms")
            }
        }
        let errors = findings.count { $0.severity == .error }
        let warnings = findings.count { $0.severity == .warning }
        note(
            "\(ModelerTool.name): \(findings.count) finding(s) (\(errors) error(s), \(warnings) warning(s)); "
                + "\(checked.suppressed.count) suppressed, \(context.baselined) baselined")
        // ADR-0018: an error fails the run, a warning only under --strict, a note never.
        if RunOutcome.fails(findings.map(\.severity), strict: output.strict) {
            throw ExitCode(ExitStatus.findings.rawValue)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// A line on stderr, unless `--quiet`.
    private func note(_ line: String) {
        if !output.quiet { write(line + "\n", to: .standardError) }
    }

    private func loadBaseline(_ path: String) throws -> Baseline {
        do { return try Baseline.load(from: path) } catch {
            write("\(ModelerTool.name): \(error)\n", to: .standardError)
            throw ExitCode(ExitStatus.badConfiguration.rawValue)
        }
    }

    private func scopedFiles() throws -> Set<String>? {
        var entries = corpus.input.only
        if let onlyFrom = corpus.input.onlyFrom {
            if onlyFrom == "-" {
                while let line = readLine() { entries.append(line) }
            } else {
                let text = try String(contentsOfFile: onlyFrom, encoding: .utf8)
                entries += text.split(whereSeparator: \.isNewline).map(String.init)
            }
        }
        return entries.isEmpty && corpus.input.onlyFrom == nil ? nil : Set(entries.map(SourcePath.canonical))
    }
}
