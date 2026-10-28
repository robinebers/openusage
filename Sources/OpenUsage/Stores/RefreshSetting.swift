import Foundation

enum RefreshSetting {
    static let interval: TimeInterval = 5 * 60

    static let failureBackoffBase = interval
    static let failureBackoffCap: TimeInterval = 60 * 60

    static let secondaryReadInterval: TimeInterval = 60 * 60
    static let forcedResetGrantsMinimumAge: TimeInterval = 15 * 60
}
