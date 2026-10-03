/// A boolean combination of terms: *and*, *or* and *not* over whatever a
/// `Term` is — a predicate about a voice, a mail message, a file.
///
/// The library knows nothing about terms except how to combine them. What a
/// term means, how it is written and how it is edited are the caller's: see
/// ``BooleanTerm`` for the text syntax and ``RuleSchema`` for the rule
/// editor.
public indirect enum BooleanExpression<Term> {
    case term(Term)
    case not(BooleanExpression)
    /// Every one holds. Empty holds for everything.
    case all([BooleanExpression])
    /// At least one holds. Empty holds for nothing.
    case any([BooleanExpression])

    /// Holds for everything: the empty filter.
    public static var everything: Self { .all([]) }
}

extension BooleanExpression: Equatable where Term: Equatable {}
extension BooleanExpression: Hashable where Term: Hashable {}
extension BooleanExpression: Sendable where Term: Sendable {}

extension BooleanExpression {
    /// Whether the expression holds, given whether each term does.
    public func evaluate(_ holds: (Term) throws -> Bool) rethrows -> Bool {
        switch self {
        case .term(let term): try holds(term)
        case .not(let inner): try !inner.evaluate(holds)
        case .all(let inner): try inner.allSatisfy { try $0.evaluate(holds) }
        case .any(let inner): try inner.contains { try $0.evaluate(holds) }
        }
    }

    public func map<Other>(_ transform: (Term) throws -> Other) rethrows -> BooleanExpression<Other>
    {
        switch self {
        case .term(let term): .term(try transform(term))
        case .not(let inner): .not(try inner.map(transform))
        case .all(let inner): .all(try inner.map { try $0.map(transform) })
        case .any(let inner): .any(try inner.map { try $0.map(transform) })
        }
    }

    /// The same expression with the structure that does not change its
    /// meaning taken out: a group inside a group of the same kind is spliced
    /// in (`(a b) c` is `a b c`), a group of one is its member, and a double
    /// negation cancels.
    ///
    /// Two expressions that normalise equal mean the same thing *by
    /// structure*; this is not a solver, and `a or not a` stays as it is. It
    /// is what the parser produces and what the rule editor compares with, so
    /// that grouping someone chose in the editor is not mistaken for a change.
    public var normalized: Self {
        switch self {
        case .term: return self
        case .not(let inner):
            let inner = inner.normalized
            if case .not(let twice) = inner { return twice }
            return .not(inner)
        case .all(let members):
            let flat = members.map(\.normalized).flatMap { member -> [Self] in
                if case .all(let inner) = member { return inner }
                return [member]
            }
            return flat.count == 1 ? flat[0] : .all(flat)
        case .any(let members):
            let flat = members.map(\.normalized).flatMap { member -> [Self] in
                if case .any(let inner) = member { return inner }
                return [member]
            }
            return flat.count == 1 ? flat[0] : .any(flat)
        }
    }
}

extension BooleanExpression {
    /// Both this and `other`: how a pinned part of a filter and the part a
    /// person edits combine. Normalised, so pinning nothing changes nothing.
    public func and(_ other: Self) -> Self { Self.all([self, other]).normalized }
}
