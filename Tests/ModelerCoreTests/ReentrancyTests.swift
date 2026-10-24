import ModelerCore
import Testing

@Suite struct ReentrancyTests {
    private func findings(_ body: String, header: String = "actor A") -> [ReentrancyFinding] {
        ReentrancyAnalysis.findings(
            in: modelFacts(
                """
                \(header) {
                    var phase = 0
                    var other = 0
                    func f() async {
                        \(body)
                    }
                }
                """))
    }

    @Test func `a check, an await and a write of the same member is reported with all three lines`() throws {
        let found = try #require(findings("guard phase == 0 else { return }\nawait g()\nphase = 1").first)
        #expect(found.property == "phase")
        #expect([found.checkLine, found.suspendLine, found.writeLine] == [5, 6, 7])
        #expect(found.method == "f()" && found.type == "A" && found.file == "File0.swift")
    }

    @Test func `checking again after the await clears it`() {
        #expect(
            findings("guard phase == 0 else { return }\nawait g()\nguard phase == 0 else { return }\nphase = 1").isEmpty
        )
    }

    @Test func `no await, or a write to another member, is not reported`() {
        #expect(findings("guard phase == 0 else { return }\nphase = 1").isEmpty)
        #expect(findings("guard phase == 0 else { return }\nawait g()\nother = 1").isEmpty)
    }

    @Test func `a write before the await is not reported`() {
        #expect(findings("if phase == 0 { phase = 1 }\nawait g()").isEmpty)
    }

    @Test func `a type that no other task can interleave with is not reported`() {
        #expect(findings("guard phase == 0 else { return }\nawait g()\nphase = 1", header: "final class A").isEmpty)
        #expect(
            findings("guard phase == 0 else { return }\nawait g()\nphase = 1", header: "@MainActor final class A").count
                == 1)
    }

    @Test func `an await or write inside a closure is ignored`() {
        #expect(findings("guard phase == 0 else { return }\nTask { await g() }\nphase = 1").isEmpty)
        #expect(findings("guard phase == 0 else { return }\nawait g()\nTask { phase = 1 }").isEmpty)
    }
}
