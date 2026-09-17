import Foundation

/// Browser-cookie sources for the Muse `llm_sess` session cookie, ported
/// from lassejlv's upstream PR #1248 (robinebers/openusage). Covered there by
/// the page-scrape quota path; here it feeds the same fallback slot behind
/// our OAuth-first account endpoint and Responses probe.
///
/// Resolution order, first hit wins:
/// 1. Manually saved cookie: `~/.config/muse-usage/session`, then the
///    `MUSE_LLM_SESS` environment variable. Never touches the keychain or a
///    browser, so it works with zero permissions.
/// 2. The default browser's cookie store, then every other installed
///    browser. Chromium cookies are Keychain-encrypted; Firefox stores them
///    in cleartext; Safari uses `Cookies.binarycookies`.
///
/// Reads distinguish found / absent / present-but-unreadable (macOS denied
/// the read — Full Disk Access missing) so a permission problem never
/// renders as "not logged in".
enum MuseBrowserCookieResult: Sendable, Equatable {
    case found(String)
    case absent
    case unreadable
}

/// Browsers probed for the session cookie, in fallback order after the default browser.
enum MuseBrowser: String, CaseIterable, Sendable {
    case brave
    case chrome
    case arc
    case edge
    case chromium
    case firefox
    case safari

    /// macOS bundle ID used to resolve the user's default browser.
    var bundleID: String {
        switch self {
        case .brave: return "com.brave.browser"
        case .chrome: return "com.google.chrome"
        case .arc: return "company.thebrowser.browser"
        case .edge: return "com.microsoft.edgemac"
        case .chromium: return "org.chromium.chromium"
        case .firefox: return "org.mozilla.firefox"
        case .safari: return "com.apple.safari"
        }
    }
}

struct MuseSessionCookieStore: Sendable {
    static let cookieName = "llm_sess"
    static let cookieDomainHint = "meta.ai"
    static let configPaths = ["~/.config/muse-usage/session"]
    static let environmentNames = ["MUSE_LLM_SESS"]

