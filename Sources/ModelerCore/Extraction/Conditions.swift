import SwiftSyntax

/// What `if`, `guard`, `while` and `switch` conditions say about enum-valued members, read from syntax alone.
///
/// Recognised: `member == .case`, `.case == member`, `case .a = member`, `case .a, .b = member`, joined by `&&`
/// or by `||` over one member. Anything else establishes nothing, so the analyses that use this err toward
/// "any state".
enum Conditions {
    /// A member's possible cases.
    typealias Constraints = [String: Set<String>]

    /// The member a bare identifier or `self.name` names, or nil for a local, a type, a closure argument or
    /// anything else that cannot be a member of `self`.
    static func memberName(of expression: ExprSyntax, locals: Set<String>) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return bareMember(reference.baseName.text, locals: locals)
        }
        if let access = expression.as(MemberAccessExprSyntax.self),
            let base = access.base?.as(DeclReferenceExprSyntax.self), base.baseName.text == "self"
        {
            return access.declName.baseName.text
        }
        return nil
    }

    /// `name` when it can be a member: lowercase or `_`, not `$0`, not a local. `self` stands for an enum's
    /// own value.
    static func bareMember(_ name: String, locals: Set<String>) -> String? {
        guard let first = name.first, first == "_" || first.isLowercase, !locals.contains(name) else { return nil }
        return name
    }

    /// The case an implicit-member expression names: `.idle` or `.running(x)`.
    static func caseLiteral(_ expression: ExprSyntax) -> String? {
        if let access = expression.as(MemberAccessExprSyntax.self), access.base == nil {
            return access.declName.baseName.text
        }
        if let call = expression.as(FunctionCallExprSyntax.self) { return caseLiteral(call.calledExpression) }
        return nil
    }

    /// What an assigned expression says about the new value, when it is a literal: the enum case an implicit
    /// member names, `true` or `false`, an integer, or `nil`.
    static func literalValue(_ expression: ExprSyntax) -> String? {
        if let name = caseLiteral(expression) { return name }
        if let boolean = expression.as(BooleanLiteralExprSyntax.self) { return boolean.literal.text }
        if let integer = expression.as(IntegerLiteralExprSyntax.self) { return integer.literal.text }
        if expression.is(NilLiteralExprSyntax.self) { return "nil" }
        return nil
    }

    /// The case names a pattern's text begins with, one per comma-separated item: `.a, .b(let x)` gives a and b.
    static func caseNames(inPattern text: String) -> [String] {
        text.split(separator: ",").compactMap { item in
            var rest = item.drop { $0 == " " || $0 == "\n" }
            for keyword in ["let ", "var "] where rest.hasPrefix(keyword) { rest = rest.dropFirst(keyword.count) }
            guard rest.first == "." else { return nil }
            let name = rest.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
    }

    /// What a condition list establishes when all of it holds.
    static func constraints(of conditions: ConditionElementListSyntax, locals: Set<String>) -> Constraints {
        var result: Constraints = [:]
        for condition in conditions {
            switch condition.condition {
            case .expression(let expression):
                merge(constraints(of: expression, locals: locals), into: &result)
            case .matchingPattern(let matching):
                if let member = memberName(of: matching.initializer.value, locals: locals) {
                    let names = caseNames(inPattern: matching.pattern.trimmedDescription)
                    if !names.isEmpty { merge([member: Set(names)], into: &result) }
                }
            default:
                break
            }
        }
        return result
    }

    /// What one boolean expression establishes when it is true.
    ///
    /// A member used as a condition on its own, `if ready`, is `true`, and `if !ready` is `false`; `ready ==
    /// true` and `== false` say the same. Their "cases" are the literals `true` and `false`.
    static func constraints(of expression: ExprSyntax, locals: Set<String>) -> Constraints {
        if let truth = booleanMember(expression, locals: locals) { return [truth.member: [truth.value]] }
        guard let sequence = expression.as(SequenceExprSyntax.self) else { return [:] }
        let elements = Array(sequence.elements)
        let alternatives = split(elements, on: "||")
        if alternatives.count > 1 {
            let each = alternatives.map { conjunction($0, locals: locals) }
            guard let property = each.first?.keys.first, each.allSatisfy({ $0.keys.contains(property) }) else {
                return [:]
            }
            return [property: each.reduce(into: Set<String>()) { $0.formUnion($1[property] ?? []) }]
        }
        return conjunction(elements, locals: locals)
    }

    /// `member` and the truth it has when `expression` holds, for a bare member or its negation.
    private static func booleanMember(_ expression: ExprSyntax, locals: Set<String>) -> (member: String, value: String)?
    {
        if let negation = expression.as(PrefixOperatorExprSyntax.self), negation.operator.text == "!",
            let member = memberName(of: negation.expression, locals: locals), member != "self"
        {
            return (member, "false")
        }
        if let member = memberName(of: expression, locals: locals), member != "self" { return (member, "true") }
        if let negation = expression.as(PrefixOperatorExprSyntax.self), negation.operator.text == "!",
            let predicate = predicateMember(negation.expression, locals: locals)
        {
            return (predicate.member, negated + predicate.name)
        }
        if let predicate = predicateMember(expression, locals: locals) {
            return (predicate.member, marker + predicate.name)
        }
        return nil
    }

    // MARK: - Predicates of an enum

    /// The prefix of a "case" that names a Boolean property of the member's type, `@isRecording`, to be resolved to
    /// the enum's cases once every file is read (``ModelFacts``), or dropped.
    static let marker = "@"
    /// The prefix of a negated one, `!@isRecording`: the enum's other cases.
    static let negated = "!@"

    static func isMarker(_ value: String) -> Bool { value.hasPrefix(marker) || value.hasPrefix(negated) }

    /// `member.name`, or `self.member.name`: a property read on a member, which may be a predicate of its enum.
    private static func predicateMember(_ expression: ExprSyntax, locals: Set<String>) -> (
        member: String, name: String
    )? {
        guard let access = expression.as(MemberAccessExprSyntax.self), let base = access.base,
            let member = memberName(of: base, locals: locals), member != "self"
        else { return nil }
        let name = access.declName.baseName.text
        guard let first = name.first, first.isLowercase else { return nil }
        return (member, name)
    }

    /// The cases a Boolean getter on `self` is true for, or nil when it is not one of the recognized shapes:
    /// `if case .a = self { return true }; return false`, `if case .a = self { true } else { false }`,
    /// `switch self { case .a, .b: return true; default: return false }`, `self == .a || self == .b`.
    static func predicateCases(of statements: CodeBlockItemListSyntax) -> Set<String>? {
        let items = Array(statements).map(\.item)
        if items.count == 1, let expression = expression(of: items[0]) { return cases(whenTrue: expression) }
        if items.count == 2,
            let first = items[0].as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self)
                ?? (items[0].as(ExprSyntax.self)?.as(IfExprSyntax.self)),
            first.elseBody == nil, truth(of: first.body.statements) == true, truth(of: items[1]) == false
        {
            return constraints(of: first.conditions, locals: [])["self"]
        }
        return nil
    }

    private static func expression(of item: CodeBlockItemSyntax.Item) -> ExprSyntax? {
        if let returned = item.as(ReturnStmtSyntax.self) { return returned.expression }
        if let statement = item.as(ExpressionStmtSyntax.self) { return statement.expression }
        return item.as(ExprSyntax.self)
    }

    private static func cases(whenTrue expression: ExprSyntax) -> Set<String>? {
        if let conditional = expression.as(IfExprSyntax.self) {
            guard case .codeBlock(let otherwise)? = conditional.elseBody,
                truth(of: conditional.body.statements) == true, truth(of: otherwise.statements) == false
            else { return nil }
            return constraints(of: conditional.conditions, locals: [])["self"]
        }
        if let switched = expression.as(SwitchExprSyntax.self) {
            guard switched.subject.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" else { return nil }
            var result: Set<String> = []
            for element in switched.cases {
                guard case .switchCase(let switchCase) = element, let value = truth(of: switchCase.statements) else {
                    return nil
                }
                switch switchCase.label {
                case .case(let label):
                    let names = label.caseItems.flatMap { caseNames(inPattern: $0.pattern.trimmedDescription) }
                    guard !names.isEmpty else { return nil }
                    if value { result.formUnion(names) }
                case .default:
                    if value { return nil }
                }
            }
            return result
        }
        return constraints(of: expression, locals: [])["self"]
    }

    /// The Boolean literal a one-statement block yields, `return true` or `true`.
    private static func truth(of statements: CodeBlockItemListSyntax) -> Bool? {
        guard statements.count == 1, let item = statements.first?.item else { return nil }
        return truth(of: item)
    }

    private static func truth(of item: CodeBlockItemSyntax.Item) -> Bool? {
        guard let literal = expression(of: item)?.as(BooleanLiteralExprSyntax.self) else { return nil }
        return literal.literal.tokenKind == .keyword(.true)
    }

    private static func conjunction(_ elements: [ExprSyntax], locals: Set<String>) -> Constraints {
        var result: Constraints = [:]
        for atom in split(elements, on: "&&") where atom.count == 1 {
            if let truth = booleanMember(atom[0], locals: locals) {
                merge([truth.member: [truth.value]], into: &result)
            }
        }
        for atom in split(elements, on: "&&") where atom.count == 3 {
            guard let op = atom[1].as(BinaryOperatorExprSyntax.self), op.operator.text == "==" else { continue }
            if let member = memberName(of: atom[0], locals: locals), let name = literalValue(atom[2]) {
                merge([member: [name]], into: &result)
            } else if let member = memberName(of: atom[2], locals: locals), let name = literalValue(atom[0]) {
                merge([member: [name]], into: &result)
            }
        }
        return result
    }

    /// Both conditions hold, so a member constrained twice is narrowed to the intersection.
    /// A predicate is not resolved yet, so a member constrained by one and by something else keeps the side without
    /// it: wider than the intersection, so the model still over-approximates.
    static func merge(_ new: Constraints, into existing: inout Constraints) {
        for (member, cases) in new {
            guard let old = existing[member] else {
                existing[member] = cases
                continue
            }
            let oldMarked = old.contains(where: isMarker)
            let newMarked = cases.contains(where: isMarker)
            if oldMarked || newMarked {
                existing[member] = oldMarked && !newMarked ? cases : old
            } else {
                existing[member] = old.intersection(cases)
            }
        }
    }

    private static func split(_ elements: [ExprSyntax], on separator: String) -> [[ExprSyntax]] {
        var groups: [[ExprSyntax]] = [[]]
        for element in elements {
            if let op = element.as(BinaryOperatorExprSyntax.self), op.operator.text == separator {
                groups.append([])
            } else {
                groups[groups.count - 1].append(element)
            }
        }
        return groups
    }
}
