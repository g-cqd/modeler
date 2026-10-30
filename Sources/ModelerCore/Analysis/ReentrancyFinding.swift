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
    /// For ``InterleavingKind/claimedAwait``: the line of the write that claimed the member before the `await`.
    public let claimLine: Int?
    /// For ``InterleavingKind/claimedAwait``: the other methods of the type that write the member.
    public let writers: [String]?

    public init(
        type: String, file: String, method: String, property: String, kind: InterleavingKind = .await,
        checkLine: Int, suspendLine: Int, writeLine: Int,
        awaited: String, claimLine: Int? = nil, writers: [String]? = nil
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
        self.claimLine = claimLine
        self.writers = writers
    }
}

/// Finds ``ReentrancyFinding``s.
///
/// Each method is a dataflow over its control-flow graph (roadmap 0026): a check and a write pair only when one path
/// joins them, a loop carries a check and an `await` into its next iteration, and a write after the check and before
/// the `await` is a claim. Facts without a graph fall back to source order. A write in a closure, and an `await` in
/// one, are ignored, since a closure runs elsewhere.
public enum ReentrancyAnalysis {
    /// - Complexity: O(*e* · *h*) per method, for *e* graph edges and a state of height *h*.
    public static func findings(in facts: ModelFacts) -> [ReentrancyFinding] {
        var found: [ReentrancyFinding] = []
        for type in facts.types {
            let mutable = Set(type.properties.filter { $0.isMutable && !$0.isStatic }.map(\.name))
            if type.isIsolated {
                for method in type.methods where !method.isNonisolated && !method.isStatic {
                    found += awaits(method, in: type, mutable: mutable)
                }
            } else if type.kind == .classType || type.kind == .structType,
                type.methods.contains(where: { $0.effects.contains { $0.kind == .acquire } })
            {
                for method in type.methods where method.name != "init" && !method.isStatic {
                    found += lockGaps(method, in: type, mutable: mutable)
                }
            }
        }
        return found
    }

    // MARK: - Awaits

    private struct Stale: Equatable {
        var checkLine: Int
        var suspendLine: Int
        var awaited: String
        var claimLine: Int?

        /// The one a join keeps: an unclaimed path first, since a claim only shields the paths that made it.
        static func preferred(_ left: Stale, _ right: Stale) -> Stale {
            let key: (Stale) -> (Int, Int, Int, String) = {
                ($0.claimLine == nil ? 0 : 1, $0.checkLine, $0.suspendLine, $0.awaited)
            }
            return key(left) <= key(right) ? left : right
        }
    }

    private struct AwaitState: Equatable {
        /// Members checked since the last `await`, with the line of the check.
        var checked: [String: Int] = [:]
        /// Checked members written since their check and before any `await`, on every path, with the write's line.
        var claimed: [String: Int] = [:]
        /// Members checked before an `await` and neither checked nor written since.
        var stale: [String: Stale] = [:]

        static func join(_ left: AwaitState, _ right: AwaitState) -> AwaitState {
            var joined = AwaitState()
            joined.checked = left.checked.merging(right.checked, uniquingKeysWith: min)
            joined.claimed = left.claimed.filter { right.claimed[$0.key] != nil }
                .merging(right.claimed.filter { left.claimed[$0.key] != nil }, uniquingKeysWith: min)
            joined.stale = left.stale.merging(right.stale, uniquingKeysWith: Stale.preferred)
            return joined
        }
    }

    private static func awaits(_ method: MethodFacts, in type: TypeFacts, mutable: Set<String>) -> [ReentrancyFinding] {
        // A claim is a hazard only when another method can write the member while this one is suspended.
        let writers: (String) -> [String] = { property in
            type.methods.filter { other in
                other.signature != method.signature && other.name != "init" && other.name != "deinit"
                    && other.effects.contains { $0.kind == .write && $0.subject == property }
            }.map(\.signature).sorted()
        }
        var found: [ReentrancyFinding] = []
        var seen: Set<String> = []
        let report: (Effect, Stale) -> Void = { write, stale in
            guard seen.insert("\(write.subject)|\(write.line)").inserted else { return }
            var kind = InterleavingKind.await
            var others: [String]?
            if stale.claimLine != nil {
                let names = writers(write.subject)
                guard !names.isEmpty else { return }
                kind = .claimedAwait
                others = names
            }
            found.append(
                ReentrancyFinding(
                    type: type.name, file: method.file, method: method.signature, property: write.subject,
                    kind: kind, checkLine: stale.checkLine, suspendLine: stale.suspendLine, writeLine: write.line,
                    awaited: stale.awaited, claimLine: kind == .claimedAwait ? stale.claimLine : nil,
                    writers: others))
        }
        let step: (Effect, inout AwaitState, Bool) -> Void = { effect, state, reporting in
            guard effect.closureDepth == 0 else { return }
            switch effect.kind {
            case .read where effect.isCheck && mutable.contains(effect.subject):
                state.stale.removeValue(forKey: effect.subject)
                state.claimed.removeValue(forKey: effect.subject)
                state.checked[effect.subject] = effect.line
            case .suspend:
                for (property, line) in state.checked {
                    state.stale[property] = Stale(
                        checkLine: line, suspendLine: effect.line, awaited: effect.subject,
                        claimLine: state.claimed[property])
                }
                state.checked.removeAll()
                state.claimed.removeAll()
            case .write:
                if let stale = state.stale.removeValue(forKey: effect.subject) {
                    if reporting { report(effect, stale) }
                } else if state.checked[effect.subject] != nil, state.claimed[effect.subject] == nil {
                    state.claimed[effect.subject] = effect.line
                }
            default:
                break
            }
        }
        guard let flow = method.flow else {
            var state = AwaitState()
            for effect in method.effects { step(effect, &state, true) }
            return found.sorted { ($0.writeLine, $0.property) < ($1.writeLine, $1.property) }
        }
        let byNode = effectsByNode(method, count: flow.count)
        let entries = FlowSolver.solve(flow, initial: AwaitState(), join: AwaitState.join) { node, state in
            var next = state
            for effect in byNode[node] { step(effect, &next, false) }
            return next
        }
        for (node, entry) in entries.enumerated() {
            guard var state = entry else { continue }
            for effect in byNode[node] { step(effect, &state, true) }
        }
        return found.sorted { ($0.writeLine, $0.property) < ($1.writeLine, $1.property) }
    }

