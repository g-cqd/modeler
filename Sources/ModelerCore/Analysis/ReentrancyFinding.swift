/// A check of a member, an `await`, then a write of the same member with no new check in between, in a method
/// of an actor or global-actor type.
///
/// An actor method runs without interruption only between suspension points. When the `await` returns, other
/// calls may have run and changed the member, so the earlier check no longer says what the write assumes.
public struct ReentrancyFinding: Codable, Sendable, Hashable {
    public let type: String
    /// The file that declares the method.
    public let file: String
    /// The method, as `name(labels:)`.
    public let method: String
    public let property: String
    public let kind: InterleavingKind
    public let checkLine: Int
    public let suspendLine: Int
    public let writeLine: Int
    /// The awaited expression, shortened.
    public let awaited: String

    public init(
        type: String, file: String, method: String, property: String, kind: InterleavingKind = .await,
        checkLine: Int, suspendLine: Int, writeLine: Int,
        awaited: String
    ) {
        self.type = type
        self.file = file
        self.method = method
        self.property = property
        self.kind = kind
        self.checkLine = checkLine
        self.suspendLine = suspendLine
        self.writeLine = writeLine
        self.awaited = awaited
    }
}

/// Finds ``ReentrancyFinding``s.
///
/// Path-insensitive: effects are ordered by source position, so a check in one branch and a write in another
/// can pair. A write in a closure, and an `await` in one, are ignored, since a closure runs elsewhere.
public enum ReentrancyAnalysis {
    /// - Complexity: O(*e*) in the number of effects of isolated types.
    public static func findings(in facts: ModelFacts) -> [ReentrancyFinding] {
        var found: [ReentrancyFinding] = []
        for type in facts.types {
            let mutable = Set(type.properties.filter { $0.isMutable && !$0.isStatic }.map(\.name))
            if type.isIsolated {
                for method in type.methods where !method.isNonisolated && !method.isStatic {
                    found += scan(method, in: type, mutable: mutable)
                }
            } else if type.kind == .classType || type.kind == .structType,
                type.methods.contains(where: { $0.effects.contains { $0.kind == .acquire } })
            {
                for method in type.methods where method.name != "init" && !method.isStatic {
                    found += scanLockGaps(method, in: type, mutable: mutable)
                }
            }
        }
        return found
    }

    /// A check and a later write of one member that no single `withLock` scope covers, with no new check in
    /// between, in a type that takes locks: another thread can change the member in the gap.
    private static func scanLockGaps(_ method: MethodFacts, in type: TypeFacts, mutable: Set<String>)
        -> [ReentrancyFinding]
    {
        // A scope is the number of `acquire`s seen so far; outside every lock each effect is its own scope.
        var scope = 0
        var checks: [String: (line: Int, scope: Int)] = [:]
        var found: [ReentrancyFinding] = []
        for effect in method.effects {
            switch effect.kind {
            case .acquire where effect.locks.isEmpty:
                scope += 1
            case .read where effect.isCheck && mutable.contains(effect.subject):
                if effect.locks.isEmpty { scope += 1 }
                checks[effect.subject] = (effect.line, scope)
            case .write where mutable.contains(effect.subject):
                if effect.locks.isEmpty { scope += 1 }
                guard let check = checks.removeValue(forKey: effect.subject), check.scope != scope else { continue }
                found.append(
                    ReentrancyFinding(
                        type: type.name, file: method.file, method: method.signature, property: effect.subject,
                        kind: .lockGap, checkLine: check.line, suspendLine: check.line, writeLine: effect.line,
                        awaited: "the lock is not held across the check and the write"))
            default:
                break
            }
        }
        return found
    }

    private struct Stale {
        var checkLine: Int
        var suspendLine: Int
        var awaited: String
    }

    private static func scan(_ method: MethodFacts, in type: TypeFacts, mutable: Set<String>) -> [ReentrancyFinding] {
        var checked: [String: Int] = [:]
        var stale: [String: Stale] = [:]
        var found: [ReentrancyFinding] = []
        for effect in method.effects where effect.closureDepth == 0 {
            switch effect.kind {
            case .read where effect.isCheck && mutable.contains(effect.subject):
                stale.removeValue(forKey: effect.subject)
                checked[effect.subject] = effect.line
            case .suspend:
                for (property, line) in checked {
                    stale[property] = Stale(checkLine: line, suspendLine: effect.line, awaited: effect.subject)
                }
                checked.removeAll()
            case .write:
                guard let pending = stale.removeValue(forKey: effect.subject) else { continue }
                found.append(
                    ReentrancyFinding(
                        type: type.name, file: method.file, method: method.signature, property: effect.subject,
                        kind: .await, checkLine: pending.checkLine, suspendLine: pending.suspendLine,
                        writeLine: effect.line,
                        awaited: pending.awaited))
            default:
                break
            }
        }
        return found.sorted { ($0.writeLine, $0.property) < ($1.writeLine, $1.property) }
    }
}
