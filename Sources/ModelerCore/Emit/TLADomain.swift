/// The finite set a member ranges over in a TLA+ model.
struct TLADomain: Sendable {
    enum Shape: Sendable {
        case enumeration([String])
        case boolean
        case integer
        /// Anything else: a set of interchangeable model values.
        case opaque
    }

    let shape: Shape
    let isOptional: Bool

    private static let integerTypes: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    ]

    init(of property: PropertyFacts, in facts: ModelFacts) {
        isOptional = property.typeText?.hasSuffix("?") == true || property.initialLiteral == "nil"
        if let name = property.baseTypeName, let cases = facts.enumCases(named: name) {
            shape = .enumeration(cases)
        } else if property.baseTypeName == "Bool" || ["true", "false"].contains(property.initialLiteral ?? "") {
            shape = .boolean
        } else if property.baseTypeName.map(Self.integerTypes.contains) == true
            || Int(property.initialLiteral ?? "") != nil
        {
            shape = .integer
        } else {
            shape = .opaque
        }
    }

    var usesOpaque: Bool { if case .opaque = shape { true } else { false } }
    var usesIntegerBound: Bool { if case .integer = shape { true } else { false } }

    /// The TLA+ expression for the set.
    var expression: String {
        let base: String
        switch shape {
        case .enumeration(let cases): base = "{" + cases.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        case .boolean: base = "BOOLEAN"
        case .integer: base = "0..IntMax"
        case .opaque: base = "Opaque"
        }
        guard isOptional else { return base }
        return base.hasPrefix("{") ? String(base.dropLast()) + ", \"nil\"}" : base + " \\cup {\"nil\"}"
    }

    /// The TLA+ term for a literal assigned to a member of this domain, or nil when the literal is not in it.
    func term(for literal: String, integerBound: Int) -> String? {
        if literal == "nil" { return isOptional ? "\"nil\"" : nil }
        switch shape {
        case .enumeration(let cases): return cases.contains(literal) ? "\"\(literal)\"" : nil
        case .boolean: return literal == "true" ? "TRUE" : literal == "false" ? "FALSE" : nil
        case .integer: return Int(literal).flatMap { (0...integerBound).contains($0) ? String($0) : nil }
        case .opaque: return nil
        }
    }
}
