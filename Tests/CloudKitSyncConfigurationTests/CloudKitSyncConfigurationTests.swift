import Foundation
import Testing

@testable import CloudKitSyncConfiguration

// MARK: - Sync configuration

/// The guard in front of a call that traps rather than throwing: a false
/// positive is a crash on launch, not a missing feature.
@Suite
struct SyncConfigurationTests {
    @Test
    func `the simulator is recognised by its own environment`() {
        // Tests run on the Mac, where CoreSimulator has set nothing.
        #expect(SyncConfiguration.isSimulator == false)
    }

    @Test
    func `a build that declares nothing does not sync`() {
        // The test bundle has no such key: the path taken by any build that
        // forgets it.
        let sync = SyncConfiguration(infoPlistKey: "MyAppSyncEnabled")
        #expect(sync.declaresSyncEnabled == false)
        #expect(sync.isEnabled == false)
    }
}

// MARK: - The decision

func check(unmarked: CloudKitEnvironment = .development) -> CloudKitEnvironment.Check {
    CloudKitEnvironment.Check(
        infoPlistKey: "MyAppCloudKitEnvironment", containerIdentifier: "iCloud.com.example.MyApp",
        unmarkedMetadatabase: unmarked, loggerSubsystem: "CloudKitSyncConfigurationTests")
}

func expectRefusal(_ decision: CloudKitEnvironment.Check.Decision) {
    guard case .refuse = decision else {
        Issue.record("expected a refusal, got \(decision)")
        return
    }
}

@Suite
struct CloudKitEnvironmentDecisionTests {
    @Test(arguments: [true, false])
    func `the same environment changes nothing`(metadatabaseExists: Bool) {
        for environment in ["Development", "Production"] {
            #expect(
                check().decide(
                    declared: environment, marker: environment,
                    metadatabaseExists: metadatabaseExists) == .unchanged)
        }
    }

    @Test(arguments: CloudKitEnvironment.allCases)
    func `a fresh start is marked`(build: CloudKitEnvironment) {
        for unmarked in CloudKitEnvironment.allCases {
            #expect(
                check(unmarked: unmarked).decide(
                    declared: build.rawValue, marker: nil, metadatabaseExists: false)
                    == .mark(build))
        }
    }

    // MARK: Unmarked state is Development (an app that moved to Production
    // after the marker existed)

    @Test
    func `unmarked Development state is kept by a Development build`() {
        #expect(
            check(unmarked: .development).decide(
                declared: "Development", marker: nil, metadatabaseExists: true)
                == .mark(.development))
    }

    @Test
    func `unmarked Development state is reset by a Production build`() {
        #expect(
            check(unmarked: .development).decide(
                declared: "Production", marker: nil, metadatabaseExists: true) == .reset)
    }

    // MARK: Unmarked state is Production (an app that synced against
    // Production before it had the marker)

    @Test
    func `unmarked Production state is kept by a Production build`() {
        #expect(
            check(unmarked: .production).decide(
                declared: "Production", marker: nil, metadatabaseExists: true) == .mark(.production)
        )
    }

    @Test
    func `unmarked Production state is refused to a Development build`() {
        expectRefusal(
            check(unmarked: .production).decide(
                declared: "Development", marker: nil, metadatabaseExists: true))
    }

    // MARK: Marked state

    @Test(arguments: [true, false])
    func `marked Development moving to Production is reset`(metadatabaseExists: Bool) {
        #expect(
            check().decide(
                declared: "Production", marker: "Development",
                metadatabaseExists: metadatabaseExists) == .reset)
    }

    /// An old development build installed after the move.
    @Test(arguments: [true, false])
    func `Production back to Development is refused`(metadatabaseExists: Bool) {
        expectRefusal(
            check().decide(
                declared: "Development", marker: "Production",
                metadatabaseExists: metadatabaseExists))
    }

    @Test(arguments: [nil, "", "production", "Sandbox"] as [String?])
    func `an undeclared or unknown build is refused`(declared: String?) {
        expectRefusal(check().decide(declared: declared, marker: nil, metadatabaseExists: false))
    }

    @Test
    func `an unreadable marker is refused`() {
        expectRefusal(
            check().decide(declared: "Production", marker: "garbage", metadatabaseExists: true))
    }
}

// MARK: - On disk

@Suite
struct CloudKitEnvironmentDiskTests {
    let directory: URL
    let database: URL

