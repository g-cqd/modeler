import ModelerCore
import Testing

@Suite struct StateMachineTests {
    private let source = """
        enum Phase { case idle, running, done }
        final class Job {
            var phase: Phase = .idle
            var attempts = 0
            func start() { guard phase == .idle else { return }; phase = .running }
            func finish() { if phase == .running || phase == .idle { phase = .done } }
            func reset() { phase = .idle; attempts = 0 }
            func apply(_ next: Phase) { phase = next }
        }
        enum Light {
            case red, green
            mutating func advance() { switch self { case .red: self = .green; case .green: self = .red } }
        }
        """

    @Test func `every write of a known case becomes a transition from what the guard allows`() throws {
        let machines = StateMachines.extract(from: modelFacts(source))
        let job = try #require(machines.first { $0.owner == "Job" })
        #expect(job.stateType == "Phase" && job.property == "phase" && job.initial == "idle")
        #expect(job.cases == ["idle", "running", "done"])
        #expect(
            job.transitions.map { "\($0.method) \($0.from ?? []) -> \($0.to)" } == [
                "start() [\"idle\"] -> running", "finish() [\"idle\", \"running\"] -> done", "reset() [] -> idle",
            ])
        #expect(job.transitions[2].from == nil)
        #expect(job.opaqueWrites == 1, "apply(_:) assigns a parameter")
    }

    @Test func `an enum that assigns itself is a machine over its own cases`() throws {
        let light = try #require(StateMachines.extract(from: modelFacts(source)).first { $0.owner == "Light" })
        #expect(light.property == "self")
        #expect(
            light.transitions.map { "\($0.from ?? []) -> \($0.to)" } == ["[\"red\"] -> green", "[\"green\"] -> red"])
    }

    @Test func `a transition guarded before an await is marked stale`() throws {
        let facts = modelFacts(
            """
            enum P { case a, b }
            actor X {
                var p: P = .a
                func go() async { guard p == .a else { return }; await h(); p = .b }
            }
            """)
        let machine = try #require(StateMachines.extract(from: facts).first)
        #expect(machine.transitions.map(\.isStale) == [true])
    }

    @Test func `an initializer is not a transition`() {
        let facts = modelFacts(
            "enum K { case a, b\n init(_ n: Int) { self = n == 0 ? .a : .b }\n init() { self = .a } }")
        #expect(StateMachines.extract(from: facts).isEmpty)
    }

    @Test func `members of other types and members nothing writes are not machines`() {
        let facts = modelFacts("enum P { case a }\nstruct S { var p: P = .a; var n = 1; func f() { _ = p } }")
        #expect(StateMachines.extract(from: facts).isEmpty)
    }

    @Test func `assignments through subscripts produce state machine transitions`() throws {
        let source = """
            enum Phase { case idle, running, done }

            struct Machine {
                var phase: Phase = .idle
                var items: [Item] = []

                struct Item { var phase: Phase = .idle }

                mutating func start() { phase = .running }
                mutating func finish() { phase = .done }
                mutating func advanceItem(_ i: Int) { items[i].phase = .running }
                mutating func viaSelf() { self.items[0].phase = .done }
            }
            """
        let machines = StateMachines.extract(from: modelFacts(source))
        let item = try #require(machines.first { $0.owner.contains("Item") })
        #expect(item.property == "phase")
        #expect(item.transitions.map(\.to).sorted() == ["done", "running"])
    }
}
