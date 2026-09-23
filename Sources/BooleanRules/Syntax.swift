/// A term that can be written as text: `lang:en`, `is:novelty`, `eddy`.
///
/// Conform your term type, and ``BooleanExpression`` gains
/// ``BooleanExpression/parse(_:)`` and a `description` in this syntax:
///
///     filter  := term ( ("and"? term)* | ("or" term)* )
///     term    := ("not" | "!" | "-") term | "(" filter ")" | field ":" value | value
///     value   := word | "quoted string"          (\" and \\ escape)
///
/// **There is no precedence.** One level holds *and*s or *or*s, never both:
/// `a b or c` is an error asking for parentheses, not a guess. Terms side by
/// side are joined by *and*, as in a search box. `not` takes the one term or
/// group after it. The keywords are case-insensitive.
public protocol BooleanTerm {
    /// Reads one term: `field` is what came before the colon, if anything,
    /// lowercased; `value` is after it, unquoted. Throw ``TermError`` with a
    /// message for the reader — "There is no field “colour”" — and the
    /// parser adds where it happened.
    static func read(field: String?, value: String) throws(TermError) -> Self

    /// The term as text that ``read(field:value:)`` reads back. Use
    /// ``BooleanSyntax/written(field:value:)`` to get the quoting right.
    var written: String { get }
}

/// Why a term does not read. The parser supplies the position.
public struct TermError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Why a filter's text does not parse, and where.
public struct BooleanSyntaxError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// The character offset the problem starts at.
    public var offset: Int

    public init(message: String, offset: Int) {
        self.message = message
        self.offset = offset
    }

    public var description: String { message }
}

/// Helpers for writing terms.
public enum BooleanSyntax {
    /// `field:value`, quoting the value if it would not read back as one word.
    /// With no field, a bare value — quoted also if it is a keyword or holds a
    /// colon, which would otherwise read as something else.
    public static func written(field: String?, value: String) -> String {
        guard let field else {
            let isKeyword = ["and", "or", "not"].contains(value.lowercased())
            return isKeyword || value.contains(":") ? forceQuoted(value) : quoted(value)
        }
        return "\(field):\(quoted(value))"
    }

    /// As it is, when it reads back as one word; quoted otherwise.
    public static func quoted(_ value: String) -> String {
        let plain =
            !value.isEmpty
            && !value.contains {
                $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "\"" || $0 == "\\"
            } && value.first != "-" && value.first != "!"
        return plain ? value : forceQuoted(value)
    }

    static func forceQuoted(_ value: String) -> String {
        var escaped = ""
        for c in value {
            if c == "\\" || c == "\"" { escaped.append("\\") }
            escaped.append(c)
        }
        return "\"" + escaped + "\""
    }
}

// MARK: - Parsing

extension BooleanExpression where Term: BooleanTerm {
    /// Reads an expression. Empty text is ``everything``. The result is
    /// ``normalized``.
    public static func parse(_ text: String) throws(BooleanSyntaxError) -> Self {
        var parser = Parser<Term>(tokens: try Tokenizer.tokens(in: text), end: text.count)
        guard !parser.isAtEnd else { return .everything }
        let expression = try parser.expression()
        if let extra = parser.peek {
            throw BooleanSyntaxError(
                message: extra.kind == .close
                    ? "There is a ) with no ( to match it." : "Unexpected \(extra.kind.shown).",
                offset: extra.offset)
        }
        return expression.normalized
    }
}

struct Token: Equatable {
    enum Kind: Equatable {
        case open, close, not, and, or
        case term(field: String?, value: String)

        var shown: String {
            switch self {
            case .open: "("
            case .close: ")"
            case .not: "not"
            case .and: "and"
            case .or: "or"
            case .term(let field, let value): field.map { "\($0):\(value)" } ?? value
            }
        }
    }
    var kind: Kind
    var offset: Int
}

enum Tokenizer {
    static func tokens(in text: String) throws(BooleanSyntaxError) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0

        func isWordCharacter(_ c: Character) -> Bool {
            !c.isWhitespace && c != "(" && c != ")" && c != "\""
        }

        func quoted() throws(BooleanSyntaxError) -> String {
            let start = index
            index += 1
            var value = ""
            while index < characters.count {
                let c = characters[index]
                if c == "\\", index + 1 < characters.count {
                    value.append(characters[index + 1])
                    index += 2
                } else if c == "\"" {
                    index += 1
                    return value
                } else {
                    value.append(c)
                    index += 1
                }
            }
            throw BooleanSyntaxError(message: "This quote is never closed.", offset: start)
        }