    init() throws {
        directory = URL.temporaryDirectory.appending(
            path: "cloudkit-environment-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appending(path: "MyApp.sqlite")
    }

    var marker: URL { check().markerURL(databaseURL: database) }
    var metadatabase: [URL] { check().metadatabaseURLs(databaseURL: database) }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func touch(_ urls: [URL]) throws { for url in urls { try Data("x".utf8).write(to: url) } }

    /// The name SQLiteData gives the metadatabase. If this changes, the reset
    /// deletes nothing.
    @Test
    func `the metadatabase is named as SQLiteData names it`() {
        #expect(
            metadatabase.map(\.lastPathComponent) == [
                ".MyApp.metadata-iCloud.com.example.MyApp.sqlite",
                ".MyApp.metadata-iCloud.com.example.MyApp.sqlite-wal",
                ".MyApp.metadata-iCloud.com.example.MyApp.sqlite-shm",
            ])
        #expect(marker.lastPathComponent == ".MyApp.metadata-iCloud.com.example.MyApp.environment")
    }

    @Test
    func `the move deletes the metadatabase and marks Production`() throws {
        try touch(metadatabase)
        try Data("db".utf8).write(to: database)

        let outcome = check().check(databaseURL: database, declared: "Production")

        #expect(outcome == .reset(deleted: metadatabase.map(\.lastPathComponent)))
        #expect(metadatabase.allSatisfy { !exists($0) })
        #expect(try contents(marker) == "Production")
        // The data itself is never touched.
        #expect(try contents(database) == "db")
    }

    /// A move interrupted after the deletion and before the marker is the same
    /// as a fresh start. (The other order is the failure this prevents.)
    @Test
    func `a move interrupted before the marker is a fresh start`() throws {
        #expect(
            check().check(databaseURL: database, declared: "Production") == .marked(.production))
        #expect(try contents(marker) == "Production")
    }

    @Test
    func `a Development build marks existing state and keeps it`() throws {
        try touch(metadatabase)

        let outcome = check().check(databaseURL: database, declared: "Development")

        #expect(outcome == .marked(.development))
        #expect(metadatabase.allSatisfy(exists))
        #expect(try contents(marker) == "Development")
    }

    @Test
    func `marked Development state is reset by a Production build`() throws {
        try touch(metadatabase)
        _ = check().check(databaseURL: database, declared: "Development")

        let outcome = check().check(databaseURL: database, declared: "Production")

        #expect(outcome == .reset(deleted: metadatabase.map(\.lastPathComponent)))
        #expect(metadatabase.allSatisfy { !exists($0) })
        #expect(try contents(marker) == "Production")
    }

    /// An app whose metadatabase predates the marker and was always Production
    /// keeps its state: re-uploading every row is what this parameter avoids.
    @Test
    func `unmarked Production state is kept and marked`() throws {
        try touch(metadatabase)

        let outcome = check(unmarked: .production).check(
            databaseURL: database, declared: "Production")

        #expect(outcome == .marked(.production))
        #expect(metadatabase.allSatisfy(exists))
        #expect(try contents(marker) == "Production")
    }

    @Test
    func `the move happens once`() throws {
        try touch(metadatabase)
        _ = check().check(databaseURL: database, declared: "Production")
        // SQLiteData makes a fresh metadatabase, which must then be kept.
        try touch(metadatabase)

        #expect(check().check(databaseURL: database, declared: "Production") == .unchanged)
        #expect(metadatabase.allSatisfy(exists))
    }

    @Test
    func `going back refuses and deletes nothing`() throws {
        try touch(metadatabase)
        try Data("Production".utf8).write(to: marker)

        let outcome = check().check(databaseURL: database, declared: "Development")

        guard case .refused = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(metadatabase.allSatisfy(exists))
        #expect(try contents(marker) == "Production")
    }

    @Test
    func `a marker with a trailing newline is read`() throws {
        try touch(metadatabase)
        try Data("Production\n".utf8).write(to: marker)

        #expect(check().check(databaseURL: database, declared: "Production") == .unchanged)
    }

    /// A build that cannot sync reads, writes and deletes nothing.
    @Test
    func `prepare does nothing for a build that cannot sync`() throws {
        try touch(metadatabase)

        let refusal = check().prepare(
            databaseURL: database, sync: SyncConfiguration(infoPlistKey: "MyAppSyncEnabled"))

        #expect(refusal == nil)
        #expect(metadatabase.allSatisfy(exists))
        #expect(!exists(marker))
    }
}
