import SwiftSyntax

/// Every name a function body or its parameters bind: parameters, `let` and `var`, `for` and `case`
/// patterns, closure parameters and captures, `catch` errors.
///
/// A bare identifier in this set is a local, never the type's member, wherever in the body it appears. That
/// over-approximates for a body that declares a local after using a member of the same name; `self.name`
/// still reaches the member.
final class LocalBindings: SyntaxVisitor {
    private(set) var names: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    static func collect(parameters: FunctionParameterClauseSyntax?, body: CodeBlockSyntax?) -> Set<String> {
        let collector = LocalBindings()
        for parameter in parameters?.parameters ?? [] {
            collector.names.insert((parameter.secondName ?? parameter.firstName).text)
        }
        if let body { collector.walk(body) }
        return collector.names
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert((node.secondName ?? node.firstName).text)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        if node.catchItems.isEmpty { names.insert("error") }
        return .visitChildren
    }
}
