/// The part of a method between two suspension points, which an actor runs without interruption.
struct TLASegment {
    /// What a segment does to one member.
    struct Write {
        var literals: [String] = []
        var hasUnknown = false
    }

    let effects: [Effect]
    /// Members whose value the code checked in this segment, with the cases that let it proceed. Absent when
    /// the segment can proceed whatever the member holds.
    let precondition: [String: [String]]
    let writes: [String: Write]

    /// Splits `method`'s effects after each `await` of its own body. Effects in closures stay in the segment
    /// that contains the closure.
    ///
    /// With `perLock`, which is for a type that takes locks, a segment is a whole `withLock` scope or a single
    /// read or write outside every scope, so code outside a lock interleaves with other callers at each access.
    /// - Complexity: O(*e*) in the effects.
    static func split(_ method: MethodFacts, perLock: Bool = false) -> [TLASegment] {
        if perLock { return splitPerLock(method) }
        var groups: [[Effect]] = [[]]
        for effect in method.effects {
            if effect.kind == .suspend, effect.closureDepth == 0 {
                groups[groups.count - 1].append(effect)
                groups.append([])
            } else {
                groups[groups.count - 1].append(effect)
            }
        }
        return groups.map(TLASegment.init)
    }

    private static func splitPerLock(_ method: MethodFacts) -> [TLASegment] {
        var groups: [[Effect]] = []
        var current: [Effect] = []
        var inScope = false
        func flush() {
            if !current.isEmpty { groups.append(current) }
            current = []
        }
        for effect in method.effects {
            if effect.kind == .acquire, effect.locks.isEmpty {
                flush()
                inScope = true
                current = [effect]
            } else if inScope {
                current.append(effect)
                if effect.kind == .release, effect.locks.isEmpty {
                    inScope = false
                    flush()
                }
            } else if effect.kind == .read || effect.kind == .write || effect.kind == .suspend {
                flush()
                groups.append([effect])
            } else {
                current.append(effect)
            }
        }
        flush()
        return (groups.isEmpty ? [[]] : groups).map(TLASegment.init)
    }

    private init(_ effects: [Effect]) {
        self.effects = effects
        var writes: [String: Write] = [:]
        for effect in effects where effect.kind == .write {
            if let value = effect.value {
                writes[effect.subject, default: Write()].literals.append(value)
            } else {
                writes[effect.subject, default: Write()].hasUnknown = true
            }
        }
        self.writes = writes
        // The guard a segment acts under is the one every effect that changes state or ends the segment shares,
        // up to the segment's own first write of that member: after it, the narrowing describes the write, not
        // the state the segment was entered in.
        let deciding = effects.filter { $0.kind == .write || ($0.kind == .suspend && $0.closureDepth == 0) }
        var precondition: [String: [String]] = [:]
        if let first = deciding.first {
            for candidate in first.when where candidate.isFresh {
                let property = candidate.property
                // The check must be made in this segment: a guard from an earlier one says nothing about now.
                guard effects.contains(where: { $0.kind == .read && $0.isCheck && $0.subject == property }) else {
                    continue
                }
                let cut = deciding.firstIndex { $0.kind == .write && $0.subject == property } ?? deciding.count - 1
                let entering = deciding[...cut].map { $0.when.first { $0.property == property && $0.isFresh } }
                guard entering.allSatisfy({ $0 != nil }) else { continue }
                precondition[property] = Array(Set(entering.compactMap { $0?.cases }.joined())).sorted()
            }
        }
        self.precondition = precondition
    }
}
