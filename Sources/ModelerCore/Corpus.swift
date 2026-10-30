public import CorpusScan
public import ProjectModel
import SourceCorpus

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
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
        /// Files read but not modelled, with the reason (a syntax tree nested too deeply to walk).
        public let degraded: [String: String]
        /// Why the cache was not used, when that is worth telling the user.
        public let cacheNote: String?
        /// Files classified by path conventions although a project encloses them (`project-unknown`,
        /// `project-unclaimed`).
        public let classificationIssues: [ClassificationIssue]
        /// Seconds per phase: `discover` (and classify) and `scan`.
        public let timings: [String: Double]
    }

    /// Reads, parses and merges every Swift file under `paths`, reusing cached facts for unchanged files.
    ///
    /// Only production code is modelled unless `configuration` selects other regions. A file's region comes from its
    /// project first (ADR-0024): the path decides before the scan, so a test target is not parsed; the content (a
    /// test-framework import, a generator's header) decides after. Parsing runs on all cores, and a file whose bytes
    /// did not change since the last run is not parsed.
    /// - Parameters:
    ///   - paths: files and directories.
    ///   - cache: where the cache lives, or nil for none.
    ///   - configuration: the regions and the configuration's exclusions.
    ///   - isExcluded: further exclusions (the command line's `--exclude-path`).
    /// - Throws: `CancellationError`.
    /// - Complexity: O(*n*) in the corpus size over the available cores.
    public static func load(
        paths: [String], cache: CacheLocation?, configuration: Configuration = .default,
        isExcluded: @escaping @Sendable (String) -> Bool = { _ in false }
    ) async throws -> Report {
        let started = ContinuousClock.now
        let fromFile = configuration.pathFilter
        let excluded: @Sendable (String) -> Bool = { fromFile.excludes($0) || isExcluded($0) }
        var files: [String] = []
        for path in paths {
            let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            if type == .typeDirectory {
                files += SourceDiscovery.swiftFiles(under: path, isExcluded: excluded)
            } else if !excluded(path) {
                files.append(path)
            }
        }
        let classification = ProjectLayout.discover(paths: paths).map(ProjectClassification.load) ?? .conventionsOnly
        let included = files.filter { configuration.models(classification.classify(SourcePath.canonical($0)).region) }
        let discovered = ContinuousClock.now
        let scan = try await CorpusScanner.scan(
            paths: included, cache: cache,
            identity: CacheIdentity.current(tool: ModelerTool.name, version: ModelerTool.version)
        ) { path, bytes in FactsExtractor.extract(bytes: bytes, path: path, classification: classification) }
        var kept: [FileFacts] = []
        var unreadable: [String: String] = [:]
        var degraded: [String: String] = [:]
        var count = 0
        var hits = 0
        for file in scan.files {
            // A file its content places in a region the run leaves out is neither modelled nor counted.
            guard configuration.models(CodeRegion(rawValue: file.facts?.region ?? 0)) else { continue }
            count += 1
            if file.cacheHit { hits += 1 }
            if let failure = file.failure {
                unreadable[file.path] = failure
            } else if let reason = file.facts?.degraded {
                degraded[file.path] = reason
            } else if let facts = file.facts {
                kept.append(facts)
            }
        }
        return Report(
            facts: ModelFacts(files: kept), fileCount: count, cacheHits: hits, unreadable: unreadable,
            degraded: degraded, cacheNote: scan.cacheLoadFailure,
            classificationIssues: classification.issues(for: included.map(SourcePath.canonical)),
            timings: ["discover": seconds(discovered - started), "scan": seconds(ContinuousClock.now - discovered)])
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
