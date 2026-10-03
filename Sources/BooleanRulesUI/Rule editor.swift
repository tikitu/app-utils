import BooleanRules
import SwiftUI

/// Edits a ``BooleanExpression`` as nested rules, in the manner of Finder's
/// and Mail's rule editors: "Match all of the following", then a row per rule
/// — field, *is / is not*, value — and groups inside groups.
///
/// It binds to the expression, not to its own state: change the expression
/// from elsewhere (a text field, a script) and the rules follow. It keeps a
/// ``RuleTree`` of its own only so that rows keep their identity while they
/// are edited, and so that a rule still being filled in, or grouping the
/// expression would flatten away, survives until it means something.
///
/// A *pinned* expression is shown above the rules, locked: the part of a
/// filter that belongs to the screen rather than to the person — "source is
/// Health" on a screen that only ever shows Health. It is not in the bound
/// expression; what the screen filters by is both, ``BooleanExpression/and(_:)``.
public struct RuleEditor<Schema: RuleSchema>: View {
    @Binding
    var expression: BooleanExpression<Schema.Term>
    let pinned: BooleanExpression<Schema.Term>?
    let schema: Schema

    @State
    private var tree: RuleTree<Schema.Field>?

    public init(
        expression: Binding<BooleanExpression<Schema.Term>>,
        pinned: BooleanExpression<Schema.Term>? = nil, schema: Schema
    ) {
        self._expression = expression
        self.pinned = pinned
        self.schema = schema
    }

    public var body: some View {
        let tree = self.tree ?? RuleTree(expression, schema: schema)
        VStack(alignment: .leading, spacing: 6) {
            if let pinned, pinned.normalized != .everything {
                PinnedRules(expression: pinned, schema: schema)
            }
            GroupEditor(group: tree.root, depth: 0, schema: schema, edit: edit)
        }.onChange(of: expression, initial: true) { _, new in
            // Rebuild only for a change that came from outside. Grouping
            // chosen here that the expression flattens, and rules not yet
            // finished, both compare equal once normalised.
            if self.tree?.expression(schema: schema) != new.normalized {
                self.tree = RuleTree(new, schema: schema)
            }
        }
    }

    private func edit(_ change: (inout RuleTree<Schema.Field>) -> Void) {
        var edited = tree ?? RuleTree(expression, schema: schema)
        change(&edited)
        tree = edited
        let meaning = edited.expression(schema: schema)
        if meaning != expression.normalized { expression = meaning }
    }
}

/// The pinned expression, locked. A pinned *all* — the usual case, one
/// term or a few that must all hold — shows as bare rows, since every row
/// above the editable group is read as also holding; anything else shows as
/// a locked group.
private struct PinnedRules<Schema: RuleSchema>: View {
    typealias Tree = RuleTree<Schema.Field>

    let expression: BooleanExpression<Schema.Term>
    let schema: Schema

    var body: some View {
        let root = Tree(expression, schema: schema).root
        if root.kind == .all {
            ForEach(root.members) { member in PinnedMember(member: member, schema: schema) }
        } else {
            GroupEditor(group: root, depth: 1, schema: schema, isLocked: true)
        }
    }
}

/// One member of a pinned *all*: a locked rule, or a locked group.
private struct PinnedMember<Schema: RuleSchema>: View {
    let member: RuleTree<Schema.Field>.Node
    let schema: Schema

    var body: some View {
        switch member {
        case .rule(let rule): RuleRowEditor(rule: rule, schema: schema, isLocked: true)
        case .group(let group): GroupEditor(group: group, depth: 1, schema: schema, isLocked: true)
        }
    }
}

/// A change to the editor's tree, applied by ``RuleEditor``.
private typealias TreeEdit<Field: Hashable & Sendable> = ((inout RuleTree<Field>) -> Void) -> Void

/// One group: its header, then its members, indented.
private struct GroupEditor<Schema: RuleSchema>: View {
    typealias Tree = RuleTree<Schema.Field>

