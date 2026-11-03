import os
import Foundation
import Security

protocol CredentialVault: Sendable {
    func load(_ id: UUID) throws -> AccountCredential?
    func save(_ credential: AccountCredential, for id: UUID) throws
    func update(_ credential: AccountCredential, for id: UUID) throws
    func delete(_ id: UUID) throws
}

/// Holds one sign-in in memory, so a new one proves itself without seeing the sign-in it would replace.
struct ProvisionalCredentialVault: CredentialVault {
    private let stored: OSAllocatedUnfairLock<AccountCredential?>

    init(_ credential: AccountCredential) {
        stored = OSAllocatedUnfairLock(initialState: credential)
    }

    func load(_ id: UUID) throws -> AccountCredential? { stored.withLock { $0 } }
    func save(_ credential: AccountCredential, for id: UUID) throws { stored.withLock { $0 = credential } }
    func update(_ credential: AccountCredential, for id: UUID) throws { stored.withLock { $0 = credential } }
    func delete(_ id: UUID) throws { stored.withLock { $0 = nil } }
}

enum CredentialVaultError: LocalizedError {
    case missingCredential

    var errorDescription: String? {
        "This account's sign-in is missing from the Keychain. Sign in again from the account's page."
    }
}

struct KeychainCredentialVault: CredentialVault {
    static let service = "com.robinebers.openusage.accounts"
    private let items = KeychainItems(service: service)

    func load(_ id: UUID) throws -> AccountCredential? {
        try items.load(id).map { try JSONDecoder().decode(AccountCredential.self, from: $0) }
    }

    func save(_ credential: AccountCredential, for id: UUID) throws {
        try items.save(JSONEncoder().encode(credential), for: id)
    }

    func update(_ credential: AccountCredential, for id: UUID) throws {
        try items.update(JSONEncoder().encode(credential), for: id)
    }

    func delete(_ id: UUID) throws {
        try items.delete(id)
    }
}

/// The generic-password items of one Keychain service, one per id.
struct KeychainItems: Sendable {
    let service: String

    func load(_ id: UUID) throws -> Data? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainVaultError.status(status)
        }
        return data
    }

    func save(_ data: Data, for id: UUID) throws {
        let query = baseQuery(for: id)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainVaultError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainVaultError.status(status)
        }
    }

    func update(_ data: Data, for id: UUID) throws {
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(for: id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { throw CredentialVaultError.missingCredential }
        guard status == errSecSuccess else { throw KeychainVaultError.status(status) }
    }

    func delete(_ id: UUID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainVaultError.status(status)
        }
    }

    private func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }
}

enum KeychainVaultError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "OpenUsage couldn't use its Keychain item for this account (\(reason))."
        }
    }
}
