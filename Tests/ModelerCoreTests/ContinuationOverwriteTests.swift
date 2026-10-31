import ModelerCore
import Testing

/// `continuation-overwrite` (analyzerkit roadmap 0065): a stored continuation replaced while it may still be pending.
@Suite struct ContinuationOverwriteTests {
    private func findings(_ body: String, type: String = "CheckedContinuation<Int, Error>?") -> [ReentrancyFinding] {
        ReentrancyAnalysis.findings(
            in: modelFacts(
                """
                @MainActor final class Camera {
                    private var pending: \(type)
                    func frame() async throws -> Int {
                        try await withCheckedThrowingContinuation { continuation in
                            \(body)
                            start()
                        }
                    }
                    func finished(_ value: Int) {
                        defer { pending = nil }
                        pending?.resume(returning: value)
                    }
                }
                """))
    }

    @Test func `storing a continuation over one that may be pending is reported, as an error`() throws {
        let found = try #require(findings("pending = continuation").first)
        #expect(found.kind == .continuationOverwrite && found.property == "pending" && found.writeLine == 5)
        #expect(found.method == "frame()")
        let finding = Finding(found, severity: RuleID.continuationOverwrite.defaultSeverity)
        #expect(finding.rule == .continuationOverwrite && finding.severity == .error)
    }

    @Test(arguments: [
        "guard pending == nil else { continuation.resume(throwing: Busy()); return }\npending = continuation",
        "pending?.resume(throwing: Replaced())\npending = continuation",
        "if let old = pending { old.resume(throwing: Replaced()) }\npending = continuation",
    ])
    func `checking or resuming the old one first is not`(body: String) {
        #expect(findings(body).isEmpty)
    }

    @Test func `setting it to nil, or a member of another type, is not`() {
        #expect(findings("pending = nil").isEmpty)
        #expect(findings("pending = continuation", type: "Int?").isEmpty)
    }

    @Test func `continuations kept under a key are not this shape`() {
        #expect(
            findings(
                "pending[id] = continuation", type: "[Int: CheckedContinuation<Int, Error>]"
            ).isEmpty)
    }

    @Test func `the rule is an error by default`() {
        #expect(RuleID.continuationOverwrite.rawValue == "continuation-overwrite")
        #expect(RuleID.continuationOverwrite.defaultSeverity == .error)
    }
}
