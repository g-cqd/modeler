import ModelerCore
import Testing

@Suite struct EmitTests {
    private let source = """
        protocol Runner { func run() }
        @MainActor final class Base: Runner {
            var phase: Phase = .idle
            var count = 0
            func run() {}
        }
        final class Sub: Base { var helper: Helper? }
        struct Helper { var items: [Int] = [] }
        enum Phase { case idle, running }
        extension Base { func extra() {} }
        """

    @Test func `the class diagram lists types, members, stereotypes and edges`() {
        let diagram = MermaidClassDiagram.render(modelFacts(source))
        #expect(diagram.hasPrefix("classDiagram\n"))
        #expect(diagram.contains("class Base[\"Base\"] {\n        <<@MainActor>>"))
        #expect(diagram.contains("<<enumeration>>"))
        #expect(diagram.contains("<<interface>>"))
        #expect(diagram.contains("+phase: Phase"))
        #expect(diagram.contains("+extra()"), "an extension's method belongs to its type")
        #expect(diagram.contains("Runner <|.. Base"))
        #expect(diagram.contains("Base <|-- Sub"))
        #expect(diagram.contains("Sub --> Helper : helper"))
        #expect(diagram.contains("Base --> Phase : phase"))
        #expect(!diagram.contains("Equatable"))
    }

    @Test func `focus keeps the neighbourhood and nothing else`() {
        let facts = modelFacts(source)
        let near = MermaidClassDiagram.render(facts, focus: ["Helper"], depth: 1)
        #expect(near.contains("class Helper") && near.contains("class Sub"))
        #expect(!near.contains("class Base[") && !near.contains("class Phase"))
        let far = MermaidClassDiagram.render(facts, focus: ["Helper"], depth: 2)
        #expect(far.contains("class Base["))
    }

    @Test func `long member lists are cut`() {
        let members = (0..<20).map { "var v\($0) = 0" }.joined(separator: "\n")
        let diagram = MermaidClassDiagram.render(modelFacts("struct Big {\n\(members)\n}"), maximumMembers: 5)
        #expect(diagram.contains("v4") && !diagram.contains("v5") && diagram.contains("…"))
    }

    @Test func `the state diagram draws the initial state, every edge and the stale mark`() throws {
        let facts = modelFacts(
            """
            enum P { case a, b, state }
            actor X {
                var p: P = .a
                func go() async { guard p == .a else { return }; await h(); p = .b }
                func back() { p = .state }
            }
            """)
        let machine = try #require(StateMachines.extract(from: facts).first)
        let diagram = MermaidStateDiagram.render(machine)
        #expect(diagram.contains("[*] --> a"))
        #expect(diagram.contains("a --> b : go() L4 (stale)"))
        #expect(diagram.contains("any --> state_ : back() L5"), "a Mermaid keyword is not used as an id")
        #expect(diagram.contains("state \"any state\" as any"))
    }
}
