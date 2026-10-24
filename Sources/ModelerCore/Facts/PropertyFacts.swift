/// A stored property.
public struct PropertyFacts: Codable, Sendable, Hashable {
    public let name: String
    /// The declared type as written, or nil when inferred.
    public let typeText: String?
    /// `var`, as opposed to `let`.
    public let isMutable: Bool
    public let isStatic: Bool
    public let line: Int
    /// The enum case of an initializer that is a `.case` literal.
    public let initialCase: String?
    /// The initializer's text when it is a short literal (`0`, `false`, `""`).
    public let initialLiteral: String?

    public init(
        name: String, typeText: String?, isMutable: Bool, isStatic: Bool, line: Int, initialCase: String?,
        initialLiteral: String?
    ) {
        self.name = name
        self.typeText = typeText
        self.isMutable = isMutable
        self.isStatic = isStatic
        self.line = line
        self.initialCase = initialCase
        self.initialLiteral = initialLiteral
    }

    /// ``typeText`` without optionality markers, `Foo?` and `Foo!` becoming `Foo`.
    public var baseTypeName: String? {
        guard var text = typeText else { return nil }
        while let last = text.last, last == "?" || last == "!" { text.removeLast() }
        return text
    }
}

/// One case of an enum.
public struct EnumCaseFacts: Codable, Sendable, Hashable {
    public let name: String
    /// The associated values' types as written; empty for a bare case.
    public let payload: [String]

    public init(name: String, payload: [String]) {
        self.name = name
        self.payload = payload
    }
}
