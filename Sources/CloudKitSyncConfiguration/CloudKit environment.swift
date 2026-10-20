import Foundation
import OSLog

/// A CloudKit environment, spelled as the
/// `com.apple.developer.icloud-container-environment` entitlement spells it.
public enum CloudKitEnvironment: String, Sendable, CaseIterable {
    case development = "Development"
    case production = "Production"
}

extension CloudKitEnvironment {
    /// Whether the sync state on disk belongs to the environment this build
    /// syncs against.
    ///
    /// **Why this exists.** SQLiteData keeps the sync state (the engine's
    /// change tokens, and per row the last record the server confirmed) in a
    /// *metadatabase* beside the database. Its name carries the container but
    /// not the environment, so a build entitled to Production restores the
    /// state Development left behind. With that state every table counts as
    /// already seen, existing rows are never uploaded, and Production fills
    /// only with edits made from then on. Silently partial.
    ///
    /// So a marker file beside the metadatabase records the environment its
    /// state belongs to, and ``prepare(databaseURL:sync:)`` compares it with
    /// the build's before the database is opened:
    ///
    /// - equal: nothing to do, beyond writing the marker if it is missing;
    /// - Development moving to Production: **the planned move**. The
    ///   metadatabase is deleted, so SQLiteData sees every table as new and
    ///   uploads every row. The database itself is never touched;
    /// - anything else: **sync is refused**. A move back to Development would
    ///   re-upload every row into a database that has them, and conflict
    ///   handling could overwrite newer local edits. That move is its own
    ///   plan.
    ///
    /// A metadatabase with no marker beside it was made before the app had
    /// one, so which environment it belongs to is the app's history, and
    /// ``unmarkedMetadatabase`` says. Get it wrong towards Development and a
    /// Production build re-uploads every row; towards Production and a
    /// Production build keeps Development's state, the silent partial upload
    /// above.
    ///
    /// The build declares its environment as `infoPlistKey` in `Info.plist`,
    /// set from the entitlement, never typed a second time.
    public struct Check: Sendable {
        /// The `Info.plist` key naming the build's environment,
        /// `<App>CloudKitEnvironment` by convention.
        public let infoPlistKey: String
        /// The container the sync engine is made for: part of the
        /// metadatabase's name.
        public let containerIdentifier: String
        /// Which environment a metadatabase with no marker belongs to.
        public let unmarkedMetadatabase: CloudKitEnvironment
        let logger: Logger

        public init(
            infoPlistKey: String, containerIdentifier: String,
            unmarkedMetadatabase: CloudKitEnvironment, loggerSubsystem: String
        ) {
            self.infoPlistKey = infoPlistKey
            self.containerIdentifier = containerIdentifier
            self.unmarkedMetadatabase = unmarkedMetadatabase
            self.logger = Logger(subsystem: loggerSubsystem, category: "CloudKitEnvironment")
        }

        /// What this build's `Info.plist` says, verbatim: an unrecognised
        /// value is refused rather than guessed at.
        public var declared: String? {
            Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
        }

        /// Checks the sync state on disk against the build, and resets it for
        /// the planned move. Returns why sync must not start, or `nil`.
        ///
        /// Call before the database is opened: the metadatabase is attached to
        /// the database's connection, and deleting it under an open connection
        /// would leave SQLite writing to an unlinked file.
        ///
        /// Does nothing for a build that cannot sync (`sync.isEnabled` false):
        /// nothing is read, written or deleted on its behalf. Never throws: the
        /// database must open whatever happens here, and a failure refuses
        /// sync instead.
        public func prepare(databaseURL: URL, sync: SyncConfiguration) -> String? {
            guard sync.isEnabled else { return nil }
            guard case .refused(let reason) = check(databaseURL: databaseURL, declared: declared)
            else { return nil }
            logger.error("sync refused: \(reason, privacy: .public)")
            return reason
        }

        /// What ``check(databaseURL:declared:fileManager:)`` did.
        enum Outcome: Equatable {
            /// The state on disk belongs to this environment.
            case unchanged
            /// The marker was absent; it now names this environment.
            case marked(CloudKitEnvironment)
            /// The planned move: these files were deleted, then the marker
            /// written.
            case reset(deleted: [String])
            case refused(String)
        }

        /// The decision, from what is on disk. Separate from the side effects
        /// so that every combination can be tested.
        enum Decision: Equatable {
            case unchanged
            case mark(CloudKitEnvironment)
            case reset
            case refuse(String)
        }

