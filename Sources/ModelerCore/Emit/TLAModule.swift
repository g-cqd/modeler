/// A TLA+ module and TLC configuration for one type, generated from its extracted facts.
public struct TLAModel: Sendable {
    /// The module name; the module file is `<name>.tla` and the configuration `<name>.cfg`.
    public let name: String
    public let module: String
    public let config: String
}

/// Builds a TLA+ model of a type's state and methods.
///
/// The model over-approximates what the code can do. Each member the methods touch becomes a variable over a
/// finite set. Each method becomes one action per segment between `await`s, run by some caller out of
/// `Procs`, so segments of different calls interleave exactly where an actor lets them. A segment's checks
/// become its precondition; the cases assigned become its effect; a write of a computed value may produce any
/// member of the set. Control flow, other types and the arguments are not modelled. A check before an `await`
/// does not constrain the segment after it, which is how a stale check shows up in the checker.
///
/// For each ``ReentrancyFinding`` the model adds a monitor, `NoStaleWrite_n`, that is violated when the
/// member changes between the check and the write.
public enum TLAModule {
    /// Sizes of the model's finite sets, written into the configuration.
    public struct Bounds: Sendable {
        public var callers = 2
        public var integerMaximum = 2
        public var opaqueValues = 2

        public init() {}
    }

    private struct Variable {
        let name: String
        let domain: TLADomain
        let initial: String
    }

    /// Everything one segment's action needs.
    private struct Action {
        let name: String
        let comment: String
        let method: String
        let from: String
        let to: String
        let segment: TLASegment
        let isFirst: Bool
    }

    /// - Parameters:
    ///   - typeName: the type to model, qualified or simple.
    ///   - facts: the corpus the type belongs to.
    ///   - bounds: sizes of the finite sets.
    /// - Returns: nil when the type is unknown or has no state that its methods touch.
    /// - Complexity: O(*e*) in the effects of the type's methods.
    public static func render(type typeName: String, in facts: ModelFacts, bounds: Bounds = Bounds()) -> TLAModel? {
        guard let type = facts.type(named: typeName) else { return nil }
        let methods = type.methods.filter { $0.name != "init" && !$0.isStatic }
        let touched = Set(methods.flatMap(\.effects).filter { $0.kind == .read || $0.kind == .write }.map(\.subject))
        let variables = type.properties.filter { $0.isMutable && !$0.isStatic && touched.contains($0.name) }.map {
            variable(for: $0, in: facts, bounds: bounds)
        }
        guard !variables.isEmpty else { return nil }
        let byName = Dictionary(uniqueKeysWithValues: variables.map { ($0.name, $0) })
        let findings = ReentrancyAnalysis.findings(in: facts).filter { $0.type == type.name }

        var actions: [Action] = []
        var labels: [String] = []
        var methodIDs: [String: [Action]] = [:]
        for method in methods {
            let segments = TLASegment.split(method)
            let modelled =
                segments.contains { !$0.writes.keys.filter(byName.keys.contains).isEmpty } || segments.count > 1
            guard modelled else { continue }
            let base = identifier(method.name, taken: Set(methodIDs.keys))
            var built: [Action] = []
            for (index, segment) in segments.enumerated() {
                let last = index == segments.count - 1
                let target = last ? "idle" : "\(base)_\(index + 1)"
                if !last { labels.append(target) }
                built.append(
                    Action(
                        name: "\(base)_\(index)",
                        comment:
                            "\(method.signature), segment \(index + 1) of \(segments.count), \(type.file):\(method.line)",
                        method: method.signature,
                        from: index == 0 ? "idle" : "\(base)_\(index)", to: target, segment: segment,
                        isFirst: index == 0))
            }
            methodIDs[base] = built
            actions += built
        }
        return TLAModel(
            name: identifier(type.name, taken: []) + "Model",
            module: moduleText(
                type: type, variables: variables, byName: byName, actions: actions, labels: labels,
                findings: findings, bounds: bounds),
            config: configText(variables: variables, findings: findings, bounds: bounds))
    }

    // MARK: - Text

