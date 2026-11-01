import Foundation
import SQLite3

/// The one writer of one app's feed. Appends, and never updates or deletes.
///
/// It has two ways to add a row: ``add(inEffect:)``, for the events the
/// source has now, and ``retract(removed:recordedAt:zone:)``, for a removal
/// the source's own write path reports. It never retracts by comparing the
/// feed with the source: a source that is empty or partial (a reinstall, a
/// bug) would become a mass retraction. ``differences(inEffect:)`` reports
/// that comparison and changes nothing.
///
/// Not `Sendable`: a connection belongs to whoever opened it.
public final class FeedWriter {
    public let url: URL
    /// The source name every event's id is derived with.
    public let source: String
    public let bundle: String
    /// Whether opening found a corrupt or unreadable file and replaced it
    /// with an empty feed. The feed is a projection: adding what is in
    /// effect rebuilds it, less the retractions it held.
    public let recreated: Bool
    private let connection: SQLiteConnection

    /// Opens, or creates, `<base>/Feeds/<bundle>.sqlite`.
    ///
    /// A file that cannot be opened, fails SQLite's integrity check, or has
    /// any schema but this library's is deleted and created again. A file
    /// with a newer schema, or made for another source or bundle, is left
    /// alone and the open throws.
    public init(base: URL, source: String, bundle: String) throws(FeedError) {
        precondition(!source.isEmpty && !source.contains("/"), "a source name has no slash")
        self.url = FeedConventions.file(bundle: bundle, in: base)
        self.source = source
        self.bundle = bundle
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { throw .couldNotOpen(path: url.path, error.localizedDescription) }
        let expected = FeedMeta(
            schema: FeedConventions.schema, source: source, bundle: bundle,
            writer: FeedConventions.writer)
        do {
            connection = try Self.open(url, expecting: expected)
            recreated = false
        } catch let error where Self.isReplaceable(error) {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            connection = try Self.open(url, expecting: expected)
            recreated = true
        }
    }

    /// Appends the events the feed lacks, in one transaction, and returns
    /// how many. The source's events in effect now, each with its derived
    /// id; adding them again adds nothing.
    @discardableResult
    public func add(inEffect events: [FeedEvent]) throws(FeedError) -> Int {
        if let retraction = events.first(where: \.isRetraction) {
            throw .retractionPassedToAdd(retraction.id)
        }
        return try connection.transaction { () throws(FeedError) in
            var added = 0
            for event in events { added += try insert(event) }
            return added
        }
    }

    /// Appends the retraction of feed event `removed`, which the caller's
    /// own write path reports as removed (deleted, or about to be edited),
    /// and returns it; retracting an id again appends nothing. `recordedAt`
    /// and `zone` are the source's own where it records a removal, and
    /// otherwise the moment and zone of the removal on the one device it
    /// was made on.
    @discardableResult
    public func retract(
        removed: UUID, recordedAt: Date, zone: String?
    ) throws(FeedError) -> FeedEvent {
        let retraction = FeedEvent.retraction(
            source: source, of: removed, recordedAt: recordedAt, zone: zone)
        try insert(retraction)
        return retraction
    }

    /// Appends a version of `subject`'s name, unless that exact version is
    /// there. Returns whether it appended.
    @discardableResult
    public func name(subject: String, name: String, since: Date) throws(FeedError) -> Bool {
        let version = FeedSubject(source: source, subject: subject, name: name, since: since)
        return try connection.run(
            """
            INSERT INTO feed_subjects (\(FeedSchema.subjectColumns)) VALUES (?, ?, ?, ?)
            ON CONFLICT (id) DO NOTHING
            """,
            [
                .text(version.id.uuidString), .text(subject), .text(name),
                .text(FeedTime.text(version.since)),
            ]) == 1
    }

    /// Posts ``FeedConventions/changedNotification``, for readers to look.
    public func post() { FeedConventions.post() }

