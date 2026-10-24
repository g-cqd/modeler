import ArgumentParser
import ModelerCore
import SystemPackage

struct TLA: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tla", abstract: "A TLA+ model and TLC configuration of one type's state and methods.")

    @OptionGroup var corpus: CorpusOptions

    @Option(name: .long, help: "The type to model, qualified or simple.")
    var type: String

    @Option(name: .long, help: "Write <Type>Model.tla and .cfg into this directory; without it the module is printed.")
    var output: String?

    @Option(name: .long, help: "Concurrent callers in the model.")
    var callers = 2

    @Option(name: .long, help: "The largest integer an integer member takes.")
    var intMax = 2

    @Option(name: .long, help: "Interchangeable values for members of other types.")
    var opaque = 2

    func run() async throws {
        let facts = try await corpus.load()
        var bounds = TLAModule.Bounds()
        bounds.callers = callers
        bounds.integerMaximum = intMax
        bounds.opaqueValues = opaque
        guard let model = TLAModule.render(type: type, in: facts, bounds: bounds) else {
            throw ValidationError(
                "'\(type)' is not a type of this corpus, or none of its methods touch a mutable member.")
        }
        if let output {
            try writeFiles(["\(model.name).tla": model.module, "\(model.name).cfg": model.config], to: output)
        } else {
            write(model.module, to: .standardOutput)
        }
    }
}
