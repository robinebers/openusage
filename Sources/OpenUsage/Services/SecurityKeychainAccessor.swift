import Foundation
import Security
import Synchronization

protocol KeychainAccessing: Sendable {
    func genericPasswordExists(service: String) -> Bool?
    func readGenericPassword(service: String) throws -> String?
    func writeGenericPassword(service: String, value: String) throws
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws
    /// Read a generic password scoped to an explicit account (`-a`). Used when another app stored the
    /// item under a known account name (e.g. Antigravity's `agy` token under service `gemini`,
    /// account `antigravity`) rather than the current user.
    func readGenericPassword(service: String, account: String) throws -> String?
    /// Update the item belonging to this exact account, without changing another account's login.
    func writeGenericPassword(service: String, account: String, value: String) throws
}

extension KeychainAccessing {
    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writeGenericPassword(service: service, value: value)
    }

    /// Default for mocks that don't model accounts: fall back to the service-only lookup. The real
    /// `SecurityKeychainAccessor` overrides this to pass `-a <account>`.
    func readGenericPassword(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    /// An accessor without scoped-write support must fail rather than drop the account and risk
    /// overwriting a different login. The production accessor implements the explicit `-a` write.
    func writeGenericPassword(service: String, account: String, value: String) throws {
        throw KeychainError.writeFailed("Account-scoped Keychain writes are unavailable.")
    }

    /// Whether an item exists for `service`, without reading its secret. `nil` means the probe
    /// itself failed (locked keychain, denied) — the caller picks its own safe side, which is not
    /// the same for every caller. The default (for mocks) falls back to a read; the real
    /// `SecurityKeychainAccessor` overrides this with an in-process attributes-only probe, safe for
    /// the launch path — it can't trigger an unlock prompt and returns in microseconds.
    func genericPasswordExists(service: String) -> Bool? {
        do {
            return try readGenericPassword(service: service) != nil
        } catch {
            return nil
        }
    }
}

protocol SecurityItemAccessing: Sendable {
    func probeGenericPassword(service: String, account: String?) -> OSStatus
    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?)
    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?)
    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus
    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus
}

extension SecurityItemAccessing {
    // Test adapters without a metadata model remain indeterminate; never read a secret to probe.
    func probeGenericPassword(service: String, account: String?) -> OSStatus { errSecInteractionNotAllowed }
}

