import Foundation

struct MistralAuth: Hashable, Sendable {
    /// The full `Cookie` header value for admin.mistral.ai (`ory_session_…=…; csrftoken=…`).
    var cookieHeader: String
    /// The `csrftoken` cookie's value, sent as `X-CSRFTOKEN` on the console fallback route.
    var csrfToken: String?
}

enum MistralAuthError: Error, LocalizedError, Equatable {
    case notSignedIn
    case cookiesUnreadable
    case invalidCookieHeader

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to admin.mistral.ai in your browser and try again."
        case .cookiesUnreadable:
            return "Couldn't read your browser's Mistral cookies. Check browser access permissions."
        case .invalidCookieHeader:
            return "The saved Mistral cookie header is invalid. It needs an ory_session_* cookie."
        }
    }
}

/// Reads a Mistral Admin (admin.mistral.ai) web session the user already has in a browser on this
/// Mac. Mistral publishes its included API and Vibe Code allowances only through the Admin console
/// — there is no companion CLI credential and no API-key endpoint for them — so the browser session
/// (`ory_session_*`, plus `csrftoken`) is the only reusable local credential, exactly like Cursor
/// borrows its app's session token.
///
/// Sources, in order:
/// 1. A pasted `Cookie:` header saved to `~/.config/openusage/mistral.json` (the explicit path —
///    it also makes the saved header an override for the browser read).
/// 2. Firefox's `cookies.sqlite` — plain-text values, host `%mistral.ai`.
/// 3. Chrome-family `Cookies` SQLite (Chrome, Chromium, Brave, Edge, Arc, Orion) — values are
///    `v10`-prefixed AES-CBC ciphertext under the browser's Keychain "Safe Storage" key, decrypted
///    with the same PBKDF2 (`saltysalt`, 1003, AES-128) derivation Claude Desktop's store uses.
///
/// Safari's cookie store needs Full Disk Access and a binary format this store doesn't parse;
/// a Safari-only user pastes the header instead.
struct MistralAuthStore: Sendable {
    /// A saved full `Cookie:` header (JSON `{"cookieHeader":"…"}`), first in the chain.
    static let savedHeaderPath = "~/.config/openusage/mistral.json"

    /// The session is the `ory_session_*` cookie; `csrftoken` enables the console fallback route.
    static let sessionCookiePrefix = "ory_session_"

