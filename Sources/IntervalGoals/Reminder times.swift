import Foundation

/// A time of day a reminder is convenient to receive.
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
}

/// Which convenient times reminders prefer, when the cadence is long enough
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
}
