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
        var lookup: [String: Int] = [:]
        for (offset, type) in merged.enumerated() {
            lookup[type.name] = offset
            // A simple name resolves only while it is unambiguous.
            if lookup[type.simpleName] == nil { lookup[type.simpleName] = offset }
        }
        index = lookup
        types = merged.map { Self.resolvePredicates(in: $0, types: merged, index: lookup) }
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

    /// Replaces each guard's predicate markers (``Conditions/marker``) with the cases of the member's enum they hold
    /// for, and drops a guard any of whose markers does not resolve: then it narrows nothing, as before.
    private static func resolvePredicates(in type: TypeFacts, types: [TypeFacts], index: [String: Int]) -> TypeFacts {
        let marked = type.methods.contains { method in
            method.effects.contains { effect in effect.when.contains { $0.cases.contains(where: Conditions.isMarker) } }
        }
        guard marked else { return type }
        var enums: [String: TypeFacts] = [:]
        for property in type.properties {
            guard let name = property.baseTypeName,
                let offset = index[name] ?? index[String(name.split(separator: ".").last ?? "")],
                types[offset].kind == .enumType
            else { continue }
            enums[property.name] = types[offset]
        }
        let resolve: (StateGuard) -> StateGuard? = { stateGuard in
            guard stateGuard.cases.contains(where: Conditions.isMarker) else { return stateGuard }
            guard let target = enums[stateGuard.property] else { return nil }
            let all = Set(target.cases.map(\.name))
            var cases: Set<String> = []
            for value in stateGuard.cases {
                if value.hasPrefix(Conditions.negated) {
                    guard let holds = target.predicates?[String(value.dropFirst(Conditions.negated.count))] else {
                        return nil
                    }
                    cases.formUnion(all.subtracting(holds))
                } else if value.hasPrefix(Conditions.marker) {
                    guard let holds = target.predicates?[String(value.dropFirst(Conditions.marker.count))] else {
                        return nil
                    }
                    cases.formUnion(holds)
                } else {
                    cases.insert(value)
                }
            }
            return StateGuard(property: stateGuard.property, cases: cases.sorted(), isFresh: stateGuard.isFresh)
        }
        let methods = type.methods.map { method in
            MethodFacts(
                signature: method.signature, name: method.name, file: method.file, line: method.line,
                isAsync: method.isAsync, isThrowing: method.isThrowing, isStatic: method.isStatic,
                isMutating: method.isMutating, isNonisolated: method.isNonisolated, attributes: method.attributes,
                effects: method.effects.map { effect in
                    let guards = effect.when.compactMap(resolve)
                    guard guards != effect.when else { return effect }
                    return Effect(
                        kind: effect.kind, line: effect.line, subject: effect.subject, value: effect.value,
                        isCheck: effect.isCheck, closureDepth: effect.closureDepth, when: guards, locks: effect.locks,
                        nodes: effect.nodes)
                }, flow: method.flow)
        }
        return TypeFacts(
            name: type.name, kind: type.kind, inherited: type.inherited, attributes: type.attributes, file: type.file,
            line: type.line, properties: type.properties, cases: type.cases, methods: methods,
            predicates: type.predicates)
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
            properties: declarations.flatMap(\.properties), cases: declarations.flatMap(\.cases), methods: methods,
            predicates: Self.predicates(of: declarations))
    }

    private static func resolve(_ effect: Effect, members: Set<String>, functions: Set<String>, isEnum: Bool) -> Effect?
    {
        func known(_ name: String) -> Bool {
            if members.contains(name) || (isEnum && name == "self") { return true }
            if let dot = name.firstIndex(of: "."), members.contains(String(name[..<dot])) { return true }
            return false
        }
        switch effect.kind {
        case .read:
            guard known(effect.subject) || effect.subject == BodyEffectCollector.cancellation else { return nil }
        case .write, .cancel, .bindIndex, .useIndex, .resume:
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

    private static func predicates(of declarations: [TypeFacts]) -> [String: [String]]? {
        let all = declarations.compactMap(\.predicates).reduce(into: [String: [String]]()) {
            $0.merge($1) { first, _ in first }
        }
        return all.isEmpty ? nil : all
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
