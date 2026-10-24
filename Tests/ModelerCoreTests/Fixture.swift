import ModelerCore

/// Facts of in-memory sources, one file per element.
func modelFacts(_ sources: String...) -> ModelFacts {
    ModelFacts(
        files: sources.enumerated().map { FactsExtractor.extract(source: $1, path: "File\($0).swift") })
}

func method(_ name: String, of type: String, in facts: ModelFacts) -> MethodFacts? {
    facts.type(named: type)?.methods.first { $0.name == name }
}

extension Effect {
    /// `kind subject` for compact assertions.
    var summary: String { "\(kind.rawValue) \(subject)" }
}
