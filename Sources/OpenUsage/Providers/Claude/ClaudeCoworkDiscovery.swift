import Foundation

/// Launch-time identity walk over Cowork's session sandboxes (the `.claude` dirs the Claude desktop
/// app creates per session, see `ClaudeLogUsageScanner.coworkClaudeDirs`).
///
/// Each sandbox carries its own `.claude.json`, which names the account that ran the session. The
/// walk only reads those identity files — no keychain, no credential files — so it can never raise
/// a permission dialog or block launch. Routing is the assembly's job: sandboxes naming the default
/// account stay on the default card, sandboxes naming a known config-dir account attach as its log
/// roots, and a distinct account becomes one Desktop-backed card.
struct ClaudeCoworkDiscovery {
    /// One Cowork session sandbox and the account it names, when it names one.
    struct Sandbox: Equatable, Sendable {
        /// The session's `.claude` dir (a spend-log root: it holds `projects/**/*.jsonl`).
        var root: URL
        /// `nil` when the sandbox's identity file is missing or names no account — such a sandbox
        /// stays on the default card, exactly where the built-in walk has always put it.
        var identityKey: String?
        var label: String?
        /// The account's org UUID (lowercased) — the pin a Desktop-backed card reads credentials
        /// under. Claude Desktop caches tokens per org, so an account without one can't get a card.
        var organization: String?
    }

    struct Result: Sendable {
        var sandboxes: [Sandbox] = []
        /// The support trail (token-free and email-free): identity hashes and paths only.
        var notes: [String] = []
    }

    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL
    /// The sandbox walk, injectable for tests; defaults to the scanner's own walk so discovery and
    /// spend scanning can never see different sandbox sets.
    var listSandboxes: @Sendable (URL) -> [URL]
    /// Wall-clock budget; on overrun the scan returns what it has (and the next launch resumes).
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listSandboxes: @escaping @Sendable (URL) -> [URL] = { ClaudeLogUsageScanner.coworkClaudeDirs(home: $0) },
        timeBudget: TimeInterval = 0.4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.homeDirectory = homeDirectory
        self.listSandboxes = listSandboxes
        self.timeBudget = timeBudget
        self.now = now
    }

    func run() -> Result {
        let started = now()
        var result = Result()
        for root in listSandboxes(homeDirectory()) {
            if now().timeIntervalSince(started) > timeBudget {
                result.notes.append("cowork sandbox scan hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results")
                break
            }
            result.sandboxes.append(sandbox(at: root, notes: &result.notes))
        }
        return result
    }

    private func sandbox(at root: URL, notes: inout [String]) -> Sandbox {
        let identityText: String?
        do {
            identityText = try files.readTextIfPresent(root.path + "/.claude.json")
        } catch {
            notes.append("cowork sandbox \(logPath(root.path)): identity file unreadable → kept on the default card")
            return Sandbox(root: root)
        }
        guard let identityText,
              let parsed = try? JSONDecoder().decode(
                  DefaultAccountObserver.ClaudeStateFile.self, from: Data(identityText.utf8)
              ),
              let account = parsed.oauthAccount,
              let key = DefaultAccountObserver.claudeIdentityKey(account)
        else {
            // No identity = a sandbox the default login produced before identity files existed, or
            // one mid-creation. The built-in walk has always counted these on the default card.
            return Sandbox(root: root)
        }
        return Sandbox(
            root: root,
            identityKey: key,
            label: DefaultAccountObserver.claudeIdentityLabel(account),
            organization: account.organizationUuid?.nilIfEmpty?.lowercased()
        )
    }

    /// Log-safe path: the home prefix is folded to `~` so support logs don't carry the username.
    private func logPath(_ path: String) -> String {
        let home = homeDirectory().path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