    private let files: TextFileAccessing
    private let sqlite: SQLiteAccessing
    private let keychain: KeychainAccessing
    private let directoryLister: @Sendable (String) -> [String]

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        directoryLister: @escaping @Sendable (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: expandHome(path))) ?? []
        }
    ) {
        self.files = files
        self.sqlite = sqlite
        self.keychain = keychain
        self.directoryLister = directoryLister
    }

    /// First source with a usable session wins. Blocking (SQLite CLI + Keychain) — call off the
    /// main actor, and mirror this order in `hasLocalCredentials`.
    func loadAuth() throws -> MistralAuth? {
        if let saved = try loadSavedHeader() { return saved }
        if let firefox = try loadFirefoxSession() { return firefox }
        if let chrome = try loadChromiumSession() { return chrome }
        return nil
    }

    /// Whether a saved cookie header exists (local-only, prompt-free probe for first-run seeding).
    /// The browser reads are deliberately not probed here: SQLite presence says nothing about a
    /// Mistral session, and the Keychain read can prompt. A fresh install without a pasted header
    /// simply leaves Mistral off until the user enables it in Customize.
    func hasSavedHeader() -> Bool {
        guard let header = Self.savedHeaderText(fromFileContent: readSavedFileSoft()) else { return false }
        return Self.parseCookieHeader(header) != nil
    }

    /// Parse and validate the saved `Cookie:` header, mapping an unusable one to a typed error so
    /// a hand-edited file reads as "invalid", not silently as "signed out".
    func loadSavedHeader() throws -> MistralAuth? {
        guard let text = try files.readTextIfPresent(Self.savedHeaderPath) else { return nil }
        guard let header = Self.savedHeaderText(fromFileContent: text) else {
            throw MistralAuthError.invalidCookieHeader
        }
        guard let auth = Self.parseCookieHeader(header) else {
            throw MistralAuthError.invalidCookieHeader
        }
        return auth
    }

    private func readSavedFileSoft() -> String? {
        guard let text = try? files.readTextIfPresent(Self.savedHeaderPath) else { return nil }
        return text
    }

    /// The saved file stores the header as `{"cookieHeader":"…"}`; a plain header is tolerated
    /// too (a hand-edited file), so both shapes are accepted.
    static func savedHeaderText(fromFileContent text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return trimmed.nilIfEmpty }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = (object["cookieHeader"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return header.nilIfEmpty
    }

    // MARK: - Saved header

    /// Persist a full `Cookie:` header (with or without the leading `Cookie:`) as the session.
    /// The file wins over the browser reads, so this is also the override path.
    func saveCookieHeader(_ header: String) throws {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.parseCookieHeader(trimmed) != nil else {
            throw MistralAuthError.invalidCookieHeader
        }
        let data = try JSONSerialization.data(withJSONObject: ["cookieHeader": trimmed], options: [.sortedKeys])
        try files.writeText(Self.savedHeaderPath, String(decoding: data, as: UTF8.self))
    }

    /// Remove the saved header; the browser reads take over again on the next refresh.
    func deleteSavedHeader() throws {
        guard files.exists(Self.savedHeaderPath) else { return }
        try files.remove(Self.savedHeaderPath)
    }

    /// Extract the `ory_session_*` pairs and the `csrftoken` value from a pasted `Cookie:` header.
    /// Only those ever leave the machine; every other cookie stays origin-bound.
    static func parseCookieHeader(_ text: String) -> MistralAuth? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count))
        }
        var session: [String] = []
        var csrf: String?
        for part in value.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<equals])
            let cookieValue = String(pair[pair.index(after: equals)...])
            guard !cookieValue.isEmpty,
                  cookieValue.rangeOfCharacter(from: CharacterSet(charactersIn: ",\r\n")) == nil
            else { continue }
            if name.hasPrefix(Self.sessionCookiePrefix), name.count > Self.sessionCookiePrefix.count {
                session.append("\(name)=\(cookieValue)")
            } else if name == "csrftoken", csrf == nil {
                csrf = cookieValue
            }
        }
        guard !session.isEmpty else { return nil }
        return MistralAuth(
            cookieHeader: (session + (csrf.map { ["csrftoken=\($0)"] } ?? [])).joined(separator: "; "),
            csrfToken: csrf
        )
    }

    // MARK: - Firefox

    /// Firefox stores cookie values in plain text. The same name can appear for several hosts, so
    /// one row per cookie is read (newest first) and the first `ory_session_*` wins.
    private func loadFirefoxSession() throws -> MistralAuth? {
        let profilesRoot = "~/Library/Application Support/Firefox/Profiles"
        for profile in directoryLister(profilesRoot) {
            let databasePath = "\(profilesRoot)/\(profile)/cookies.sqlite"
            guard files.exists(databasePath) else { continue }
            let sql = """
            SELECT 'plain:' || name || '=' || value
            FROM moz_cookies
            WHERE (host = 'mistral.ai' OR host LIKE '%.mistral.ai')
              AND (name LIKE '\(Self.sessionCookiePrefix)%' OR name = 'csrftoken')
            ORDER BY lastAccessed DESC
            """
            if let auth = Self.auth(fromEncodedRows: try queryRows(path: databasePath, sql: sql)) {
                return auth
            }
        }
        return nil
    }

    /// Shared row decoding: `mode:name=value` rows (one per cookie, newest first) → the session
    /// pairs and the CSRF value. Duplicate names keep the newest row only.
    static func auth(fromEncodedRows rows: [String]) -> MistralAuth? {
        var session: [String] = []
        var csrf: String?
        var seenSessionNames: Set<String> = []
        for row in rows {
            guard let separator = row.firstIndex(of: ":"),
                  let equals = row.firstIndex(of: "=")
            else { continue }
            let name = String(row[row.index(after: separator)..<equals])
            let value = String(row[row.index(after: equals)...])
            guard !value.isEmpty else { continue }
            if name.hasPrefix(sessionCookiePrefix), name.count > sessionCookiePrefix.count {
                guard seenSessionNames.insert(name).inserted else { continue }
                session.append("\(name)=\(value)")
            } else if name == "csrftoken", csrf == nil {
                csrf = value
            }
        }
        guard !session.isEmpty else { return nil }
        return MistralAuth(
            cookieHeader: (session + (csrf.map { ["csrftoken=\($0)"] } ?? [])).joined(separator: "; "),
            csrfToken: csrf
        )
    }

    // MARK: - Chrome family

    /// Chrome-family cookie values are `v10`-prefixed AES-128-CBC ciphertext (key = PBKDF2 of the
    /// browser's Keychain "Safe Storage" password with `saltysalt`, 1003 iterations, space-filled
    /// IV) — the same envelope Claude Desktop's Safe Storage uses. Each profile's `Cookies`
    /// database is tried (`Network/Cookies` on newer builds, `Cookies` on older ones).
    private func loadChromiumSession() throws -> MistralAuth? {
        for browser in Self.chromeBrowsers {
            let profilesRoot = browser.profilesRoot
            let profileNames = ["Default"] + directoryLister(profilesRoot).filter { $0 != "Default" }
            for profile in profileNames {
                for relative in ["Network/Cookies", "Cookies"] {
                    let databasePath = "\(profilesRoot)/\(profile)/\(relative)"
                    guard files.exists(databasePath) else { continue }
                    if let auth = try loadChromiumSession(databasePath: databasePath,
                                                          keychainService: browser.keychainService,
                                                          keychainAccount: browser.keychainAccount) {
                        return auth
                    }
                }
            }
        }
        return nil
    }

    private func loadChromiumSession(databasePath: String, keychainService: String, keychainAccount: String) throws -> MistralAuth? {
        // host_key patterns: '.mistral.ai' (domain cookie) and 'admin.mistral.ai' (host cookie).
        let sql = """
        SELECT CASE
            WHEN length(value) > 0 THEN 'plain:' || name || '=' || value
            ELSE 'encrypted:' || name || '=' || hex(encrypted_value)
        END
        FROM cookies
        WHERE (host_key = '.mistral.ai' OR host_key LIKE '%.mistral.ai')
          AND (name LIKE '\(Self.sessionCookiePrefix)%' OR name = 'csrftoken')
        ORDER BY last_update_utc DESC
        """
        let rows = try queryRows(path: databasePath, sql: sql)
        guard !rows.isEmpty else { return nil }
        guard let password = try keychain.readGenericPassword(service: keychainService, account: keychainAccount),
              let key = Self.deriveKey(password: password)
        else { return nil }
        // Decrypt the `v10` ciphertext rows in place, then decode through the shared path.
        let plainRows: [String] = rows.map { row in
            guard let separator = row.firstIndex(of: ":"), String(row[..<separator]) == "encrypted" else { return row }
            let payload = String(row[row.index(after: separator)...])
            guard let equals = payload.firstIndex(of: "="),
                  let data = Data(hexString: String(payload[payload.index(after: equals)...])),
                  let decrypted = Self.decryptChromiumValue(data, key: key),
                  let value = String(data: decrypted, encoding: .utf8)
            else { return row }
            return "plain:" + String(payload[..<equals]) + "=" + value
        }
        return Self.auth(fromEncodedRows: plainRows)
    }

    /// One row per matching cookie, newest first. `queryValue` returns a single value, so the rows
    /// are paged through with `LIMIT 1 OFFSET n` until the query answers empty.
    private func queryRows(path: String, sql: String) throws -> [String] {
        var rows: [String] = []
        var cursor = 0
        while let row = try sqlite.queryValue(path: path, sql: sql + " LIMIT 1 OFFSET \(cursor)"),
              !row.isEmpty {
            rows.append(row)
            cursor += 1
        }
        return rows
    }

    // MARK: - Chrome profile discovery

    /// Chrome-family browsers, ordered by likelihood. The Keychain service/account pair is
    /// per-browser ("Chrome Safe Storage"/"Chrome" for Chrome and Chromium; the rest carry their
    /// own names).
    private struct ChromiumBrowser {
        let profilesRoot: String
        let keychainService: String
        let keychainAccount: String
    }

    private static let chromeBrowsers = [
        ChromiumBrowser(
            profilesRoot: "~/Library/Application Support/Google/Chrome",
            keychainService: "Chrome Safe Storage",
            keychainAccount: "Chrome"
        ),
        ChromiumBrowser(
            profilesRoot: "~/Library/Application Support/Chromium",
            keychainService: "Chromium Safe Storage",
            keychainAccount: "Chromium"
        ),
        ChromiumBrowser(
            profilesRoot: "~/Library/Application Support/BraveSoftware/Brave-Browser",
            keychainService: "Brave Safe Storage",
            keychainAccount: "Brave"
        ),
        ChromiumBrowser(
            profilesRoot: "~/Library/Application Support/Microsoft Edge",
            keychainService: "Microsoft Edge Safe Storage",
            keychainAccount: "Microsoft Edge"
        ),
        ChromiumBrowser(
            profilesRoot: "~/Library/Application Support/Arc/User Data",
            keychainService: "Arc Safe Storage",
            keychainAccount: "Arc"
        )
    ]

    // MARK: - Chromium decryption

    /// PBKDF2-HMAC-SHA1 (`saltysalt`, 1003 iterations) → AES-128 key, the Chromium Safe Storage
    /// envelope on macOS.
    static func deriveKey(password: String) -> Data? {
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
        guard result == kCCSuccess else { return nil }
        return key
    }

    /// Decrypt a `v10`-prefixed AES-128-CBC cookie value with the space-filled IV Chromium uses.
    static func decryptChromiumValue(_ encrypted: Data, key: Data) -> Data? {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else { return nil }
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
        guard status == kCCSuccess else { return nil }
        return output.prefix(outputLength)
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