struct SystemSecurityItemAccessor: SecurityItemAccessing {
    func probeGenericPassword(service: String, account: String?) -> OSStatus {
        var query = itemQuery(service: service, account: account)
        KeychainSystemAccess.disallowInteraction(in: &query)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return KeychainSystemAccess.perform(interactive: false, unavailable: errSecInteractionNotAllowed) {
            SecItemCopyMatching(query as CFDictionary, nil)
        }
    }
    static func passwordReadQuery(service: String, account: String?, allowsInteraction: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: allowsInteraction
                ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        if !allowsInteraction { KeychainSystemAccess.disallowInteraction(in: &query) }
        return query
    }

    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        let query = Self.passwordReadQuery(service: service, account: account,
                                           allowsInteraction: KeychainAccessContext.allowsInteraction)
        var result: CFTypeRef?
        let status = KeychainSystemAccess.perform(unavailable: errSecInteractionNotAllowed) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        return (status, result as? Data)
    }

    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: KeychainAccessContext.allowsInteraction
                ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
        ]
        if !KeychainAccessContext.allowsInteraction { KeychainSystemAccess.disallowInteraction(in: &query) }
        var result: CFTypeRef?
        let status = KeychainSystemAccess.perform(unavailable: errSecInteractionNotAllowed) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        let account = (result as? [String: Any])?[kSecAttrAccount as String] as? String ?? ""
        return (status, account)
    }

    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        KeychainSystemAccess.perform(unavailable: errSecInteractionNotAllowed) {
            SecItemUpdate(
                itemQuery(service: service, account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        var attributes = itemQuery(service: service, account: account)
        attributes[kSecValueData as String] = data
        return KeychainSystemAccess.perform(unavailable: errSecInteractionNotAllowed) {
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    private func itemQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationUI as String: KeychainAccessContext.allowsInteraction
                ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if !KeychainAccessContext.allowsInteraction { KeychainSystemAccess.disallowInteraction(in: &query) }
        return query
    }
}

struct SecurityKeychainAccessor: KeychainAccessing {
    // Prevent concurrent refreshes for a service from stacking authorization dialogs before the first grant lands.
    private static let accessLocks = Mutex<[String: NSLock]>([:])
    let itemAccessor: any SecurityItemAccessing

    init(itemAccessor: any SecurityItemAccessing = SystemSecurityItemAccessor()) {
        self.itemAccessor = itemAccessor
    }

    func readGenericPassword(service: String) throws -> String? {
        try readPassword(service: service, account: nil)
    }

    /// Attributes-only existence probe used on the launch path: an in-process Security-framework
    /// query (no subprocess, returns in microseconds) that never requests the secret and forbids
    /// any UI, so it can neither trigger an unlock prompt nor stall launch. A failed probe (locked
    /// keychain, denied) reports `nil` ("unknown"), never a definite answer, so callers can pick
    /// their safe side.
    func genericPasswordExists(service: String) -> Bool? {
        switch itemAccessor.probeGenericPassword(service: service, account: nil) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readPassword(service: service, account: currentUserAccount())
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try readPassword(service: service, account: account)
    }

    private func readPassword(service: String, account: String?) throws -> String? {
        if KeychainAccessContext.current?.mode == .discovery {
            let status = itemAccessor.probeGenericPassword(service: service, account: account)
            if status == errSecItemNotFound { return nil }
            KeychainAccessContext.current?.recordPermissionNeeded()
            throw KeychainPermissionNeeded()
        }
        let result = Self.withAccessLock(service: service) {
            itemAccessor.readGenericPasswordData(service: service, account: account)
        }
        guard result.status == errSecSuccess else {
            if result.status == errSecItemNotFound { return nil }
            if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(result.status) {
                KeychainAccessContext.current?.recordPermissionNeeded()
            }
            let message = Self.errorMessage(for: result.status)
            AppLog.warn(.keychain, "read failed for service '\(service)' (\(result.status)): \(message)")
            throw KeychainError.readFailed(message)
        }
        guard let data = result.data, let password = String(data: data, encoding: .utf8) else {
            let message = "Keychain item for service '\(service)' is not valid UTF-8."
            AppLog.warn(.keychain, message)
            throw KeychainError.readFailed(message)
        }
        let value = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func writeGenericPassword(service: String, value: String) throws {
        try writePassword(service: service, account: nil, value: value)
    }

    func writeGenericPassword(service: String, account: String, value: String) throws {
        try writePassword(service: service, account: account, value: value)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writePassword(service: service, account: currentUserAccount(), value: value)
    }

    private func writePassword(service: String, account: String?, value: String) throws {
        guard KeychainAccessContext.current?.mode != .discovery else { throw KeychainPermissionNeeded() }
        let data = Data(value.utf8)
        let status = Self.withAccessLock(service: service) {
            if account == nil {
                let lookup = itemAccessor.firstGenericPasswordAccount(service: service)
                if lookup.status == errSecItemNotFound {
                    return itemAccessor.addGenericPasswordData(service: service, account: nil, data: data)
                }
                guard lookup.status == errSecSuccess else { return lookup.status }
                return updateOrAddPassword(
                    service: service,
                    account: lookup.account ?? "",
                    data: data
                )
            }
            return updateOrAddPassword(service: service, account: account, data: data)
        }
        guard status == errSecSuccess else {
            if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
                KeychainAccessContext.current?.recordPermissionNeeded()
            }
            let message = Self.errorMessage(for: status)
            AppLog.warn(.keychain, "write failed for service '\(service)' (\(status)): \(message)")
            throw KeychainError.writeFailed(message)
        }
    }

    private func updateOrAddPassword(service: String, account: String?, data: Data) -> OSStatus {
        let updateStatus = itemAccessor.updateGenericPasswordData(
            service: service,
            account: account,
            data: data
        )
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        return itemAccessor.addGenericPasswordData(service: service, account: account, data: data)
    }

    private static func withAccessLock<T>(service: String, _ operation: () throws -> T) rethrows -> T {
        let lock = accessLocks.withLock { locks in
            if let lock = locks[service] { return lock }
            let lock = NSLock()
            locks[service] = lock
            return lock
        }
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func errorMessage(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }

    private func currentUserAccount() -> String {
        ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? NSUserName()
    }
}

enum KeychainError: Error, LocalizedError {
    case writeFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message.isEmpty ? "Keychain write failed." : message
        case .readFailed(let message):
            return message.isEmpty ? "Keychain read failed." : message
        }
    }
}

