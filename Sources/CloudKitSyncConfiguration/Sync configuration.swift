import Foundation

/// Whether this build is allowed to talk to CloudKit.
///
/// Checked rather than caught, because `CKContainer(identifier:)` **traps**
/// for a container the app is not entitled to: `EXC_BREAKPOINT` inside
/// CloudKit, not a thrown error. A sync engine made for that container takes
/// the whole process with it, and no `do`/`catch` can help. The only safe move
/// is not to make the call.
///
/// The obvious check, reading the app's own code signature, is not portable:
/// `SecTaskCopyValueForEntitlement` is absent from the iOS SDK.
///
/// So the build declares it instead. Whatever adds the iCloud entitlement also
/// sets `infoPlistKey` to `true` in `Info.plist`, and nothing else sets it. A
/// missing key means no sync: it fails closed, because a missing key costs a
/// feature and a false positive costs the app.
///
/// **The simulator is the one case the declaration cannot get right.** An iOS
/// `Info.plist` is one file for every destination, so it says `true` for a
/// simulator build too; but a simulator build is signed to run locally, no
/// profile grants it the container, and `CKContainer(identifier:)` traps
/// exactly as it does for a missing entitlement. That crashed an app on every
/// launch in the simulator, for days before anyone noticed. Hence
/// ``isSimulator``.
public struct SyncConfiguration: Sendable {
    /// The `Info.plist` key the build sets, `<App>SyncEnabled` by convention.
    public let infoPlistKey: String

    public init(infoPlistKey: String) { self.infoPlistKey = infoPlistKey }

    /// Whether to start syncing: the build declares it, and this is not a
    /// simulator.
    public var isEnabled: Bool { declaresSyncEnabled && !Self.isSimulator }

    /// What this build's `Info.plist` says. Anything but a Boolean `true` is
    /// `false`.
    public var declaresSyncEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? Bool ?? false
    }

    /// Whether this is a simulator, asked of the environment rather than with
    /// `#if targetEnvironment(simulator)`, so that one build of a library
    /// answers correctly wherever it is hosted. CoreSimulator sets this
    /// variable for every process it hosts; it is absent on a device and on the
    /// Mac.
    public static var isSimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
    }
}
