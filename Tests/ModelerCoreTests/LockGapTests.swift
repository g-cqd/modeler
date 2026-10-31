import ModelerCore
import Testing

@Suite struct LockGapTests {
    private func findings(_ body: String, locked: Bool = true) -> [ReentrancyFinding] {
        ReentrancyAnalysis.findings(
            in: modelFacts(
                """
                final class Cache: @unchecked Sendable {
                    var ready = false
                    var value = 0
                    let lock = NSLock()
                    func f() {
                        \(body)
                    }
                    func g() { lock.withLock { value = 1 } }
                }
                """))
    }

    @Test func `a check in one lock scope and a write in another is a gap`() throws {
        let found = try #require(findings("lock.withLock { if ready {} }\nlock.withLock { ready = true }").first)
        #expect(found.kind == .lockGap && found.property == "ready")
    }

    @Test func `a check and a write in one scope is not`() {
        #expect(findings("lock.withLock { if !ready { ready = true } }").isEmpty)
    }

    @Test func `an unlocked check then an unlocked write in a type that takes locks is a gap`() throws {
        let found = try #require(findings("if !ready { ready = true }").first)
        #expect(found.kind == .lockGap && found.checkLine == found.writeLine)
    }

    @Test func `a type that never takes a lock is not examined`() {
        let facts = modelFacts("final class Plain { var ready = false; func f() { if !ready { ready = true } } }")
        #expect(ReentrancyAnalysis.findings(in: facts).isEmpty)
    }

    @Test func `a lock on a local value does not make the type one that takes locks`() {
        let facts = modelFacts(
            """
            final class Converter {
                var cache: [Int: Int] = [:]
                func convert(_ key: Int) -> Int {
                    let state = Box()
                    state.value.withLock { $0 = true }
                    if let cached = cache[key] { return cached }
                    cache[key] = key
                    return key
                }
            }
            """)
        #expect(ReentrancyAnalysis.findings(in: facts).isEmpty)
    }

    @Test func `a lock on a static member does`() throws {
        let facts = modelFacts(
            """
            final class Converter: @unchecked Sendable {
                static let lock = NSLock()
                var cache: [Int: Int] = [:]
                func convert(_ key: Int) -> Int {
                    Self.lock.withLock { }
                    if let cached = cache[key] { return cached }
                    cache[key] = key
                    return key
                }
            }
            """)
        #expect(try #require(ReentrancyAnalysis.findings(in: facts).first).kind == .lockGap)
    }

    @Test func `checking again inside the second scope clears the gap`() {
        #expect(findings("lock.withLock { if ready {} }\nlock.withLock { if !ready { ready = true } }").isEmpty)
    }

    @Test func `each lock scope is one TLA+ step and each unlocked access is its own`() throws {
        let facts = modelFacts(
            """
            final class Cache: @unchecked Sendable {
                var ready = false
                let lock = NSLock()
                func racy() { if !ready { ready = true } }
                func safe() { lock.withLock { if !ready { ready = true } } }
            }
            """)
        let module = try #require(TLAModule.render(type: "Cache", in: facts)).module
        #expect(
            module.contains("racy_0(p) ==") && module.contains("racy_1(p) =="), "the check and the write interleave")
        #expect(module.contains("safe_0(p) ==") && !module.contains("safe_1(p)"), "the lock scope is atomic")
        #expect(module.contains("NoStaleWrite_1 == ~stale_1"))
    }
}
