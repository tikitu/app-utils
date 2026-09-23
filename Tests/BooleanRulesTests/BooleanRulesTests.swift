import Foundation
import Testing

@testable import BooleanRules

/// A term for testing: a bare word, or `colour:red`. The only field is
/// `colour`, so errors from the term reader can be tested too.
enum Toy: Equatable, BooleanTerm {
    case word(String)
    case colour(String)

    static func read(field: String?, value: String) throws(TermError) -> Toy {
        switch field {
        case nil: return .word(value)
        case "colour":
            guard !value.isEmpty else { throw TermError("colour: needs a value.") }
            return .colour(value)
        case let other?: throw TermError("There is no field “\(other)”.")
        }
    }

    var written: String {
        switch self {
        case .word(let value): BooleanSyntax.written(field: nil, value: value)
        case .colour(let value): BooleanSyntax.written(field: "colour", value: value)
        }
    }
}

typealias Expr = BooleanExpression<Toy>

func w(_ word: String) -> Expr { .term(.word(word)) }

@Suite
struct Parsing {
    @Test
    func `empty is everything`() throws {
        #expect(try Expr.parse("") == .everything)
        #expect(try Expr.parse("  ") == .everything)
    }

    @Test
    func `side by side is and; or; not; parentheses`() throws {
        #expect(try Expr.parse("a b") == .all([w("a"), w("b")]))
        #expect(try Expr.parse("a AND b") == .all([w("a"), w("b")]))
        #expect(try Expr.parse("a or b") == .any([w("a"), w("b")]))
        #expect(try Expr.parse("(a or b) -c") == .all([.any([w("a"), w("b")]), .not(w("c"))]))
        #expect(try Expr.parse("not !a") == w("a"))
    }

    @Test
    func `fields and quoting`() throws {
        #expect(
            try Expr.parse(#"colour:"dark red" "two words" "12:30""#)
                == .all([.term(.colour("dark red")), w("two words"), w("12:30")]))
        #expect(try Expr.parse(#""a \"b\" c""#) == w(#"a "b" c"#))
    }

    @Test
    func `groups of the same kind flatten`() throws {
        #expect(try Expr.parse("(a b) c") == .all([w("a"), w("b"), w("c")]))
        #expect(try Expr.parse("((a))") == w("a"))
    }

    @Test(arguments: [
        ("a b or c", 4, "mixes"), ("a or b and c", 7, "mixes"), ("(a", 0, "never closed"),
        ("a)", 1, "no ( to match"), ("()", 0, "empty"), ("or a", 0, "each side"),
        ("a and", 5, "missing at the end"), (#""a"#, 0, "quote is never closed"),
        ("size:big", 0, "no field “size”"), ("x colour:", 2, "needs a value"),
    ])
    func `errors say what and where`(text: String, offset: Int, message: String) {
        #expect { try Expr.parse(text) } throws: { error in
            guard let error = error as? BooleanSyntaxError else { return false }
            return error.offset == offset && error.message.contains(message)
        }
    }
}

@Suite
struct Printing {
    @Test(arguments: [
        "a b", "a or b", "(a or b) c", "a or (b c)", "not (a or b)", "not (a b)", "not a",
        #"colour:"dark red" "or" ":x" "-y""#, "(a or not (b c)) d",
    ])
    func `canonical text round-trips`(text: String) throws {
        let expression = try Expr.parse(text)
        #expect(expression.description == text)
        #expect(try Expr.parse(expression.description) == expression)
    }
}

@Suite
struct Evaluating {
    @Test
    func `evaluates with the caller's meaning of a term`() throws {
        let holds: (Toy) -> Bool = { $0 == .word("a") }
        #expect(try Expr.parse("a").evaluate(holds))
        #expect(try !Expr.parse("a b").evaluate(holds))
        #expect(try Expr.parse("a or b").evaluate(holds))
        #expect(try Expr.parse("not (b or c)").evaluate(holds))
        #expect(Expr.everything.evaluate(holds))
        #expect(!Expr.any([]).evaluate(holds))
    }
}

