import Foundation

/// A Codex home whose `auth.json` names the account signed in there.
struct CodexHomeLogin: Equatable, Sendable {
    let home: String
    let identity: CodexAccountIdentity

    var authPath: String { home + "/auth.json" }
}

struct CodexHomeScan: Equatable, Sendable {
    let logins: [CodexHomeLogin]
    /// A home holds a token that names no account at all. Such a login may belong to a second account,
    /// so history with no provable owner must not be counted while it exists.
    let hasIncompleteLogin: Bool
}

/// Finds the Codex homes on this Mac — the configured default (`CODEX_HOME`, else `~/.config/codex`
/// and `~/.codex`) plus sibling `~/.codex-*` and `~/.config/codex-*` folders — and reads which
/// account is signed in at each. Read-only.
struct CodexHomeScanner: Sendable {
    var environment: EnvironmentReading
    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL
    var listDirectories: @Sendable (String) -> [String]

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listDirectories: @escaping @Sendable (String) -> [String] = Self.listSubdirectories
    ) {
        self.environment = environment
        self.files = files
        self.homeDirectory = homeDirectory
        self.listDirectories = listDirectories
    }

    static func listSubdirectories(_ path: String) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true
            else { return nil }
            return url.lastPathComponent
        }
    }

    /// `CODEX_HOME` is one path, as the Codex CLI reads it. (The log scanner's comma-list parsing of
    /// the same variable is a separate ccusage compatibility.)
    static func configuredHomeValues(environment: EnvironmentReading) -> [String] {
        if let home = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty
        {
            return [home]
        }
        return ["~/.config/codex", "~/.codex"]
    }

    static func configuredHomes(environment: EnvironmentReading, homeDirectory: URL) -> [String] {
        uniqueHomes(configuredHomeValues(environment: environment), homeDirectory: homeDirectory)
    }

    func candidateHomes() -> [String] {
        let home = homeDirectory()
        let siblingHomes = listDirectories(home.path)
            .filter { $0.hasPrefix(".codex-") }
            .sorted()
            .map { "~/\($0)" }
            + listDirectories(home.appendingPathComponent(".config").path)
            .filter { $0.hasPrefix("codex-") }
            .sorted()
            .map { "~/.config/\($0)" }
        return Self.uniqueHomes(
            Self.configuredHomes(environment: environment, homeDirectory: home) + ["~/.config/codex", "~/.codex"] + siblingHomes,
            homeDirectory: home
        )
    }

    /// Every candidate home (plus `additionalHomes`) holding a token login that names its account.
    func logins(additionalHomes: [String] = []) -> [CodexHomeLogin] {
        scan(additionalHomes: additionalHomes).logins
    }

    func scan(additionalHomes: [String] = []) -> CodexHomeScan {
        let homes = Self.uniqueHomes(candidateHomes() + additionalHomes, homeDirectory: homeDirectory())
        var logins: [CodexHomeLogin] = []
        var hasIncompleteLogin = false
        for home in homes {
            let text: String?
            do {
                text = try files.readTextIfPresent(home + "/auth.json")
            } catch {
                AppLog.warn(.config, "accounts: Codex home \(home) has an unreadable auth.json; skipping it")
                continue
            }
            guard let text,
                  let auth = CodexAuthStore.parseAuth(text),
                  auth.tokens?.accessToken?.nilIfEmpty != nil
            else { continue }
            if let identity = CodexAccountIdentity(auth: auth) {
                logins.append(CodexHomeLogin(home: home, identity: identity))
            } else {
                hasIncompleteLogin = true
            }
        }
        return CodexHomeScan(logins: logins, hasIncompleteLogin: hasIncompleteLogin)
    }

    static func standardizedHome(_ raw: String, homeDirectory: URL) -> String {
        let expanded = expandTilde(raw, homeDirectory: homeDirectory).trimmingTrailingSlashes
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// A home with `~`, `..`, and symlinks resolved, so an alias of a home xswap manages compares equal
    /// to the home itself.
    static func canonicalHome(
        _ raw: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        URL(fileURLWithPath: standardizedHome(raw, homeDirectory: homeDirectory)).resolvingSymlinksInPath().path
    }

    static func expandTilde(_ path: String, homeDirectory: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory.path + String(path.dropFirst(1))
    }

    private static func uniqueHomes(_ homes: [String], homeDirectory: URL) -> [String] {
        var seen = Set<String>()
        return homes.compactMap { raw in
            let standardized = standardizedHome(raw, homeDirectory: homeDirectory)
            return seen.insert(standardized).inserted ? standardized : nil
        }
    }
}
