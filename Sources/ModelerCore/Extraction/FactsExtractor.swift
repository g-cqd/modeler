public import ProjectModel
import SwiftParser
import SwiftSyntax

/// Turns Swift source into ``FileFacts``.
public enum FactsExtractor {
    /// The type declarations, members and method effects of one file.
    /// - Parameters:
    ///   - source: the file's text.
    ///   - path: how findings and diagrams name the file.
    /// - Complexity: O(*n*) in the source size.
    ///   - classification: when given, the file's region is recorded from its project and its content.
    ///   - conditions: with a define, only the active `#if` clauses are modelled (analyzerkit ADR-0029).
    public static func extract(
        source: String, path: String, classification: ProjectClassification? = nil,
        conditions: CompilationConditions = CompilationConditions()
    ) -> FileFacts {
        let parsed = Parser.parse(source: source)
        let region = classification?.classify(path, tree: parsed).region.rawValue ?? 0
        // The inactive clauses are blanked in place, so every line of the code that stays is where it was.
        let tree =
            conditions.isRequested
            ? conditions.activeSource(Array(source.utf8), tree: parsed).map {
                Parser.parse(source: String(decoding: $0, as: UTF8.self))
            } ?? parsed : parsed
        // Extraction recurses once per level of the tree; past the limit the file is listed, not walked.
        if SyntaxDepth.exceeds(tree) {
            return FileFacts(
                path: path, types: [], degraded: "nested deeper than \(SyntaxDepth.defaultLimit) levels; not modelled",
                region: region)
        }
        var facts = DeclarationExtractor.extract(from: tree, path: path)
        facts.region = region
        return facts
    }

    /// As ``extract(source:path:classification:)``, from the file's UTF-8 bytes. Invalid UTF-8 is replaced, not
    /// rejected.
    public static func extract(
        bytes: [UInt8], path: String, classification: ProjectClassification? = nil,
        conditions: CompilationConditions = CompilationConditions()
    ) -> FileFacts {
        extract(
            source: String(decoding: bytes, as: UTF8.self), path: path, classification: classification,
            conditions: conditions)
    }
}