/// A schema for the toy: fields "word" (typed) and "colour" (a menu).
struct ToySchema: RuleSchema {
    enum Field: String, Hashable, Sendable { case word, colour }
    var fields: [Field] { [.word, .colour] }
    func title(of field: Field) -> String { field.rawValue }
    func values(of field: Field) -> RuleValues {
        field == .word
            ? .text(prompt: "word")
            : .choice([
                RuleChoice(value: "red", title: "Red"), RuleChoice(value: "blue", title: "Blue"),
            ])
    }
    func defaultValue(of field: Field) -> String { field == .colour ? "red" : "" }
    func row(for term: Toy) -> RuleRow<Field> {
        switch term {
        case .word(let value): RuleRow(field: .word, value: value)
        case .colour(let value): RuleRow(field: .colour, value: value)
        }
    }
    func term(for row: RuleRow<Field>) -> Toy? {
        guard !row.value.isEmpty else { return nil }
        return row.field == .word ? .word(row.value) : .colour(row.value)
    }
}

@Suite
struct RuleTrees {
    let schema = ToySchema()

    @Test(arguments: [
        "", "a", "not a", "a b", "a or b", "not (a or b)", "not (a b)", "(a or not b) c",
        "(a or (b not (c or colour:red))) d",
    ])
    func `every expression has a tree that means it`(text: String) throws {
        let expression = try Expr.parse(text)
        let tree = RuleTree(expression, schema: schema)
        #expect(tree.expression(schema: schema) == expression)
    }

    @Test
    func `groups show as all, any, none and not all, and rules as is / is not`() throws {
        let tree = RuleTree(try Expr.parse("not (a or -b) not (c d)"), schema: schema)
        #expect(tree.root.kind == .all)
        guard case .group(let none) = tree.root.members[0],
            case .group(let notAll) = tree.root.members[1], case .rule(let b) = none.members[1]
        else {
            Issue.record("unexpected shape: \(tree)")
            return
        }
        #expect(none.kind == .none)
        #expect(notAll.kind == .notAll)
        #expect(b.isNegated && b.row == RuleRow(field: .word, value: "b"))
    }

    @Test
    func `unfinished rules and empty groups are left out, not matched against`() throws {
        var tree = RuleTree(try Expr.parse("a"), schema: schema)
        let a = tree.root.members[0].id
        tree.insert(.rule(.init(id: UUID(), row: RuleRow(field: .word, value: ""))), after: a)
        tree.append(.group(.init(id: UUID(), kind: .any)), to: tree.root.id)
        #expect(tree.expression(schema: schema) == w("a"))
    }

    @Test
    func `grouping chosen in the editor survives, and means the same once normalised`() throws {
        var tree = RuleTree(try Expr.parse("a"), schema: schema)
        let inner = UUID()
        tree.append(
            .group(
                .init(
                    id: inner, kind: .all,
                    members: [.rule(.init(id: UUID(), row: .init(field: .word, value: "b")))])),
            to: tree.root.id)
        tree.append(.rule(.init(id: UUID(), row: .init(field: .word, value: "c"))), to: inner)
        #expect(tree.root.members.count == 2)  // still a group in the tree
        #expect(tree.expression(schema: schema) == .all([w("a"), w("b"), w("c")]))
    }

    @Test
    func `editing: remove, update, kind, and the root stays`() throws {
        var tree = RuleTree(try Expr.parse("a (b or c)"), schema: schema)
        guard case .group(let group) = tree.root.members[1] else {
            Issue.record("no group")
            return
        }
        tree.setKind(.none, of: group.id)
        #expect(tree.expression(schema: schema).description == "a not (b or c)")

        var b = try #require(tree.rule(group.members[0].id))
        b.isNegated = true
        b.row = RuleRow(field: .colour, value: "blue")
        tree.update(b)
        #expect(tree.expression(schema: schema).description == "a not (not colour:blue or c)")

        tree.remove(group.members[1].id)
        #expect(tree.expression(schema: schema).description == "a colour:blue")

        tree.remove(group.id)
        tree.remove(tree.root.id)
        #expect(tree.expression(schema: schema).description == "a")
    }
}
