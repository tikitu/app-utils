import Foundation

/// A command the inbox can run: the app's own command type, which decodes
/// itself strictly (``StrictCommand``) and says its name for the result.
public protocol InboxCommand: Decodable {
    /// The command's name in a command file, reported in the result.
    var name: String { get }
}

/// The JSON a sender writes to `inbox.json`: an optional `id`, echoed into
/// the result, and the commands, run in order.
public struct CommandFile<Command: Decodable>: Decodable {
    /// Echoed into the result, so a sender can match result to request.
    public var id: String?
    public var commands: [InboxEntry<Command>]

    public init(id: String? = nil, commands: [InboxEntry<Command>]) {
        self.id = id
        self.commands = commands
    }
}

extension CommandFile: Equatable where Command: Equatable {}

/// One command in a command file: the app's, or one of the inbox's own,
/// which no control performs and every app gets. An app command with the
/// same name as one of these is never reached from a file.
public enum InboxEntry<Command> {
    case command(Command)
    /// `pause {seconds}`: waits, for an animation to finish before a
    /// `snapshot`, say.
    case pause(seconds: Double)
    /// `snapshot {}`: the app draws its windows to files and reports them.
    /// Fails unless the app gave the inbox a way to (`snapshot:`).
    case snapshot
}

extension InboxEntry: Equatable where Command: Equatable {}

extension InboxEntry: Decodable where Command: Decodable {
    public init(from decoder: any Decoder) throws {
        let entry = try decoder.container(keyedBy: AnyKey.self)
        guard entry.allKeys.count == 1, let key = entry.allKeys.first,
            FieldCheck.inboxOwnNames.contains(key.stringValue)
        else {
            self = .command(try Command(from: decoder))
            return
        }
        switch key.stringValue {
        case "pause":
            try FieldCheck.check(key, in: entry, allowed: ["seconds"], command: "pause")
            let seconds = try entry.nestedContainer(keyedBy: AnyKey.self, forKey: key).decode(
                Double.self, forKey: AnyKey(stringValue: "seconds"))
            guard seconds.isFinite, seconds >= 0 else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: entry.codingPath + [key],
                        debugDescription: "pause takes a number of seconds, at least 0"))
            }
            self = .pause(seconds: seconds)
        default:
            try FieldCheck.check(key, in: entry, allowed: [], command: "snapshot")
            self = .snapshot
        }
    }
}

extension InboxEntry where Command: InboxCommand {
    var name: String {
        switch self {
        case .command(let command): command.name
        case .pause: "pause"
        case .snapshot: "snapshot"
        }
    }
}

/// What a command reports: a line saying what it did, and, if it has any,
/// structured detail a script can read rather than pixels (the `state`
/// command's, by convention).
public struct CommandReply {
    public var message: String
    public var state: (any Encodable)?

    public init(_ message: String, state: (any Encodable)? = nil) {
        self.message = message
        self.state = state
    }
}

/// Why the inbox could not run a command; reported in the result's `error`.
public struct InboxError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// What `result.json` holds: what completed, in order, and `error` when a
/// command failed, at which point the run stopped.
public struct CommandResult: Encodable {
    public struct Completed: Encodable {
        public var command: String
        public var message: String
        /// The reply's structured detail, if it had any.
        public var state: (any Encodable)?

        enum CodingKeys: String, CodingKey { case command, message, state }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(command, forKey: .command)
            try container.encode(message, forKey: .message)
            if let state { try container.encode(state, forKey: .state) }
        }
    }

    public var requestID: String?
    public var completed: [Completed] = []
    public var error: String?
}

/// The request examples in a command document, so a test can decode every
/// one of them and the document cannot drift from the decoder.
public enum CommandDocumentation {
    /// Every ```` ```json ```` block in `markdown` that holds `"commands"`:
    /// the requests, not the results.
    public static func requests(in markdown: String) -> [String] {
        markdown.components(separatedBy: "```json\n").dropFirst().compactMap { block in
            let json = block.components(separatedBy: "```").first ?? ""
            return json.contains("\"commands\"") ? json : nil
        }
    }

    /// The same, read from a file; none if it cannot be read, so a test
    /// should also expect how many there are.
    public static func requests(inFileAt url: URL) -> [String] {
        requests(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }
}
