import Foundation
import LocalAuthentication
import Security

/// Legacy login-Keychain ACL checks can present UI despite per-query flags. Every native call in
/// the app shares this gate, so an interactive request cannot lend permission to background work.
enum KeychainSystemAccess {
    private static let gate = KeychainOperationGate()

    static func perform<T>(interactive: Bool = KeychainAccessContext.allowsInteraction,
                           unavailable: T, _ operation: () -> T) -> T {
        // Unit tests must never access the user's real credentials, even through a default adapter.
        guard NSClassFromString("XCTestCase") == nil else { return unavailable }
        guard gate.acquire(interactive: interactive) else { return unavailable }
        defer { gate.release() }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(interactive) == errSecSuccess else {
            AppLog.warn(.keychain, "could not configure Keychain interaction policy")
            return unavailable
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return operation()
    }

    static func disallowInteraction(in query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
}

/// Serialize short background calls, but never make the main thread or another background request
/// wait behind an authorization dialog. The caller can retry at its normal refresh boundary.
final class KeychainOperationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var active = false
    private var activeIsInteractive = false

    func acquire(interactive: Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while active {
            if !interactive && (activeIsInteractive || Thread.isMainThread) { return false }
            condition.wait()
        }
        active = true
        activeIsInteractive = interactive
        return true
    }

    func release() {
        condition.lock()
        active = false
        activeIsInteractive = false
        condition.broadcast()
        condition.unlock()
    }
}
