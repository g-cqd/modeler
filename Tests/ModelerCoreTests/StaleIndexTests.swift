import ModelerCore
import Testing

/// `stale-index` (analyzerkit roadmap 0064): an index into a member collection, kept across an `await`, then used on it.
@Suite struct StaleIndexTests {
    private func findings(_ body: String, header: String = "@MainActor final class A") -> [ReentrancyFinding] {
        ReentrancyAnalysis.findings(
            in: modelFacts(
                """
                \(header) {
                    var items: [Int] = []
                    var others: [Int] = []
                    func f(id: Int) async {
                        \(body)
                    }
                }
                """))
    }

    @Test func `an index from a guard let, an await, then a replaceSubrange is reported once, under its own rule`()
        throws
    {
        let found = findings(
            """
            guard let index = items.firstIndex(where: { $0 == id }) else { return }
            let value = await load(id)
            items.replaceSubrange(index..<(index + 1), with: [value])
            """)
        let only = try #require(found.first)
        #expect(found.count == 1, "the reentrancy finding on the same line is not reported twice")
        #expect(only.kind == .staleIndex && only.property == "items")
        #expect([only.checkLine, only.suspendLine, only.writeLine] == [5, 6, 7])
        #expect(Finding(only, severity: .error).rule == .staleIndex)
    }

    @Test func `an index from a force unwrap, used in a subscript after the await, is reported`() throws {
        let found = try #require(
            findings(
                """
                let index = items.firstIndex(of: id)!
                await load(id)
                items[index] = 0
                """
            ).first)
        #expect(found.kind == .staleIndex && found.writeLine == 7)
    }

    @Test func `an index derived by arithmetic, or read through a subscript, is followed`() {
        #expect(
            findings(
                """
                let index = items.firstIndex(of: id)!
                let next = index + 1
                await load(id)
                _ = items[next]
                """
            ).map(\.kind) == [.staleIndex])
    }

    @Test func `looking the index up again after the await clears it`() {
        #expect(
            findings(
                """
                var index = items.firstIndex(of: id)!
                await load(id)
                index = items.firstIndex(of: id)!
                items.remove(at: index)
                """
            ).isEmpty)
    }

    @Test func `an index used on another member, or before the await, is not reported`() {
        #expect(
            findings(
                """
                let index = items.firstIndex(of: id)!
                items[index] = 1
                await load(id)
                others[index] = 0
                """
            ).isEmpty)
    }

    @Test func `a type no other task interleaves with is not examined`() {
        #expect(
            findings(
                "let index = items.firstIndex(of: id)!\nawait load(id)\nitems[index] = 0", header: "final class A"
            ).isEmpty)
    }

    @Test func `the rule is an error by default, with its explanation`() {
        #expect(RuleID.staleIndex.rawValue == "stale-index" && RuleID.staleIndex.defaultSeverity == .error)
        #expect(RuleID.staleIndex.explanation.contains("again"))
    }
}
