import Foundation

/// An ideal length of time between events, measured on the calendar:
/// "1 month", "every 10 days", "1 month, 3 days and 2 hours".
///
/// Not `DateComponents`, which also holds fields that are points in the
/// calendar rather than lengths (`weekday`), fields that date arithmetic
/// ignores (`quarter`), and negative fields. A valid cadence always adds to a
/// positive interval, which is what makes comparing a gap against it defined.
/// See docs/IntervalGoals.md, "Calendar arithmetic".
public struct Cadence: Hashable, Sendable {
    public var years: Int
    public var months: Int
    public var weeks: Int
    public var days: Int
    public var hours: Int
    public var minutes: Int

    public init(
        years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0, hours: Int = 0,
        minutes: Int = 0
    ) {
        self.years = years
        self.months = months
        self.weeks = weeks
        self.days = days
        self.hours = hours
        self.minutes = minutes
    }

    private var fields: [Int] { [years, months, weeks, days, hours, minutes] }

    /// No negative field and at least one positive one. Storage that keeps a
    /// cadence should refuse the others (a `CHECK`, say).
    public var isValid: Bool { fields.allSatisfy { $0 >= 0 } && fields.contains { $0 > 0 } }

    /// Less frequent than daily: longer than one calendar day, however the
    /// fields add up. A property of the cadence, not of any one day, so
    /// "25 hours" is longer than a day even across a DST change, and "1 day"
    /// is not, even on a 25-hour day.
    public var isLongerThanADay: Bool {
        if years > 0 || months > 0 || weeks > 0 { return true }
        let minutesPastDays = hours * 60 + minutes
        return days > 1 || (days == 1 && minutesPastDays > 0)
            || (days == 0 && minutesPastDays > 24 * 60)
    }

    /// The cadence as components to add with `Calendar.date(byAdding:to:)`;
    /// weeks become `weekOfYear`.
    public var dateComponents: DateComponents {
        DateComponents(
            year: years, month: months, day: days, hour: hours, minute: minutes, weekOfYear: weeks)
    }

    /// `self` added on `calendar` from `start`, as a duration: the length
    /// this cadence has when it starts there. `nil` when the calendar cannot
    /// add it or the result is not after `start`, which for a valid cadence
    /// never happens.
    public func length(from start: Date, calendar: Calendar) -> TimeInterval? {
        guard let end = calendar.date(byAdding: dateComponents, to: start) else { return nil }
        let length = end.timeIntervalSince(start)
        return length > 0 ? length : nil
    }
}
