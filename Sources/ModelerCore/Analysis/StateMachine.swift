/// One enum-valued member, or an enum's own value, and every change of it the code makes.
public struct StateMachine: Codable, Sendable, Hashable {
    /// A write of a known case.
    public struct Transition: Codable, Sendable, Hashable {
        /// The cases the member held when the write ran, or nil when no condition says.
        public let from: [String]?
        public let to: String
        /// The method that writes, as `name(labels:)`.
        public let method: String
        public let line: Int
        /// The condition that fixed ``from`` was checked before an `await`, so the member may have changed since.
        public let isStale: Bool

        public init(from: [String]?, to: String, method: String, line: Int, isStale: Bool) {
            self.from = from
            self.to = to
            self.method = method
            self.line = line
            self.isStale = isStale
        }
    }

    /// The type that holds the member.
    public let owner: String
    /// The member's name, or `self` for an enum that assigns itself.
    public let property: String
    /// The enum, qualified.
    public let stateType: String
    public let cases: [String]
    /// The case of the member's initializer, when it is a `.case` literal.
    public let initial: String?
    public let transitions: [Transition]
    /// Writes whose new value is not a `.case` literal, so no edge can be drawn for them.
    public let opaqueWrites: Int

    public init(
        owner: String, property: String, stateType: String, cases: [String], initial: String?,
        transitions: [Transition], opaqueWrites: Int
    ) {
        self.owner = owner
        self.property = property
        self.stateType = stateType
        self.cases = cases
        self.initial = initial
        self.transitions = transitions
        self.opaqueWrites = opaqueWrites
    }
}

/// Finds the state machines of a corpus.
public enum StateMachines {
    /// Every mutable member whose type is an enum of the corpus, and every enum that assigns itself, that some
    /// method writes.
    /// - Complexity: O(*e*) in the number of effects, plus O(*m*) members looked up in the type index.
    public static func extract(from facts: ModelFacts) -> [StateMachine] {
        var machines: [StateMachine] = []
        for type in facts.types {
            for property in type.properties where property.isMutable && !property.isStatic {
                guard let typeName = property.baseTypeName, let stateType = facts.type(named: typeName),
                    stateType.kind == .enumType
                else { continue }
                if let machine = machine(
                    of: type, property: property.name, initial: property.initialCase, stateType: stateType)
                {
                    machines.append(machine)
                }
            }
            if type.kind == .enumType,
                let machine = machine(of: type, property: "self", initial: nil, stateType: type)
            {
                machines.append(machine)
            }
        }
        return machines
    }

    private static func machine(
        of owner: TypeFacts, property: String, initial: String?, stateType: TypeFacts
    ) -> StateMachine? {
        var transitions: [StateMachine.Transition] = []
        var seen: Set<StateMachine.Transition> = []
        var opaque = 0
        // An initializer chooses the first state; it is not a transition out of one.
        for method in owner.methods where method.name != "init" {
            for effect in method.effects where effect.kind == .write && effect.subject == property {
                guard let target = effect.value, stateType.cases.contains(where: { $0.name == target }) else {
                    opaque += 1
                    continue
                }
                let guardOnProperty = effect.when.first { $0.property == property }
                let transition = StateMachine.Transition(
                    from: guardOnProperty?.cases, to: target, method: method.signature, line: effect.line,
                    isStale: guardOnProperty.map { !$0.isFresh } ?? false)
                if seen.insert(transition).inserted { transitions.append(transition) }
            }
        }
        guard !transitions.isEmpty || opaque > 0 else { return nil }
        return StateMachine(
            owner: owner.name, property: property, stateType: stateType.name, cases: stateType.cases.map(\.name),
            initial: initial, transitions: transitions, opaqueWrites: opaque)
    }
}
