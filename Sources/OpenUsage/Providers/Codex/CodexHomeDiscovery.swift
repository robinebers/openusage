import Foundation

/// Launch-time scan for additional file-backed Codex logins. Each accepted home must contain an
/// `auth.json` with a usable OAuth token that names its ChatGPT account; a path, email, or token hash
/// is never used as identity. That strict rule makes it safe to route usage, cached snapshots, and
/// local rollout logs to a first-class account card.
///
/// The scan is deliberately bounded to conventional sibling homes (`~/.codex*` and
/// `~/.config/codex*`). Keyring-only homes are left for the separate keyring binding phase because
/// reading their secret during launch could show a macOS permission prompt and still would not prove
/// which home owns the returned credential.
struct CodexHomeDiscovery {
    struct Finding: Equatable, Sendable {
        var identityKey: String
        var label: String?
        /// Canonical home path used by the scoped auth store and rollout scanner.
        var anchorPath: String
    }

    struct Result: Sendable {
        var findings: [Finding] = []
        /// Token-free, email-free decisions emitted to the support log.
        var notes: [String] = []
    }

    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL
    var listSubdirectories: @Sendable (URL) -> [URL]
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
        },
        listSubdirectories: @escaping @Sendable (URL) -> [URL] = Self.filesystemSubdirectories,
        timeBudget: TimeInterval = 0.4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.homeDirectory = homeDirectory
        self.listSubdirectories = listSubdirectories
        self.timeBudget = timeBudget
        self.now = now
    }

    /// `excluding` contains the home that feeds the bare Codex card this launch. Other standard
    /// candidates remain eligible, so `~/.config/codex` and `~/.codex` can represent two accounts
    /// instead of the default runtime silently falling through from one account to another.
    func run(excluding: [String] = []) -> Result {
        let started = now()
        let excluded = Set(excluding.map(canonical))
        var result = Result()

        for candidate in candidateDirectories() {
            if now().timeIntervalSince(started) > timeBudget {
                result.notes.append(
                    "codex home scan hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results"
                )
                break
            }
            let anchor = canonical(candidate.path)
            guard !excluded.contains(anchor) else { continue }
            guard let text = try? files.readTextIfPresent(anchor + "/auth.json") else {
                continue
            }
            guard let auth = CodexAuthStore.parseAuth(text) else {
                result.notes.append("codex candidate \(logPath(anchor)): auth.json is invalid → skipped")
                continue
            }
            guard let identity = DefaultAccountObserver.codexIdentity(auth) else {
                result.notes.append(
                    "codex candidate \(logPath(anchor)): OAuth credential names no account → skipped"
                )
                continue
            }
            result.findings.append(Finding(
                identityKey: identity.identityKey,
                label: identity.label,
                anchorPath: anchor
            ))
            result.notes.append(
                "codex candidate \(logPath(anchor)): accepted (\(identityHash(identity.identityKey)))"
            )
        }
        return result
    }

    /// Immediate sibling homes only: no project-tree or disk-wide walk. Identity extraction is the
    /// final validation, so a coincidentally named directory without real Codex auth is ignored.
    private func candidateDirectories() -> [URL] {
        let home = homeDirectory()
        var candidates = listSubdirectories(home).filter {
            $0.lastPathComponent.hasPrefix(".codex")
        }
        candidates += listSubdirectories(home.appendingPathComponent(".config")).filter {
            $0.lastPathComponent.hasPrefix("codex")
        }

        var seen = Set<String>()
        return candidates
            .sorted { $0.path < $1.path }
            .filter { seen.insert(canonical($0.path)).inserted }
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

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func logPath(_ path: String) -> String {
        let home = homeDirectory().path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func identityHash(_ identityKey: String) -> String {
        String(ProviderAccountID.make(family: "codex", identityKey: identityKey).dropFirst("codex@".count))
    }
}
