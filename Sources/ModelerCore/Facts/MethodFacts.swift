/// A function, initializer or accessor-free method of a type.
public struct MethodFacts: Codable, Sendable, Hashable {
    /// `name(label:label:)`, so overloads differ.
    public let signature: String
    public let name: String
    /// The file that declares the method, which for a method of an extension is not the type's file.
    public let file: String
    public let line: Int
    public let isAsync: Bool
    public let isThrowing: Bool
    public let isStatic: Bool
    public let isMutating: Bool
    public let isNonisolated: Bool
    public let attributes: [String]
    /// Source order, closures included (see ``Effect/closureDepth``).
    public let effects: [Effect]
    /// The body's control-flow graph as successor lists, node 0 the entry; ``Effect/nodes`` places each effect in it.
    /// Nil for facts made without it, and left out of `modeler facts`.
    public let flow: [[Int]]?

    public init(
        signature: String, name: String, file: String, line: Int, isAsync: Bool, isThrowing: Bool, isStatic: Bool,
        isMutating: Bool,
        isNonisolated: Bool, attributes: [String], effects: [Effect], flow: [[Int]]? = nil
    ) {
        self.signature = signature
        self.name = name
        self.file = file
        self.line = line
        self.isAsync = isAsync
        self.isThrowing = isThrowing
        self.isStatic = isStatic
        self.isMutating = isMutating
        self.isNonisolated = isNonisolated
        self.attributes = attributes
        self.effects = effects
        self.flow = flow
    }

    /// The method without its control-flow graph, as `modeler facts` prints it.
    public var withoutFlow: MethodFacts {
        MethodFacts(
            signature: signature, name: name, file: file, line: line, isAsync: isAsync, isThrowing: isThrowing,
            isStatic: isStatic, isMutating: isMutating, isNonisolated: isNonisolated, attributes: attributes,
            effects: effects.map(\.withoutFlow))
    }
}
