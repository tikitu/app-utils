import CryptoKit
import Foundation

/// A UUID derived from a key rather than allocated: SHA-256 of its UTF-8,
/// the first 16 bytes stamped as a v4 UUID. The same function as Time
/// Tracker's `stableIdentifier(from:)`, so ids are comparable across them.
public func stableIdentifier(from key: String) -> UUID {
    let digest = SHA256.hash(data: Data(key.utf8))
    var bytes = [UInt8](digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
        uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
}

/// JSON written one way only, so the same values are the same bytes on
/// every device and every OS version: no whitespace, object keys in UTF-8
/// byte order, only `"`, `\` and control characters escaped (as `\u00XX`).
/// `JSONEncoder` promises none of that.
enum CanonicalJSON {
    enum Value {
        case string(String)
        case null
        case object([String: String])
    }

    static func array(_ values: [Value]) -> String {
        "[" + values.map(encode).joined(separator: ",") + "]"
    }

    static func object(_ object: [String: String]) -> String {
        let entries = object.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        return "{" + entries.map { string($0.key) + ":" + string($0.value) }.joined(separator: ",")
            + "}"
    }

    private static func encode(_ value: Value) -> String {
        switch value {
        case .string(let text): string(text)
        case .null: "null"
        case .object(let object): self.object(object)
        }
    }

    private static func string(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
