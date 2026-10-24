import CommonCrypto
import Foundation
import Security

/// Cursor 3.27 seals `cursorAuth/accessToken` and `cursorAuth/refreshToken` when
/// `cursor.storage.authTokenEncryptionAtRest` is on. The cell is
/// `cursor-safe-storage:v1:` plus standard base64 of an Electron safeStorage
/// `v10` blob: AES-128-CBC, a 16-space IV, and a key from PBKDF2-HMAC-SHA1
/// (salt `saltysalt`, 1003 rounds) over the Keychain password.
enum CursorSealedToken {
    static let prefix = "cursor-safe-storage:v1:"

    static func isSealed(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    /// The JWT inside a sealed cell, or nil when the password does not open it.
    /// A wrong key can still produce padding-valid garbage, so the result has to
    /// be a JWT before it is used as a bearer token.
    static func open(stored: String, password: String) -> String? {
        guard isSealed(stored) else { return nil }
        let encoded = String(stored.dropFirst(prefix.count))
        guard let encrypted = Data(base64Encoded: encoded),
              let key = try? deriveKey(password: password),
              let plain = try? decrypt(encrypted, key: key),
              let token = String(data: plain, encoding: .utf8),
              isJWT(token)
        else {
            return nil
        }
        return token
    }

    /// Seal a rotated JWT the same way Cursor wrote the cell, so a refresh does
    /// not replace the ciphertext with a plaintext token.
    static func seal(token: String, password: String) throws -> String {
        let key = try deriveKey(password: password)
        let encrypted = try encrypt(Data(token.utf8), key: key)
        return prefix + encrypted.base64EncodedString()
    }

    private static func isJWT(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty } && ProviderParse.jwtPayload(token) != nil
    }

    private static func deriveKey(password: String) throws -> Data {
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
            throw CursorSealedTokenError.invalidKey
        }
        return key
    }

    private static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else {
            throw CursorSealedTokenError.invalidCiphertext
        }
        return try crypt(CCOperation(kCCDecrypt), data: encrypted.dropFirst(3), key: key)
    }

    private static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let encrypted = try crypt(CCOperation(kCCEncrypt), data: plaintext, key: key)
        return Data("v10".utf8) + encrypted
    }

    private static func crypt(_ operation: CCOperation, data: any DataProtocol, key: Data) throws -> Data {
        let input = Data(data)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw CursorSealedTokenError.cryptFailed(status)
        }
        output.count = outputLength
        return output
    }
}

enum CursorSealedTokenError: Error {
    case invalidKey
    case invalidCiphertext
    case cryptFailed(Int32)
    case missingKey
}

protocol CursorSafeStorageKeyReading: Sendable {
    func readPassword() throws -> String?
}

/// The password Electron's safeStorage keeps for Cursor. Read by OpenUsage itself,
/// not through `/usr/bin/security`, so an "Always Allow" trusts this app alone.
/// The password is kept in memory for the process; it is never written out.
struct CursorSafeStorageKeyReader: CursorSafeStorageKeyReading {
    static let service = "Cursor Safe Storage"
    /// Current Cursor builds use `Cursor Key`, matching Claude Desktop's `Claude Key`.
    /// `Cursor` is the account name some safeStorage builds use instead.
    static let accounts = ["Cursor Key", "Cursor"]

    private static let cache = SafeStorageKeyCache()

    func readPassword() throws -> String? {
        if let cached = Self.cache.value,
           let password = String(data: cached, encoding: .utf8),
           !password.isEmpty {
            return password
        }
        for account in Self.accounts {
            switch Self.copyPassword(account: account) {
            case .found(let password):
                Self.cache.value = Data(password.utf8)
                return password
            case .missing:
                continue
            case .denied:
                return nil
            }
        }
        return nil
    }

    private enum CopyResult {
        case found(String)
        case missing
        case denied
    }

    private static func copyPassword(account: String) -> CopyResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        let (status, data) = KeychainAccessGuard.read(service: service) {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
        switch status {
        case errSecSuccess:
            guard let data, let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                return .denied
            }
            return .found(password)
        case errSecItemNotFound:
            return .missing
        default:
            return .denied
        }
    }
}
