import SwiftSyntax

/// Reads the type declarations of one parsed file: their members, and the effects of their method bodies.
final class DeclarationExtractor: SyntaxVisitor {
    private struct Scope {
        var name: String
        var kind: TypeFacts.Kind
        var inherited: [String]
        var attributes: [String]
        var line: Int
        var properties: [PropertyFacts] = []
        var cases: [EnumCaseFacts] = []
        var methods: [MethodFacts] = []
    }

    private let path: String
    private let converter: SourceLocationConverter
    private var scopes: [Scope] = []
    private var finished: [TypeFacts] = []

    private init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    /// The type declarations and extensions in `tree`.
    /// - Complexity: O(*n*) in the syntax tree's size; each body is walked once for bindings and once for effects.
    static func extract(from tree: SourceFileSyntax, path: String) -> FileFacts {
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let extractor = DeclarationExtractor(path: path, converter: converter)
        extractor.walk(tree)
        return FileFacts(path: path, types: extractor.finished)
    }

    // MARK: - Types

    private func open(
        _ kind: TypeFacts.Kind, name: String, node: some SyntaxProtocol, inherited: InheritanceClauseSyntax?,
        attributes: AttributeListSyntax
    ) {
        let qualified: String
        if kind == .extensionType {
            qualified = name
        } else if let parent = scopes.last {
            qualified = parent.name + "." + name
        } else {
            qualified = name
        }
        scopes.append(
            Scope(
                name: qualified, kind: kind,
                inherited: inherited?.inheritedTypes.map { $0.type.trimmedDescription } ?? [],
                attributes: Self.attributeNames(attributes),
                line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line))
    }

    private func close() {
        guard let scope = scopes.popLast() else { return }
        finished.append(
            TypeFacts(
                name: scope.name, kind: scope.kind, inherited: scope.inherited, attributes: scope.attributes,
                file: path, line: scope.line, properties: scope.properties, cases: scope.cases, methods: scope.methods))
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        open(
            .structType, name: node.name.text, node: node, inherited: node.inheritanceClause,
            attributes: node.attributes)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { close() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        open(
            .classType, name: node.name.text, node: node, inherited: node.inheritanceClause, attributes: node.attributes
        )
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { close() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        open(
            .actorType, name: node.name.text, node: node, inherited: node.inheritanceClause, attributes: node.attributes
        )
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { close() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        open(
            .enumType, name: node.name.text, node: node, inherited: node.inheritanceClause, attributes: node.attributes)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { close() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        open(
            .protocolType, name: node.name.text, node: node, inherited: node.inheritanceClause,
            attributes: node.attributes)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) { close() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        open(
            .extensionType, name: node.extendedType.trimmedDescription, node: node, inherited: node.inheritanceClause,
            attributes: node.attributes)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { close() }

    // MARK: - Members

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !scopes.isEmpty else { return .skipChildren }
        for element in node.elements {
            let payload = element.parameterClause?.parameters.map { $0.type.trimmedDescription } ?? []
            scopes[scopes.count - 1].cases.append(EnumCaseFacts(name: element.name.text, payload: payload))
        }
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !scopes.isEmpty else { return .skipChildren }
        let modifiers = Set(node.modifiers.map { $0.name.text })
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                Self.isStored(binding.accessorBlock)
            else { continue }
            let initializer = binding.initializer?.value
            scopes[scopes.count - 1].properties.append(
                PropertyFacts(
                    name: name, typeText: binding.typeAnnotation?.type.trimmedDescription,
                    isMutable: node.bindingSpecifier.tokenKind == .keyword(.var),
                    isStatic: modifiers.contains("static") || modifiers.contains("class"),
                    line: converter.location(for: binding.positionAfterSkippingLeadingTrivia).line,
                    initialCase: initializer.flatMap(Conditions.caseLiteral),
                    initialLiteral: initializer.flatMap(Self.literalText)))
        }
        return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !scopes.isEmpty else { return .skipChildren }
        let modifiers = Set(node.modifiers.map { $0.name.text })
        let labels = node.signature.parameterClause.parameters.map { $0.firstName.text + ":" }.joined()
        let effects =
            node.body.map {
                BodyEffectCollector.effects(
                    of: $0, converter: converter,
                    locals: LocalBindings.collect(parameters: node.signature.parameterClause, body: $0))
            } ?? []
        scopes[scopes.count - 1].methods.append(
            MethodFacts(
                signature: "\(node.name.text)(\(labels))", name: node.name.text, file: path,
                line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
                isThrowing: node.signature.effectSpecifiers?.throwsClause != nil,
                isStatic: modifiers.contains("static") || modifiers.contains("class"),
                isMutating: modifiers.contains("mutating"), isNonisolated: modifiers.contains("nonisolated"),
                attributes: Self.attributeNames(node.attributes), effects: effects))
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !scopes.isEmpty else { return .skipChildren }
        let labels = node.signature.parameterClause.parameters.map { $0.firstName.text + ":" }.joined()
        let effects =
            node.body.map {
                BodyEffectCollector.effects(
                    of: $0, converter: converter,
                    locals: LocalBindings.collect(parameters: node.signature.parameterClause, body: $0))
            } ?? []
        scopes[scopes.count - 1].methods.append(
            MethodFacts(
                signature: "init(\(labels))", name: "init", file: path,
                line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
                isThrowing: node.signature.effectSpecifiers?.throwsClause != nil, isStatic: false, isMutating: false,
                isNonisolated: false, attributes: Self.attributeNames(node.attributes), effects: effects))
        return .skipChildren
    }

    // MARK: - Helpers

    private static func attributeNames(_ attributes: AttributeListSyntax) -> [String] {
        attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
    }

    /// A stored property has no accessor block, or only observers.
    private static func isStored(_ block: AccessorBlockSyntax?) -> Bool {
        guard let block else { return true }
        guard case .accessors(let accessors) = block.accessors else { return false }
        return accessors.allSatisfy { ["willSet", "didSet"].contains($0.accessorSpecifier.text) }
    }

    private static func literalText(_ expression: ExprSyntax) -> String? {
        let isLiteral =
            expression.is(IntegerLiteralExprSyntax.self) || expression.is(BooleanLiteralExprSyntax.self)
            || expression.is(StringLiteralExprSyntax.self) || expression.is(NilLiteralExprSyntax.self)
            || expression.is(FloatLiteralExprSyntax.self)
        let text = expression.trimmedDescription
        return isLiteral && text.count <= 40 ? text : nil
    }
}
