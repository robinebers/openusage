import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum ClaudeDesktopCredentialStatus: Sendable, Equatable {
    case notChecked
    case notFound
    case permissionRequired
    case stale
    case invalid
    case available
}

struct ClaudeDesktopCredentialResult: Sendable {
    var oauth: ClaudeOAuth?
    var status: ClaudeDesktopCredentialStatus
    var organization: String? = nil
}

protocol ClaudeDesktopSafeStorageKeyReading: Sendable {
    func readPassword(allowInteraction: Bool) throws -> String?
}

struct ClaudeDesktopSafeStorageKeyReader: ClaudeDesktopSafeStorageKeyReading {
    private static let service = "Claude Safe Storage"
    private static let account = "Claude Key"

    func readPassword(allowInteraction: Bool) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else {
                throw ClaudeDesktopCredentialError.invalidSafeStorageKey
            }
            return password
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw ClaudeDesktopCredentialError.permissionRequired
        default:
            throw ClaudeDesktopCredentialError.keychainFailure(Int(status))
        }
    }
}

enum ClaudeDesktopCredentialError: Error, Sendable {
    case permissionRequired
    case invalidSafeStorageKey
    case keychainFailure(Int)
    case invalidCiphertext
    case decryptionFailed(Int32)
}

/// Reads Claude Desktop's Electron OAuth cache as an externally owned, read-only credential source.
///
/// The refresh token is deliberately never decoded into `ClaudeOAuth`: Anthropic rotates refresh
/// tokens, so using one here would invalidate Claude Desktop's copy. OpenUsage only borrows a currently
/// valid access token and waits for Desktop to renew it.
struct ClaudeDesktopAuthStore: Sendable {
    private static let configRelativePath = "Library/Application Support/Claude/config.json"
    private static let cookieRelativePaths = [
        "Library/Application Support/Claude/Cookies",
        "Library/Application Support/Claude/Network/Cookies"
    ]
    private static let cacheV1Key = "oauth:tokenCache"
    private static let cacheV2Key = "oauth:tokenCacheV2"
    private static let cookieHosts = [".claude.ai", "claude.ai"]

