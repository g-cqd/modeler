import Foundation
import Testing

/// What modeler printed before it moved onto analyzerkit's shared surface (analyzerkit roadmap 0022), pinned:
/// `check`'s xcode report and every diagram, byte for byte, on `Goldens/Corpus`. Recorded from `a271b20`'s build;
/// regenerate only for a deliberate change, and say so in the release notes.
@Suite(.serialized) struct ReportGoldenTests {
    private static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let goldens = testsDirectory.appending(path: "Goldens")

    private static func executable() throws -> URL {
        let build = testsDirectory.deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build")
        let candidates = ["debug", "release"].map { build.appending(path: "\($0)/modeler") }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        func modified(_ url: URL) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate]
                as? Date ?? .distantPast
        }
        return try #require(candidates.max { modified($0) < modified($1) }, "build modeler first")
    }

    /// Runs modeler on a copy of the corpus; `<root>` stands for the copy in what it prints.
    private static func run(_ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "modeler-golden-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = scratch.appending(path: "corpus")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: goldens.appending(path: "Corpus"), to: corpus)
        try Data("gitdir: none\n".utf8).write(to: corpus.appending(path: ".git"))
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments + [".", "--no-cache"]
        process.currentDirectoryURL = corpus
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        func shown(_ data: Data) -> String {
            String(decoding: data, as: UTF8.self).replacingOccurrences(of: corpus.path, with: "<root>")
        }
        return (process.terminationStatus, shown(out), shown(err))
    }

    private static func golden(_ name: String) throws -> String {
        try String(contentsOf: goldens.appending(path: name), encoding: .utf8)
    }

    @Test(arguments: [
        (["check"], "check", false), (["check", "--include-tests"], "check_includetests", false),
        (["classes"], "classes", true), (["states"], "states", true), (["facts"], "facts", true),
        (["tla", "--type", "Door"], "tla", true),
    ])
    func `the output is the recorded one`(arguments: [String], name: String, checkErrors: Bool) throws {
        let run = try Self.run(arguments)
        #expect(run.output == (try Self.golden(name + ".out")), "stdout of \(arguments)")
        #expect("\(run.status)\n" == (try Self.golden(name + ".status")), "status of \(arguments)")
        if checkErrors { #expect(run.errors == (try Self.golden(name + ".err")), "stderr of \(arguments)") }
    }
}