        while index < characters.count {
            let c = characters[index]
            let start = index
            if c.isWhitespace {
                index += 1
            } else if c == "(" {
                tokens.append(Token(kind: .open, offset: start))
                index += 1
            } else if c == ")" {
                tokens.append(Token(kind: .close, offset: start))
                index += 1
            } else if c == "!"
                || (c == "-" && index + 1 < characters.count && !characters[index + 1].isWhitespace)
            {
                tokens.append(Token(kind: .not, offset: start))
                index += 1
            } else if c == "\"" {
                tokens.append(Token(kind: .term(field: nil, value: try quoted()), offset: start))
            } else {
                var word = ""
                while index < characters.count, isWordCharacter(characters[index]),
                    characters[index] != ":"
                {
                    word.append(characters[index])
                    index += 1
                }
                if index < characters.count, characters[index] == ":" {
                    index += 1
                    let value: String
                    if index < characters.count, characters[index] == "\"" {
                        value = try quoted()
                    } else {
                        var bare = ""
                        while index < characters.count, isWordCharacter(characters[index]) {
                            bare.append(characters[index])
                            index += 1
                        }
                        value = bare
                    }
                    tokens.append(
                        Token(kind: .term(field: word.lowercased(), value: value), offset: start))
                } else {
                    let kind: Token.Kind =
                        switch word.lowercased() {
                        case "and": .and
                        case "or": .or
                        case "not": .not
                        default: .term(field: nil, value: word)
                        }
                    tokens.append(Token(kind: kind, offset: start))
                }
            }
        }
        return tokens
    }
}

struct Parser<Term: BooleanTerm> {
    let tokens: [Token]
    /// The text's length, for errors at the end.
    let end: Int
    var position = 0

    init(tokens: [Token], end: Int) {
        self.tokens = tokens
        self.end = end
    }

    var peek: Token? { position < tokens.count ? tokens[position] : nil }
    var isAtEnd: Bool { peek == nil }

    mutating func expression() throws(BooleanSyntaxError) -> BooleanExpression<Term> {
        var members = [try term()]
        var joiner: Token.Kind?
        while let next = peek, next.kind != .close {
            let kind: Token.Kind
            if next.kind == .and || next.kind == .or {
                kind = next.kind
                position += 1
            } else {
                kind = .and  // side by side
            }
            if let joiner, joiner != kind {
                throw BooleanSyntaxError(
                    message:
                        "This mixes “and” with “or”. Add parentheses to say which comes first, e.g. (a and b) or c.",
                    offset: next.offset)
            }
            joiner = kind
            members.append(try term())
        }
        guard members.count > 1 else { return members[0] }
        return joiner == .or ? .any(members) : .all(members)
    }

    mutating func term() throws(BooleanSyntaxError) -> BooleanExpression<Term> {
        guard let token = peek else {
            throw BooleanSyntaxError(message: "Something is missing at the end.", offset: end)
        }
        position += 1
        switch token.kind {
        case .not: return .not(try term())
        case .open:
            if peek?.kind == .close {
                throw BooleanSyntaxError(
                    message: "These parentheses are empty.", offset: token.offset)
            }
            let inner = try expression()
            guard peek?.kind == .close else {
                throw BooleanSyntaxError(message: "This ( is never closed.", offset: token.offset)
            }
            position += 1
            return inner
        case .close:
            throw BooleanSyntaxError(
                message: "There is a ) with no ( to match it.", offset: token.offset)
        case .and, .or:
            throw BooleanSyntaxError(
                message: "“\(token.kind.shown)” needs something on each side.", offset: token.offset
            )
        case .term(let field, let value):
            do { return .term(try Term.read(field: field, value: value)) } catch {
                throw BooleanSyntaxError(message: error.message, offset: token.offset)
            }
        }
    }
}

// MARK: - Printing

extension BooleanExpression: CustomStringConvertible where Term: BooleanTerm {
    /// The canonical text: spaces for *and*, `or`, `not`, parentheses only
    /// where they are needed. ``parse(_:)`` reads it back to the same
    /// (normalised) expression.
    public var description: String { printed(inside: nil) }

    private enum Context { case all, any, not }

    private func printed(inside context: Context?) -> String {
        switch self {
        case .term(let term): return term.written
        case .not(let inner): return "not " + inner.printed(inside: .not)
        case .all(let members):
            let text = members.map { $0.printed(inside: .all) }.joined(separator: " ")
            return members.count > 1 && context != nil && context != .all ? "(\(text))" : text
        case .any(let members):
            let text = members.map { $0.printed(inside: .any) }.joined(separator: " or ")
            return members.count > 1 && context != nil ? "(\(text))" : text
        }
    }
}
