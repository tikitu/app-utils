import Foundation

/// What the rule editor needs to know about a kind of term: which fields
/// there are, how each is labelled and chosen, and how a row of the editor
/// becomes a term and back.
///
/// The editor itself handles *and*, *or*, *not* and nesting; a schema only
/// ever sees one row at a time. A row's value is a `String` — a choice's
/// identifier, or typed text — so that a row can be half-finished (nothing
/// typed yet) without the term type having to allow that.
public protocol RuleSchema {
    associatedtype Term: Equatable
    associatedtype Field: Hashable & Sendable

    /// In the order the field menu shows them.
    var fields: [Field] { get }
    func title(of field: Field) -> String
    /// How the row reads with and without *not*: ("is", "is not"),
    /// ("contains", "does not contain").
    func comparison(of field: Field) -> RuleComparison
    func values(of field: Field) -> RuleValues
    /// What a row starts as when its field is chosen. Prefer a value that
    /// already filters, so a new rule does something straight away.
    func defaultValue(of field: Field) -> String

    func row(for term: Term) -> RuleRow<Field>
    /// The term a row means, or `nil` while it is unfinished — an empty text
    /// field. Unfinished rows are left out of the expression rather than
    /// matching nothing.
    func term(for row: RuleRow<Field>) -> Term?
}

extension RuleSchema {
    /// A new rule: the first field, with its default value.
    public func newRow() -> RuleRow<Field>? {
        fields.first.map { RuleRow(field: $0, value: defaultValue(of: $0)) }
    }

    public func comparison(of field: Field) -> RuleComparison { .is }
}

/// One row's field and value, as the editor holds it.
public struct RuleRow<Field: Hashable>: Equatable, Sendable where Field: Sendable {
    public var field: Field
    public var value: String

    public init(field: Field, value: String) {
        self.field = field
        self.value = value
    }
}

public struct RuleComparison: Equatable, Sendable {
    public var positive: String
    public var negative: String

    public init(positive: String, negative: String) {
        self.positive = positive
        self.negative = negative
    }

    public static let `is` = RuleComparison(positive: "is", negative: "is not")
    public static let contains = RuleComparison(positive: "contains", negative: "does not contain")
}

/// How a row's value is chosen.
public enum RuleValues: Equatable, Sendable {
    /// No value: the field says it all ("is a favourite").
    case none
    /// Typed.
    case text(prompt: String)
    /// Chosen from a menu. A row whose value is not among the choices keeps
    /// it and shows it, rather than silently becoming something else.
    case choice([RuleChoice])
}

public struct RuleChoice: Equatable, Sendable, Identifiable {
    public var value: String
    public var title: String
    public var id: String { value }

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

/// An expression as the rule editor shows it: groups of rules, nested.
///
/// Each group matches **all**, **any**, **none** or **not all** of its
/// members, and each rule can be negated, so every ``BooleanExpression`` has
/// a tree and every tree an expression. Nodes have identities, so editing a
/// rule does not rebuild its neighbours, and a rule still being filled in —
/// which is not in the expression yet — survives.
public struct RuleTree<Field: Hashable & Sendable>: Equatable, Sendable {
    public var root: Group

    public init(root: Group) { self.root = root }

    public struct Group: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var kind: Kind
        public var members: [Node]

        public init(id: UUID, kind: Kind = .all, members: [Node] = []) {
            self.id = id
            self.kind = kind
            self.members = members
        }
    }

    public enum Kind: String, CaseIterable, Equatable, Sendable {
        case all, any, none, notAll

        public var title: String {
            switch self {
            case .all: "all"
            case .any: "any"
            case .none: "none"
            case .notAll: "not all"
            }
        }
    }

    public struct Rule: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var isNegated: Bool
        public var row: RuleRow<Field>

        public init(id: UUID, isNegated: Bool = false, row: RuleRow<Field>) {
            self.id = id
            self.isNegated = isNegated
            self.row = row
        }
    }

    public enum Node: Equatable, Sendable, Identifiable {
        case rule(Rule)
        case group(Group)

        public var id: UUID {
            switch self {
            case .rule(let rule): rule.id
            case .group(let group): group.id
            }
        }
    }
}

// MARK: - To and from expressions

