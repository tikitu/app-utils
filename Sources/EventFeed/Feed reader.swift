import Foundation
import SQLite3

/// A feed, opened read-only. It never writes, so a reader can open a feed
/// another app is appending to.
public final class FeedReader {
    public let url: URL
    public let meta: FeedMeta
    private let connection: SQLiteConnection

    /// Opens the feed at `url`. Throws ``FeedError/newerSchema(found:known:)``
    /// for a file written by a newer version of the format, before reading
    /// anything else.
    public init(url: URL) throws(FeedError) {
        self.url = url
        connection = try SQLiteConnection(path: url.path, flags: SQLITE_OPEN_READONLY)
        try connection.execute("PRAGMA busy_timeout=5000;")
        meta = try FeedSchema.meta(in: connection)
    }

    /// Every event and retraction, in the order they were appended. The
    /// order is a hint, never a watermark: read the whole feed every time.
    public func events() throws(FeedError) -> [FeedEvent] {
        var events: [FeedEvent] = []
        for row in try connection.rows(
            "SELECT \(FeedSchema.eventColumns) FROM feed_events ORDER BY rowid")
        { events.append(try FeedSchema.event(row)) }
        return events
    }

    /// Every name version, in the order they were appended.
    public func subjects() throws(FeedError) -> [FeedSubject] {
        var subjects: [FeedSubject] = []
        for row in try connection.rows(
            "SELECT \(FeedSchema.subjectColumns) FROM feed_subjects ORDER BY rowid")
        { subjects.append(try FeedSchema.subject(row)) }
        return subjects
    }
}
