import Foundation
import OSLog
import notify

/// Runs commands handed to the app from outside, so a script can drive it
/// without clicks and without taking focus.
///
/// A sender writes `inbox.json` into ``directory``, then posts the Darwin
/// notification ``notificationName``. app-tooling's `command-inbox` pattern
/// has the sender, `scripts/command-inbox-send.sh`.
/// The inbox removes the file, runs its commands in order, stopping at the
/// first failure, and writes `result.json` beside it once the last has
/// finished, however long it waited. An inbox already waiting when
/// ``start()`` is called runs then.
///
/// The app decides when to start it, and must never start it on real data:
/// a command must not act on what someone is working with.
@MainActor
public final class CommandInbox<Command: InboxCommand> {
    public let directory: URL
    public let notificationName: String

    private let decoder: JSONDecoder
    private let readyTimeout: Duration
    private let isReady: @MainActor () throws -> Bool
    private let snapshot: (@MainActor () async throws -> [URL])?
    private let perform: @MainActor (Command) async throws -> CommandReply
    private var isStarted = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CommandInbox", category: "Commands")

    /// - Parameters:
    ///   - directory: where the sender writes `inbox.json`. On the Mac, the
    ///     `--commands <dir>` launch argument (``InboxDirectory/argument(in:)``);
    ///     in an iOS simulator, ``InboxDirectory/applicationSupport``.
    ///   - notificationName: the Darwin notification the sender posts,
    ///     conventionally `<bundle id>.commands`.
    ///   - decoder: decodes the file; set its strategies (dates, say) here.
    ///   - readyTimeout: how long an app command waits for `isReady`.
    ///   - isReady: whether the app can run its commands yet: its data
    ///     loaded, its window open. Each app command waits until it returns
    ///     `true`, up to `readyTimeout`, so a script can send commands
    ///     straight after launch. Throws for a state waiting will not fix
    ///     ("two windows are open"), which fails the command at once.
    ///   - snapshot: draws the app's windows to files and returns them, for
    ///     the `snapshot` command; without it, `snapshot` fails.
    ///   - perform: runs one of the app's commands, as its control would.
    public init(
        directory: URL, notificationName: String, decoder: JSONDecoder = JSONDecoder(),
        readyTimeout: Duration = .seconds(30),
        isReady: @escaping @MainActor () throws -> Bool = { true },
        snapshot: (@MainActor () async throws -> [URL])? = nil,
        perform: @escaping @MainActor (Command) async throws -> CommandReply
    ) {
        self.directory = directory
        self.notificationName = notificationName
        self.decoder = decoder
        self.readyTimeout = readyTimeout
        self.isReady = isReady
        self.snapshot = snapshot
        self.perform = perform
    }

    var inboxURL: URL { directory.appending(path: "inbox.json") }
    var resultURL: URL { directory.appending(path: "result.json") }

    /// Accepts commands from now on, starting with any inbox already
    /// waiting. Listens for as long as the app runs; a second call does
    /// nothing.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        var token: Int32 = 0
        let status = notify_register_dispatch(notificationName, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.processInbox() }
            }
        }
        guard status == NOTIFY_STATUS_OK else {
            logger.error(
                "could not listen for \(self.notificationName, privacy: .public): status \(status)")
            return
        }
        logger.notice(
            "accepting commands in \(self.directory.path(percentEncoded: false), privacy: .public)")
        Task { await processInbox() }
    }

    func processInbox() async {
        guard let data = try? Data(contentsOf: inboxURL) else { return }
        // Taken before its commands run, and not run if it cannot be taken: a
        // command can wait, and a second notification meanwhile would run the
        // same file again.
        guard (try? FileManager.default.removeItem(at: inboxURL)) != nil else { return }
        let result = await run(data)
        do {
            try Self.encoder.encode(result).write(to: resultURL, options: .atomic)
            logger.notice(
                "ran \(result.completed.count) command(s)\(result.error.map { "; \($0)" } ?? "", privacy: .public)"
            )
        } catch { logger.error("could not write the result: \(error, privacy: .public)") }
    }

    /// Runs a command file's commands, as `processInbox` does, without the
    /// files: for tests.
    public func run(_ data: Data) async -> CommandResult {
        let file: CommandFile<Command>
        do { file = try decoder.decode(CommandFile<Command>.self, from: data) } catch {
            return CommandResult(error: "could not read commands: \(error)")
        }
        var result = CommandResult(requestID: file.id)
        for entry in file.commands {
            do {
                let reply = try await run(entry)
                result.completed.append(
                    .init(command: entry.name, message: reply.message, state: reply.state))
            } catch {
                result.error = "\(entry.name) failed: \(error)"
                break
            }
        }
        return result
    }

    private func run(_ entry: InboxEntry<Command>) async throws -> CommandReply {
        switch entry {
        case .command(let command):
            try await waitUntilReady()
            return try await perform(command)
        case .pause(let seconds):
            try await Task.sleep(for: .seconds(seconds))
            return CommandReply("paused \(seconds)s")
        case .snapshot:
            guard let snapshot else { throw InboxError("this app takes no snapshots") }
            let files = try await snapshot()
            guard !files.isEmpty else { throw InboxError("no window was drawn") }
            return CommandReply(
                files.map { $0.path(percentEncoded: false) }.joined(separator: ", "))
        }
    }

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now + readyTimeout
        while try !isReady() {
            guard ContinuousClock.now < deadline else {
                throw InboxError("the app was not ready after \(readyTimeout)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// Where an inbox is.
public enum InboxDirectory {
    /// The directory given as `--commands <dir>` in `arguments`, if any.
    ///
    /// On the Mac, whatever launches the app for scripts passes it (`make
    /// run-scratch`, with app-tooling's patterns), so the inbox is wherever
    /// the project chose: beside the scratch data for an unsandboxed app, a
    /// directory its entitlements open for a sandboxed one. Either way not
    /// in a container, which a terminal cannot touch without a privacy
    /// prompt. Put it before any switch without a value: AppKit reads launch
    /// arguments as `-key value` pairs.
    public static func argument(in arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--commands"),
            arguments.indices.contains(index + 1)
        else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    /// `Commands` under the app's Application Support: for an iOS
    /// simulator, where app-tooling's `command-inbox-send.sh --simulator` finds
    /// it.
    public static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: "Commands", directoryHint: .isDirectory)
    }
}
