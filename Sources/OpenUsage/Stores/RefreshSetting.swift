import Foundation

enum RefreshSetting {
    static let interval: TimeInterval = 5 * 60

    /// A forced refresh lets the next pass skip an account, so working refreshes can leave its values
    /// about two intervals old.
    static let stalenessThreshold = interval * 2

    static let failureBackoffBase = interval
    static let failureBackoffCap: TimeInterval = 60 * 60

    static let secondaryReadInterval: TimeInterval = 60 * 60
    static let forcedResetGrantsMinimumAge: TimeInterval = 15 * 60
}