    private static func moduleText(
        type: TypeFacts, variables: [Variable], byName: [String: Variable], actions: [Action], labels: [String],
        findings: [ReentrancyFinding], bounds: Bounds
    ) -> String {
        let monitors = findings.enumerated().map { (offset, finding) in Monitor(index: offset + 1, finding: finding) }
        let name = identifier(type.name, taken: []) + "Model"
        var out: [String] = []
        out.append("---- MODULE \(name) ----")
        out.append(
            "\\* Generated by modeler from \(type.name) (\(type.file):\(type.line)). Edit freely; regenerating overwrites."
        )
        out.append("\\* Over-approximation: control flow, arguments and other types are not modelled; a write of a")
        out.append("\\* computed value may produce any member of the variable's set; effects inside closures run in")
        out.append("\\* the segment that contains the closure.")
        out.append("EXTENDS Naturals")
        var constants = ["Procs"]
        if variables.contains(where: { $0.domain.usesOpaque }) { constants.append("Opaque") }
        if variables.contains(where: { $0.domain.usesIntegerBound }) { constants.append("IntMax") }
        out.append("CONSTANTS \(constants.joined(separator: ", "))")
        let stateVars = variables.map(\.name) + ["pc"] + monitors.flatMap { ["chk_\($0.index)", "stale_\($0.index)"] }
        out.append("VARIABLES \(stateVars.joined(separator: ", "))")
        out.append("vars == <<\(stateVars.joined(separator: ", "))>>")
        out.append("")
        for variable in variables { out.append("Dom_\(variable.name) == \(variable.domain.expression)") }
        let pcs = (["idle"] + labels).map { "\"\($0)\"" }.joined(separator: ", ")
        out.append("PCs == {\(pcs)}")
        out.append("")
        out.append("TypeOK ==")
        out.append("    /\\ pc \\in [Procs -> PCs]")
        for variable in variables { out.append("    /\\ \(variable.name) \\in Dom_\(variable.name)") }
        for monitor in monitors {
            let domain = byName[monitor.finding.property].map { "Dom_\($0.name)" } ?? "{}"
            out.append("    /\\ chk_\(monitor.index) \\in [Procs -> \(domain) \\cup {\"none\"}]")
            out.append("    /\\ stale_\(monitor.index) \\in BOOLEAN")
        }
        out.append("")
        out.append("Init ==")
        out.append("    /\\ pc = [p \\in Procs |-> \"idle\"]")
        for variable in variables { out.append("    /\\ \(variable.name) = \(variable.initial)") }
        for monitor in monitors {
            out.append("    /\\ chk_\(monitor.index) = [p \\in Procs |-> \"none\"]")
            out.append("    /\\ stale_\(monitor.index) = FALSE")
        }
        out.append("")
        var disjuncts: [String] = []
        for action in actions {
            out += actionLines(action, variables: variables, byName: byName, monitors: monitors, bounds: bounds)
            disjuncts.append("\(action.name)(p)")
            if !action.segment.precondition.isEmpty {
                disjuncts.append("\(action.name)_skip(p)")
            }
        }
        if disjuncts.isEmpty {
            out.append("Next == UNCHANGED vars")
        } else {
            out.append("Next == \\E p \\in Procs : " + disjuncts.joined(separator: " \\/ "))
        }
        out.append("")
        out.append("Spec == Init /\\ [][Next]_vars")
        for monitor in monitors {
            let f = monitor.finding
            out.append("")
            out.append(
                "\\* \(f.method): \(f.property) checked at line \(f.checkLine), awaited at \(f.suspendLine), written at \(f.writeLine)."
            )
            out.append("NoStaleWrite_\(monitor.index) == ~stale_\(monitor.index)")
        }
        out.append("====")
        return out.joined(separator: "\n") + "\n"
    }

    private struct Monitor {
        let index: Int
        let finding: ReentrancyFinding
    }

