import Foundation

/// The feed's timestamp text: `YYYY-MM-DD HH:MM:SS.SSS`, UTC, milliseconds.
///
/// The same text SQLiteData writes for a `Date`, but made here from whole
/// milliseconds, rounded to the nearest. Foundation's ISO-8601 format style
/// truncates the binary fraction, so it re-encodes about half of all
/// millisecond values one millisecond lower when a date read back from its
/// own text is written again (`…02.999` becomes `…02.998`). Rounding makes a
/// date read back from a store's text encode to exactly that text, every
/// time, which identity (``FeedEvent``) depends on.
enum FeedTime {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// `date` at the millisecond the feed stores it as.
    static func normalized(_ date: Date) -> Date { Self.date(milliseconds: milliseconds(date)) }

    static func text(_ date: Date) -> String {
        let total = milliseconds(date)
        let (seconds, millis) = floorDivision(total, 1000)
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", parts.tm_year + 1900, parts.tm_mon + 1,
            parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec, Int32(millis))
    }

    /// Parses exactly the form ``text(_:)`` writes; anything else is `nil`.
    static func date(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 23 else { return nil }
        func number(_ range: Range<Int>) -> Int32? {
            guard bytes[range].allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            return bytes[range].reduce(0) { $0 * 10 + Int32($1 - 0x30) }
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
            let millis = number(20..<23)
        else { return nil }
        var parts = tm()
        parts.tm_year = year - 1900
        parts.tm_mon = month - 1
        parts.tm_mday = day
        parts.tm_hour = hour
        parts.tm_min = minute
        parts.tm_sec = second
        let seconds = Int64(timegm(&parts))
        let result = date(milliseconds: seconds * 1000 + Int64(millis))
        // timegm normalises 13th months and 61st seconds; the text must not.
        return self.text(result) == text ? result : nil
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func floorDivision(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
        let remainder = ((a % b) + b) % b
        return ((a - remainder) / b, remainder)
    }
}
