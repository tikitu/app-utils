import Foundation
import UserNotifications

/// The calls reconciling makes on the system's notification center, so the
/// logic can run against a fake in tests. `UNUserNotificationCenter`
/// conforms.
public protocol ReminderNotificationCenter: AnyObject {
    nonisolated(nonsending) func pendingIdentifiers() async -> [String]
    nonisolated(nonsending) func deliveredIdentifiers() async -> [String]
    /// Adding under an existing identifier replaces that notification.
    nonisolated(nonsending) func add(_ request: UNNotificationRequest) async throws
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

extension UNUserNotificationCenter: ReminderNotificationCenter {
    nonisolated(nonsending) public func pendingIdentifiers() async -> [String] {
        await pendingNotificationRequests().map(\.identifier)
    }

    nonisolated(nonsending) public func deliveredIdentifiers() async -> [String] {
        await deliveredNotifications().map(\.request.identifier)
    }

    public func removePending(_ identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func removeDelivered(_ identifiers: [String]) {
        removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