    private static func actionLines(
        _ action: Action, variables: [Variable], byName: [String: Variable], monitors: [Monitor], bounds: Bounds
    ) -> [String] {
        let precondition = action.segment.precondition.filter { byName[$0.key] != nil }
        var body: [String] = ["/\\ pc[p] = \"\(action.from)\""]
        var primed: Set<String> = []
        for (property, cases) in precondition.sorted(by: { $0.key < $1.key }) {
            body.append("/\\ \(property) \\in {" + cases.map { "\"\($0)\"" }.joined(separator: ", ") + "}")
        }
        for (property, write) in action.segment.writes.sorted(by: { $0.key < $1.key }) {
            guard let variable = byName[property] else { continue }
            primed.insert(property)
            let terms = write.literals.compactMap { variable.domain.term(for: $0, integerBound: bounds.integerMaximum) }
            let distinct = Array(Set(terms)).sorted()
            if write.hasUnknown || distinct.count != write.literals.count && !write.literals.isEmpty || distinct.isEmpty
            {
                body.append("/\\ \(property)' \\in Dom_\(property)")
            } else if distinct.count == 1 {
                body.append("/\\ \(property)' = \(distinct[0])")
            } else {
                body.append("/\\ \(property)' \\in {" + distinct.joined(separator: ", ") + "}")
            }
        }
        body.append("/\\ pc' = [pc EXCEPT ![p] = \"\(action.to)\"]")
        var unchanged = variables.map(\.name).filter { !primed.contains($0) }
        for monitor in monitors {
            guard action.method == monitor.finding.method else {
                unchanged += ["chk_\(monitor.index)", "stale_\(monitor.index)"]
                continue
            }
            let f = monitor.finding
            let isCheck = action.segment.effects.contains {
                $0.kind == .read && $0.isCheck && $0.line == f.checkLine && $0.subject == f.property
            }
            let isWrite = action.segment.effects.contains {
                $0.kind == .write && $0.line == f.writeLine && $0.subject == f.property
            }
            if isCheck {
                body.append("/\\ chk_\(monitor.index)' = [chk_\(monitor.index) EXCEPT ![p] = \(f.property)]")
            } else if action.isFirst {
                body.append("/\\ chk_\(monitor.index)' = [chk_\(monitor.index) EXCEPT ![p] = \"none\"]")
            } else {
                unchanged.append("chk_\(monitor.index)")
            }
            if isWrite {
                body.append(
                    "/\\ stale_\(monitor.index)' = (stale_\(monitor.index) \\/ (chk_\(monitor.index)[p] # \"none\" /\\ chk_\(monitor.index)[p] # \(f.property)))"
                )
            } else {
                unchanged.append("stale_\(monitor.index)")
            }
        }
        if !unchanged.isEmpty { body.append("/\\ UNCHANGED <<\(unchanged.joined(separator: ", "))>>") }
        var lines = ["\\* \(action.comment)", "\(action.name)(p) =="] + body.map { "    " + $0 }
        if !precondition.isEmpty {
            let guardText = precondition.sorted { $0.key < $1.key }.map { property, cases in
                "\(property) \\in {" + cases.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
            }.joined(separator: " /\\ ")
            lines.append("")
            lines.append("\\* The check fails: the call returns without changing state.")
            lines.append("\(action.name)_skip(p) ==")
            lines.append("    /\\ pc[p] = \"\(action.from)\"")
            lines.append("    /\\ ~(\(guardText))")
            lines.append("    /\\ pc' = [pc EXCEPT ![p] = \"idle\"]")
            lines.append(
                "    /\\ UNCHANGED <<"
                    + (variables.map(\.name) + monitors.flatMap { ["chk_\($0.index)", "stale_\($0.index)"] }).joined(
                        separator: ", ") + ">>")
        }
        lines.append("")
        return lines
    }

    private static func configText(variables: [Variable], findings: [ReentrancyFinding], bounds: Bounds) -> String {
        var lines = ["SPECIFICATION Spec", "CONSTANTS"]
        lines.append("    Procs = {" + (1...max(bounds.callers, 1)).map { "p\($0)" }.joined(separator: ", ") + "}")
        if variables.contains(where: { $0.domain.usesOpaque }) {
            lines.append(
                "    Opaque = {" + (1...max(bounds.opaqueValues, 1)).map { "o\($0)" }.joined(separator: ", ") + "}")
        }
        if variables.contains(where: { $0.domain.usesIntegerBound }) {
            lines.append("    IntMax = \(bounds.integerMaximum)")
        }
        lines.append("INVARIANTS")
        lines.append("    TypeOK")
        for index in findings.indices { lines.append("    NoStaleWrite_\(index + 1)") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    private static func variable(for property: PropertyFacts, in facts: ModelFacts, bounds: Bounds) -> Variable {
        let domain = TLADomain(of: property, in: facts)
        let initial =
            (property.initialCase ?? property.initialLiteral).flatMap {
                domain.term(for: $0, integerBound: bounds.integerMaximum)
            } ?? "CHOOSE v \\in Dom_\(property.name) : TRUE"
        return Variable(name: property.name, domain: domain, initial: initial)
    }

    private static func identifier(_ name: String, taken: Set<String>) -> String {
        var cleaned = String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        if cleaned.first?.isNumber == true { cleaned = "T" + cleaned }
        var candidate = cleaned
        var count = 1
        while taken.contains(candidate) {
            count += 1
            candidate = "\(cleaned)\(count)"
        }
        return candidate
    }
}
