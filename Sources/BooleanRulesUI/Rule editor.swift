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
public struct RuleEditor<Schema: RuleSchema>: View {
    @Binding
    var expression: BooleanExpression<Schema.Term>
    let schema: Schema

    @State
    private var tree: RuleTree<Schema.Field>?

    public init(expression: Binding<BooleanExpression<Schema.Term>>, schema: Schema) {
        self._expression = expression
        self.schema = schema
    }

    public var body: some View {
        let tree = self.tree ?? RuleTree(expression, schema: schema)
        GroupEditor(group: tree.root, depth: 0, schema: schema, edit: edit).onChange(
            of: expression, initial: true
        ) { _, new in
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

/// One group: its header, then its members, indented.
private struct GroupEditor<Schema: RuleSchema>: View {
    typealias Tree = RuleTree<Schema.Field>

    let group: Tree.Group
    let depth: Int
    let schema: Schema
    let edit: ((inout Tree) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // Members sit one step in from their group's header, so the
            // nesting reads as a staircase, as in Finder's editor.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.members) { member in
                    switch member {
                    case .rule(let rule):
                        RuleRowEditor(
                            rule: rule, schema: schema, edit: edit,
                            addRule: { addRule(after: rule.id) })
                    case .group(let inner):
                        // AnyView: a view cannot contain itself by type.
                        AnyView(
                            GroupEditor(group: inner, depth: depth + 1, schema: schema, edit: edit))
                    }
                }
            }.padding(.leading, 18)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Match")
            Picker(
                "Match",
                selection: Binding(
                    get: { group.kind }, set: { kind in edit { $0.setKind(kind, of: group.id) } })
            ) { ForEach(Tree.Kind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) } }
            .labelsHidden().fixedSize()
            Text("of the following")
            Spacer(minLength: 8)
            // Words, not icons: a group's buttons are about the group, and
            // the round − and + beside every rule are about that rule.
            Button("Add Rule") { appendRule() }.help("Add a rule to this group")
            Button("Add Group") { appendGroup() }.help("Add a group of rules inside this one")
            if depth > 0 {
                RoundButton(systemImage: "minus", help: "Remove this group and its rules") {
                    edit { $0.remove(group.id) }
                }
            }
        }.controlSize(.small)
    }

    private func newRule() -> Tree.Node? {
        schema.newRow().map { .rule(Tree.Rule(id: UUID(), row: $0)) }
    }

    private func addRule(after id: UUID) {
        guard let rule = newRule() else { return }
        edit { $0.insert(rule, after: id) }
    }

    private func appendRule() {
        guard let rule = newRule() else { return }
        edit { $0.append(rule, to: group.id) }
    }

    /// A new group starts as "any" with one rule: grouping is almost always
    /// for an *or* inside an *and*.
    private func appendGroup() {
        let members = newRule().map { [$0] } ?? []
        edit {
            $0.append(.group(Tree.Group(id: UUID(), kind: .any, members: members)), to: group.id)
        }
    }
}

/// One rule: field, comparison, value, and its − and + buttons.
private struct RuleRowEditor<Schema: RuleSchema>: View {
    typealias Tree = RuleTree<Schema.Field>

    let rule: Tree.Rule
    let schema: Schema
    let edit: ((inout Tree) -> Void) -> Void
    let addRule: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("Field", selection: binding(\.row.field)) {
                ForEach(schema.fields, id: \.self) { field in
                    Text(schema.title(of: field)).tag(field)
                }
            }.labelsHidden().fixedSize()
            let comparison = schema.comparison(of: rule.row.field)
            Picker("Comparison", selection: binding(\.isNegated)) {
                Text(comparison.positive).tag(false)
                Text(comparison.negative).tag(true)
            }.labelsHidden().fixedSize()
            value
            Spacer(minLength: 8)
            RoundButton(systemImage: "minus", help: "Remove this rule") {
                edit { $0.remove(rule.id) }
            }
            RoundButton(systemImage: "plus", help: "Add a rule after this one", action: addRule)
        }.controlSize(.small)
    }

    @ViewBuilder
    private var value: some View {
        switch schema.values(of: rule.row.field) {
        case .none: EmptyView()
        case .text(let prompt):
            TextField("Value", text: binding(\.row.value), prompt: Text(prompt)).textFieldStyle(
                .roundedBorder
            ).frame(minWidth: 80, maxWidth: 220)
        case .choice(let choices):
            Picker("Value", selection: binding(\.row.value)) {
                ForEach(choices) { choice in Text(choice.title).tag(choice.value) }
                if !choices.contains(where: { $0.value == rule.row.value }) {
                    Divider()
                    Text(rule.row.value.isEmpty ? "Choose…" : "“\(rule.row.value)”").tag(
                        rule.row.value)
                }
            }.labelsHidden().fixedSize()
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
