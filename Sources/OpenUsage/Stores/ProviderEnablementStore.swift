import Foundation
import Observation

/// The single source of truth for which providers the user has turned off.
///
/// Only the *disabled* IDs are persisted, never the enabled ones. That keeps "everything on" as an
/// empty set, so a provider shipped in a future release defaults to enabled without any migration.
@MainActor
@Observable
final class ProviderEnablementStore {
    private static let storageKey = "openusage.disabledProviders.v1"

    /// Posted when the enabled-provider set actually changes. The refresh loop listens for this to wake
    /// early and fetch a newly-enabled provider promptly, instead of waiting out the full interval —
    /// WITHOUT subscribing to the firehose `UserDefaults.didChangeNotification`, which also fires for the
    /// app's own snapshot-cache writes, Sparkle's update bookkeeping, and unrelated global-domain changes
    /// from other processes. Waking on that (with no minimum interval) collapsed the fixed 5-minute
    /// cadence into a refresh storm.
    ///
    /// `nonisolated` so the refresh loop's background task can name it without hopping to the main actor
    /// (it's an immutable, `Sendable` constant — like Foundation's own notification names).
    nonisolated static let didChangeNotification = Notification.Name("ProviderEnablementDidChange")

    /// Called with a provider's id the moment the user turns it ON (not on disable, not on a no-op
    /// re-set). `AppContainer` wires this to clear that provider's failure backoff, so the enablement
    /// wake's refresh actually probes it instead of being suppressed by a backoff left over from a
    /// failure just before it was turned off.
    var onProviderEnabled: (@MainActor (String) -> Void)?

    private(set) var disabledIDs: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.disabledIDs = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    func setEnabled(_ enabled: Bool, for id: String) {
        let before = disabledIDs
        if enabled {
            disabledIDs.remove(id)
        } else {
            disabledIDs.insert(id)
        }
        // A no-op toggle (re-setting the same value) shouldn't persist or wake the refresh loop.
        guard disabledIDs != before else { return }
        defaults.set(Array(disabledIDs), forKey: Self.storageKey)
        // Clear the backoff BEFORE the wake notification, so the refresh it triggers actually probes the
        // just-enabled provider instead of skipping it as recently-failed.
        if enabled { onProviderEnabled?(id) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