    private let keyStore: UserAPIKeyStore
    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var process: ProcessRunning
    var binaryReader: @Sendable (String) throws -> Data?
    var profileNames: @Sendable (String) -> [String]

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        process: ProcessRunning = SystemProcessRunner(),
        binaryReader: @escaping @Sendable (String) throws -> Data? = Self.readBinaryFile,
        profileNames: @escaping @Sendable (String) -> [String] = Self.listProfiles
    ) {
        keyStore = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { _ in MuseUsageError.apiKeyMissing }
        )
        self.sqlite = sqlite
        self.keychain = keychain
        self.process = process
        self.binaryReader = binaryReader
        self.profileNames = profileNames
    }

    // MARK: - Manual cookie (config file / env)

    func loadManualCookie() -> String? {
        keyStore.loadKey()
    }

    // MARK: - Browser cookies

    /// First browser cookie found, default browser first. Throws nothing: per-browser failures
    /// fall through to the next browser, and collapse to `unreadable` only when at least one
    /// store was present-but-unreadable and nothing else yielded a cookie.
    func loadBrowserCookie() -> MuseBrowserCookieResult {
        var sawUnreadable = false
        for browser in orderedBrowsers() {
            switch loadBrowserCookie(browser) {
            case .found(let cookie): return .found(cookie)
            case .unreadable: sawUnreadable = true
            case .absent: break
            }
        }
        return sawUnreadable ? .unreadable : .absent
    }

    /// Local-only presence probe for `hasLocalCredentials`: true when any browser holds the
    /// cookie row. Never reads the keychain (no unlock prompts on the launch path) and treats
    /// every failure as absent — `refresh()` reports the loud reason.
    func browserCookiePresent() -> Bool {
        if firefoxCookiePresent() || safariCookiePresent() { return true }
        return orderedBrowsers().contains { chromiumCookiePresent($0) }
    }

    func orderedBrowsers() -> [MuseBrowser] {
        var order = MuseBrowser.allCases
        if let preferred = defaultBrowser(),
           let index = order.firstIndex(of: preferred) {
            order.remove(at: index)
            order.insert(preferred, at: 0)
        }
        return order
    }

    func defaultBrowser() -> MuseBrowser? {
        let result = try? process.run(
            executable: "/usr/bin/defaults",
            arguments: ["read", "com.apple.LaunchServices/com.apple.launchservices.secure", "LSHandlers"],
            environment: [:],
            timeout: 5
        )
        guard let output = result?.stdout, !(result?.succeeded == false) else { return nil }
        return Self.parseDefaultBrowser(output)
    }

    /// Parse `LSHandlers` output: each scheme entry carries `LSHandlerRoleAll` directly before
    /// its `LSHandlerURLScheme` (block-splitting breaks on the nested
    /// `LSHandlerPreferredVersions` braces, so match adjacently). Prefers the https handler.
    static func parseDefaultBrowser(_ output: String) -> MuseBrowser? {
        let pattern = #"LSHandlerRoleAll = "?([^";\s]+)"?;\s*LSHandlerURLScheme = (https?);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, range: range).compactMap { match -> (String, String)? in
            guard match.numberOfRanges == 3,
                  let bundleRange = Range(match.range(at: 1), in: output),
                  let schemeRange = Range(match.range(at: 2), in: output)
            else { return nil }
            return (String(output[bundleRange]), String(output[schemeRange]))
        }
        for (bundle, scheme) in matches where scheme == "https" {
            if let browser = MuseBrowser.allCases.first(where: { $0.bundleID == bundle }) {
                return browser
            }
        }
        for (bundle, _) in matches {
            if let browser = MuseBrowser.allCases.first(where: { $0.bundleID == bundle }) {
                return browser
            }
        }
        return nil
    }

    private func loadBrowserCookie(_ browser: MuseBrowser) -> MuseBrowserCookieResult {
        switch browser {
        case .firefox: return loadFirefoxCookie()
        case .safari: return loadSafariCookie()
        case .brave, .chrome, .arc, .edge, .chromium: return loadChromiumCookie(browser)
        }
    }

    // MARK: - Chromium (Brave/Chrome/Arc/Edge)

    /// Application Support directory + Keychain service per Chromium browser.
    static func chromiumIdentity(_ browser: MuseBrowser) -> (directory: String, service: String)? {
        switch browser {
        case .brave: return ("BraveSoftware/Brave-Browser", "Brave Safe Storage")
        case .chrome: return ("Google/Chrome", "Chrome Safe Storage")
        case .arc: return ("Arc/User Data", "Arc Safe Storage")
        case .edge: return ("Microsoft Edge", "Microsoft Edge Safe Storage")
        case .chromium: return ("Chromium", "Chromium Safe Storage")
        case .firefox, .safari: return nil
        }
    }

    static func chromiumCookiePaths(_ browser: MuseBrowser) -> [String] {
        guard let identity = chromiumIdentity(browser) else { return [] }
        let profiles = ["Default"] + (1..<10).map { "Profile \($0)" }
        return profiles.map {
            "~/Library/Application Support/\(identity.directory)/\($0)/Cookies"
        }
    }

    /// Prefer the cookie set on the exact usage host when several meta.ai rows exist.
    private static let cookiePreferenceSQL =
        "CASE WHEN host_key IN ('dev.meta.ai', '.dev.meta.ai') THEN 0 ELSE 1 END, host_key"

    private func loadChromiumCookie(_ browser: MuseBrowser) -> MuseBrowserCookieResult {
        guard let identity = Self.chromiumIdentity(browser) else { return .absent }
        var sawUnreadable = false
        for path in Self.chromiumCookiePaths(browser) {
            // Cleartext first (unusual on macOS, but some stores keep it), then the
            // Keychain-encrypted value as hex — the sqlite CLI would mangle raw blob bytes.
            if let value = tryOrUnreadable(sawUnreadable: &sawUnreadable, {
                try sqlite.queryValue(path: path, sql: """
                    SELECT value FROM cookies \
                    WHERE host_key LIKE '%\(Self.cookieDomainHint)%' \
                    AND name = '\(Self.cookieName)' AND value != '' \
                    ORDER BY \(Self.cookiePreferenceSQL) LIMIT 1
                    """)
            }), !value.isEmpty {
                return .found(value)
            }
            guard let hex = tryOrUnreadable(sawUnreadable: &sawUnreadable, {
                try sqlite.queryValue(path: path, sql: """
                    SELECT hex(encrypted_value) FROM cookies \
                    WHERE host_key LIKE '%\(Self.cookieDomainHint)%' \
                    AND name = '\(Self.cookieName)' \
                    AND (value = '' OR value IS NULL) \
                    ORDER BY \(Self.cookiePreferenceSQL) LIMIT 1
                    """)
            }), !hex.isEmpty else { continue }
            guard let password = try? keychain.readGenericPassword(service: identity.service),
                  !password.isEmpty,
                  let cookie = try? MuseCookieDecrypt.decryptChromiumCookie(hex: hex, password: password)
            else {
                sawUnreadable = true
                continue
            }
            return .found(cookie)
        }
        return sawUnreadable ? .unreadable : .absent
    }

    private func chromiumCookiePresent(_ browser: MuseBrowser) -> Bool {
        Self.chromiumCookiePaths(browser).contains { path in
            (try? sqlite.queryValue(path: path, sql: """
                SELECT 1 FROM cookies \
                WHERE host_key LIKE '%\(Self.cookieDomainHint)%' \
                AND name = '\(Self.cookieName)' LIMIT 1
                """)) != nil
        }
    }

    // MARK: - Firefox

    static let firefoxProfilesDirectory = "~/Library/Application Support/Firefox/Profiles"

    private func firefoxCookieDatabases() -> [String] {
        profileNames(Self.firefoxProfilesDirectory).map {
            "\(Self.firefoxProfilesDirectory)/\($0)/cookies.sqlite"
        }
    }

    private func loadFirefoxCookie() -> MuseBrowserCookieResult {
        var sawUnreadable = false
        for path in firefoxCookieDatabases() {
            if let value = tryOrUnreadable(sawUnreadable: &sawUnreadable, {
                try sqlite.queryValue(path: path, sql: """
                    SELECT value FROM moz_cookies \
                    WHERE host LIKE '%\(Self.cookieDomainHint)%' \
                    AND name = '\(Self.cookieName)' AND value != '' \
                    ORDER BY host LIMIT 1
                    """)
            }), !value.isEmpty {
                return .found(value)
            }
        }
        return sawUnreadable ? .unreadable : .absent
    }

    private func firefoxCookiePresent() -> Bool {
        firefoxCookieDatabases().contains { path in
            (try? sqlite.queryValue(path: path, sql: """
                SELECT 1 FROM moz_cookies \
                WHERE host LIKE '%\(Self.cookieDomainHint)%' \
                AND name = '\(Self.cookieName)' LIMIT 1
                """)) != nil
        }
    }

    // MARK: - Safari

    static let safariCookiePaths = [
        "~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
        "~/Library/Cookies/Cookies.binarycookies"
    ]

    private func loadSafariCookie() -> MuseBrowserCookieResult {
        var sawUnreadable = false
        for path in Self.safariCookiePaths {
            let data: Data?
            do {
                data = try binaryReader(path)
            } catch {
                sawUnreadable = true
                continue
            }
            guard let data, !data.isEmpty else { continue }
            if let cookie = MuseBinaryCookies.cookie(named: Self.cookieName, domainHint: Self.cookieDomainHint, in: data) {
                return .found(cookie)
            }
            // Present but unparseable: a corrupt store must read as unreadable (with the
            // Full Disk Access guidance), never as "not logged in".
            if !MuseBinaryCookies.isWellFormed(data) {
                sawUnreadable = true
            }
        }
        return sawUnreadable ? .unreadable : .absent
    }

    private func safariCookiePresent() -> Bool {
        Self.safariCookiePaths.contains { path in
            guard let data = try? binaryReader(path), !data.isEmpty else { return false }
            return MuseBinaryCookies.cookie(named: Self.cookieName, domainHint: Self.cookieDomainHint, in: data) != nil
        }
    }

    // MARK: - Defaults

    /// Runs a throwing SQLite read, folding "no row" (nil) through and recording store-level
    /// failures (TCC denial, corrupt DB) in `sawUnreadable`. A missing database is absence, not
    /// failure — `SQLiteCLIAccessor` returns nil before launching a process for those.
    private func tryOrUnreadable(sawUnreadable: inout Bool, _ read: () throws -> String?) -> String? {
        do {
            return try read()
        } catch {
            sawUnreadable = true
            return nil
        }
    }

    static func readBinaryFile(_ path: String) throws -> Data? {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: expandHome(path)), options: .mappedIfSafe)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func listProfiles(_ directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: expandHome(directory))) ?? []
    }
}