    let group: Tree.Group
    let depth: Int
    let schema: Schema
    /// Locked groups are shown, not edited: no buttons, and their controls
    /// disabled.
    var isLocked = false
    var edit: TreeEdit<Schema.Field> = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupHeader(
                kind: group.kind, groupID: group.id, isRemovable: depth > 0, isLocked: isLocked,
                schema: schema, edit: edit)
            // Members sit one step in from their group's header, so the
            // nesting reads as a staircase, as in Finder's editor.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.members) { member in
                    switch member {
                    case .rule(let rule):
                        RuleRowEditor(
                            rule: rule, schema: schema, isLocked: isLocked, edit: edit,
                            addRule: { addRule(after: rule.id) })
                    case .group(let inner):
                        // AnyView: a view cannot contain itself by type.
                        AnyView(
                            GroupEditor(
                                group: inner, depth: depth + 1, schema: schema, isLocked: isLocked,
                                edit: edit))
                    }
                }
            }.padding(.leading, 18)
        }
    }

    private func addRule(after id: UUID) {
        guard let rule = schema.newRuleNode() else { return }
        edit { $0.insert(rule, after: id) }
    }
}

/// A group's header: on one line where there is room; where there is not —
/// a phone — the buttons go underneath rather than squeezing the words.
private struct GroupHeader<Schema: RuleSchema>: View {
    let kind: RuleTree<Schema.Field>.Kind
    let groupID: UUID
    let isRemovable: Bool
    let isLocked: Bool
    let schema: Schema
    let edit: TreeEdit<Schema.Field>

    var body: some View {
        let match = GroupMatch(kind: kind, groupID: groupID, isLocked: isLocked, edit: edit)
        let buttons = GroupButtons(
            groupID: groupID, isRemovable: isRemovable, isLocked: isLocked, schema: schema,
            edit: edit)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                match
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 6) {
                match
                HStack(spacing: 6) { buttons }
            }
        }.controlSize(.small)
    }
}

/// "Match all/any of the following".
private struct GroupMatch<Field: Hashable & Sendable>: View {
    typealias Tree = RuleTree<Field>

    let kind: Tree.Kind
    let groupID: UUID
    let isLocked: Bool
    let edit: TreeEdit<Field>

    var body: some View {
        HStack(spacing: 6) {
            Text("Match")
            Picker(
                "Match",
                selection: Binding(
                    get: { kind }, set: { kind in edit { $0.setKind(kind, of: groupID) } })
            ) { ForEach(Tree.Kind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) } }
            .labelsHidden().fixedSize().disabled(isLocked)
            Text("of the following")
        }
    }
}

/// A group's buttons, or its lock.
private struct GroupButtons<Schema: RuleSchema>: View {
    typealias Tree = RuleTree<Schema.Field>

    let groupID: UUID
    let isRemovable: Bool
    let isLocked: Bool
    let schema: Schema
    let edit: TreeEdit<Schema.Field>

    var body: some View {
        if isLocked {
            LockMark()
        } else {
            // Words, not icons: a group's buttons are about the group, and
            // the round − and + beside every rule are about that rule.
            Button("Add Rule") { appendRule() }.help("Add a rule to this group")
            Button("Add Group") { appendGroup() }.help("Add a group of rules inside this one")
            if isRemovable {
                RoundButton(systemImage: "minus", help: "Remove this group and its rules") {
                    edit { $0.remove(groupID) }
                }
            }
        }
    }

    private func appendRule() {
        guard let rule = schema.newRuleNode() else { return }
        edit { $0.append(rule, to: groupID) }
    }

    /// A new group starts as "any" with one rule: grouping is almost always
    /// for an *or* inside an *and*.
    private func appendGroup() {
        let members = schema.newRuleNode().map { [$0] } ?? []
        edit {
            $0.append(.group(Tree.Group(id: UUID(), kind: .any, members: members)), to: groupID)
        }
    }
}

extension RuleSchema {
    /// A new rule for an editor's tree, if the schema has a field to start from.
    fileprivate func newRuleNode() -> RuleTree<Field>.Node? {
        newRow().map { .rule(RuleTree<Field>.Rule(id: UUID(), row: $0)) }
    }
}

/// One rule: field, comparison, value, and its − and + buttons.
private struct RuleRowEditor<Schema: RuleSchema>: View {
    typealias Tree = RuleTree<Schema.Field>

