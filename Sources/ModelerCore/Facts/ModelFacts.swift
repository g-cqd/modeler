/// The facts of a whole corpus, with each type's declarations and extensions merged by name.
///
/// A body is extracted without knowing the properties of its type, since they may be declared in another
/// file, so each body records every bare lowercase identifier it reads or writes. Merging keeps only the
/// effects that name a member of the merged type.
public struct ModelFacts: Sendable {
    /// Sorted by qualified name.
    public let types: [TypeFacts]
    private let index: [String: Int]

    /// - Complexity: O(*n*) in the total number of members and effects, plus sorting the type names.
    public init(files: [FileFacts]) {
        var grouped: [String: [TypeFacts]] = [:]
        for file in files {
            for declaration in file.types { grouped[declaration.name, default: []].append(declaration) }
        }
        let merged = grouped.keys.sorted().map { Self.merge(grouped[$0] ?? []) }
        types = merged
        var lookup: [String: Int] = [:]
        for (offset, type) in merged.enumerated() {
            lookup[type.name] = offset
            // A simple name resolves only while it is unambiguous.
            if lookup[type.simpleName] == nil { lookup[type.simpleName] = offset }
        }
        index = lookup
    }

    /// The type named `name`, qualified or simple. A simple name shared by several types resolves to the first
    /// in qualified order.
    public func type(named name: String) -> TypeFacts? {
        index[name].map { types[$0] }
    }

    /// The case names of the enum named `name`, or nil when it is not an enum of this corpus.
    public func enumCases(named name: String) -> [String]? {
        guard let type = type(named: name), type.kind == .enumType else { return nil }
        return type.cases.map(\.name)
    }

    private static func merge(_ declarations: [TypeFacts]) -> TypeFacts {
        let primary = declarations.first { $0.kind != .extensionType } ?? declarations[0]
        let members = Set(declarations.flatMap { $0.properties.map(\.name) })
        let functions = Set(declarations.flatMap { $0.methods.map(\.name) })
        let methods = declarations.flatMap(\.methods).map { method in
            MethodFacts(
                signature: method.signature, name: method.name, file: method.file, line: method.line,
                isAsync: method.isAsync,
                isThrowing: method.isThrowing, isStatic: method.isStatic, isMutating: method.isMutating,
                isNonisolated: method.isNonisolated, attributes: method.attributes,
                effects: method.effects.compactMap {
                    resolve($0, members: members, functions: functions, isEnum: primary.kind == .enumType)
                }, flow: method.flow)
        }
        return TypeFacts(
            name: primary.name, kind: primary.kind,
            inherited: unique(declarations.flatMap(\.inherited)),
            attributes: unique(declarations.flatMap(\.attributes)),
            file: primary.file, line: primary.line,
            properties: declarations.flatMap(\.properties), cases: declarations.flatMap(\.cases), methods: methods)
    }

    private static func resolve(_ effect: Effect, members: Set<String>, functions: Set<String>, isEnum: Bool) -> Effect?
    {
        func known(_ name: String) -> Bool {
            if members.contains(name) || (isEnum && name == "self") { return true }
            if let dot = name.firstIndex(of: "."), members.contains(String(name[..<dot])) { return true }
            return false
        }
        switch effect.kind {
        case .read, .write:
            guard known(effect.subject) else { return nil }
        case .call:
            guard functions.contains(effect.subject) else { return nil }
        case .suspend, .spawn, .acquire, .release:
            break
        }
        let guards = effect.when.filter { known($0.property) }
        guard guards.count != effect.when.count else { return effect }
        return Effect(
            kind: effect.kind, line: effect.line, subject: effect.subject, value: effect.value,
            isCheck: effect.isCheck, closureDepth: effect.closureDepth, when: guards, locks: effect.locks,
            nodes: effect.nodes)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
