import Foundation

/// One Claude account found on the machine: a config-dir file source, a keychain service source, or
/// both. `isDefault` marks the primary account (`~/.claude` / the bare keychain service), which is
/// always provider id `"claude"` and never gets a stored record.
struct DiscoveredClaudeAccount: Hashable, Sendable {
    var configDir: String?
    var keychainService: String?
    var isDefault: Bool
}

/// Finds Claude accounts already present on the machine, with no user configuration. Checks are one
/// level deep only (never a disk-wide search): the default `~/.claude`, sibling `~/.claude*` dirs with
/// credentials, `$XDG_CONFIG_HOME/claude`, every `CLAUDE_CONFIG_DIR` entry, and generic-password
/// keychain items under the `Claude Code-credentials` service prefix.
///
/// A config dir and a keychain service that hash to the same account are collapsed into one entry
/// (reusing `ClaudeAuthStore`'s own service derivation, never a second copy of the hash). A keychain
/// service with no matching dir stands alone as a keychain-only account.
struct ClaudeAccountDiscovery {
    private static let credentialFileName = ".credentials.json"

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL
    /// Names of the immediate children of a directory. Injected so discovery's `~/.claude*` sibling scan
    /// is testable without touching the real home directory.
    var contentsOfDirectory: @Sendable (String) -> [String]

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        contentsOfDirectory: @escaping @Sendable (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        self.contentsOfDirectory = contentsOfDirectory
    }

    func discover() -> [DiscoveredClaudeAccount] {
        let authStore = ClaudeAuthStore(environment: environment, files: files, keychain: keychain)

        // The default instance reads env `CLAUDE_CONFIG_DIR` when set, else `~/.claude`; its keychain
        // services (bare + the env dir's hash) are reserved for the default account. The dir is
        // canonicalized (symlinks resolved, trailing slash stripped) so a trailing-slash or symlinked
        // `CLAUDE_CONFIG_DIR` pointing at the default dir can't reappear as a phantom second account.
        // ponytail: `CLAUDE_CONFIG_DIR` is read raw here (not comma-split) to match the auth store's own
        // single-path read; a rare comma-separated value won't match a real dir, so its entries fall
        // through to the extra-account scan below — acceptable for v1.
        let rawDefaultDir = environment.value(for: "CLAUDE_CONFIG_DIR")?.nilIfEmpty.map { expandHome($0) }
            ?? "\(homeDirectory().path)/.claude"
        let defaultDir = Self.canonicalize(rawDefaultDir)
        // Ordered so the default account's chosen service is deterministic; the Set is only for
        // membership tests and the `consumed` bookkeeping.
        let defaultServiceCandidates = authStore.keychainServiceCandidates()
        let defaultServices = Set(defaultServiceCandidates)

        let enumerated = enumeratedServices(prefix: authStore.baseKeychainService())

        var accounts: [DiscoveredClaudeAccount] = []
        var consumed = Set<String>()

        accounts.append(DiscoveredClaudeAccount(
            configDir: defaultDir,
            keychainService: defaultServiceCandidates.first { enumerated.contains($0) },
            isDefault: true
        ))
        consumed.formUnion(defaultServices)

        for candidate in candidateConfigDirs() where candidate.canonical != defaultDir {
            // Claude Code hashes the raw configured dir string, so match keychain services against the
            // raw AND canonical forms; identity/dedupe/persistence use the canonical path only.
            let hashCandidates = orderedUnique([candidate.raw, candidate.canonical].compactMap {
                authStore.keychainServiceCandidates(forConfigDir: $0).first
            })
            let matched = hashCandidates.first { enumerated.contains($0) && !consumed.contains($0) }
            let hasUsableFile = hasUsableFileCredentials(inConfigDir: candidate.canonical)
            guard hasUsableFile || matched != nil else { continue }
            if let matched { consumed.insert(matched) }
            accounts.append(DiscoveredClaudeAccount(configDir: candidate.canonical, keychainService: matched, isDefault: false))
        }

        for service in enumerated.subtracting(consumed).sorted() {
            accounts.append(DiscoveredClaudeAccount(configDir: nil, keychainService: service, isDefault: false))
        }

        return accounts
    }

    /// Whether a config dir holds a genuinely usable login — a parseable OAuth blob with a non-empty
    /// access token — not merely a `.credentials.json` that exists. Reuses the auth store's own file
    /// loader (a config-dir-scoped, keychain-free `ClaudeAuthStore`) rather than a second credential
    /// read, so discovery's "is this an account" bar matches `refresh()`'s. Cheap: a scoped store with no
    /// keychain service reads only the one file, never the keychain or the env token.
    private func hasUsableFileCredentials(inConfigDir dir: String) -> Bool {
        let scoped = ClaudeAuthStore(
            environment: environment,
            files: files,
            keychain: keychain,
            account: ClaudeAccountScope(configDir: dir, keychainService: nil)
        )
        return scoped.loadCredentialCandidates().contains { $0.hasUsableAccessToken }
    }

    /// Resolve symlinks and strip a trailing slash so two spellings of one dir compare and dedupe as the
    /// same account. Input is expected already `~`-expanded.
    private static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func enumeratedServices(prefix: String) -> Set<String> {
        do {
            return Set(try keychain.genericPasswordServices(withPrefix: prefix))
        } catch {
            AppLog.warn(.keychain, "Claude account keychain enumeration failed: \(error.localizedDescription)")
            return []
        }
    }

    /// A config dir worth probing, carrying both its canonical path (for identity/dedupe/persistence) and
    /// the raw configured string (to reproduce Claude Code's keychain-service hash, which is taken over
    /// the raw value).
    private struct CandidateDir {
        var canonical: String
        var raw: String
    }

    /// Every config dir worth probing, expanded and deduped by canonical path: the default,
    /// credential-bearing `~/.claude*` siblings, `$XDG_CONFIG_HOME/claude`, and each `CLAUDE_CONFIG_DIR`
    /// entry (comma-separated, like the log scanner).
    private func candidateConfigDirs() -> [CandidateDir] {
        let home = homeDirectory().path
        var dirs: [CandidateDir] = []
        var seen = Set<String>()
        func add(_ path: String) {
            let raw = expandHome(path)
            let canonical = Self.canonicalize(raw)
            if seen.insert(canonical).inserted { dirs.append(CandidateDir(canonical: canonical, raw: raw)) }
        }

        add("\(home)/.claude")

        for name in contentsOfDirectory(home) where name.hasPrefix(".claude") {
            let path = "\(home)/\(name)"
            if files.exists("\(path)/\(Self.credentialFileName)") { add(path) }
        }

        let xdgBase = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map { expandHome($0) } ?? "\(home)/.config"
        let xdgClaude = "\(xdgBase)/claude"
        if files.exists("\(xdgClaude)/\(Self.credentialFileName)") { add(xdgClaude) }

        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                add(part)
            }
        }

        return dirs
    }
}
