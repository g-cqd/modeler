internal import AemiJSON
public import AnalyzerConfiguration
public import ProjectModel
public import SourceCorpus

#if canImport(FoundationEssentials)
    internal import FoundationEssentials
#else
    internal import Foundation
#endif

/// What `.modeler.json`, or the `"modeler"` section of `.swift-analyzers.json`, can say (analyzerkit ADR-0020).
///
/// ```json
/// { "disable": ["lock-gap"],
///   "severity": { "reentrancy": "error" },
///   "exclude": ["/Generated/"],
///   "includeRegions": "test" }
/// ```
public struct Configuration: Codable, Sendable, Equatable {
    public var disable: [RuleID]
    public var severity: [RuleID: Severity]
    /// Paths to leave out (ADR-0008): a substring, or a glob relative to ``root`` (`SourceCorpus.PathFilter`).
    public var exclude: [String]
    /// The directory `exclude` globs are relative to: the configuration file's. Not part of the file.
    public var root: String?
    /// Which regions besides production code are modelled and checked; by default none.
    public var regions: RegionSelection

    public init(
        disable: [RuleID] = [], severity: [RuleID: Severity] = [:], exclude: [String] = [],
        regions: RegionSelection = .none
    ) {
        self.disable = disable
        self.severity = severity
        self.exclude = exclude
        self.regions = regions
    }

    public static let `default` = Configuration()

    private enum CodingKeys: String, CodingKey { case disable, severity, exclude }
    private enum RegionKeys: String, CodingKey { case includeRegions, excludeRegions }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        disable = try values.decodeIfPresent([RuleID].self, forKey: .disable) ?? []
        let named = try values.decodeIfPresent([String: Severity].self, forKey: .severity) ?? [:]
        var parsed: [RuleID: Severity] = [:]
        for (name, level) in named {
            guard let rule = RuleID(rawValue: name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .severity, in: values, debugDescription: "no rule named \(name)")
            }
            parsed[rule] = level
        }
        severity = parsed
        exclude = try values.decodeIfPresent([String].self, forKey: .exclude) ?? []
        let regionValues = try decoder.container(keyedBy: RegionKeys.self)
        do {
            regions = try RegionSelection(
                include: try regionValues.decodeIfPresent(String.self, forKey: .includeRegions),
                exclude: try regionValues.decodeIfPresent(String.self, forKey: .excludeRegions))
        } catch let error as UnknownRegionName {
            throw DecodingError.dataCorruptedError(
                forKey: .includeRegions, in: regionValues, debugDescription: error.description)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(disable, forKey: .disable)
        try values.encode(
            Dictionary(uniqueKeysWithValues: severity.map { ($0.key.rawValue, $0.value) }), forKey: .severity)
        try values.encode(exclude, forKey: .exclude)
    }

    /// Why a configuration file was not used.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(path: String, reason: String)
        case invalid(path: String, reason: String)

        public var description: String {
            switch self {
            case .unreadable(let path, let reason): "cannot read configuration \(path): \(reason)"
            case .invalid(let path, let reason): "invalid configuration \(path): \(reason)"
            }
        }
    }

    /// `exclude` as one filter; build it once for many paths.
    public var pathFilter: PathFilter { PathFilter(exclude, root: root) }

    /// Whether a file of `region` is modelled: production code always, other regions when selected.
    public func models(_ region: CodeRegion) -> Bool { region.isEmpty || regions.isIncluded(region) }

    public func severity(of rule: RuleID) -> Severity { severity[rule] ?? rule.defaultSeverity }
    public func isEnabled(_ rule: RuleID) -> Bool { !disable.contains(rule) }

    /// What the shared configuration reader checks modeler's keys against (ADR-0020); the shared keys are its own.
    public static let sharedReading = SharedConfiguration.Tool(
        name: ModelerTool.name, fileName: ".modeler.json", keys: ["disable", "severity"])

    /// The configuration of a run: `explicit` (`--config`) or the configuration directory's `.swift-analyzers.json` and
    /// `.modeler.json`, merged, every key checked; the default when there is none.
    /// - Throws: a ``Failure``, so a typo never silently turns a rule off.
    public static func resolve(
        explicit: String?, currentDirectory: String, analyzedPaths: [String]
    ) throws(Failure) -> (configuration: Configuration, sources: SharedConfiguration.Resolved) {
        let resolved: SharedConfiguration.Resolved
        do {
            resolved = try SharedConfiguration.resolve(
                for: sharedReading, explicit: explicit, currentDirectory: currentDirectory, analyzedPaths: analyzedPaths
            )
        } catch .unreadable(let path, let reason) {
            throw .unreadable(path: path, reason: reason)
        } catch {
            throw .invalid(path: error.path, reason: error.reason)
        }
        guard let directory = resolved.directory, let last = resolved.sources.last else { return (.default, resolved) }
        do {
            var configuration = try AemiJSON.JSONDecoder().decode(Configuration.self, from: resolved.json)
            configuration.root = directory
            return (configuration, resolved)
        } catch {
            throw .invalid(path: last.path, reason: "\(error)")
        }
    }
}
