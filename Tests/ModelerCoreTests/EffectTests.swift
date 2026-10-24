import ModelerCore
import Testing

@Suite struct EffectTests {
    private func effects(
        _ body: String, members: String = "var state: Phase = .idle; var count = 0; var items = [Int]()"
    ) -> [Effect] {
        let facts = modelFacts(
            """
            enum Phase { case idle, running, done }
            actor A {
                \(members)
                func f(_ arg: Int) async throws {
                    \(body)
                }
            }
            """)
        return method("f", of: "A", in: facts)?.effects ?? []
    }

    @Test func `assignments to members are writes, in source order after the right-hand side`() {
        let found = effects("count = count + arg; self.state = .running")
        #expect(found.map(\.summary) == ["read count", "write count", "write state"])
        #expect(found.last?.value == "running")
    }

    @Test func `a compound assignment reads then writes`() {
        #expect(effects("count += 1").map(\.summary) == ["read count", "write count"])
    }

    @Test func `a local or parameter of the same name is not the member`() {
        #expect(effects("let count = 1; _ = count; _ = arg").isEmpty)
        #expect(effects("let count = 1; self.count = count").map(\.summary) == ["write count"])
    }

    @Test func `a mutating call reads then writes the member and an inout argument writes it`() {
        #expect(
            effects("items.append(1); items[0] = 2").map(\.summary) == ["read items", "write items", "write items"])
        #expect(effects("modify(&count)").map(\.summary) == ["write count"])
    }

    @Test func `reads in conditions are checks and other reads are not`() {
        let found = effects("if count > 0 { _ = state }")
        #expect(found.map(\.isCheck) == [true, false])
    }

    @Test func `an if narrows its body and a write replaces the narrowing`() {
        let found = effects("if state == .idle { count = 1; state = .running; count = 2 }")
        let writes = found.filter { $0.kind == .write }
        #expect(writes[0].when == [StateGuard(property: "state", cases: ["idle"], isFresh: true)])
        #expect(writes[1].when == [StateGuard(property: "state", cases: ["idle"], isFresh: true)])
        #expect(writes[2].when == [StateGuard(property: "state", cases: ["running"], isFresh: true)])
    }

    @Test func `a guard that exits narrows the rest of the block, one that does not narrows nothing`() {
        let exits = effects("guard state == .idle else { throw CancellationError() }; count = 1")
        #expect(exits.last?.when.first?.cases == ["idle"])
        let falls = effects("guard state == .idle else { count = 9 }; count = 1")
        #expect(falls.last?.when.isEmpty == true)
    }

    @Test func `a switch narrows each case and a default narrows nothing`() {
        let found = effects(
            """
            switch state {
            case .idle, .done: count = 1
            case .running(let x): count = 2
            default: count = 3
            }
            """)
        let writes = found.filter { $0.kind == .write }
        #expect(writes.map { $0.when.first?.cases } == [["done", "idle"], ["running"], nil])
    }

    @Test func `or over one member unions its cases and over two members establishes nothing`() {
        let same = effects("if state == .idle || state == .done { count = 1 }")
        #expect(same.last?.when.first?.cases == ["done", "idle"])
        let mixed = effects("if state == .idle || count == 0 { count = 1 }")
        #expect(mixed.last?.when.isEmpty == true)
    }

    @Test func `an await makes every earlier guard stale`() {
        let found = effects("guard state == .idle else { return }; try await other(); state = .running")
        #expect(found.map(\.kind) == [.read, .suspend, .write])
        #expect(found[1].when.first?.isFresh == true, "the guard held when the await was reached")
        #expect(found[2].when == [StateGuard(property: "state", cases: ["idle"], isFresh: false)])
    }

    @Test func `for await suspends and a closure's effects carry its depth`() {
        let found = effects("for await _ in stream() {}; Task { count = 1 }; let g = { count = 2 }; g()")
        #expect(found.map(\.kind) == [.suspend, .spawn, .write, .write])
        #expect(found.map(\.closureDepth) == [0, 0, 1, 1])
    }

    @Test func `calls on self are recorded and calls on anything else are not`() {
        let facts = modelFacts("actor A { func g() {}; func f() { g(); self.g(); other.g(); h() } }")
        #expect(method("f", of: "A", in: facts)?.effects.map(\.summary) == ["call g", "call g"])
    }
}

@Suite struct BooleanNarrowingTests {
    private func writeGuards(_ condition: String) -> [StateGuard] {
        let facts = modelFacts("actor A { var ready = false; var count = 0; func f() { \(condition) { count = 1 } } }")
        return method("f", of: "A", in: facts)?.effects.last { $0.kind == .write }?.when ?? []
    }

    @Test func `a bare member in a condition is true and its negation is false`() {
        #expect(writeGuards("if ready").map(\.cases) == [["true"]])
        #expect(writeGuards("if !ready").map(\.cases) == [["false"]])
        #expect(writeGuards("if ready == false").map(\.cases) == [["false"]])
    }

    @Test func `a guard that exits narrows the rest, and an and joins both`() {
        let facts = modelFacts(
            "actor A { var ready = false; var done = false; var n = 0; func f() { guard !done, ready else { return }; n = 1 } }"
        )
        let guards = method("f", of: "A", in: facts)?.effects.last { $0.kind == .write }?.when ?? []
        #expect(Set(guards.map { "\($0.property)=\($0.cases)" }) == ["done=[\"false\"]", "ready=[\"true\"]"])
    }

    @Test func `an or of different members establishes nothing`() {
        #expect(writeGuards("if ready || count == 0").isEmpty)
    }

    @Test func `the TLA+ precondition of a boolean check is written in TLA+ booleans`() throws {
        let facts = modelFacts(
            "actor A { var ready = false; func f() async { guard !ready else { return }; await g(); ready = true } }")
        let module = try #require(TLAModule.render(type: "A", in: facts)).module
        #expect(module.contains("/\\ ready \\in {FALSE}"))
        #expect(module.contains("f_0_skip(p) =="))
    }
}
