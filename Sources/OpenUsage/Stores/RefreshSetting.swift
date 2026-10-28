import Foundation

/// Single source of truth for how often OpenUsage asks the providers. Every cadence and wait lives here
/// so they are easy to tune together.
///
/// The periodic refresh loop and the snapshot-cache TTL both read the cadence through here so they can
/// never disagree: the cache treats a snapshot as fresh for exactly one refresh interval, and the loop
/// re-fetches when that window elapses. There's no user-facing control.
enum RefreshSetting {
    /// Every account refreshes together this often, whatever the user is doing, so the menu bar stays
    /// current.
    static let interval: TimeInterval = 5 * 60

    /// The wait after an account's first failed refresh in a row; each further failure doubles it.
    static let failureBackoffBase = interval
    /// The longest wait between attempts on an account that keeps failing.
    static let failureBackoffCap: TimeInterval = 60 * 60

    /// How long a read that rarely changes (a plan name, Codex's reset-credit list, Claude's reset
    /// grants) is reused before it is asked again; a forced refresh (⌘R) asks it again at once.
    static let secondaryReadInterval: TimeInterval = 60 * 60
}
