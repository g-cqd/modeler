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
    static func constraints(of expression: ExprSyntax, locals: Set<String>) -> Constraints {
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

    private static func conjunction(_ elements: [ExprSyntax], locals: Set<String>) -> Constraints {
        var result: Constraints = [:]
        for atom in split(elements, on: "&&") where atom.count == 3 {
            guard let op = atom[1].as(BinaryOperatorExprSyntax.self), op.operator.text == "==" else { continue }
            if let member = memberName(of: atom[0], locals: locals), let name = caseLiteral(atom[2]) {
                merge([member: [name]], into: &result)
            } else if let member = memberName(of: atom[2], locals: locals), let name = caseLiteral(atom[0]) {
                merge([member: [name]], into: &result)
            }
        }
        return result
    }

    /// Both conditions hold, so a member constrained twice is narrowed to the intersection.
    static func merge(_ new: Constraints, into existing: inout Constraints) {
        for (member, cases) in new {
            existing[member] = existing[member].map { $0.intersection(cases) } ?? cases
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
