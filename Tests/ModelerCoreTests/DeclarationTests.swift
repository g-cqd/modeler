import ModelerCore
import Testing

@Suite struct DeclarationTests {
    @Test func `kinds, inheritance, attributes and nesting are recorded`() throws {
        let facts = modelFacts(
            """
            @MainActor final class Model: Sendable, Equatable {
                struct Inner { var x = 0 }
                enum Phase { case a }
            }
            actor Counter {}
            protocol Runner {}
            """)
        let model = try #require(facts.type(named: "Model"))
        #expect(model.kind == .classType)
        #expect(model.inherited == ["Sendable", "Equatable"])
        #expect(model.attributes == ["MainActor"])
        #expect(model.isIsolated)
        #expect(facts.type(named: "Model.Inner")?.kind == .structType)
        #expect(facts.type(named: "Model.Phase")?.kind == .enumType)
        #expect(facts.type(named: "Counter")?.isIsolated == true)
        #expect(facts.type(named: "Runner")?.kind == .protocolType)
        #expect(facts.type(named: "Inner")?.name == "Model.Inner", "an unambiguous simple name resolves")
    }

    @Test func `stored properties are kept and computed ones are not`() throws {
        let facts = modelFacts(
            """
            struct S {
                var count = 0
                let name: String? = nil
                static var shared = S()
                var state: Phase = .idle
                var total: Int { count + 1 }
                var observed = 1 { didSet {} }
                lazy var cache = [Int]()
            }
            """)
        let properties = try #require(facts.type(named: "S")).properties
        #expect(properties.map(\.name) == ["count", "name", "shared", "state", "observed", "cache"])
        #expect(properties.first { $0.name == "count" }?.initialLiteral == "0")
        #expect(properties.first { $0.name == "name" }?.isMutable == false)
        #expect(properties.first { $0.name == "name" }?.baseTypeName == "String")
        #expect(properties.first { $0.name == "shared" }?.isStatic == true)
        #expect(properties.first { $0.name == "state" }?.initialCase == "idle")
    }

    @Test func `enum cases keep their payload types`() throws {
        let facts = modelFacts("enum E { case a, b(Int, String); case c(x: Bool) }")
        let cases = try #require(facts.type(named: "E")).cases
        #expect(
            cases == [
                EnumCaseFacts(name: "a", payload: []), EnumCaseFacts(name: "b", payload: ["Int", "String"]),
                EnumCaseFacts(name: "c", payload: ["Bool"]),
            ])
        #expect(facts.enumCases(named: "E") == ["a", "b", "c"])
        #expect(facts.enumCases(named: "Missing") == nil)
    }

    @Test func `method signatures, flags and attributes are recorded`() throws {
        let facts = modelFacts(
            """
            actor A {
                func run(count: Int, _ other: String) async throws {}
                nonisolated func peek() {}
                static func make() {}
                init(seed: Int) {}
            }
            struct S { mutating func bump() {} }
            """)
        let run = try #require(method("run", of: "A", in: facts))
        #expect(run.signature == "run(count:_:)" && run.isAsync && run.isThrowing)
        #expect(method("peek", of: "A", in: facts)?.isNonisolated == true)
        #expect(method("make", of: "A", in: facts)?.isStatic == true)
        #expect(method("init", of: "A", in: facts)?.signature == "init(seed:)")
        #expect(method("bump", of: "S", in: facts)?.isMutating == true)
    }

    @Test func `an extension in another file merges into its type and resolves its members`() throws {
        let facts = modelFacts(
            "actor A { var state: Int = 0 }",
            "extension A { func bump() { state = 1; other = 2 } }")
        let bump = try #require(method("bump", of: "A", in: facts))
        #expect(bump.effects.map(\.summary) == ["write state"], "a name that is no member is dropped")
        #expect(facts.types.count == 1)
    }
}
