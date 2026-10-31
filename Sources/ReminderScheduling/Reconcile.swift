import Foundation
import UserNotifications

/// A notification the app wants pending, and when it fires: the request the
/// app built (its text, category, sound, trigger) and the date that orders
/// it against the pending limit.
public struct WantedNotification {
    public var request: UNNotificationRequest
    public var fireDate: Date

    public init(request: UNNotificationRequest, fireDate: Date) {
        self.request = request
        self.fireDate = fireDate
    }

    /// A request firing once at `fireDate`, on `calendar`, to the second.
    public init(
        identifier: String, content: UNNotificationContent, fireDate: Date, calendar: Calendar
    ) {
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate), repeats: false)
        self.init(
            request: UNNotificationRequest(
                identifier: identifier, content: content, trigger: trigger), fireDate: fireDate)
    }
}

/// What one reconcile did, for the app's log.
public struct Reconciliation: Sendable {
    public struct Failure: Sendable {
        public var identifier: String
        public var error: any Error
    }

    /// Identifiers added (or replaced), soonest first.
    public var scheduled: [String] = []
    public var removedPending: [String] = []
    public var removedDelivered: [String] = []
    /// Requests the center refused to add; the rest were still added.
    public var failures: [Failure] = []
}

extension ReminderIdentifiers {
    /// The system's limit on an app's pending notifications.
    public static let pendingLimit = 64

    /// Makes `center`'s pending reminders the wanted ones.
    ///
    /// - Drops wanted notifications that fire at or before `now`: past
    ///   stages are not sent late.
    /// - Keeps the soonest `limit` of the rest.
    /// - Removes pending reminders not kept, except a snooze in an open
    ///   cycle (``isStale(_:wanted:openCycles:)``).
    /// - Adds every kept one; adding replaces, so a changed text or time
    ///   takes effect.
    /// - Removes delivered reminders of cycles no longer open.
    ///
    /// Notifications without ``prefix`` are never touched. Run it on every
    /// change to what the app wants, against the whole of it: what is
    /// pending then follows from the app's state, whoever changed it.
    ///
    /// `openCycles` is the cycle of every gap still open, from
    /// ``cycle(_:since:)``, whether or not it has a notification wanted.
    nonisolated(nonsending) public func reconcile(
        _ wanted: [WantedNotification], openCycles: Set<String>,
        in center: some ReminderNotificationCenter, now: Date, limit: Int = pendingLimit
    ) async -> Reconciliation {
        let kept = wanted.filter { $0.fireDate > now }.sorted { $0.fireDate < $1.fireDate }.prefix(
            limit
        ).map(\.request)
        let keptIDs = Set(kept.map(\.identifier))
        var result = Reconciliation()

        result.removedPending = await center.pendingIdentifiers().filter {
            isStale($0, wanted: keptIDs, openCycles: openCycles)
        }
        center.removePending(result.removedPending)

        for request in kept {
            do {
                try await center.add(request)
                result.scheduled.append(request.identifier)
            } catch { result.failures.append(.init(identifier: request.identifier, error: error)) }
        }

        result.removedDelivered = await center.deliveredIdentifiers().filter {
            isClosed($0, openCycles: openCycles)
        }
        center.removeDelivered(result.removedDelivered)
        return result
    }

    /// Puts `request` off by `interval`: `content`, or the same content
    /// again, under the cycle's snooze identifier, so snoozing again replaces
    /// it and it goes when the gap closes. Returns the snoozed identifier.
    ///
    /// Pass `content` when the original's text says when things happen
    /// relative to when it was sent ("due in 6 seconds"), which would be
    /// wrong by the time the snooze arrives.
    @discardableResult
    nonisolated(nonsending) public static func snooze(
        _ request: UNNotificationRequest, for interval: TimeInterval,
        content: UNNotificationContent? = nil, in center: some ReminderNotificationCenter
    ) async throws -> String {
        let snoozed = UNNotificationRequest(
            identifier: snoozed(request.identifier), content: content ?? request.content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        try await center.add(snoozed)
        return snoozed.identifier
    }
}
