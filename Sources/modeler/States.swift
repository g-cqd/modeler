import ArgumentParser
import ModelerCore
import SystemPackage

struct States: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mermaid state diagrams of every enum-valued member the code assigns.")

    @OptionGroup var corpus: CorpusOptions

    @Option(name: .long, help: "Only machines whose owner or enum is this type; repeatable.")
    var type: [String] = []

    @Option(name: .long, help: "Write one .mmd file per machine into this directory instead of printing.")
    var output: String?

    func run() async throws {
        let facts = try await corpus.load()
        let wanted = Set(type.compactMap { facts.type(named: $0)?.name })
        let machines = StateMachines.extract(from: facts).filter {
            type.isEmpty || wanted.contains($0.owner) || wanted.contains($0.stateType)
        }
        guard !machines.isEmpty else {
            write("\(ModelerTool.name): no state machine found\n", to: .standardError)
            return
        }
        if let output {
            var files: [String: String] = [:]
            for machine in machines {
                files["\(machine.owner).\(machine.property).mmd"] = MermaidStateDiagram.render(machine)
            }
            try writeFiles(files, to: output)
        } else {
            write(machines.map(MermaidStateDiagram.render).joined(separator: "\n"), to: .standardOutput)
        }
    }
}
