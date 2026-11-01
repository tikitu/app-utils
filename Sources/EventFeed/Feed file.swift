import Foundation
import SQLite3
import notify

/// Where feeds live and how a change is announced. The library's, so every
/// writer and reader agrees.
public enum FeedConventions {
    /// The Darwin notification a writer posts after appending.
    public static let changedNotification = "org.logophile.feed.changed"
    /// The directory feeds live in, inside the directory an app passes (an
    /// App Group container, or any directory).
    public static let directoryName = "Feeds"
    /// The newest `feed_meta.schema` this library writes and reads.
    public static let schema = 1
    /// `feed_meta.writer` in files this library creates.
    public static let writer = "app-utils EventFeed 0.6.0"

    /// `<base>/Feeds`.
    public static func directory(in base: URL) -> URL {
        base.appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// `<base>/Feeds/<bundle>.sqlite`: named by the writer's bundle id, so
    /// two installs of one app under different bundle ids never share one.
    public static func file(bundle: String, in base: URL) -> URL {
        directory(in: base).appending(path: "\(bundle).sqlite", directoryHint: .notDirectory)
    }

    /// Every feed file in `<base>/Feeds`, by name; none if it does not exist.
    public static func files(in base: URL) -> [URL] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory(in: base), includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "sqlite" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    /// Posts ``changedNotification``.
    public static func post() { notify_post(changedNotification) }
}

/// `feed_meta`, written once when the file is created.
public struct FeedMeta: Equatable, Sendable {
    public let schema: Int
    /// The source app's name for itself, as readers know it.
    public let source: String
    /// The writer's bundle id; also the file's name.
    public let bundle: String
    /// The library and version that created the file.
    public let writer: String
}

public enum FeedError: Error, Equatable, CustomStringConvertible {
    case couldNotOpen(path: String, String)
    case sqlFailed(code: Int32, String)
    /// The file's schema is newer than this library knows.
    case newerSchema(found: Int, known: Int)
    /// The file is not a feed this library can read.
    case notAFeed(String)
    /// The file at this bundle's path was made for another source or bundle.
    case belongsToAnother(expected: String, found: String)
    /// ``FeedWriter/add(inEffect:)`` takes events, not retractions.
    case retractionPassedToAdd(UUID)
    /// A row whose stored text is not what the library writes.
    case corruptRow(id: String, column: String)

    public var description: String {
        switch self {
        case .couldNotOpen(let path, let message): "could not open feed \(path): \(message)"
        case .sqlFailed(let code, let message): "feed SQL failed (\(code)): \(message)"
        case .newerSchema(let found, let known):
            "feed schema \(found) is newer than this library knows (\(known))"
        case .notAFeed(let reason): "not a feed: \(reason)"
        case .belongsToAnother(let expected, let found): "feed belongs to \(found), not \(expected)"
        case .retractionPassedToAdd(let id):
            "\(id.uuidString) is a retraction; use retract(removed:recordedAt:zone:)"
        case .corruptRow(let id, let column): "feed row \(id) has an unreadable \(column)"
        }
    }
}

/// Schema version 1, verbatim. A writer recreates a file whose schema is not
/// exactly this.
enum FeedSchema {
    static let tables: [(name: String, sql: String)] = [
        (
            "feed_events",
            """
            CREATE TABLE feed_events (
              id          TEXT PRIMARY KEY NOT NULL,
              kind        TEXT NOT NULL,
              subject     TEXT,
              occurred_at TEXT,
              recorded_at TEXT NOT NULL,
              zone        TEXT,
              retracts    TEXT,
              payload     TEXT NOT NULL DEFAULT '{}',
              CHECK ((retracts IS NULL) = (kind != 'retraction')),
              CHECK ((retracts IS NULL) = (occurred_at IS NOT NULL))
            ) STRICT
            """
        ),
        (
            "feed_meta",
            "CREATE TABLE feed_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) STRICT"
        ),
        (
            "feed_subjects",
            """
            CREATE TABLE feed_subjects (
              id      TEXT PRIMARY KEY NOT NULL,
              subject TEXT NOT NULL,
              name    TEXT NOT NULL,
              since   TEXT NOT NULL
            ) STRICT
            """
        ),
    ]

    static let eventColumns = "id, kind, subject, occurred_at, recorded_at, zone, retracts, payload"
    static let subjectColumns = "id, subject, name, since"

    /// The file's tables and their SQL, by name, without SQLite's own
    /// automatic indexes.
    static func objects(in connection: SQLiteConnection) throws(FeedError) -> [String: String] {
        let rows = try connection.rows(
            "SELECT name, sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name")
        var objects: [String: String] = [:]
        for row in rows { if let name = row[0].text { objects[name] = row[1].text } }
        return objects
    }

    static func meta(in connection: SQLiteConnection) throws(FeedError) -> FeedMeta {
        var values: [String: String] = [:]
        for row in try connection.rows("SELECT key, value FROM feed_meta") {
            if let key = row[0].text, let value = row[1].text { values[key] = value }
        }
        guard let schemaText = values["schema"], let schema = Int(schemaText) else {
            throw .notAFeed("feed_meta has no schema")
        }
        if schema > FeedConventions.schema {
            throw .newerSchema(found: schema, known: FeedConventions.schema)
        }
        guard let source = values["source"], let bundle = values["bundle"],
            let writer = values["writer"]
        else { throw .notAFeed("feed_meta is incomplete") }
        return FeedMeta(schema: schema, source: source, bundle: bundle, writer: writer)
    }

    static func event(_ row: [SQLValue]) throws(FeedError) -> FeedEvent {
        let idText = row[0].text ?? ""
        func column(_ name: String) -> FeedError { .corruptRow(id: idText, column: name) }
        guard let id = UUID(uuidString: idText) else { throw column("id") }
        guard let kind = row[1].text else { throw column("kind") }
        guard let recordedAt = row[4].text.flatMap(FeedTime.date) else {
            throw column("recorded_at")
        }
        var occurredAt: Date?
        if let text = row[3].text {
            guard let date = FeedTime.date(text) else { throw column("occurred_at") }
            occurredAt = date
        }
        var retracts: UUID?
        if let text = row[6].text {
            guard let uuid = UUID(uuidString: text) else { throw column("retracts") }
            retracts = uuid
        }
        guard let payloadText = row[7].text,
            let payload = try? JSONDecoder().decode(
                [String: String].self, from: Data(payloadText.utf8))
        else { throw column("payload") }
        return FeedEvent(
            id: id, kind: kind, subject: row[2].text, occurredAt: occurredAt,
            recordedAt: recordedAt, zone: row[5].text, retracts: retracts, payload: payload)
    }

    static func subject(_ row: [SQLValue]) throws(FeedError) -> FeedSubject {
        let idText = row[0].text ?? ""
        guard let id = UUID(uuidString: idText), let subject = row[1].text, let name = row[2].text,
            let since = row[3].text.flatMap(FeedTime.date)
        else { throw .corruptRow(id: idText, column: "feed_subjects") }
        return FeedSubject(id: id, subject: subject, name: name, since: since)
    }
}