    /// Compares the feed with the events the source has in effect, for a
    /// diagnostic the app shows. Changes nothing: what to retract is the
    /// owner's call, made through ``retract(removed:recordedAt:zone:)``.
    public func differences(inEffect events: [FeedEvent]) throws(FeedError) -> FeedDifferences {
        var feed: [FeedEvent] = []
        for row in try connection.rows("SELECT \(FeedSchema.eventColumns) FROM feed_events") {
            feed.append(try FeedSchema.event(row))
        }
        let retracted = Retractions.retracted(feed)
        let rows = Set(feed.filter { !$0.isRetraction }.map(\.id))
        let inEffect = rows.subtracting(retracted)
        let supplied = Set(events.map(\.id))
        func sorted(_ ids: Set<UUID>) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
        return FeedDifferences(
            onlyInFeed: sorted(inEffect.subtracting(supplied)),
            onlySupplied: sorted(supplied.subtracting(rows)),
            suppliedButRetracted: sorted(supplied.intersection(retracted)))
    }

    @discardableResult
    private func insert(_ event: FeedEvent) throws(FeedError) -> Int {
        try connection.run(
            """
            INSERT INTO feed_events (\(FeedSchema.eventColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO NOTHING
            """,
            [
                .text(event.id.uuidString), .text(event.kind), SQLValue(event.subject),
                SQLValue(event.occurredAt.map(FeedTime.text)),
                .text(FeedTime.text(event.recordedAt)), SQLValue(event.zone),
                SQLValue(event.retracts?.uuidString), .text(CanonicalJSON.object(event.payload)),
            ])
    }

    private static func open(
        _ url: URL, expecting expected: FeedMeta
    ) throws(FeedError) -> SQLiteConnection {
        let connection = try SQLiteConnection(
            path: url.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try connection.execute("PRAGMA busy_timeout=5000;")
        try connection.execute("PRAGMA journal_mode=WAL;")
        let check = try connection.rows("PRAGMA quick_check;")
        guard check == [[.text("ok")]] else { throw .notAFeed("quick_check failed") }

        let objects = try FeedSchema.objects(in: connection)
        if objects.isEmpty {
            try connection.transaction { () throws(FeedError) in
                for table in FeedSchema.tables { try connection.execute(table.sql + ";") }
                for (key, value) in [
                    ("schema", String(expected.schema)), ("source", expected.source),
                    ("bundle", expected.bundle), ("writer", expected.writer),
                ] {
                    try connection.run(
                        "INSERT INTO feed_meta (key, value) VALUES (?, ?)",
                        [.text(key), .text(value)])
                }
            }
            return connection
        }
        // The schema number first: a newer file is not ours to replace.
        let meta: FeedMeta?
        do { meta = try FeedSchema.meta(in: connection) } catch {
            if case .newerSchema = error { throw error }
            meta = nil
        }
        let ours = Dictionary(uniqueKeysWithValues: FeedSchema.tables.map { ($0.name, $0.sql) })
        guard objects == ours, let meta else { throw .notAFeed("not this library's schema") }
        guard meta.source == expected.source, meta.bundle == expected.bundle else {
            throw .belongsToAnother(
                expected: "\(expected.source) (\(expected.bundle))",
                found: "\(meta.source) (\(meta.bundle))")
        }
        return connection
    }

    /// Damage, not someone else's file: worth replacing with an empty feed.
    private static func isReplaceable(_ error: FeedError) -> Bool {
        switch error {
        case .couldNotOpen, .notAFeed, .corruptRow: true
        case .sqlFailed(let code, _):
            [SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CANTOPEN].contains(code & 0xFF)
        case .newerSchema, .belongsToAnother, .retractionPassedToAdd: false
        }
    }
}

/// What ``FeedWriter/differences(inEffect:)`` found, ids sorted.
public struct FeedDifferences: Equatable, Sendable {
    /// Feed events in effect that no supplied event has: removals whose
    /// retraction never ran, or a source that is empty or partial.
    public let onlyInFeed: [UUID]
    /// Supplied events the feed has no row for: ``FeedWriter/add(inEffect:)``
    /// has not run since they were made.
    public let onlySupplied: [UUID]
    /// Supplied events whose row the feed has retracted: a restore whose
    /// retraction of the retraction never ran.
    public let suppliedButRetracted: [UUID]
}
