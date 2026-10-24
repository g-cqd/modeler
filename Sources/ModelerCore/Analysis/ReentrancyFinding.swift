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
    public let checkLine: Int
    public let suspendLine: Int
    public let writeLine: Int
    /// The awaited expression, shortened.
    public let awaited: String

    public init(
        type: String, file: String, method: String, property: String, checkLine: Int, suspendLine: Int, writeLine: Int,
        awaited: String
    ) {
        self.type = type
        self.file = file
        self.method = method
        self.property = property
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
        for type in facts.types where type.isIsolated {
            let mutable = Set(type.properties.filter { $0.isMutable && !$0.isStatic }.map(\.name))
            for method in type.methods where !method.isNonisolated && !method.isStatic {
                found += scan(method, in: type, mutable: mutable)
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
                        checkLine: pending.checkLine, suspendLine: pending.suspendLine, writeLine: effect.line,
                        awaited: pending.awaited))
            default:
                break
            }
        }
        return found.sorted { ($0.writeLine, $0.property) < ($1.writeLine, $1.property) }
    }
}