        func decide(declared: String?, marker: String?, metadatabaseExists: Bool) -> Decision {
            guard let declared else { return .refuse("the build declares no \(infoPlistKey)") }
            guard let build = CloudKitEnvironment(rawValue: declared) else {
                return .refuse(
                    "the build declares \(infoPlistKey) = \"\(declared)\", which is not an environment"
                )
            }
            let onDisk: CloudKitEnvironment?
            if let marker {
                guard let parsed = CloudKitEnvironment(rawValue: marker) else {
                    return .refuse(
                        "the environment marker says \"\(marker)\", which is not an environment")
                }
                onDisk = parsed
            } else {
                onDisk = metadatabaseExists ? unmarkedMetadatabase : nil
            }
            switch (onDisk, build) {
            case (nil, _): return .mark(build)
            // Written down even though nothing changes, so that what the state
            // belongs to can be read off the device rather than inferred.
            case (let disk?, _) where disk == build:
                return marker == nil ? .mark(build) : .unchanged
            case (.development, .production): return .reset
            case (let disk?, _):
                return .refuse(
                    "the sync state belongs to \(disk.rawValue) and this build is \(build.rawValue); "
                        + "moving back is not automatic")
            }
        }

        /// Reads the disk, decides, and acts. The metadatabase is deleted
        /// **before** the marker is written: interrupted between the two, the
        /// next launch finds no metadatabase and no marker, and marks a fresh
        /// start. The other order could leave a Production marker beside
        /// Development's state, which is the silent partial upload this exists
        /// to prevent.
        func check(
            databaseURL: URL, declared: String?, fileManager: FileManager = .default
        ) -> Outcome {
            let markerURL = markerURL(databaseURL: databaseURL)
            let metadatabaseFiles = metadatabaseURLs(databaseURL: databaseURL).filter {
                fileManager.fileExists(atPath: $0.path(percentEncoded: false))
            }
            do {
                let marker: String? =
                    fileManager.fileExists(atPath: markerURL.path(percentEncoded: false))
                    ? try String(contentsOf: markerURL, encoding: .utf8).trimmingCharacters(
                        in: .whitespacesAndNewlines) : nil

                switch decide(
                    declared: declared, marker: marker,
                    metadatabaseExists: !metadatabaseFiles.isEmpty)
                {
                case .unchanged: return .unchanged
                case .mark(let environment):
                    try write(environment, to: markerURL)
                    logger.notice("sync state marked \(environment.rawValue, privacy: .public)")
                    return .marked(environment)
                case .reset:
                    for file in metadatabaseFiles { try fileManager.removeItem(at: file) }
                    try write(.production, to: markerURL)
                    let deleted = metadatabaseFiles.map(\.lastPathComponent)
                    logger.notice(
                        "moved to Production: deleted \(deleted.joined(separator: ", "), privacy: .public)"
                    )
                    return .reset(deleted: deleted)
                case .refuse(let reason): return .refused(reason)
                }
            } catch { return .refused("checking the sync state failed: \(error)") }
        }

        private func write(_ environment: CloudKitEnvironment, to url: URL) throws {
            try Data(environment.rawValue.utf8).write(to: url, options: .atomic)
        }

        /// SQLiteData's metadatabase, for the database at `databaseURL`, and
        /// the SQLite files that go with it.
        ///
        /// The name is SQLiteData's
        /// (`URL.metadatabase(databasePath:containerIdentifier:)`, `package`
        /// access, so not callable from here): a dot, the database's name
        /// without extension, `.metadata-`, the container, `.sqlite`. A test
        /// pins it; if SQLiteData ever renames it, this must follow, or the
        /// reset deletes nothing and reports success.
        func metadatabaseURLs(databaseURL: URL) -> [URL] {
            let directory = databaseURL.deletingLastPathComponent()
            let name =
                ".\(databaseURL.deletingPathExtension().lastPathComponent)"
                + ".metadata-\(containerIdentifier).sqlite"
            return ["", "-wal", "-shm"].map { directory.appending(path: name + $0) }
        }

        /// The marker beside the metadatabase, naming the environment its
        /// state belongs to.
        func markerURL(databaseURL: URL) -> URL {
            databaseURL.deletingLastPathComponent().appending(
                path: ".\(databaseURL.deletingPathExtension().lastPathComponent)"
                    + ".metadata-\(containerIdentifier).environment")
        }
    }
}
