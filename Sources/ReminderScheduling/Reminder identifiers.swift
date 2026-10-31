import Foundation

/// The identifiers an app gives its reminder notifications, and which of them
/// are still wanted.
///
/// `<prefix><subject>/<start of the gap, epoch seconds>/<stage>`; a snoozed
/// one has `snoozed` in place of the stage, so snoozing again replaces it.
/// Everything before the stage is the *cycle*: every notification about one
/// gap shares it, and a gap that has closed (the thing was done) is a cycle
/// the app no longer reports as open.
///
/// The prefix marks the notifications as these reminders: anything without
/// it is left alone. A stage must not contain `/`.
public struct ReminderIdentifiers: Hashable, Sendable {
    public var prefix: String

    /// What stands in for the stage in a snoozed notification.
    public static let snoozedStage = "snoozed"

    /// `prefix` should end with a separator, such as `"reminder/"`.
    public init(prefix: String) { self.prefix = prefix }

    /// The cycle of the gap about `subject` that started at `start`, to
    /// second precision.
    public func cycle(_ subject: String, since start: Date) -> String {
        "\(prefix)\(subject)/\(Int(start.timeIntervalSince1970))/"
    }

    public static func stage(_ stage: String, in cycle: String) -> String { cycle + stage }

    /// `identifier` snoozed: the same cycle, so it goes when that gap closes.
    public static func snoozed(_ identifier: String) -> String {
        guard let slash = identifier.lastIndex(of: "/") else {
            return identifier + "/" + snoozedStage
        }
        return identifier[...slash] + snoozedStage
    }

    /// Whether a pending notification should be removed: one of these
    /// reminders that is not wanted, unless it is a snooze of a gap still
    /// open, which no schedule contains.
    public func isStale(_ identifier: String, wanted: Set<String>, openCycles: Set<String>) -> Bool
    {
        guard identifier.hasPrefix(prefix), !wanted.contains(identifier) else { return false }
        return
            !(identifier.hasSuffix("/" + Self.snoozedStage)
            && Self.isOpen(identifier, openCycles: openCycles))
    }

    /// Whether a delivered notification is one of these reminders, about a
    /// gap that has closed.
    public func isClosed(_ identifier: String, openCycles: Set<String>) -> Bool {
        identifier.hasPrefix(prefix) && !Self.isOpen(identifier, openCycles: openCycles)
    }

    private static func isOpen(_ identifier: String, openCycles: Set<String>) -> Bool {
        openCycles.contains { identifier.hasPrefix($0) }
    }
}
