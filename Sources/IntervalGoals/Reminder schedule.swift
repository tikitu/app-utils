import Foundation

/// One reminder in a gap with a cadence: sent as the gap reaches 95%, 100%
/// and 105% of it.
public struct Reminder: Hashable, Sendable {
    public enum Stage: String, CaseIterable, Hashable, Sendable {
        case approaching
        case due
        case overdue

        /// The share of the cadence the gap has reached.
        public var fraction: Double {
            switch self {
            case .approaching: 0.95
            case .due: 1
            case .overdue: 1.05
            }
        }
    }

    public var stage: Stage
    /// When the gap reaches the stage's share of the cadence.
    public var reached: Date
    /// When it is sent: `reached` itself, or a convenient time near it.
    public var sendAt: Date

    public init(stage: Stage, reached: Date, sendAt: Date) {
        self.stage = stage
        self.reached = reached
        self.sendAt = sendAt
    }
}

/// When a gap's reminders are sent. See docs/IntervalGoals.md, "Reminders".
///
/// The three stages are the ratio ``GoalProgress`` reads, measured from the
/// last event, so a new event starts a fresh set: an event at 102% means
/// 105% is never reached, and the new set does not contain its reminder.
///
/// A cadence of a day or less is reminded at the exact moments. Anything
/// longer moves each reminder to a convenient time (``ReminderTime``):
///
/// - **due** to the nearest of the preferred times;
/// - **approaching** and **overdue** to the nearest time before and after
///   that one — among the preferred times while the stages are a day or
///   more apart, and among all three once they are closer, so a short
///   cadence spreads its reminders over one day instead of three.
///
/// The three are always in stage order and at distinct instants.
public enum ReminderSchedule {
    /// Empty when the calendar cannot add `cadence` to `last`, which a valid
    /// cadence never is.
    public static func reminders(
        every cadence: Cadence, preferring times: ReminderTimes, since last: Date,
        calendar: Calendar
    ) -> [Reminder] {
        guard let ideal = cadence.length(from: last, calendar: calendar) else { return [] }
        func reached(_ stage: Reminder.Stage) -> Date {
            last.addingTimeInterval(stage.fraction * ideal)
        }

        guard cadence.isLongerThanADay else {
            return Reminder.Stage.allCases.map {
                Reminder(stage: $0, reached: reached($0), sendAt: reached($0))
            }
        }

        let spacing = (Reminder.Stage.due.fraction - Reminder.Stage.approaching.fraction) * ideal
        let preferred = times.isValid ? times.times : ReminderTime.allCases
        let nearby = spacing >= 86_400 ? preferred : ReminderTime.allCases
        let dueAt =
            nearest(to: reached(.due), among: preferred, calendar: calendar) { _ in true }
            ?? reached(.due)
        let approachingAt =
            nearest(to: reached(.approaching), among: nearby, calendar: calendar) { $0 < dueAt }
            ?? reached(.approaching)
        let overdueAt =
            nearest(to: reached(.overdue), among: nearby, calendar: calendar) { $0 > dueAt }
            ?? reached(.overdue)
        return [
            Reminder(stage: .approaching, reached: reached(.approaching), sendAt: approachingAt),
            Reminder(stage: .due, reached: reached(.due), sendAt: dueAt),
            Reminder(stage: .overdue, reached: reached(.overdue), sendAt: overdueAt),
        ]
    }

    /// The instant at one of `times`, on a day within a week of `target`,
    /// nearest to it and allowed by `isAllowed`; the earlier of a tie.
    private static func nearest(
        to target: Date, among times: [ReminderTime], calendar: Calendar,
        where isAllowed: (Date) -> Bool
    ) -> Date? {
        let day = calendar.startOfDay(for: target)
        let candidates = (-7...7).flatMap { offset -> [Date] in
            guard let date = calendar.date(byAdding: .day, value: offset, to: day) else {
                return []
            }
            return times.compactMap {
                calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: date)
            }
        }
        return candidates.filter(isAllowed).min { a, b in
            let (da, db) = (abs(a.timeIntervalSince(target)), abs(b.timeIntervalSince(target)))
            return da != db ? da < db : a < b
        }
    }
}
