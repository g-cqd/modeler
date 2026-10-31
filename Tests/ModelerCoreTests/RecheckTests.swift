import ModelerCore
import Testing

/// What else re-validates a check after an `await`, besides reading the member again: a method of the type that reads
/// it, a generation token that every other writer bumps, a cancellation that every other writer triggers.
@Suite struct RecheckTests {
    private func findings(_ source: String) -> [ReentrancyFinding] {
        ReentrancyAnalysis.findings(in: modelFacts(source))
    }

    // MARK: A method of the type, called in a condition

    @Test func `a condition calling a method that reads the member checks it again`() {
        #expect(
            findings(
                """
                actor A {
                    var phase = 0
                    func isCurrent(_ expected: Int) -> Bool { phase == expected }
                    func f() async {
                        guard phase == 0 else { return }
                        await g()
                        guard isCurrent(0) else { return }
                        phase = 1
                    }
                }
                """
            ).isEmpty)
    }

    @Test func `a condition calling a method that does not read the member does not`() {
        #expect(
            findings(
                """
                actor A {
                    var phase = 0
                    var other = 0
                    func isReady() -> Bool { other == 0 }
                    func f() async {
                        guard phase == 0 else { return }
                        await g()
                        guard isReady() else { return }
                        phase = 1
                    }
                }
                """
            ).map(\.property) == ["phase"])
    }

    // MARK: A generation token

    private func token(otherWriter: String) -> String {
        """
        actor A {
            var phase = 0
            var generation = 0
            func f() async {
                guard phase == 0 else { return }
                generation += 1
                let mine = generation
                await g()
                guard mine == generation else { return }
                phase = 1
            }
            func reset() {
                \(otherWriter)
            }
        }
        """
    }

    @Test func `a token the method bumps and checks after the await, which every other writer bumps, checks it again`()
    {
        #expect(findings(token(otherWriter: "generation += 1\nphase = 2")).isEmpty)
    }

    @Test func `a token that another writer of the member does not bump does not`() {
        #expect(findings(token(otherWriter: "phase = 2")).map(\.property) == ["phase"])
    }

    // MARK: Cancellation

    private func cancellation(check: String, otherWriter: String) -> String {
        """
        actor A {
            var phase = 0
            var task: Task<Void, Never>?
            func f() async throws {
                guard phase == 0 else { return }
                await g()
                \(check)
                phase = 1
            }
            func stop() {
                \(otherWriter)
            }
        }
        """
    }

    @Test(arguments: ["try Task.checkCancellation()", "guard !Task.isCancelled else { return }"])
    func `a cancellation check after the await, when every other writer cancels a task, checks it again`(
        check: String
    ) {
        #expect(findings(cancellation(check: check, otherWriter: "task?.cancel()\nphase = 2")).isEmpty)
    }

    @Test func `a cancellation check when another writer cancels nothing does not`() {
        #expect(
            findings(cancellation(check: "try Task.checkCancellation()", otherWriter: "phase = 2")).map(\.property)
                == ["phase"])
    }

    @Test func `cancelling without checking for it after the await does not`() {
        #expect(
            findings(cancellation(check: "", otherWriter: "task?.cancel()\nphase = 2")).map(\.property) == ["phase"])
    }

    @Test func `a cancel of a member task is an effect of its own`() throws {
        let facts = modelFacts("actor A { var task: Task<Void, Never>?\nfunc stop() { task?.cancel() } }")
        let stop = try #require(method("stop", of: "A", in: facts))
        #expect(stop.effects.map(\.summary).contains("cancel task"))
    }
}
