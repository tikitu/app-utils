import Foundation
import SQLite3

/// The one writer of one app's feed. Appends, and never updates or deletes.
///
/// It adds rows two ways: ``add(inEffect:)``, for the events the source has
/// now, and ``retract(removed:recordedAt:zone:)``,
/// ``restore(_:recordedAt:zone:)`` and ``replace(removed:with:recordedAt:zone:)``
/// for a change the source's own write path reports. It never retracts by comparing the
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
    /// A file that is not a database, fails SQLite's integrity check, or has
    /// any schema but this library's is deleted and created again. A file
    /// with a newer schema, made for another source or bundle, or that
    /// cannot be opened now (permissions, data protection, busy) is left
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

    /// Makes feed event `removed` no longer in effect, because the caller's
    /// own write path reports it removed (deleted, or about to be edited).
    /// Returns the retraction that now retracts it: the one appended, or the
    /// one already in effect, in which case nothing is appended.
    ///
    /// A retraction's id depends only on what it retracts, so an id has one
    /// chain of retractions: its retraction, that one's retraction (a
    /// restore), and so on. This appends at the end of the chain, so delete,
    /// restore, delete again appends three rows and leaves the event
    /// retracted. `recordedAt` and `zone` are the source's own where it
    /// records a removal, and otherwise the moment and zone of the removal
    /// on the one device it was made on.
    @discardableResult
    public func retract(
        removed: UUID, recordedAt: Date, zone: String?
    ) throws(FeedError) -> FeedEvent {
        try connection.transaction { () throws(FeedError) in
            try retractInTransaction(removed, recordedAt: recordedAt, zone: zone)
        }
    }

    /// Puts a retracted feed event `restored` back in effect, because the
    /// caller's own write path reports it back (an undone delete), by
    /// retracting the retraction in effect over it. Returns the retraction
    /// that now restores it, or `nil` if it was never retracted; nothing is
    /// appended unless it was retracted. `recordedAt` and `zone` as for
    /// ``retract(removed:recordedAt:zone:)``.
    @discardableResult
    public func restore(
        _ restored: UUID, recordedAt: Date, zone: String?
    ) throws(FeedError) -> FeedEvent? {
        try connection.transaction { () throws(FeedError) in
            try restoreInTransaction(restored, recordedAt: recordedAt, zone: zone)
        }
    }

    /// An edit of a frozen column, in one transaction: retracts `removed`,
    /// adds `replacement`, and restores `replacement` if the feed had it
    /// retracted, so editing A to B and back to A leaves A in effect.
    public func replace(
        removed: UUID, with replacement: FeedEvent, recordedAt: Date, zone: String?
    ) throws(FeedError) {
        if replacement.isRetraction { throw .retractionPassedToAdd(replacement.id) }
        try connection.transaction { () throws(FeedError) in
            try retractInTransaction(removed, recordedAt: recordedAt, zone: zone)
            try insert(replacement)
            try restoreInTransaction(replacement.id, recordedAt: recordedAt, zone: zone)
        }
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
    private func retractInTransaction(
        _ removed: UUID, recordedAt: Date, zone: String?
    ) throws(FeedError) -> FeedEvent {
        let chain = try retractionChain(of: removed)
        // An odd chain ends in a retraction in effect over `removed`.
        if chain.count % 2 == 1, let last = chain.last { return last }
        return try appendRetraction(
            of: chain.last?.id ?? removed, recordedAt: recordedAt, zone: zone)
    }

    @discardableResult
    private func restoreInTransaction(
        _ restored: UUID, recordedAt: Date, zone: String?
    ) throws(FeedError) -> FeedEvent? {
        let chain = try retractionChain(of: restored)
        guard let last = chain.last else { return nil }
        if chain.count % 2 == 0 { return last }
        return try appendRetraction(of: last.id, recordedAt: recordedAt, zone: zone)
    }

    /// The retractions of `id`, of that retraction, and so on, as far as the
    /// feed has them. The fold makes `id` in effect exactly when the chain's
    /// length is even.
    private func retractionChain(of id: UUID) throws(FeedError) -> [FeedEvent] {
        var chain: [FeedEvent] = []
        var current = id
        while true {
            let next = FeedEvent.retractionID(source: source, of: current)
            guard
                let row = try connection.rows(
                    "SELECT \(FeedSchema.eventColumns) FROM feed_events WHERE id = ? AND retracts = ?",
                    [.text(next.uuidString), .text(current.uuidString)]
                ).first
            else { return chain }
            chain.append(try FeedSchema.event(row))
            current = next
        }
    }

    private func appendRetraction(
        of id: UUID, recordedAt: Date, zone: String?
    ) throws(FeedError) -> FeedEvent {
        let retraction = FeedEvent.retraction(
            source: source, of: id, recordedAt: recordedAt, zone: zone)
        try insert(retraction)
        return retraction
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
    /// A file that cannot be opened at this moment is not damage: a locked
    /// device's data protection or a permission would otherwise delete a
    /// healthy feed and the retractions in it.
    private static func isReplaceable(_ error: FeedError) -> Bool {
        switch error {
        case .notAFeed: true
        case .sqlFailed(let code, _): [SQLITE_CORRUPT, SQLITE_NOTADB].contains(code & 0xFF)
        case .couldNotOpen, .newerSchema, .belongsToAnother, .retractionPassedToAdd, .corruptRow:
            false
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
