import Foundation
import Security
import Synchronization

/// Keeps Keychain popups from repeating. Every read and save of an item passes through here.
///
/// - One operation per service runs at a time, so a second refresh waits for the open popup
///   instead of showing another one.
/// - macOS doesn't remember Deny. After the user denies or cancels a popup, later reads of that
///   service fail without asking, until the user refreshes manually (`forgetDenials()`).
enum KeychainAccessGuard {
    private static let locks = Mutex<[String: NSLock]>([:])
    private static let deniedServices = Mutex<Set<String>>([])
    /// A popup stays open until the user answers. Waiters give up well inside the 120-second provider
    /// refresh deadline, so unanswered popups can't pile up blocked threads.
    private static let lockWait: TimeInterval = 60

    static func read(
        service: String,
        _ read: () -> (status: OSStatus, data: Data?)
    ) -> (status: OSStatus, data: Data?) {
        withLock(service: service, timedOut: (errSecInteractionNotAllowed, nil)) {
            if deniedServices.withLock({ $0.contains(service) }) {
                return (errSecAuthFailed, nil)
            }
            let result = read()
            if result.status == errSecAuthFailed || result.status == errSecUserCanceled {
                deniedServices.withLock { _ = $0.insert(service) }
                AppLog.warn(.keychain, "access to '\(service)' was denied; not asking again until a manual refresh")
            }
            return result
        }
    }

    static func write(service: String, _ write: () -> OSStatus) -> OSStatus {
        withLock(service: service, timedOut: errSecInteractionNotAllowed, write)
    }

    /// A manual refresh is the user asking again, so logins they denied may show their popup once more.
    static func forgetDenials() {
        deniedServices.withLock { $0.removeAll() }
    }

    private static func withLock<T>(service: String, timedOut: T, _ operation: () -> T) -> T {
        let lock = locks.withLock { locks in
            if let lock = locks[service] { return lock }
            let lock = NSLock()
            locks[service] = lock
            return lock
        }
        guard lock.lock(before: Date().addingTimeInterval(lockWait)) else {
            AppLog.warn(.keychain, "'\(service)' is still waiting on an earlier Keychain popup; skipping")
            return timedOut
        }
        defer { lock.unlock() }
        return operation()
    }
}
