import ArgumentParser
import ModelerCore
import SystemPackage

struct Classes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A Mermaid class diagram: types, members, conformance and ownership.")

    @OptionGroup var corpus: CorpusOptions

    @Option(name: .long, help: "Centre the diagram on this type; repeatable. Without it every type is drawn.")
    var type: [String] = []

    @Option(name: .long, help: "How many edges away from --type to include.")
    var depth = 1

    func run() async throws {
        let facts = try await corpus.load()
        write(MermaidClassDiagram.render(facts, focus: type, depth: depth), to: .standardOutput)
    }
}
