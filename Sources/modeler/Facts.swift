import ArgumentParser
import ModelerCore
import SystemPackage

struct Facts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Every extracted fact, state machine and finding as JSON.")

    @OptionGroup var corpus: CorpusOptions

    func run() async throws {
        let report = ModelReport(try await corpus.load())
        write(String(decoding: try report.json(), as: UTF8.self) + "\n", to: .standardOutput)
    }
}
