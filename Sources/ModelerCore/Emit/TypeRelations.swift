/// How the types of a corpus refer to each other: conformance and inheritance, and ownership through a
/// stored property's type.
struct TypeRelations {
    enum Kind: Hashable {
        case inherits
        case conforms
        case holds(property: String)
    }

    struct Edge: Hashable {
        let from: String
        let to: String
        let kind: Kind
    }

    let edges: [Edge]

    /// - Complexity: O(*p* · *t*) in stored properties times the identifier tokens of their types.
    init(_ facts: ModelFacts) {
        var edges: [Edge] = []
        var seen: Set<Edge> = []
        func add(_ edge: Edge) {
            if edge.from != edge.to, seen.insert(edge).inserted { edges.append(edge) }
        }
        for type in facts.types where type.kind != .extensionType {
            for (position, name) in type.inherited.enumerated() {
                guard let target = facts.type(named: name) else { continue }
                let isSuperclass = position == 0 && type.kind == .classType && target.kind == .classType
                add(Edge(from: type.name, to: target.name, kind: isSuperclass ? .inherits : .conforms))
            }
            for property in type.properties {
                for token in Self.identifiers(in: property.typeText ?? "") {
                    if let target = facts.type(named: token) {
                        add(Edge(from: type.name, to: target.name, kind: .holds(property: property.name)))
                    }
                }
            }
        }
        self.edges = edges
    }

    /// The types within `depth` edges of `roots`, in either direction, roots included.
    /// - Complexity: O(`depth` · *edges*).
    func neighborhood(of roots: Set<String>, depth: Int) -> Set<String> {
        var reached = roots
        var frontier = roots
        for _ in 0..<max(depth, 0) {
            var next: Set<String> = []
            for edge in edges {
                if frontier.contains(edge.from), reached.insert(edge.to).inserted { next.insert(edge.to) }
                if frontier.contains(edge.to), reached.insert(edge.from).inserted { next.insert(edge.from) }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return reached
    }

    private static func identifiers(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }.map(String.init)
    }
}
