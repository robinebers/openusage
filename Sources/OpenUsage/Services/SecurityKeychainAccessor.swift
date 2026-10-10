import Foundation
import Security
import Synchronization

protocol KeychainAccessing: Sendable {
    /// Whether an item exists, without reading its secret. `nil` means the probe itself failed
    /// (locked keychain, denied) — the caller picks its own safe side, which is not the same for every
    /// caller. A requirement, so existential calls reach the real metadata-only probe.
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

    /// Default for in-memory mocks, which have no prompts to avoid: answer from a read.
    func genericPasswordExists(service: String) -> Bool? {
        do {
            return try readGenericPassword(service: service) != nil
        } catch {
            return nil
        }
    }
}

protocol SecurityItemAccessing: Sendable {
    func probeGenericPassword(service: String) -> OSStatus
    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?)
    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?)
    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus
    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus
}

extension SecurityItemAccessing {
    // Test adapters without a metadata model remain indeterminate; never read a secret to probe.
    func probeGenericPassword(service: String) -> OSStatus { errSecInteractionNotAllowed }
}

struct SystemSecurityItemAccessor: SecurityItemAccessing {
    func probeGenericPassword(service: String) -> OSStatus {
        var query = KeychainSystemAccess.genericPasswordQuery(service: service, account: nil, interactive: false)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return KeychainSystemAccess.perform(interactive: false, unavailable: KeychainSystemAccess.busyStatus) {
            SecItemCopyMatching(query as CFDictionary, nil)
        }
    }

    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        var query = itemQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = KeychainSystemAccess.perform(unavailable: KeychainSystemAccess.busyStatus) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        return (status, result as? Data)
    }

    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) {
        var query = itemQuery(service: service, account: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = KeychainSystemAccess.perform(unavailable: KeychainSystemAccess.busyStatus) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        let account = (result as? [String: Any])?[kSecAttrAccount as String] as? String ?? ""
        return (status, account)
    }

    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        KeychainSystemAccess.perform(unavailable: KeychainSystemAccess.busyStatus) {
            SecItemUpdate(
                itemQuery(service: service, account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        var attributes = itemQuery(service: service, account: account)
        attributes[kSecValueData as String] = data
        return KeychainSystemAccess.perform(unavailable: KeychainSystemAccess.busyStatus) {
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    private func itemQuery(service: String, account: String?) -> [String: Any] {
        KeychainSystemAccess.genericPasswordQuery(
            service: service, account: account, interactive: KeychainAccessContext.allowsInteraction
        )
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

    /// Attributes-only existence probe: an in-process Security-framework query that never requests
    /// the secret and forbids any UI, so it can neither trigger a prompt nor stall launch.
    func genericPasswordExists(service: String) -> Bool? {
        switch itemAccessor.probeGenericPassword(service: service) {
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
        let result = Self.withAccessLock(service: service) {
            itemAccessor.readGenericPasswordData(service: service, account: account)
        }
        guard result.status == errSecSuccess else {
            if result.status == errSecItemNotFound { return nil }
            KeychainSystemAccess.recordRefusal(result.status)
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
            KeychainSystemAccess.recordRefusal(status)
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
        if status == KeychainSystemAccess.busyStatus { return "another Keychain request is waiting on the user" }
        return SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
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
