import Foundation
import ModelerCore
import ProjectModel
import Testing

/// `--define` and the configuration's `defines` (analyzerkit roadmap 0059): with either, only the clauses active under
/// those conditions are modelled; without, every clause is, as before.
@Suite struct DefineTests {
    private let declarations = """
        actor A {
            var phase = 0
            #if FEATURE
            func f() async {
                guard phase == 0 else { return }
                await g()
                phase = 1
            }
            #else
            func f() async {
                await g()
                guard phase == 0 else { return }
                phase = 1
            }
            #endif
            func g() async {}
        }
        """

    private let statements = """
        actor A {
            var phase = 0
            func f() async {
                guard phase == 0 else { return }
                await g()
                #if FEATURE
                phase = 1
                #else
                if phase == 0 { phase = 1 }
                #endif
            }
            func g() async {}
        }
        """

    private func findings(_ source: String, defines: Set<String>) -> [ReentrancyFinding] {
        let facts = FactsExtractor.extract(
            source: source, path: "A.swift", conditions: CompilationConditions(defines: defines))
        return ReentrancyAnalysis.findings(in: ModelFacts(files: [facts]))
    }

    @Test func `a finding inside #if FEATURE is reported without a define and with FEATURE, not with OTHER`() {
        #expect(findings(declarations, defines: []).count == 1)
        #expect(findings(declarations, defines: ["FEATURE"]).count == 1)
        #expect(findings(declarations, defines: ["OTHER"]).isEmpty)
    }

    @Test func `a statement-level #if in a body follows the same rule`() {
        #expect(findings(statements, defines: ["FEATURE"]).count == 1)
        #expect(findings(statements, defines: ["OTHER"]).isEmpty)
    }

    @Test func `the configuration reads defines and platforms, and the corpus models with them`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "modeler-define-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try declarations.write(to: root.appending(path: "A.swift"), atomically: true, encoding: .utf8)
        let other = try await Corpus.load(
            paths: [root.path], cache: nil, configuration: Configuration(defines: ["OTHER"]))
        #expect(ReentrancyAnalysis.findings(in: other.facts).isEmpty)
        let feature = try await Corpus.load(
            paths: [root.path], cache: nil, configuration: Configuration(defines: ["FEATURE"]))
        #expect(ReentrancyAnalysis.findings(in: feature.facts).count == 1)
    }
}
