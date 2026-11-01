import Foundation

/// One row of `feed_events`: an event from the source, or a retraction of
/// one.
///
/// Every value is frozen: the source never edits it in place. Identity is
/// derived over all of them, so a source row whose content changes becomes
/// a *different* feed event, and the old one is retracted by the source's
/// write path (``FeedWriter/retract(removed:recordedAt:zone:)``). Dates are
/// held at the millisecond the feed stores.
public struct FeedEvent: Hashable, Sendable {
    /// The kind every retraction has, and no other event may.
    public static let retractionKind = "retraction"

    public let id: UUID
    /// The source app's vocabulary, or ``retractionKind``.
    public let kind: String
    /// The source's stable id of the thing the event is about.
    public let subject: String?
    /// When it happened; `nil` exactly on a retraction.
    public let occurredAt: Date?
    /// When the source wrote it down.
    public let recordedAt: Date
    /// `TimeZone.identifier` where it was recorded; `nil` if the source has
    /// none. Never invented.
    public let zone: String?
    /// On a retraction, the feed id it retracts.
    public let retracts: UUID?
    /// Frozen source columns, as strings.
    public let payload: [String: String]

    /// An event from the source, its id derived from where it came from
    /// (`source`, the source `table`, the source row's own `rowID`) and
    /// everything it carries. `kind` must not be ``retractionKind``. Pass
    /// the dates as the source stores them, read back from its store, not
    /// an in-memory value with more precision than the store keeps (see
    /// `docs/EventFeed.md`, Time).
    public init(
        source: String, table: String, rowID: String, kind: String, subject: String?,
        occurredAt: Date, recordedAt: Date, zone: String?, payload: [String: String] = [:]
    ) {
        precondition(kind != Self.retractionKind, "a retraction is made with retraction(of:…)")
        let key = CanonicalJSON.array([
            .string(source), .string(table), .string(rowID), .string(kind),
            subject.map(CanonicalJSON.Value.string) ?? .null, .string(FeedTime.text(occurredAt)),
            .string(FeedTime.text(recordedAt)), zone.map(CanonicalJSON.Value.string) ?? .null,
            .object(payload),
        ])
        self.init(
            id: stableIdentifier(from: key), kind: kind, subject: subject,
            occurredAt: FeedTime.normalized(occurredAt),
            recordedAt: FeedTime.normalized(recordedAt), zone: zone, retracts: nil, payload: payload
        )
    }

    /// The retraction of feed event `retracted`. Its id depends only on the
    /// source and what it retracts, so retracting one id twice is one row.
    public static func retraction(
        source: String, of retracted: UUID, recordedAt: Date, zone: String?
    ) -> FeedEvent {
        FeedEvent(
            id: retractionID(source: source, of: retracted), kind: retractionKind, subject: nil,
            occurredAt: nil, recordedAt: FeedTime.normalized(recordedAt), zone: zone,
            retracts: retracted, payload: [:])
    }

    static func retractionID(source: String, of retracted: UUID) -> UUID {
        stableIdentifier(from: "\(source)/retracts/\(retracted.uuidString)")
    }

    init(
        id: UUID, kind: String, subject: String?, occurredAt: Date?, recordedAt: Date,
        zone: String?, retracts: UUID?, payload: [String: String]
    ) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.zone = zone
        self.retracts = retracts
        self.payload = payload
    }

    public var isRetraction: Bool { retracts != nil }
}

/// One row of `feed_subjects`: a version of a subject's name. Names change;
/// a version never does. The newest `since` wins, ties broken by `id`.
public struct FeedSubject: Hashable, Sendable {
    public let id: UUID
    public let subject: String
    public let name: String
    /// The source's own edit time for this name.
    public let since: Date

    init(source: String, subject: String, name: String, since: Date) {
        let key = CanonicalJSON.array([
            .string(source), .string("subject"), .string(subject), .string(FeedTime.text(since)),
            .string(name),
        ])
        self.init(
            id: stableIdentifier(from: key), subject: subject, name: name,
            since: FeedTime.normalized(since))
    }

    init(id: UUID, subject: String, name: String, since: Date) {
        self.id = id
        self.subject = subject
        self.name = name
        self.since = since
    }
}

/// The fold: which events are no longer in effect.
public enum Retractions {
    /// The rows no longer in effect, given every retraction as
    /// `(id, retracts)`. A row is in effect unless a retraction in effect
    /// names it. No order is needed, so a retraction that arrives before its
    /// target hides it from the start. A retraction names only a row that
    /// existed when it was written, so chains never loop.
    public static func retracted(_ retractions: [(id: UUID, retracts: UUID)]) -> Set<UUID> {
        let retractionsOf = Dictionary(grouping: retractions, by: \.retracts)
        var inEffect: [UUID: Bool] = [:]
        func isInEffect(_ row: UUID) -> Bool {
            if let known = inEffect[row] { return known }
            let result = !(retractionsOf[row] ?? []).contains { isInEffect($0.id) }
            inEffect[row] = result
            return result
        }
        return Set(retractionsOf.keys.filter { !isInEffect($0) })
    }

    /// ``retracted(_:)`` over feed events: the retractions among them.
    public static func retracted(_ events: some Sequence<FeedEvent>) -> Set<UUID> {
        retracted(events.compactMap { event in event.retracts.map { (event.id, $0) } })
    }
}
