import ControlFlow
import SwiftSyntax

/// Walks one method body and records, in source order, the member reads and writes, `await`s, spawns and calls
/// on `self`, with what the enclosing conditions say about enum-valued members at each point.
///
/// The analysis is syntactic and path-insensitive: statements are visited in source order, branches
/// included, so an effect in one branch is ordered against an effect in another. A narrowing lasts for the
/// block that established it, and a write to a member replaces it. Nested types and local functions are not
/// entered as separate scopes; a local function's body counts as a closure.
final class BodyEffectCollector: SyntaxVisitor {
    private struct Known {
        var cases: Set<String>
        var epoch: Int
    }

    private static let mutatingMembers: Set<String> = [
        "append", "insert", "remove", "removeAll", "removeValue", "removeFirst", "removeLast", "removeSubrange",
        "popLast", "popFirst", "merge", "formUnion", "formIntersection", "subtract", "sort", "reverse", "swapAt",
        "updateValue", "replaceSubrange", "reserveCapacity", "append(contentsOf:)", "enqueue", "push", "pop",
    ]

    private let converter: SourceLocationConverter
    private let locals: Set<String>
    private(set) var effects: [Effect] = []
    /// Where each effect's syntax starts, to place it in the control-flow graph.
    private var offsets: [Int] = []
    private var conditionDepth = 0
    private var closureDepth = 0
    private var epoch = 0
    private var known: [String: Known] = [:]
    private var closureScopes: [[String: Known]] = []
    private var heldLocks: [String] = []

    init(converter: SourceLocationConverter, locals: Set<String>) {
        self.converter = converter
        self.locals = locals
        super.init(viewMode: .sourceAccurate)
    }

    /// The effects of `body`, in source order, each with the nodes of the body's control-flow graph it happens in,
    /// and that graph as successor lists (roadmap 0026).
    static func effects(
        of body: CodeBlockSyntax, converter: SourceLocationConverter, locals: Set<String>
    ) -> (effects: [Effect], flow: [[Int]]) {
        let collector = BodyEffectCollector(converter: converter, locals: locals)
        collector.walk(body)
        let graph = ControlFlowGraph.build(body, converter: converter)
        let placed = place(collector.offsets, in: graph)
        let effects = zip(collector.effects, placed).map { effect, nodes in
            Effect(
                kind: effect.kind, line: effect.line, subject: effect.subject, value: effect.value,
                isCheck: effect.isCheck, closureDepth: effect.closureDepth, when: effect.when, locks: effect.locks,
                nodes: nodes)
        }
        return (effects, graph.nodes.map { $0.successors.map(\.target) })
    }