    // MARK: - Lock gaps

    private struct Check: Hashable {
        let line: Int
        /// The outermost `withLock` scope of the check (its `acquire`'s index), or the check's own index outside one.
        let scope: Int
    }

    /// A check and a later write of one member that no single `withLock` scope covers, with no new check in between,
    /// in a type that takes locks: another thread can change the member in the gap.
    private static func lockGaps(_ method: MethodFacts, in type: TypeFacts, mutable: Set<String>)
        -> [ReentrancyFinding]
    {
        // Outside every lock each effect is its own scope; inside, the scope is the outermost `acquire`.
        var scopes: [Int] = []
        var current = -1
        for (index, effect) in method.effects.enumerated() {
            if effect.kind == .acquire, effect.locks.isEmpty { current = index }
            scopes.append(effect.locks.isEmpty ? index : current)
        }
        var found: [ReentrancyFinding] = []
        var seen: Set<String> = []
        let step: (Int, inout [String: Set<Check>], Bool) -> Void = { index, checks, reporting in
            let effect = method.effects[index]
            guard mutable.contains(effect.subject) else { return }
            switch effect.kind {
            case .read where effect.isCheck:
                checks[effect.subject] = [Check(line: effect.line, scope: scopes[index])]
            case .write:
                guard let pending = checks.removeValue(forKey: effect.subject),
                    let check = pending.filter({ $0.scope != scopes[index] }).min(by: { $0.line < $1.line }),
                    reporting, seen.insert("\(effect.subject)|\(effect.line)").inserted
                else { return }
                found.append(
                    ReentrancyFinding(
                        type: type.name, file: method.file, method: method.signature, property: effect.subject,
                        kind: .lockGap, checkLine: check.line, suspendLine: check.line, writeLine: effect.line,
                        awaited: "the lock is not held across the check and the write"))
            default:
                break
            }
        }
        guard let flow = method.flow else {
            var checks: [String: Set<Check>] = [:]
            for index in method.effects.indices { step(index, &checks, true) }
            return found
        }
        var byNode = [[Int]](repeating: [], count: flow.count)
        for (index, effect) in method.effects.enumerated() {
            for node in effect.nodes ?? [] where node < flow.count { byNode[node].append(index) }
        }
        let join: ([String: Set<Check>], [String: Set<Check>]) -> [String: Set<Check>] = {
            $0.merging($1) { $0.union($1) }
        }
        let entries = FlowSolver.solve(flow, initial: [:], join: join) { node, state in
            var next = state
            for index in byNode[node] { step(index, &next, false) }
            return next
        }
        for (node, entry) in entries.enumerated() {
            guard var checks = entry else { continue }
            for index in byNode[node] { step(index, &checks, true) }
        }
        return found.sorted { ($0.writeLine, $0.property) < ($1.writeLine, $1.property) }
    }

    /// Each node's effects, in source order.
    private static func effectsByNode(_ method: MethodFacts, count: Int) -> [[Effect]] {
        var byNode = [[Effect]](repeating: [], count: count)
        for effect in method.effects {
            for node in effect.nodes ?? [] where node < count { byNode[node].append(effect) }
        }
        return byNode
    }
}

/// A forward dataflow over successor lists, as ``ControlFlowGraph/solve`` runs it on a live graph: the state at each
/// node's entry, nil where control does not reach, with a bound of 64 visits per node.
enum FlowSolver {
    static func solve<State: Equatable>(
        _ successors: [[Int]], initial: State, join: (State, State) -> State, transfer: (Int, State) -> State
    ) -> [State?] {
        guard !successors.isEmpty else { return [] }
        var entries = [State?](repeating: nil, count: successors.count)
        var visits = [Int](repeating: 0, count: successors.count)
        entries[0] = initial
        var work = [0]
        var queued: Set<Int> = [0]
        while let current = work.popLast() {
            queued.remove(current)
            guard let state = entries[current], visits[current] < 64 else { continue }
            visits[current] += 1
            let out = transfer(current, state)
            for target in successors[current] where target < successors.count {
                let merged = entries[target].map { join($0, out) } ?? out
                if merged != entries[target] {
                    entries[target] = merged
                    if queued.insert(target).inserted { work.append(target) }
                }
            }
        }
        return entries
    }
}
