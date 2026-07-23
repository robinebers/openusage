import CommonCrypto
import Foundation
import LocalAuthentication
import Security

struct OllamaSessionCookie: Hashable, Sendable {
    var value: String
    var source: String
}

enum OllamaAuthError: Error, LocalizedError, Equatable {
    case missingSession
    case sessionExpired
    case missingAPIKey
    case invalidAPIKey

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "No Ollama session. Set OLLAMA_SESSION_COOKIE or sign in with your browser."
        case .sessionExpired:
            return "Ollama session expired. Update your session cookie."
        case .missingAPIKey:
            return "No Ollama API key. Set OLLAMA_API_KEY."
        case .invalidAPIKey:
            return "Ollama API key invalid."
        }
    }
}

struct OllamaAuthStore: Sendable {
    static let sessionCookieName = "__Secure-session"
    static let keychainSessionService = "OpenUsage Ollama Session"
    static let keychainCookieService = "OpenUsage Ollama Cookie"
    static let firefoxProfileRoots = [
        "~/.mozilla/firefox",
        "~/.librewolf",
        "~/snap/firefox/common/.mozilla/firefox",
        "~/Library/Application Support/Firefox/Profiles",
        "~/Library/Application Support/LibreWolf/Profiles"
    ]

    struct ChromiumBrowser: Sendable {
        var name: String
        var profileRoot: String
        var safeStorageService: String
        var safeStorageAccount: String
    }

    static let chromiumBrowsers: [ChromiumBrowser] = [
        ChromiumBrowser(
            name: "Chrome",
            profileRoot: "~/Library/Application Support/Google/Chrome",
            safeStorageService: "Chrome Safe Storage",
            safeStorageAccount: "Chrome"
        ),
        ChromiumBrowser(
            name: "Brave",
            profileRoot: "~/Library/Application Support/BraveSoftware/Brave-Browser",
            safeStorageService: "Brave Safe Storage",
            safeStorageAccount: "Brave"
        ),
        ChromiumBrowser(
            name: "Edge",
            profileRoot: "~/Library/Application Support/Microsoft Edge",
            safeStorageService: "Microsoft Edge Safe Storage",
            safeStorageAccount: "Microsoft Edge"
        ),
        ChromiumBrowser(
            name: "Arc",
            profileRoot: "~/Library/Application Support/Arc",
            safeStorageService: "Arc Safe Storage",
            safeStorageAccount: "Arc"
        )
    ]

    var keychain: KeychainAccessing
    var sqlite: SQLiteAccessing
    var files: TextFileAccessing
    var environment: EnvironmentReading

    init(
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.keychain = keychain
        self.sqlite = sqlite
        self.files = files
        self.environment = environment
    }

    func loadSessionCookie() -> OllamaSessionCookie? {
        if let envSession = extractCookie(from: environment.value(for: "OLLAMA_SESSION_COOKIE")) {
            return OllamaSessionCookie(value: envSession, source: "OLLAMA_SESSION_COOKIE")
        }
        if let envCookie = extractCookie(from: environment.value(for: "OLLAMA_COOKIE")) {
            return OllamaSessionCookie(value: envCookie, source: "OLLAMA_COOKIE")
        }
        if let keychainSession = extractCookie(from: try? keychain.readGenericPasswordForCurrentUser(service: Self.keychainSessionService)) {
            return OllamaSessionCookie(value: keychainSession, source: "keychain")
        }
        if let keychainCookie = extractCookie(from: try? keychain.readGenericPasswordForCurrentUser(service: Self.keychainCookieService)) {
            return OllamaSessionCookie(value: keychainCookie, source: "keychain")
        }
        if let firefoxCookie = readFirefoxCookie() {
            return firefoxCookie
        }
        if let chromiumCookie = readChromiumCookie() {
            return chromiumCookie
        }
        return nil
    }

    func loadAPIKey() -> String? {
        environment.value(for: "OLLAMA_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func extractCookie(from raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        let header = text.replacingOccurrences(of: /^Cookie:\s*/, with: "", options: .regularExpression)
        let parts = header.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let eq = trimmed.firstIndex(of: "=")
            guard let eq else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            if name == Self.sessionCookieName {
                return String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
        }
        if !header.contains(";") { return header }
        return nil
    }

    // MARK: - Firefox

    private func readFirefoxCookie() -> OllamaSessionCookie? {
        for root in Self.firefoxProfileRoots {
            let expanded = expandHome(root)
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: expanded) else { continue }

            let sorted = profiles.sorted { a, b in
                let aIsDefault = a.lowercased().contains("default-release") || a.lowercased() == "default"
                let bIsDefault = b.lowercased().contains("default-release") || b.lowercased() == "default"
                if aIsDefault != bIsDefault { return aIsDefault }
                return a < b
            }

            for profile in sorted {
                let dbPath = "\(expanded)/\(profile)/cookies.sqlite"
                guard files.exists(dbPath) else { continue }
                do {
                    let value = try sqlite.queryValue(
                        path: dbPath,
                        sql: "SELECT value FROM moz_cookies WHERE host IN ('.ollama.com', 'ollama.com') AND name = '__Secure-session' ORDER BY expiry DESC LIMIT 1;"
                    )
                    if let value, let cookie = extractCookie(from: value) {
                        return OllamaSessionCookie(value: cookie, source: "Firefox")
                    }
                } catch {
                    AppLog.warn(LogTag.auth("ollama"), "firefox cookie read failed: \(error.localizedDescription)")
                }
            }
        }
        return nil
    }

    // MARK: - Chromium (Chrome, Brave, Edge, Arc)

    private func readChromiumCookie() -> OllamaSessionCookie? {
        for browser in Self.chromiumBrowsers {
            guard let cookie = readChromiumCookie(browser: browser) else { continue }
            return cookie
        }
        return nil
    }

    private func readChromiumCookie(browser: ChromiumBrowser) -> OllamaSessionCookie? {
        let expanded = expandHome(browser.profileRoot)
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }

        guard let decryptionKey = readSafeStorageKey(service: browser.safeStorageService, account: browser.safeStorageAccount) else {
            return nil
        }

        let cookieDBPath = "\(expanded)/Default/Cookies"
        guard files.exists(cookieDBPath) else { return nil }

        do {
            let encrypted = try sqlite.queryValue(
                path: cookieDBPath,
                sql: "SELECT encrypted_value FROM cookies WHERE host_key IN ('.ollama.com', 'ollama.com') AND name = '__Secure-session' ORDER BY expires_utc DESC LIMIT 1;"
            )
            guard let encrypted, !encrypted.isEmpty else { return nil }

            let encryptedData = Data(encrypted.utf8)
            let decrypted = try decryptChromiumValue(encryptedData, key: decryptionKey)
            guard let decryptedStr = String(data: decrypted, encoding: .utf8),
                  let cookie = extractCookie(from: decryptedStr) else { return nil }

            return OllamaSessionCookie(value: cookie, source: browser.name)
        } catch {
            AppLog.warn(LogTag.auth("ollama"), "\(browser.name) cookie read failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func readSafeStorageKey(service: String, account: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else { return nil }

        return try? deriveKey(password: password)
    }

    // MARK: - Chrome cookie decryption

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
        guard result == kCCSuccess else { throw NSError(domain: "OllamaAuth", code: 1) }
        return key
    }

    private static func decryptChromiumValue(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else {
            throw NSError(domain: "OllamaAuth", code: 2)
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
        guard status == kCCSuccess else { throw NSError(domain: "OllamaAuth", code: 3) }
        output.count = outputLength
        return output
    }
}
