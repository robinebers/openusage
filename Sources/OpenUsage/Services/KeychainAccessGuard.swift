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
    /// While the welcome screen waits for the user to pick providers, reads that would show
    /// OpenUsage's own popup fail as not allowed. Logins read through `/usr/bin/security` were
    /// saved with it, so reading them doesn't ask.
    private static let popupsHeld = Mutex(false)
    /// A read can outlive the refresh that gave up on it while its popup waits for the user.
    private static let readsInProgress = Mutex(0)
    /// A popup stays open until the user answers. Reads give up well inside the 120-second provider
    /// refresh deadline, so unanswered popups can't pile up blocked threads.
    private static let readLockWait: TimeInterval = 60

    static func read(
        service: String,
        _ read: () -> (status: OSStatus, data: Data?)
    ) -> (status: OSStatus, data: Data?) {
        if popupsHeld.withLock({ $0 }), !SecurityToolItemAccessor.handles(service: service) {
            return (errSecInteractionNotAllowed, nil)
        }
        let lock = Self.lock(for: service)
        guard lock.lock(before: Date().addingTimeInterval(readLockWait)) else {
            AppLog.warn(.keychain, "'\(service)' is still waiting on an earlier Keychain popup; skipping")
            return (errSecInteractionNotAllowed, nil)
        }
        defer { lock.unlock() }
        if deniedServices.withLock({ $0.contains(service) }) {
            return (errSecAuthFailed, nil)
        }
        readsInProgress.withLock { $0 += 1 }
        defer { readsInProgress.withLock { $0 -= 1 } }
        let result = read()
        if result.status == errSecAuthFailed || result.status == errSecUserCanceled {
            deniedServices.withLock { _ = $0.insert(service) }
            AppLog.warn(.keychain, "access to '\(service)' was denied; not asking again until a manual refresh")
        }
        return result
    }

    /// A save can carry a token the provider just rotated. Giving up would leave the Keychain holding
    /// a spent one, so saves wait for the lock as long as it takes.
    static func write(service: String, _ write: () -> OSStatus) -> OSStatus {
        let lock = Self.lock(for: service)
        lock.lock()
        defer { lock.unlock() }
        return write()
    }

    /// A manual refresh is the user asking again, so logins they denied may show their popup once more.
    static func forgetDenials() {
        deniedServices.withLock { $0.removeAll() }
    }

    static func denials() -> Set<String> {
        deniedServices.withLock { $0 }
    }

    static func holdPopups() {
        popupsHeld.withLock { $0 = true }
    }

    static func allowPopups() {
        popupsHeld.withLock { $0 = false }
    }

    /// Waits until every read has returned, so a popup still open from an earlier read isn't joined
    /// by a second one.
    static func waitForReadsToFinish() async {
        while readsInProgress.withLock({ $0 }) > 0 {
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
        }
    }

    private static func lock(for service: String) -> NSLock {
        locks.withLock { locks in
            if let lock = locks[service] { return lock }
            let lock = NSLock()
            locks[service] = lock
            return lock
        }
    }
}
