import SwiftParser
import SwiftSyntax

/// Turns Swift source into ``FileFacts``.
public enum FactsExtractor {
    /// The type declarations, members and method effects of one file.
    /// - Parameters:
    ///   - source: the file's text.
    ///   - path: how findings and diagrams name the file.
    /// - Complexity: O(*n*) in the source size.
    public static func extract(source: String, path: String) -> FileFacts {
        DeclarationExtractor.extract(from: Parser.parse(source: source), path: path)
    }

    /// As ``extract(source:path:)``, from the file's UTF-8 bytes. Invalid UTF-8 is replaced, not rejected.
    public static func extract(bytes: [UInt8], path: String) -> FileFacts {
        extract(source: String(decoding: bytes, as: UTF8.self), path: path)
    }
}
