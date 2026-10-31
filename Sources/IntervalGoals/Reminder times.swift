import Foundation

/// A time of day a reminder is convenient to receive, under a stable name
/// for storage and identifiers. An app's own set of times is a list of these;
/// ``standard`` is the set ``ReminderTime`` names.
public struct ConvenientTime: Hashable, Sendable {
    /// Stable: what storage keeps for a preference, so never rename one.
    public var name: String
    public var hour: Int
    public var minute: Int

    public init(_ name: String, hour: Int, minute: Int) {
        self.name = name
        self.hour = hour
        self.minute = minute
    }

    /// A time on the clock: hour 0–23, minute 0–59. Invalid ones are skipped.
    public var isValid: Bool { (0..<24).contains(hour) && (0..<60).contains(minute) }

    /// 8:30, 12:30 and 18:30, named `morning`, `midday` and `evening`.
    public static let standard = ReminderTime.allCases.map(\.convenientTime)
}

/// One of the standard convenient times, 8:30, 12:30 and 18:30. An app with
/// times of its own uses ``ConvenientTime``.
public enum ReminderTime: String, CaseIterable, Hashable, Sendable {
    case morning
    case midday
    case evening

    public var hour: Int {
        switch self {
        case .morning: 8
        case .midday: 12
        case .evening: 18
        }
    }

    public var minute: Int { 30 }

    /// Named by the raw value.
    public var convenientTime: ConvenientTime {
        ConvenientTime(rawValue, hour: hour, minute: minute)
    }
}

/// Which of the standard convenient times reminders prefer, when the cadence is long enough
/// for the time of day to be chosen (see ``ReminderSchedule``). Valid with at
/// least one; ``all`` means "whichever is nearest", and an invalid set is
/// read as ``all``.
///
/// A flag per time rather than a stored set, so storage can keep a column
/// each: a time added later is a new column an older build ignores, not a
/// value it cannot read.
public struct ReminderTimes: Hashable, Sendable {
    public var morning: Bool
    public var midday: Bool
    public var evening: Bool

    public init(morning: Bool = true, midday: Bool = true, evening: Bool = true) {
        self.morning = morning
        self.midday = midday
        self.evening = evening
    }

    public init(_ times: Set<ReminderTime>) {
        self.init(
            morning: times.contains(.morning), midday: times.contains(.midday),
            evening: times.contains(.evening))
    }

    public static let all = ReminderTimes()

    public subscript(time: ReminderTime) -> Bool {
        get {
            switch time {
            case .morning: morning
            case .midday: midday
            case .evening: evening
            }
        }
        set {
            switch time {
            case .morning: morning = newValue
            case .midday: midday = newValue
            case .evening: evening = newValue
            }
        }
    }

    /// The preferred times, in the order of the day.
    public var times: [ReminderTime] { ReminderTime.allCases.filter { self[$0] } }

    public var isValid: Bool { !times.isEmpty }

    /// The preferred times, for ``ReminderSchedule``.
    public var convenientTimes: [ConvenientTime] { times.map(\.convenientTime) }
}
