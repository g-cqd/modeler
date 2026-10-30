import ArgumentParser
import ModelerCore
import ProjectModel
import SystemPackage

/// `modeler rules`: the catalogue; with an id, that rule explained (ADR-0019).
struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The rules `check` applies: id, severity and what each checks; with an id, that rule explained.")

    @Argument(help: "A rule id: explain that rule, as `modeler explain <id>` does.")
    var rule: String?

    func run() throws {
        if let rule { return try Explain.explain(rule) }
        for rule in RuleID.allCases {
            write("\(rule.rawValue)  [\(rule.defaultSeverity.rawValue)]\n    \(rule.summary)\n", to: .standardOutput)
        }
    }
}

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What a rule requires and how to satisfy it.")

    @Argument(help: "A rule id, from `modeler rules`.")
    var rule: String

    func run() throws { try Self.explain(rule) }

    static func explain(_ name: String) throws {
        guard let found = RuleID(rawValue: name) else {
            throw ValidationError("no rule named \(name); `modeler rules` lists them")
        }
        write("\(found.rawValue)  [\(found.defaultSeverity.rawValue)]\n\n\(found.explanation)\n", to: .standardOutput)
    }
}
