import Foundation

enum RefreshSetting {
    static let interval: TimeInterval = 5 * 60

    /// A forced refresh lets the next pass skip an account, so working refreshes can leave its values
    /// about two intervals old.
    static let stalenessThreshold = interval * 2

    static let failureBackoffBase = interval
    static let failureBackoffCap: TimeInterval = 60 * 60
    /// The waits before each retry of a refresh that found no network path, about a minute in all. Right after
    /// launch, macOS refuses a hub on the local network for a moment before it lets OpenUsage in, and the next
    /// pass would be 5 minutes away. The account isn't flagged until the last retry fails.
    static let offlineRetryDelays: [TimeInterval] = [2, 4, 8, 16, 32]

    static let secondaryReadInterval: TimeInterval = 60 * 60
    static let forcedResetGrantsMinimumAge: TimeInterval = 15 * 60
}
