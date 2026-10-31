/// One declaration of a type, or one extension of it. ``ModelFacts`` merges them by name.
public struct TypeFacts: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case structType = "struct"
        case classType = "class"
        case actorType = "actor"
        case enumType = "enum"
        case protocolType = "protocol"
        case extensionType = "extension"
    }

    /// Qualified by the enclosing types: `Outer.Inner`.
    public let name: String
    public let kind: Kind
    public let inherited: [String]
    /// Attribute names without `@`, such as `MainActor`.
    public let attributes: [String]
    public let file: String
    public let line: Int
    public let properties: [PropertyFacts]
    public let cases: [EnumCaseFacts]
    public let methods: [MethodFacts]
    /// An enum's Boolean computed properties that test its own cases, with the cases each one holds for: `isRecording`
    /// when its getter is `if case .recording = self { return true }; return false`. Absent when there are none.
    public let predicates: [String: [String]]?

    public init(
        name: String, kind: Kind, inherited: [String], attributes: [String], file: String, line: Int,
        properties: [PropertyFacts], cases: [EnumCaseFacts], methods: [MethodFacts],
        predicates: [String: [String]]? = nil
    ) {
        self.name = name
        self.kind = kind
        self.inherited = inherited
        self.attributes = attributes
        self.file = file
        self.line = line
        self.properties = properties
        self.cases = cases
        self.methods = methods
        self.predicates = predicates
    }

    /// The type without its methods' control-flow graphs, as `modeler facts` prints it.
    public var withoutFlow: TypeFacts {
        TypeFacts(
            name: name, kind: kind, inherited: inherited, attributes: attributes, file: file, line: line,
            properties: properties, cases: cases, methods: methods.map(\.withoutFlow), predicates: predicates)
    }

    /// The last component of ``name``.
    public var simpleName: String { name.split(separator: ".").last.map(String.init) ?? name }

    /// Whether another task can run between two statements of one method: an actor, or a type isolated to a
    /// global actor.
    public var isIsolated: Bool {
        kind == .actorType || attributes.contains { $0.hasSuffix("Actor") }
    }
}

/// The facts of one source file; what the cache stores.
public struct FileFacts: Codable, Sendable, Hashable {
    public let path: String
    public let types: [TypeFacts]
    /// Why the file was not modelled, when its syntax tree nests too deeply to walk (analyzerkit roadmap 0041). Absent
    /// from the encoded facts of every modelled file.
    public let degraded: String?
    /// The file's region (`CodeRegion.rawValue`) as its project and content say (analyzerkit ADR-0024); 0 is
    /// production code.
    public var region: UInt8

    public init(path: String, types: [TypeFacts], degraded: String? = nil, region: UInt8 = 0) {
        self.path = path
        self.types = types
        self.degraded = degraded
        self.region = region
    }
}
