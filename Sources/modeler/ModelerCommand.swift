import AnalyzerCLI
import AnalyzerConfiguration
public import ArgumentParser
import CorpusScan
import ModelerCore
import ProjectModel
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
        subcommands: [Classes.self, States.self, TLA.self, Check.self, Facts.self, Rules.self, Explain.self]
    )
}

/// What every subcommand reads: analyzerkit's Input and Cache groups (ADR-0019), and the configuration they lead to.
struct CorpusOptions: ParsableArguments {
    @OptionGroup(title: OptionGroupTitle.input) var input: InputOptions
    @OptionGroup(title: OptionGroupTitle.cache) var cache: CacheOptions

    /// The run's configuration: `--config` or the configuration directory's files, then the command line's regions.
    /// - Throws: `ExitCode` 78 for a configuration that cannot be read or is invalid, 64 for an unknown region.
    func configuration(verbose: Bool = false, quiet: Bool = false) throws -> Configuration {
        func note(_ line: String) { if !quiet { write(line + "\n", to: .standardError) } }
        for deprecation in input.deprecations { note(deprecation.message(tool: ModelerTool.name)) }
        if !input.defines.isEmpty {
            note("\(ModelerTool.name): note: --define has no effect yet: modeler reads every #if clause")
        }
        let resolved: (configuration: Configuration, sources: SharedConfiguration.Resolved)
        do {
            resolved = try Configuration.resolve(
                explicit: input.config, currentDirectory: FileManager.default.currentDirectoryPath,
                analyzedPaths: input.paths)
        } catch {
            write("\(ModelerTool.name): \(error)\n", to: .standardError)
            throw ExitCode(ExitStatus.badConfiguration.rawValue)
        }
        if verbose { for line in resolved.sources.verboseLines(tool: ModelerTool.name) { note(line) } }
        var configuration = resolved.configuration
        if input.includeRegions != nil || input.excludeRegions != nil {
            do {
                let given = try RegionSelection(include: input.includeRegions, exclude: input.excludeRegions)
                configuration.regions = RegionSelection(
                    include: input.includeRegions == nil ? configuration.regions.include : given.include,
                    exclude: input.excludeRegions == nil ? configuration.regions.exclude : given.exclude)
            } catch {
                write("\(ModelerTool.name): \(error)\n", to: .standardError)
                throw ExitCode(ExitStatus.usage.rawValue)
            }
        }
        return configuration
    }

    /// Loads the corpus, printing a one-line summary, any unreadable file and the classification notes to stderr.
    /// - Throws: `ExitCode` 64 for a path that does not exist or no Swift file under the paths, 70 when no file found
    ///   could be read or modelled (ADR-0018).
    func load(_ configuration: Configuration, verbose: Bool = false, quiet: Bool = false) async throws -> Corpus.Report
    {
        func note(_ line: String) { if !quiet { write(line + "\n", to: .standardError) } }
        if let missing = input.paths.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
            write("\(ModelerTool.name): no such file or directory: \(missing)\n", to: .standardError)
            throw ExitCode(ExitStatus.usage.rawValue)
        }
        let commandLine = PathFilter(input.excludePaths, root: FileManager.default.currentDirectoryPath)
        let report = try await Corpus.load(
            paths: input.paths, cache: cache.noCache ? nil : cacheLocation(), configuration: configuration,
            isExcluded: { commandLine.excludes($0) })
        for (path, reason) in report.unreadable.sorted(by: { $0.key < $1.key }) {
            write("\(ModelerTool.name): could not read \(path): \(reason)\n", to: .standardError)
        }
        for (path, reason) in report.degraded.sorted(by: { $0.key < $1.key }) {
            write("\(ModelerTool.name): \(path): \(reason)\n", to: .standardError)
        }
        if let cacheNote = report.cacheNote { note("\(ModelerTool.name): \(cacheNote)") }
        for issue in report.classificationIssues {
            note("\(ModelerTool.name): note: \(issue.message)")
            if verbose { for path in issue.paths { note("    \(path)") } }
        }
        note(
            "\(ModelerTool.name): \(report.facts.types.count) type(s) in \(report.fileCount) file(s); cache: "
                + "\(report.cacheHits) reused, \(report.fileCount - report.cacheHits) parsed")
        guard report.fileCount > 0 else {
            write(
                "\(ModelerTool.name): no Swift files under \(input.paths.joined(separator: ", "))\n",
                to: .standardError)
            throw ExitCode(ExitStatus.usage.rawValue)
        }
        let skipped = report.unreadable.count + report.degraded.count
        if RunOutcome.status(
            severities: [], strict: false, analyzedFileCount: report.fileCount - skipped, skippedFileCount: skipped)
            == .internalFailure
        {
            write("\(ModelerTool.name): no file could be read or modelled\n", to: .standardError)
            throw ExitCode(ExitStatus.internalFailure.rawValue)
        }
        return report
    }

    /// The facts, for the diagram commands.
    func load() async throws -> ModelFacts {
        try await load(try configuration()).facts
    }

    /// The cache's root (`--cache-path`, or the user cache directory) and the workspace the run serves (ADR-0011).
    private func cacheLocation() -> CacheLocation {
        let environment = ProcessInfo.processInfo.environment
        let root =
            cache.cachePath.map(SourcePath.absolute)
            ?? CacheLocation.defaultRoot(
                tool: ModelerTool.name, environment: environment, home: environment["HOME"] ?? "/tmp")
        let workspace =
            ProjectLayout.discover(paths: input.paths)?.root ?? SourcePath.absolute(input.paths.first ?? ".")
        return CacheLocation(root: root, workspace: workspace)
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
