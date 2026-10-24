import CorpusScan
import ProjectModel
import SourceCorpus

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

/// Loads the facts of the Swift files under a set of paths.
public enum Corpus {
    /// What a load found besides the facts.
    public struct Report: Sendable {
        public let facts: ModelFacts
        public let fileCount: Int
        public let cacheHits: Int
        /// Files that could not be read, with the reason.
        public let unreadable: [String: String]
        /// Why the cache was not used, when that is worth telling the user.
        public let cacheNote: String?
    }

    /// Reads, parses and merges every Swift file under `paths`, reusing cached facts for unchanged files.
    ///
    /// Test and generated files are left out unless `includeTests` is set. Parsing runs on all cores, and a file
    /// whose bytes did not change since the last run is not parsed.
    /// - Parameters:
    ///   - paths: files and directories.
    ///   - cacheURL: the cache file, or nil for none.
    ///   - includeTests: whether to model test code.
    /// - Throws: `CancellationError`.
    /// - Complexity: O(*n*) in the corpus size over the available cores; O(*c*) for a warm cache of *c* entries.
    public static func load(paths: [String], cacheURL: URL?, includeTests: Bool = false) async throws -> Report {
        var files: [String] = []
        for path in paths {
            let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            if type == .typeDirectory {
                files += SourceDiscovery.swiftFiles(under: path)
            } else {
                files.append(path)
            }
        }
        let scan = try await CorpusScanner.scan(
            paths: files, cacheURL: cacheURL,
            identity: FactsCache<FileFacts>.Identity.current(tool: ModelerTool.name, version: ModelerTool.version)
        ) { path, bytes in FactsExtractor.extract(bytes: bytes, path: path) }
        var kept: [FileFacts] = []
        var unreadable: [String: String] = [:]
        for file in scan.files {
            if let failure = file.failure {
                unreadable[file.path] = failure
            } else if let facts = file.facts, includeTests || !isTestOrGenerated(file.path) {
                kept.append(facts)
            }
        }
        return Report(
            facts: ModelFacts(files: kept), fileCount: scan.files.count, cacheHits: scan.cacheHits,
            unreadable: unreadable, cacheNote: scan.cacheLoadFailure)
    }

    private static func isTestOrGenerated(_ path: String) -> Bool {
        TestConventions.isTestPath(path) || GeneratedCode.isGenerated(path: path, header: "")
    }
}
