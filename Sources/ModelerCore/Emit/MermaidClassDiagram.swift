/// A Mermaid `classDiagram` of a corpus: each type with its stored properties, cases and methods, and the
/// conformance, inheritance and ownership edges between them.
public enum MermaidClassDiagram {
    /// - Parameters:
    ///   - facts: the corpus.
    ///   - focus: qualified or simple type names to centre the diagram on; empty draws every type.
    ///   - depth: how many edges away from `focus` to include.
    ///   - maximumMembers: members listed per type before `…` stands for the rest.
    /// - Complexity: O(*n* + *e*) in members and edges.
    public static func render(_ facts: ModelFacts, focus: [String] = [], depth: Int = 1, maximumMembers: Int = 12)
        -> String
    {
        let relations = TypeRelations(facts)
        let roots = Set(focus.compactMap { facts.type(named: $0)?.name })
        let included = focus.isEmpty ? nil : relations.neighborhood(of: roots, depth: depth)
        let types = facts.types.filter { $0.kind != .extensionType && (included?.contains($0.name) ?? true) }
        var lines = ["classDiagram"]
        for type in types {
            lines.append("    class \(identifier(type.name))[\"\(type.name)\"] {")
            if let stereotype = stereotype(of: type) { lines.append("        <<\(stereotype)>>") }
            var members = memberLines(of: type)
            if members.count > maximumMembers {
                members = Array(members.prefix(maximumMembers)) + ["…"]
            }
            lines += members.map { "        \($0)" }
            lines.append("    }")
        }
        let names = Set(types.map(\.name))
        for edge in relations.edges where names.contains(edge.from) && names.contains(edge.to) {
            lines.append("    " + arrow(edge))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func stereotype(of type: TypeFacts) -> String? {
        let base: String? =
            switch type.kind {
            case .actorType: "actor"
            case .enumType: "enumeration"
            case .protocolType: "interface"
            case .structType: "struct"
            case .classType, .extensionType: nil
            }
        let isolation = type.attributes.filter { $0.hasSuffix("Actor") }.map { "@" + $0 }
        let parts = ([base].compactMap { $0 } + isolation).joined(separator: " ")
        return parts.isEmpty ? nil : parts
    }

    private static func memberLines(of type: TypeFacts) -> [String] {
        if type.kind == .enumType { return type.cases.map(\.name) }
        let properties = type.properties.map { property in
            "\(property.isMutable ? "+" : "-")\(property.name)\(property.typeText.map { ": " + sanitize($0) } ?? "")"
        }
        let methods = type.methods.map { method in
            "+\(method.signature)\(method.isAsync ? " async" : "")\(method.isThrowing ? " throws" : "")"
        }
        return properties + methods
    }

    private static func arrow(_ edge: TypeRelations.Edge) -> String {
        let from = identifier(edge.from)
        let to = identifier(edge.to)
        switch edge.kind {
        case .inherits: return "\(to) <|-- \(from)"
        case .conforms: return "\(to) <|.. \(from)"
        case .holds(let property): return "\(from) --> \(to) : \(property)"
        }
    }

    /// A Mermaid class id: letters, digits and `_`.
    static func identifier(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// Mermaid reads `<`, `>` and `~` in a member as generics or markup.
    private static func sanitize(_ text: String) -> String {
        String(text.map { "<>~{}".contains($0) ? "_" : $0 })
    }
}
