import ModelerCore
import ProjectModel
import Testing

/// analyzerkit's `ModelerProbes.swift` (M1–M3) as tests, with the verdicts the dataflow over the control-flow graph
/// gives (roadmap 0026).
@Suite struct InterleavingFlowTests {
    private func actor(_ body: String, extra: String = "") -> [ReentrancyFinding] {
        ReentrancyAnalysis.findings(
            in: modelFacts("actor A {\n var phase = 0\n func f() async {\n\(body)\n }\n\(extra)\n}"))
    }

    private func lines(_ found: [ReentrancyFinding]) -> [String] {
        found.map { "\($0.checkLine)-\($0.suspendLine)-\($0.writeLine)" }
    }

    /// M1: claiming the state before the await (set a phase, then await) is the remedy the rule recommends.
    @Test func `a claim before the await is not reported when nothing else writes the member`() {
        #expect(actor("guard phase == 0 else { return }\nphase = 1\nawait g()\nphase = 2").isEmpty)
    }

    @Test func `a claim before the await is reported as a claim when another method writes the member`() throws {
        let found = actor(
            "guard phase == 0 else { return }\nphase = 1\nawait g()\nphase = 2", extra: "func reset() { phase = 0 }")
        let only = try #require(found.first)
        #expect(found.count == 1)
        #expect(only.kind == .claimedAwait && lines(found) == ["4-6-7"] && only.claimLine == 5)
        #expect(only.writers == ["reset()"])
        let message = Finding(only, severity: .warning).message
        #expect(message.contains("reset()") && message.contains("line 5"), "\(message)")
    }

    /// M2: the write at the top of the loop follows the previous iteration's check and await.
    @Test func `a write the loop carries past a check and an await is reported`() {
        let found = actor("while true {\nphase = 3\nif phase == 0 { }\nawait g()\n}")
        #expect(lines(found) == ["6-7-5"] && found.first?.kind == .await)
    }

    /// M3: a check, then an await on one branch and a write on the other, never meet on a path.
    @Test func `an await and a write on exclusive branches do not pair`() {
        #expect(actor("if phase == 0 { await g() } else { phase = 1 }").isEmpty)
    }

    @Test func `an await on only one branch still reaches a write after the join`() {
        #expect(lines(actor("if phase == 0 { await g() }\nphase = 1")) == ["4-4-5"])
    }

    /// M3 for lock gaps: a check under the lock and a write on the other branch of an unlocked `if` do not pair.
    @Test func `a lock gap needs the check and the write on one path`() {
        let facts = modelFacts(
            """
            final class Cache: @unchecked Sendable {
                var ready = false
                let lock = NSLock()
                func f(_ fast: Bool) {
                    if fast { lock.withLock { if ready {} } } else { lock.withLock { ready = true } }
                }
            }
            """)
        #expect(ReentrancyAnalysis.findings(in: facts).isEmpty)
    }

    @Test func `the facts report leaves the control-flow graph out`() throws {
        let facts = modelFacts("actor A {\n var phase = 0\n func f() async {\n if phase == 0 { await g() }\n }\n}")
        let flow = try #require(facts.type(named: "A")?.methods.first?.flow)
        #expect(!flow.isEmpty)
        let json = String(decoding: try ModelReport(facts).json(), as: UTF8.self)
        #expect(!json.contains("\"flow\"") && !json.contains("\"nodes\""))
    }
}
