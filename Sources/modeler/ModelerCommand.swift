public import ArgumentParser
import ModelerCore
import SourceCorpus
import SystemPackage

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Writes `text` to a descriptor, so stdout carries only the result.
func write(_ text: String, to descriptor: FileDescriptor) {
    _ = try? descriptor.writeAll(text.utf8)
}

@main
struct ModelerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ModelerTool.name,
        abstract: "Models Swift code: UML class and state diagrams, a TLA+ skeleton for TLC, and reentrancy checks.",
        version: ModelerTool.version,
        subcommands: [Classes.self, States.self, TLA.self, Check.self, Facts.self]
    )
}

/// What every subcommand reads.
struct CorpusOptions: ParsableArguments {
    @Argument(help: "Files or directories to read (default: the current directory).")
    var paths: [String] = ["."]

    @Flag(name: .long, help: "Model test and generated code too.")
    var includeTests = false

    @Flag(name: .long, help: "Do not read or write the facts cache.")
    var noCache = false

    @Option(name: .long, help: "The facts cache file (default: a per-workspace file under the user cache directory).")
    var cachePath: String?

    /// Loads the corpus, printing a one-line summary and any unreadable file to stderr.
    func load() async throws -> ModelFacts {
        let report = try await Corpus.load(
            paths: paths, cacheURL: noCache ? nil : cacheURL(), includeTests: includeTests)
        for (path, reason) in report.unreadable.sorted(by: { $0.key < $1.key }) {
            write("\(ModelerTool.name): could not read \(path): \(reason)\n", to: .standardError)
        }
        for (path, reason) in report.degraded.sorted(by: { $0.key < $1.key }) {
            write("\(ModelerTool.name): \(path): \(reason)\n", to: .standardError)
        }
        if let note = report.cacheNote { write("\(ModelerTool.name): \(note)\n", to: .standardError) }
        write(
            "\(ModelerTool.name): \(report.facts.types.count) type(s) in \(report.fileCount) file(s); cache: "
                + "\(report.cacheHits) reused, \(report.fileCount - report.cacheHits) parsed\n", to: .standardError)
        return report.facts
    }

    private func cacheURL() -> URL {
        if let cachePath { return URL(fileURLWithPath: cachePath) }
        let base =
            ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? (ProcessInfo.processInfo.environment["HOME"] ?? "/tmp") + "/.cache"
        let key = RepositoryRoot.workspaceKey(from: FileManager.default.currentDirectoryPath)
        return URL(fileURLWithPath: base + "/\(ModelerTool.name)/\(key)/facts.json")
    }
}

/// Writes `files` under `directory`, creating it; the names are the keys.
func writeFiles(_ files: [String: String], to directory: String) throws {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
        try text.write(toFile: directory + "/" + name, atomically: true, encoding: .utf8)
        write("\(ModelerTool.name): wrote \(directory)/\(name)\n", to: .standardError)
    }
}
