import CryptoKit
import Foundation

/// Local bridge between a runtime credential read and the next launch's no-secret discovery pass.
/// Keyring-mode Codex hides `tokens.account_id` inside the keychain, so discovery cannot learn it
/// without prompting. A successful runtime read records the opaque account id under an opaque hash
/// of its home, bound to an opaque fingerprint of that keychain item's non-secret attributes. The
/// following launch can then reconcile that home by account identity without reading a keychain
/// secret or persisting an absolute path. Replacing the item in place changes `mdat`, invalidates the
/// binding, and prevents an A → B re-login from being mistaken for the cached account A.
protocol CodexHomeIdentityCaching: Sendable {
    func identityKey(forHome path: String, keychainItemFingerprint: String) -> String?
    func record(identityKey: String, forHome path: String, keychainItemFingerprint: String)
}

final class CodexHomeIdentityCache: CodexHomeIdentityCaching, @unchecked Sendable {
    static let storageKey = "openusage.codexHomeIdentities.v1"

    private struct Entry: Codable {
        var identityKey: String
        var keychainItemFingerprint: String?
    }

    private static let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func identityKey(forHome path: String, keychainItemFingerprint: String) -> String? {
        guard let fingerprint = normalizedItemFingerprint(keychainItemFingerprint) else { return nil }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let entry = load()[homeFingerprint(path)],
              entry.keychainItemFingerprint == fingerprint
        else { return nil }
        return entry.identityKey
    }

    func record(identityKey: String, forHome path: String, keychainItemFingerprint: String) {
        let normalized = identityKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = normalizedItemFingerprint(keychainItemFingerprint)
        guard !normalized.isEmpty, !ProviderInstanceID.isPathDerivedKey(normalized) else {
            AppLog.error(.config, "refused to cache a non-account Codex home identity")
            return
        }
        guard let fingerprint else {
            AppLog.error(.config, "refused to cache a Codex home identity without a keychain item fingerprint")
            return
        }

        Self.lock.lock()
        defer { Self.lock.unlock() }
        var identities = load()
        let homeKey = homeFingerprint(path)
        let entry = Entry(identityKey: normalized, keychainItemFingerprint: fingerprint)
        guard identities[homeKey]?.identityKey != entry.identityKey
            || identities[homeKey]?.keychainItemFingerprint != entry.keychainItemFingerprint
        else { return }
        identities[homeKey] = entry
        do {
            defaults.set(try JSONEncoder().encode(identities), forKey: Self.storageKey)
        } catch {
            AppLog.error(.config, "failed to encode the Codex home-identity cache: \(error.localizedDescription)")
        }
    }

    private func homeFingerprint(_ path: String) -> String {
        ProviderInstanceID.pathDerivedIdentityKey(forCanonicalHome: path)
    }

    private func normalizedItemFingerprint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The production accessor already returns a SHA-256 digest. Hash again at the persistence
        // boundary so even a custom accessor can never cause raw keychain attributes to be stored.
        return SHA256.hash(data: Data(trimmed.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            // Early provider-instance builds stored `[opaqueHome: identity]` without a keychain item
            // version. Preserve the identity as an explicitly untrusted entry: a runtime secret read
            // upgrades it with a fingerprint, but discovery must never use it before then.
            if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
                return legacy.mapValues { Entry(identityKey: $0, keychainItemFingerprint: nil) }
            }
            AppLog.error(.config, "failed to decode the Codex home-identity cache: \(error.localizedDescription)")
            return [:]
        }
    }
}
