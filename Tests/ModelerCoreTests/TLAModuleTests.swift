import Foundation
import ModelerCore
import Testing

@Suite struct TLAModuleTests {
    private static let hazard = """
        enum Phase { case idle, running, done }
        actor Session {
            var phase: Phase = .idle
            var started = 0
            var label = ""
            func start() async throws {
                guard phase == .idle else { throw CancellationError() }
                try await warmUp()
                phase = .running
                started += 1
            }
            func startSafely() async throws {
                guard phase == .idle else { throw CancellationError() }
                try await warmUp()
                guard phase == .idle else { throw CancellationError() }
                phase = .running
            }
            func finish() { guard phase == .running else { return }; phase = .done; label = "x" }
            func warmUp() async throws {}
        }
        """

    private func model(_ source: String = hazard, type: String = "Session") throws -> TLAModel {
        try #require(TLAModule.render(type: type, in: modelFacts(source)))
    }

    @Test func `variables, domains and initial values come from the declarations`() throws {
        let module = try model().module
        #expect(module.contains("---- MODULE SessionModel ----"))
        #expect(module.contains("Dom_phase == {\"idle\", \"running\", \"done\"}"))
        #expect(module.contains("Dom_started == 0..IntMax"))
        #expect(module.contains("Dom_label == Opaque"))
        #expect(module.contains("/\\ phase = \"idle\""))
        #expect(module.contains("/\\ started = 0"))
        #expect(module.contains("/\\ label = CHOOSE v \\in Dom_label : TRUE"), "a string is any value of its set")
    }

    @Test func `an await splits a method into segments that interleave`() throws {
        let module = try model().module
        #expect(module.contains("start_0(p) =="))
        #expect(module.contains("start_1(p) =="))
        #expect(module.contains("pc' = [pc EXCEPT ![p] = \"start_1\"]"))
        #expect(module.contains("finish_0(p) ==") && !module.contains("finish_1(p)"))
    }

    @Test func `a check is a precondition of its own segment and has a skip action`() throws {
        let module = try model().module
        #expect(module.contains("finish_0_skip(p) =="))
        #expect(module.contains("/\\ phase \\in {\"running\"}"))
        #expect(!module.contains("{\"done\", \"running\"}"), "the segment's own write does not widen its precondition")
    }

    @Test func `a stale check does not constrain the segment after the await, a fresh one does`() throws {
        let module = try model().module
        let stale = try #require(module.range(of: "start_1(p) =="))
        let staleBody = module[stale.lowerBound...].prefix(while: { _ in true }).split(separator: "\n").prefix(6)
            .joined(separator: "\n")
        #expect(!staleBody.contains("phase \\in {\"idle\"}"))
        let safe = try #require(module.range(of: "startSafely_1(p) =="))
        #expect(
            module[safe.lowerBound...].split(separator: "\n").prefix(4).joined(separator: "\n").contains(
                "phase \\in {\"idle\"}"))
    }

    @Test func `only the finding gets a monitor and the configuration names its invariant`() throws {
        let model = try model()
        #expect(model.module.contains("NoStaleWrite_1 == ~stale_1"))
        #expect(!model.module.contains("NoStaleWrite_2"))
        #expect(model.config.contains("INVARIANTS\n    TypeOK\n    NoStaleWrite_1"))
        #expect(model.config.contains("Procs = {p1, p2}") && model.config.contains("Opaque = {o1, o2}"))
        #expect(model.config.contains("IntMax = 2"))
    }

    @Test func `bounds change the configuration`() throws {
        var bounds = TLAModule.Bounds()
        bounds.callers = 3
        bounds.integerMaximum = 5
        let model = try #require(TLAModule.render(type: "Session", in: modelFacts(Self.hazard), bounds: bounds))
        #expect(model.config.contains("Procs = {p1, p2, p3}") && model.config.contains("IntMax = 5"))
    }

    @Test func `an unknown type, or one with no state its methods touch, has no model`() {
        let facts = modelFacts(Self.hazard + "\nstruct Empty { func f() {} }")
        #expect(TLAModule.render(type: "Nope", in: facts) == nil)
        #expect(TLAModule.render(type: "Empty", in: facts) == nil)
    }

    /// The generated module is only worth anything if TLC accepts it and finds the hazard. Set `TLA2TOOLS` to a
    /// `tla2tools.jar` to run this; it needs `java`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TLA2TOOLS"] != nil))
    func `TLC finds the stale write and accepts the safe variant`() throws {
        let jar = try #require(ProcessInfo.processInfo.environment["TLA2TOOLS"])
        let hazardous = try tlc(model(), jar: jar)
        #expect(hazardous.contains("Invariant NoStaleWrite_1 is violated"))

        let safeOnly = Self.hazard.replacingOccurrences(
            of: "try await warmUp()\n        phase = .running\n        started += 1", with: "phase = .running")
        let safe = try tlc(model(safeOnly), jar: jar)
        #expect(safe.contains("Model checking completed. No error has been found."))
    }

    private func tlc(_ model: TLAModel, jar: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "modeler-tlc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try model.module.write(to: directory.appending(path: "\(model.name).tla"), atomically: true, encoding: .utf8)
        try model.config.write(to: directory.appending(path: "\(model.name).cfg"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "java", "-cp", jar, "tlc2.TLC", "-deadlock", "-nowarning", "-config", "\(model.name).cfg",
            "\(model.name).tla",
        ]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}