    /// The nodes whose syntax covers each offset. Nodes cover disjoint ranges, except the copies of a `defer` body
    /// lowered once per exit, which share one.
    private static func place(_ offsets: [Int], in graph: ControlFlowGraph) -> [[Int]] {
        var byRange: [Range<Int>: [Int]] = [:]
        for node in graph.nodes {
            guard let syntax = node.syntax else { continue }
            let range =
                syntax.positionAfterSkippingLeadingTrivia
                .utf8Offset..<syntax.endPositionBeforeTrailingTrivia
                .utf8Offset
            byRange[range, default: []].append(node.id)
        }
        let ranges = byRange.keys.sorted { $0.lowerBound < $1.lowerBound }
        return offsets.map { offset in
            // The last range starting at or before the offset, the only one that can cover it.
            var low = 0
            var high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if ranges[middle].lowerBound <= offset { low = middle + 1 } else { high = middle }
            }
            guard low > 0, ranges[low - 1].contains(offset) else { return [] }
            return byRange[ranges[low - 1]] ?? []
        }
    }

    // MARK: - Recording

    private func line(of node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    private func record(_ kind: Effect.Kind, _ node: some SyntaxProtocol, _ subject: String, value: String? = nil) {
        let guards = known.map {
            StateGuard(property: $0.key, cases: $0.value.cases.sorted(), isFresh: $0.value.epoch == epoch)
        }
        offsets.append(node.positionAfterSkippingLeadingTrivia.utf8Offset)
        effects.append(
            Effect(
                kind: kind, line: line(of: node), subject: subject, value: value,
                isCheck: conditionDepth > 0 && kind == .read,
                closureDepth: closureDepth, when: guards.sorted { $0.property < $1.property }, locks: heldLocks))
    }

    private func suspend(at node: some SyntaxProtocol, awaiting text: String) {
        record(.suspend, node, String(text.prefix(80).map { $0 == "\n" ? " " : $0 }))
        if closureDepth == 0 { epoch += 1 }
    }

    private func apply(_ constraints: Conditions.Constraints) {
        for (member, cases) in constraints { known[member] = Known(cases: cases, epoch: epoch) }
    }

    private func walkConditions(_ conditions: ConditionElementListSyntax) {
        conditionDepth += 1
        walk(conditions)
        conditionDepth -= 1
    }

    // MARK: - Statements

    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        let saved = known
        for item in node {
            walk(item)
            if let statement = item.item.as(GuardStmtSyntax.self), Self.exits(statement.body) {
                apply(Conditions.constraints(of: statement.conditions, locals: locals))
            }
        }
        known = saved
        return .skipChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        walkConditions(node.conditions)
        let saved = known
        apply(Conditions.constraints(of: node.conditions, locals: locals))
        walk(node.body)
        known = saved
        if let elseBody = node.elseBody { walk(Syntax(elseBody)) }
        return .skipChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        walkConditions(node.conditions)
        walk(node.body)
        return .skipChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        walkConditions(node.conditions)
        let saved = known
        apply(Conditions.constraints(of: node.conditions, locals: locals))
        walk(node.body)
        known = saved
        return .skipChildren
    }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        conditionDepth += 1
        walk(node.subject)
        conditionDepth -= 1
        let subject = Conditions.memberName(of: node.subject, locals: locals)
        for element in node.cases {
            guard case .switchCase(let switchCase) = element else { continue }
            let saved = known
            if let subject, case .case(let label) = switchCase.label {
                let names = label.caseItems.flatMap { Conditions.caseNames(inPattern: $0.pattern.trimmedDescription) }
                if !names.isEmpty { known[subject] = Known(cases: Set(names), epoch: epoch) }
            }
            walk(switchCase.statements)
            known = saved
        }
        return .skipChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        walk(node.sequence)
        if node.awaitKeyword != nil { suspend(at: node, awaiting: node.sequence.trimmedDescription) }
        walk(node.body)
        return .skipChildren
    }

    // MARK: - Expressions

    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        walk(node.expression)
        suspend(at: node, awaiting: node.expression.trimmedDescription)
        return .skipChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        closureDepth += 1
        closureScopes.append(known)
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) {
        closureDepth -= 1
        known = closureScopes.removeLast()
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        closureDepth += 1
        closureScopes.append(known)
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        closureDepth -= 1
        known = closureScopes.removeLast()
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression
        if Self.isSpawn(callee) { record(.spawn, node, callee.trimmedDescription) }
        if let name = Conditions.memberName(of: callee, locals: locals) {
            walkArguments(of: node)
            record(.call, node, name)
            return .skipChildren
        }
        if let access = callee.as(MemberAccessExprSyntax.self), let base = access.base,
            Self.mutatingMembers.contains(access.declName.baseName.text), let root = rootMember(of: base)
        {
            walk(base)
            walkArguments(of: node)
            record(.write, node, root)
            known.removeValue(forKey: root)
            return .skipChildren
        }
        if let access = callee.as(MemberAccessExprSyntax.self), let base = access.base,
            ["withLock", "withLockIfAvailable"].contains(access.declName.baseName.text)
        {
            // The lock's name is the member it hangs from, or the receiver's text for anything else.
            let name = rootMember(of: base) ?? base.trimmedDescription
            record(.acquire, node, name)
            heldLocks.append(name)
            walkArguments(of: node)
            heldLocks.removeLast()
            record(.release, node, name)
            return .skipChildren
        }
        // A bare callee is a function, not a member read.
        if !callee.is(DeclReferenceExprSyntax.self) { walk(callee) }
        walkArguments(of: node)
        return .skipChildren
    }

    private func walkArguments(of node: FunctionCallExprSyntax) {
        walk(node.arguments)
        if let trailing = node.trailingClosure { walk(trailing) }
        for additional in node.additionalTrailingClosures { walk(additional) }
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard let operatorIndex = elements.firstIndex(where: Self.isAssignmentOperator), operatorIndex == 1 else {
            return .visitChildren
        }
        for element in elements[2...] { walk(element) }
        let target = elements[0]
        guard let root = rootMember(of: target) else {
            walk(target)
            return .skipChildren
        }
        let isPlainAssignment = elements[1].is(AssignmentExprSyntax.self)
        if !isPlainAssignment { record(.read, target, root) }
        let value = elements.count == 3 && isPlainAssignment ? Conditions.literalValue(elements[2]) : nil
        record(.write, target, root, value: value)
        if let access = target.as(MemberAccessExprSyntax.self) {
            let leaf = access.declName.baseName.text
            if leaf != root {
                // Record the nested write with the root collection/member as context: "root.leaf"
                record(.write, target, "\(root).\(leaf)", value: value)
            }
        }
        if elements.count == 3, isPlainAssignment, let name = Conditions.caseLiteral(elements[2]) {
            known[root] = Known(cases: [name], epoch: epoch)
        } else {
            known.removeValue(forKey: root)
        }
        return .skipChildren
    }

    override func visit(_ node: InOutExprSyntax) -> SyntaxVisitorContinueKind {
        if let root = rootMember(of: node.expression) {
            record(.write, node, root)
            known.removeValue(forKey: root)
        } else {
            walk(node.expression)
        }
        return .skipChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let base = node.base else { return .skipChildren }
        if let reference = base.as(DeclReferenceExprSyntax.self), reference.baseName.text == "self" {
            record(.read, node, node.declName.baseName.text)
        } else {
            walk(base)
        }
        return .skipChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if name == "self" {
            record(.read, node, "self")
        } else if let member = Conditions.bareMember(name, locals: locals) {
            record(.read, node, member)
        }
        return .skipChildren
    }

    // MARK: - Helpers

    /// The member an assignment target or a mutating call's receiver ultimately names.
    private func rootMember(of expression: ExprSyntax) -> String? {
        if let name = Conditions.memberName(of: expression, locals: locals) { return name }
        if let access = expression.as(MemberAccessExprSyntax.self), let base = access.base {
            return rootMember(of: base)
        }
        if let subscripted = expression.as(SubscriptCallExprSyntax.self) {
            return rootMember(of: subscripted.calledExpression)
        }
        if let unwrapped = expression.as(ForceUnwrapExprSyntax.self) { return rootMember(of: unwrapped.expression) }
        if let chained = expression.as(OptionalChainingExprSyntax.self) { return rootMember(of: chained.expression) }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return rootMember(of: only.expression)
        }
        return nil
    }

    private static func isAssignmentOperator(_ element: ExprSyntax) -> Bool {
        if element.is(AssignmentExprSyntax.self) { return true }
        guard let text = element.as(BinaryOperatorExprSyntax.self)?.operator.text else { return false }
        return text.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!=="].contains(text)
    }

    private static func isSpawn(_ callee: ExprSyntax) -> Bool {
        if callee.as(DeclReferenceExprSyntax.self)?.baseName.text == "Task" { return true }
        guard let access = callee.as(MemberAccessExprSyntax.self) else { return false }
        let name = access.declName.baseName.text
        if name == "addTask" || name == "addTaskUnlessCancelled" { return true }
        return name == "detached" && access.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Task"
    }

    /// Whether every path through `body` leaves the enclosing scope, judged by its last statement.
    private static func exits(_ body: CodeBlockSyntax) -> Bool {
        guard let last = body.statements.last?.item else { return false }
        if last.is(ReturnStmtSyntax.self) || last.is(ThrowStmtSyntax.self) || last.is(ContinueStmtSyntax.self)
            || last.is(BreakStmtSyntax.self)
        {
            return true
        }
        let callee = last.as(FunctionCallExprSyntax.self)?.calledExpression.as(DeclReferenceExprSyntax.self)
        return ["fatalError", "preconditionFailure"].contains(callee?.baseName.text ?? "")
    }
}
