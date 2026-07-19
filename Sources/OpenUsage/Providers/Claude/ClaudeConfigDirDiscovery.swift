import Foundation

/// Launch-time scan for EXTRA Claude logins in custom config dirs — the homes a user points
/// `CLAUDE_CONFIG_DIR` at besides the default (`~/.claude` / `$XDG_CONFIG_HOME/claude`).
///
/// Runs synchronously inside the launch account pass under a small time budget, and reads **no
/// keychain secrets** — credential presence is checked from file existence and attributes-only
/// keychain probes, so discovery can never raise a macOS permission dialog or block launch.
///
/// Shape rules: candidates are dot-dirs at `~` and dirs under `~/.config` — bounded, never temp dirs
/// or project trees. A candidate only counts when it carries Claude's exact credential shape AND
/// names its account (identity read from the home itself). Identity-extraction-is-validation: that
/// routing, not name matching, is what keeps toys, forks, and sandbox homes out.
struct ClaudeConfigDirDiscovery {
    /// One accepted custom-config-dir login. Whether it becomes its own card or attaches to an
    /// existing account's record is the assembly's call, not discovery's.
    struct Finding: Equatable, Sendable {
        var identityKey: String
        var label: String?
        /// The expanded config-dir path (the card's credential home and its spend-log root).
        var anchorPath: String
        /// The literal string whose hash names the dir's keychain item (see `ClaudeCredentialScope`).
        var keychainLiteral: String
    }

    struct Result: Sendable {
        var findings: [Finding] = []
        /// The support trail: one line per notable decision (near-miss rejections, folds), emitted to
        /// the log so a "my account didn't show up" report is diagnosable from a default log.
        /// Token-free and email-free by construction — identity hashes, kinds, and paths only.
        var notes: [String] = []
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL
    var listSubdirectories: @Sendable (URL) -> [URL]
    /// Wall-clock budget; on overrun the scan returns what it has (and the next launch resumes).
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listSubdirectories: @escaping @Sendable (URL) -> [URL] = Self.filesystemSubdirectories,
        timeBudget: TimeInterval = 0.4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        self.listSubdirectories = listSubdirectories
        self.timeBudget = timeBudget
        self.now = now
    }

    func run() -> Result {
        let started = now()
        var result = Result()
        let excluded = Set(defaultClaudeConfigDirs().map(canonical))

        for candidate in candidateDirectories() {
            if now().timeIntervalSince(started) > timeBudget {
                result.notes.append("claude config-dir scan hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results")
                break
            }
            guard !excluded.contains(canonical(candidate.path)) else { continue }
            if let finding = claudeCandidate(at: candidate, notes: &result.notes) {
                result.findings.append(finding)
            }
        }
        return result
    }

    // MARK: - Candidates

    /// Dot-dirs at `~` plus dirs under `~/.config`, in stable path order.
    private func candidateDirectories() -> [URL] {
        let home = homeDirectory()
        var candidates = listSubdirectories(home).filter { $0.lastPathComponent.hasPrefix(".") }
        candidates += listSubdirectories(home.appendingPathComponent(".config"))
        return candidates.sorted { $0.path < $1.path }
    }

    private static func filesystemSubdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private func claudeCandidate(at url: URL, notes: inout [String]) -> Finding? {
        // Pre-gate: only dirs that carry an identity file at all enter the trail — everything else
        // is a random dot-dir and stays out of the log. (A custom config dir keeps its state INSIDE
        // the dir; only the default `~/.claude` keeps it next door at `~/.claude.json`, and the
        // default homes are excluded before this runs.)
        guard let identityText = try? files.readTextIfPresent(url.path + "/.claude.json") else {
            return nil
        }
        guard let parsed = try? JSONDecoder().decode(
                  DefaultAccountObserver.ClaudeStateFile.self, from: Data(identityText.utf8)
              ),
              let account = parsed.oauthAccount,
              let key = DefaultAccountObserver.claudeIdentityKey(account)
        else {
            notes.append("claude candidate \(logPath(url.path)): identity file present but names no account → skipped")
            return nil
        }

        // Credential shape: the dir's own `.credentials.json`, or its *computed* keychain item.
        // Claude Code hashes the literal CLAUDE_CONFIG_DIR string, so every plausible spelling of
        // this path is probed (attributes only — no secret, no prompt).
        let fileBacked = (try? files.readTextIfPresent(url.path + "/.credentials.json"))
            .flatMap { $0 }
            .flatMap { ClaudeAuthStore.parseCredentials($0) }?
            .claudeAiOauth?.accessToken?.nilIfEmpty != nil

        var matchedLiteral: String?
        let literals = keychainLiterals(for: url)
        for literal in literals {
            let service = ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: literal,
                environment: environment
            )
            if keychain.genericPasswordExists(service: service) == true {
                matchedLiteral = literal
                break
            }
        }
        guard fileBacked || matchedLiteral != nil else {
            notes.append("claude candidate \(logPath(url.path)): identity \(hash8(key)) but no credential (no .credentials.json, no keychain item for \(literals.count) path spellings) → skipped")
            return nil
        }

        notes.append("claude candidate \(logPath(url.path)): accepted (\(hash8(key)), \(fileBacked ? "file" : "keychain") credential)")
        return Finding(
            identityKey: key,
            label: DefaultAccountObserver.claudeIdentityLabel(account),
            anchorPath: url.path,
            keychainLiteral: matchedLiteral ?? url.path
        )
    }

    /// Every plausible spelling Claude Code might have hashed for this dir's keychain item: the path
    /// as listed, symlink-resolved, and each with the home prefix swapped for `~` (users export
    /// `CLAUDE_CONFIG_DIR=~/x` and `=/Users/me/x` interchangeably).
    private func keychainLiterals(for url: URL) -> [String] {
        let home = homeDirectory()
        let homePaths = Array(Set([home.path, home.resolvingSymlinksInPath().path]))
        var candidates = [url.path, url.resolvingSymlinksInPath().path]
        for candidate in candidates {
            for homePath in homePaths where candidate.hasPrefix(homePath + "/") {
                let suffix = candidate.dropFirst(homePath.count)
                candidates += homePaths.map { $0 + suffix }
            }
        }
        var literals: [String] = []
        for candidate in candidates {
            literals.append(candidate)
            for homePath in homePaths where candidate.hasPrefix(homePath + "/") {
                literals.append("~" + candidate.dropFirst(homePath.count))
            }
        }
        var seen = Set<String>()
        return literals.filter { seen.insert($0).inserted }
    }

    // MARK: - Default homes (the exclusion set)

    /// The default card's config dirs: every `CLAUDE_CONFIG_DIR` entry when set, else the scanner's
    /// standard resolution (`$XDG_CONFIG_HOME/claude`, then `~/.claude`).
    private func defaultClaudeConfigDirs() -> [String] {
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let dirs = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !dirs.isEmpty { return dirs.map(expandTilde) }
        }
        let home = homeDirectory()
        let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map(expandTilde)
            ?? home.appendingPathComponent(".config").path
        return [xdg + "/claude", home.appendingPathComponent(".claude").path]
    }

    // MARK: - Path helpers

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandTilde(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Log-safe path: the home prefix is folded to `~` so support logs don't carry the username.
    private func logPath(_ path: String) -> String {
        let home = homeDirectory().path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func hash8(_ identityKey: String) -> String {
        String(ProviderAccountID.make(family: "claude", identityKey: identityKey).dropFirst("claude@".count))
    }
}
