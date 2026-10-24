import Foundation
import ModelerCore
import Testing

@Suite struct CorpusTests {
    private func scratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let root = FileManager.default.temporaryDirectory.appending(path: "modeler-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(root)
    }

    private func write(_ path: String, _ text: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func `a directory is walked, test and generated code is left out unless asked for`() async throws {
        try await scratch { root in
            try write("Sources/A.swift", "struct A {}", in: root)
            try write("Tests/ATests.swift", "struct ATests {}", in: root)
            try write("Sources/B.generated.swift", "struct B {}", in: root)
            let plain = try await Corpus.load(paths: [root.path], cacheURL: nil)
            #expect(plain.facts.types.map(\.name) == ["A"])
            let everything = try await Corpus.load(paths: [root.path], cacheURL: nil, includeTests: true)
            #expect(everything.facts.types.map(\.name) == ["A", "ATests", "B"])
        }
    }

    @Test func `a second load over unchanged files parses nothing and gives the same model`() async throws {
        try await scratch { root in
            try write("A.swift", "actor A { var x = 0; func f() async { if x == 0 { await g(); x = 1 } } }", in: root)
            let cache = root.appending(path: "cache/facts.json")
            let cold = try await Corpus.load(paths: [root.path], cacheURL: cache)
            let warm = try await Corpus.load(paths: [root.path], cacheURL: cache)
            #expect(cold.cacheHits == 0 && warm.cacheHits == 1)
            #expect(ReentrancyAnalysis.findings(in: warm.facts) == ReentrancyAnalysis.findings(in: cold.facts))
            #expect(warm.facts.types == cold.facts.types)
        }
    }

    @Test func `a file that cannot be read is reported and the others are still modelled`() async throws {
        try await scratch { root in
            try write("A.swift", "struct A {}", in: root)
            let report = try await Corpus.load(
                paths: [root.appending(path: "A.swift").path, root.appending(path: "Missing.swift").path], cacheURL: nil
            )
            #expect(report.facts.types.map(\.name) == ["A"])
            #expect(report.unreadable.keys.contains { $0.hasSuffix("Missing.swift") })
        }
    }

    @Test func `the JSON report is stable and carries the schema version`() throws {
        let facts = modelFacts("enum P { case a, b }\nactor X { var p: P = .a; func f() { p = .b } }")
        let first = try ModelReport(facts).json()
        #expect(first == (try ModelReport(facts).json()))
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains("\"schemaVersion\" : 1") || text.contains("\"schemaVersion\": 1"))
        #expect(text.contains("\"stateMachines\""))
    }
}
