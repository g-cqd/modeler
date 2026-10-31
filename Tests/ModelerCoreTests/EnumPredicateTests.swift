import ModelerCore
import Testing

/// A guard on an enum's Boolean computed property narrows the member to the cases the property holds for (the TLA+
/// gap of analyzerkit roadmap 0062). The enum is in another file, as it usually is.
@Suite struct EnumPredicateTests {
    private static let state = """
        enum State {
            case idle, preparing, recording(Int), paused(Int)
            var isRecording: Bool {
                if case .recording = self {
                    return true
                }
                return false
            }
            var isPaused: Bool { if case .paused = self { true } else { false } }
            var isActive: Bool {
                switch self {
                case .recording, .paused: return true
                default: return false
                }
            }
            var isIdle: Bool { self == .idle }
            var label: String { "x" }
        }
        """

    private func when(_ condition: String, in method: String = "finalize") throws -> [StateGuard] {
        let facts = modelFacts(
            """
            actor Recorder {
                var state: State = .idle
                func \(method)() async {
                    guard \(condition) else { return }
                    state = .idle
                }
            }
            """, Self.state)
        let write = try #require(
            facts.type(named: "Recorder")?.methods.first?.effects.first { $0.kind == .write && $0.subject == "state" })
        return write.when
    }

    @Test(arguments: [
        ("state.isRecording || state.isPaused", ["paused", "recording"]),
        ("state.isActive", ["paused", "recording"]),
        ("state.isIdle", ["idle"]),
        ("!state.isActive", ["idle", "preparing"]),
        ("self.state.isRecording", ["recording"]),
    ])
    func `a guard on a predicate narrows the member to its cases`(condition: String, cases: [String]) throws {
        #expect(try when(condition) == [StateGuard(property: "state", cases: cases, isFresh: true)])
    }

    @Test func `a property that is not such a predicate, or of a type that is not an enum, narrows nothing`() throws {
        #expect(try when("state.label.isEmpty").isEmpty)
        #expect(try when("state.isUnknown").isEmpty)
    }

    @Test func `the predicates are facts of the enum`() throws {
        let facts = modelFacts(Self.state)
        #expect(
            facts.type(named: "State")?.predicates == [
                "isActive": ["paused", "recording"], "isIdle": ["idle"], "isPaused": ["paused"],
                "isRecording": ["recording"],
            ])
    }

    @Test func `the TLA+ model takes the precondition from the predicate`() throws {
        let facts = modelFacts(
            """
            actor Recorder {
                var state: State = .idle
                func finalize() async {
                    guard state.isRecording || state.isPaused else { return }
                    await stop()
                    state = .idle
                }
                func stop() async {}
            }
            """, Self.state)
        let module = try #require(TLAModule.render(type: "Recorder", in: facts)).module
        #expect(module.contains("/\\ state \\in {\"paused\", \"recording\"}"))
    }
}