extension RuleTree {
    /// The tree for `expression`. The root is always a group; a lone term
    /// becomes a group of one.
    public init<Schema: RuleSchema>(
        _ expression: BooleanExpression<Schema.Term>, schema: Schema, ids: () -> UUID = UUID.init
    ) where Schema.Field == Field {
        func group(_ expression: BooleanExpression<Schema.Term>) -> Group? {
            switch expression {
            case .all(let members): Group(id: ids(), kind: .all, members: members.map(node))
            case .any(let members): Group(id: ids(), kind: .any, members: members.map(node))
            case .not(.any(let members)): Group(id: ids(), kind: .none, members: members.map(node))
            case .not(.all(let members)):
                Group(id: ids(), kind: .notAll, members: members.map(node))
            default: nil
            }
        }
        func node(_ expression: BooleanExpression<Schema.Term>) -> Node {
            switch expression {
            case .term(let term): .rule(Rule(id: ids(), row: schema.row(for: term)))
            case .not(.term(let term)):
                .rule(Rule(id: ids(), isNegated: true, row: schema.row(for: term)))
            case .not(.not(let inner)): node(inner)
            default:
                // `group` handles every other case: all, any, and not of either.
                .group(group(expression) ?? Group(id: ids()))
            }
        }
        let normalized = expression.normalized
        self.init(
            root: group(normalized) ?? Group(id: ids(), kind: .all, members: [node(normalized)]))
    }

    /// The expression the tree means. Unfinished rules, and groups left with
    /// nothing in them, are left out; what remains is ``BooleanExpression/normalized``.
    public func expression<Schema: RuleSchema>(schema: Schema) -> BooleanExpression<Schema.Term>
    where Schema.Field == Field {
        func expression(of group: Group) -> BooleanExpression<Schema.Term>? {
            let members = group.members.compactMap { node -> BooleanExpression<Schema.Term>? in
                switch node {
                case .rule(let rule):
                    guard let term = schema.term(for: rule.row) else { return nil }
                    return rule.isNegated ? .not(.term(term)) : .term(term)
                case .group(let inner): return expression(of: inner)
                }
            }
            guard !members.isEmpty else { return nil }
            switch group.kind {
            case .all: return .all(members)
            case .any: return .any(members)
            case .none: return .not(.any(members))
            case .notAll: return .not(.all(members))
            }
        }
        return (expression(of: root) ?? .everything).normalized
    }
}

// MARK: - Editing

extension RuleTree {
    /// Adds `rule` after the node `after`, or at the end of group `in`.
    public mutating func insert(_ node: Node, after sibling: UUID) {
        root.insert(node, after: sibling)
    }

    public mutating func append(_ node: Node, to group: UUID) { root.append(node, to: group) }

    /// Removes a rule or a group, with everything in it. The root stays.
    public mutating func remove(_ id: UUID) {
        guard id != root.id else { return }
        root.remove(id)
    }

    public mutating func update(_ rule: Rule) { root.update(rule) }

    public mutating func setKind(_ kind: Kind, of group: UUID) { root.setKind(kind, of: group) }

    public func rule(_ id: UUID) -> Rule? { root.rule(id) }
}

extension RuleTree.Group {
    fileprivate mutating func insert(_ node: RuleTree.Node, after sibling: UUID) {
        if let index = members.firstIndex(where: { $0.id == sibling }) {
            members.insert(node, at: index + 1)
            return
        }
        for index in members.indices {
            if case .group(var inner) = members[index] {
                inner.insert(node, after: sibling)
                members[index] = .group(inner)
            }
        }
    }

    fileprivate mutating func append(_ node: RuleTree.Node, to group: UUID) {
        if id == group {
            members.append(node)
            return
        }
        for index in members.indices {
            if case .group(var inner) = members[index] {
                inner.append(node, to: group)
                members[index] = .group(inner)
            }
        }
    }

    fileprivate mutating func remove(_ target: UUID) {
        members.removeAll { $0.id == target }
        for index in members.indices {
            if case .group(var inner) = members[index] {
                inner.remove(target)
                members[index] = .group(inner)
            }
        }
    }

    fileprivate mutating func update(_ rule: RuleTree.Rule) {
        for index in members.indices {
            switch members[index] {
            case .rule(let existing) where existing.id == rule.id: members[index] = .rule(rule)
            case .group(var inner):
                inner.update(rule)
                members[index] = .group(inner)
            default: break
            }
        }
    }

    fileprivate mutating func setKind(_ kind: RuleTree.Kind, of group: UUID) {
        if id == group {
            self.kind = kind
            return
        }
        for index in members.indices {
            if case .group(var inner) = members[index] {
                inner.setKind(kind, of: group)
                members[index] = .group(inner)
            }
        }
    }

    fileprivate func rule(_ id: UUID) -> RuleTree.Rule? {
        for member in members {
            switch member {
            case .rule(let rule) where rule.id == id: return rule
            case .group(let inner): if let found = inner.rule(id) { return found }
            default: break
            }
        }
        return nil
    }
}
