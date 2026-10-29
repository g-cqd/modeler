import Foundation
import ModelerCore
import Testing

/// A deeply nested file never crashes the load: one nested within reason is modelled on the large stack, one nested past
/// the limit is listed as not analysed, and the rest of the corpus is modelled (analyzerkit roadmap 0041).
@Suite struct DeepTreeTests {
    private static func chain(_ type: String, _ links: Int) -> String {
        "struct \(type) {\n    func f() {\n        let v = view" + String(repeating: ".m(1)", count: links)
            + "\n        print(v)\n    }\n}\n"
    }

    @Test func `a deep file is modelled or listed as degraded, and the corpus still loads`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "modeler-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.chain("Deep", 3_000).write(to: root.appending(path: "Deep.swift"), atomically: true, encoding: .utf8)
        try Self.chain("Deeper", 15_000).write(
            to: root.appending(path: "Deeper.swift"), atomically: true, encoding: .utf8)
        try "struct Plain {}\n".write(to: root.appending(path: "Plain.swift"), atomically: true, encoding: .utf8)
        let report = try await Corpus.load(paths: [root.path], cacheURL: nil)
        #expect(report.facts.types.map(\.name).sorted() == ["Deep", "Plain"])
        #expect(report.degraded.keys.map { ($0 as NSString).lastPathComponent } == ["Deeper.swift"])
        #expect(report.unreadable.isEmpty)
    }
}