    let rule: Tree.Rule
    let schema: Schema
    var isLocked = false
    var edit: TreeEdit<Schema.Field> = { _ in }
    var addRule: () -> Void = {}

    /// On one line where there is room. Where there is not — a phone — the
    /// value goes on a line of its own, where a typed value has room to be
    /// read.
    var body: some View {
        let fieldAndComparison = RuleFieldAndComparison(
            field: binding(\.row.field), isNegated: binding(\.isNegated), isLocked: isLocked,
            schema: schema)
        let buttons = RuleButtons(ruleID: rule.id, isLocked: isLocked, edit: edit, addRule: addRule)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                fieldAndComparison
                value
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    fieldAndComparison
                    Spacer(minLength: 8)
                    buttons
                }
                value
            }
        }.controlSize(.small)
    }

    @ViewBuilder
    private var value: some View {
        switch schema.values(of: rule.row.field) {
        case .none: EmptyView()
        case .text(let prompt):
            TextField("Value", text: binding(\.row.value), prompt: Text(prompt)).textFieldStyle(
                .roundedBorder
            ).frame(minWidth: 80, maxWidth: 220).disabled(isLocked)
        case .choice(let choices):
            Picker("Value", selection: binding(\.row.value)) {
                ForEach(choices) { choice in Text(choice.title).tag(choice.value) }
                if !choices.contains(where: { $0.value == rule.row.value }) {
                    Divider()
                    Text(rule.row.value.isEmpty ? "Choose…" : "“\(rule.row.value)”").tag(
                        rule.row.value)
                }
            }.labelsHidden().fixedSize().disabled(isLocked)
        }
    }

    /// Changing the field resets the value to the new field's default: a
    /// language code means nothing as a gender.
    private func binding<Value>(_ keyPath: WritableKeyPath<Tree.Rule, Value>) -> Binding<Value> {
        Binding(
            get: { rule[keyPath: keyPath] },
            set: { value in
                edit { tree in
                    guard var current = tree.rule(rule.id) else { return }
                    let field = current.row.field
                    current[keyPath: keyPath] = value
                    if current.row.field != field {
                        current.row.value = schema.defaultValue(of: current.row.field)
                    }
                    tree.update(current)
                }
            })
    }
}

/// A rule's field and its *is / is not*.
private struct RuleFieldAndComparison<Schema: RuleSchema>: View {
    @Binding
    var field: Schema.Field
    @Binding
    var isNegated: Bool
    let isLocked: Bool
    let schema: Schema

    var body: some View {
        Picker("Field", selection: $field) {
            ForEach(schema.fields, id: \.self) { field in Text(schema.title(of: field)).tag(field) }
        }.labelsHidden().fixedSize().disabled(isLocked)
        let comparison = schema.comparison(of: field)
        Picker("Comparison", selection: $isNegated) {
            Text(comparison.positive).tag(false)
            Text(comparison.negative).tag(true)
        }.labelsHidden().fixedSize().disabled(isLocked)
    }
}

/// A rule's − and +, or its lock.
private struct RuleButtons<Field: Hashable & Sendable>: View {
    let ruleID: UUID
    let isLocked: Bool
    let edit: TreeEdit<Field>
    let addRule: () -> Void

    var body: some View {
        if isLocked {
            LockMark()
        } else {
            RoundButton(systemImage: "minus", help: "Remove this rule") {
                edit { $0.remove(ruleID) }
            }
            RoundButton(systemImage: "plus", help: "Add a rule after this one", action: addRule)
        }
    }
}

/// The round − and + of a rule editor. Bordered, with a whole circle to hit:
/// a borderless "minus" symbol is a two-point line, and a click a little
/// above or below it missed.
private struct RoundButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: systemImage).frame(width: 10, height: 10) }
            .buttonStyle(.bordered).buttonBorderShape(.circle).help(help).accessibilityLabel(help)
    }
}

/// Where a locked row's − and + would be: says why the row cannot be
/// changed, rather than leaving disabled controls to explain themselves.
private struct LockMark: View {
    var body: some View {
        Image(systemName: "lock.fill").foregroundStyle(.secondary).help(
            "Part of this view's filter; it cannot be changed here"
        ).accessibilityLabel("Locked: part of this view's filter")
    }
}