    var files: TextFileAccessing
    var sqlite: SQLiteAccessing
    var keyReader: ClaudeDesktopSafeStorageKeyReading
    var homeDirectory: @Sendable () -> URL
    var now: @Sendable () -> Date
    private let keyCache: SafeStorageKeyCache

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keyReader: ClaudeDesktopSafeStorageKeyReading = ClaudeDesktopSafeStorageKeyReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        now: @escaping @Sendable () -> Date = Date.init,
        keyCache: SafeStorageKeyCache = SafeStorageKeyCache()
    ) {
        self.files = files
        self.sqlite = sqlite
        self.keyReader = keyReader
        self.homeDirectory = homeDirectory
        self.now = now
        self.keyCache = keyCache
    }

    /// Cheap, prompt-free evidence for first-run detection. The real refresh still decrypts and validates.
    func hasCredentialMaterial() -> Bool {
        let configPath = path(Self.configRelativePath)
        guard let text = try? files.readTextIfPresent(configPath),
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root[Self.cacheV2Key] is String || root[Self.cacheV1Key] is String
        else {
            return false
        }
        let sql = "SELECT 1 FROM cookies WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai') LIMIT 1"
        return Self.cookieRelativePaths.contains { relativePath in
            let databasePath = path(relativePath)
            return files.exists(databasePath)
                && (try? sqlite.queryValue(path: databasePath, sql: sql)) != nil
        }
    }

    func lastKnownAccountUUID() -> String? {
        guard let text = try? files.readTextIfPresent(path(Self.configRelativePath)),
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["lastKnownAccountUuid"] as? String,
              UUID(uuidString: user) != nil
        else { return nil }
        return user.lowercased()
    }

    func load(
        allowInteraction: Bool,
        organization: String? = nil,
        expectedAccountUUID: String? = nil
    ) -> ClaudeDesktopCredentialResult {
        let currentAccountUUID = lastKnownAccountUUID()
        if let expectedAccountUUID,
           currentAccountUUID?.caseInsensitiveCompare(expectedAccountUUID) != .orderedSame
        {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
        }
        guard hasCredentialMaterial() else {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
        }

        do {
            guard let key = try safeStorageKey(allowInteraction: allowInteraction) else {
                return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
            }
            guard let activeOrg = try loadActiveOrganization(key: key),
                  let caches = try loadCaches(key: key)
            else {
                return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
            }

            let targetOrganization = organization?.lowercased() ?? activeOrg
            let selection = Self.selectCredential(
                activeOrganization: targetOrganization,
                activeAccountUUID: currentAccountUUID,
                v2: caches.v2,
                v1: caches.v1,
                now: now()
            )
            switch selection {
            case .available(let oauth):
                return ClaudeDesktopCredentialResult(
                    oauth: oauth, status: .available, organization: targetOrganization
                )
            case .stale:
                return ClaudeDesktopCredentialResult(oauth: nil, status: .stale)
            case .notFound:
                return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
            case .invalid:
                return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
            }
        } catch ClaudeDesktopCredentialError.permissionRequired {
            return ClaudeDesktopCredentialResult(oauth: nil, status: .permissionRequired)
        } catch {
            AppLog.error(LogTag.auth("claude"), "Claude Desktop credential read failed: \(error.localizedDescription)")
            return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
        }
    }

    private func safeStorageKey(allowInteraction: Bool) throws -> Data? {
        if let cached = keyCache.value { return cached }
        guard let password = try keyReader.readPassword(allowInteraction: allowInteraction) else {
            return nil
        }
        let key = try Self.deriveKey(password: password)
        keyCache.value = key
        return key
    }

    private func loadActiveOrganization(key: Data) throws -> String? {
        for relativePath in Self.cookieRelativePaths {
            let databasePath = path(relativePath)
            guard files.exists(databasePath) else { continue }
            for host in Self.cookieHosts {
                let hostSQL = host.replacingOccurrences(of: "'", with: "''")
                let sql = """
                SELECT CASE
                    WHEN length(value) > 0 THEN 'plain:' || hex(CAST(value AS BLOB))
                    ELSE 'encrypted:' || hex(encrypted_value)
                END
                FROM cookies
                WHERE name = 'lastActiveOrg' AND host_key = '\(hostSQL)'
                ORDER BY last_update_utc DESC
                LIMIT 1;
                """
                guard let encoded = try sqlite.queryValue(path: databasePath, sql: sql),
                      let separator = encoded.firstIndex(of: ":")
                else {
                    continue
                }
                let mode = String(encoded[..<separator])
                let hex = String(encoded[encoded.index(after: separator)...])
                guard let stored = Data(hexString: hex) else { continue }

                let value: Data
                if mode == "plain" {
                    value = stored
                } else if mode == "encrypted" {
                    let decrypted = try Self.decrypt(stored, key: key)
                    let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
                    guard decrypted.starts(with: hostHash) else { continue }
                    value = decrypted.dropFirst(hostHash.count)
                } else {
                    continue
                }
                guard let organization = String(data: value, encoding: .utf8),
                      UUID(uuidString: organization) != nil
                else {
                    continue
                }
                return organization.lowercased()
            }
        }
        return nil
    }

    private func loadCaches(key: Data) throws -> (v2: [String: Any]?, v1: [String: Any]?)? {
        guard let text = try files.readTextIfPresent(path(Self.configRelativePath)),
              let data = text.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return (
            v2: try Self.decodeCache(root[Self.cacheV2Key], key: key),
            v1: try Self.decodeCache(root[Self.cacheV1Key], key: key)
        )
    }

    private static func decodeCache(_ stored: Any?, key: Data) throws -> [String: Any]? {
        guard let base64 = stored as? String else { return nil }
        guard let encrypted = Data(base64Encoded: base64) else {
            throw ClaudeDesktopCredentialError.invalidCiphertext
        }
        let plaintext = try decrypt(encrypted, key: key)
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw ClaudeDesktopCredentialError.invalidCiphertext
        }
        return object
    }

    static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyCount
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw ClaudeDesktopCredentialError.invalidSafeStorageKey
        }
        return key
    }

    static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else {
            throw ClaudeDesktopCredentialError.invalidCiphertext
        }

        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ClaudeDesktopCredentialError.decryptionFailed(status)
        }
        output.count = outputLength
        return output
    }

    private func path(_ relativePath: String) -> String {
        homeDirectory().appendingPathComponent(relativePath).path
    }
}

final class SafeStorageKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    var value: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
