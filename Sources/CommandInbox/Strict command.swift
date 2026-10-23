import Foundation

/// The names of an app's commands, as they appear in a command file, and the
/// fields each one takes. An `enum Name: String, CaseIterable` in the app's
/// decoder.
public protocol CommandName: RawRepresentable, CaseIterable where RawValue == String {
    /// Every field this command may have. Any other is an error.
    var fields: Set<String> { get }
}

/// One command of a command file, checked strictly before the app reads its
/// fields: an object with exactly one key, a known command's name, whose
/// value is an object holding only that command's fields. So a typo in a
/// script is an error rather than a command quietly not run, or run without
/// the field the script meant to set.
///
/// ```swift
/// extension AppCommand: Decodable {
///     private enum Name: String, CommandName {
///         case add, delete
///         var fields: Set<String> {
///             switch self {
///             case .add: ["title"]
///             case .delete: ["items"]
///             }
///         }
///     }
///     private enum Field: String, CodingKey { case title, items }
///
///     public init(from decoder: any Decoder) throws {
///         let command = try StrictCommand<Name>(from: decoder)
///         let fields = try command.fields(keyedBy: Field.self)
///         switch command.name {
///         case .add: self = .add(title: try fields.decode(String.self, forKey: .title))
///         case .delete: self = .delete(try fields.decode([String].self, forKey: .items))
///         }
///     }
/// }
/// ```
public struct StrictCommand<Name: CommandName> {
    public let name: Name
    private let container: KeyedDecodingContainer<AnyKey>
    private let key: AnyKey

    public init(from decoder: any Decoder) throws {
        let commands = try decoder.container(keyedBy: AnyKey.self)
        guard commands.allKeys.count == 1, let key = commands.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "a command is an object with exactly one key, its name"))
        }
        guard let name = Name(rawValue: key.stringValue) else {
            let known = Name.allCases.map(\.rawValue).sorted().joined(separator: ", ")
            let inboxOwn = FieldCheck.inboxOwnNames.joined(separator: ", ")
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: commands.codingPath + [key],
                    debugDescription:
                        "unknown command '\(key.stringValue)'; known: \(known); and the inbox's own: \(inboxOwn)"
                ))
        }
        try FieldCheck.check(key, in: commands, allowed: name.fields, command: name.rawValue)
        self.name = name
        self.container = commands
        self.key = key
    }

    /// The command's fields, for the app to decode.
    public func fields<Field: CodingKey>(
        keyedBy type: Field.Type
    ) throws -> KeyedDecodingContainer<Field> {
        try container.nestedContainer(keyedBy: type, forKey: key)
    }

    /// An error about this command's fields, for a check the field names
    /// alone cannot make ("takes exactly one of index and taxon").
    public func error(_ description: String) -> DecodingError {
        .dataCorrupted(
            .init(codingPath: container.codingPath + [key], debugDescription: description))
    }
}

/// The check every command gets: only the fields it takes.
enum FieldCheck {
    /// The inbox's own commands (``InboxEntry``), decoded before the app's.
    static let inboxOwnNames = ["pause", "snapshot"]

    static func check(
        _ key: AnyKey, in commands: KeyedDecodingContainer<AnyKey>, allowed: Set<String>,
        command: String
    ) throws {
        let unknown = try commands.nestedContainer(keyedBy: AnyKey.self, forKey: key).allKeys.map(
            \.stringValue
        ).filter { !allowed.contains($0) }
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: commands.codingPath + [key],
                    debugDescription:
                        "unknown field(s) \(unknown.sorted()) for \(command); allowed: "
                        + allowed.sorted().joined(separator: ", ")))
        }
    }
}

/// A coding key for whatever keys an object has, so a decoder can check them
/// against what it expects.
public struct AnyKey: CodingKey, Equatable {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}
