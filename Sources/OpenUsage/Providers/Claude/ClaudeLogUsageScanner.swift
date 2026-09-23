import Foundation

/// Builds daily token/cost estimates for Claude by scanning Claude Code's local session logs
/// natively (`<config dir>/projects/**/*.jsonl`), replacing the external `ccusage` CLI.
///
/// Ports ccusage's Claude adapter semantics:
/// - Roots come from `CLAUDE_CONFIG_DIR` (comma-separated; each entry is a config dir containing
///   `projects/`, or the `projects/` dir itself), else `$XDG_CONFIG_HOME/claude` and `~/.claude`.
/// - A usage line must carry `"usage":{`, parse as JSON with a valid timestamp, not carry `null` in
///   fields Claude never writes as null, and pass the validity checks (semver-ish `version`,
///   non-empty ids/model).
/// - Entries are deduplicated by `(message.id, requestId)`, with a second pass that catches
///   sidechain logs replaying a parent message under a new request id. On collision the non-sidechain
///   entry wins, then the larger token total, then the one carrying a `speed` field.
/// - Advisor-message iterations become separate entries under their own model. Other iteration
///   types stay represented only by the parent usage totals, avoiding double-counting.
/// - Cost mode "auto": a line's `costUSD` when present, else tokens priced through `ModelPricing`.
///
/// An actor so the whole scan runs off the main actor. Parsed files are cached by path + size + mtime
/// in memory and Application Support: refreshes and relaunches parse only changed files, then re-run
/// the cheap dedup + day aggregation over cached entries before local model-rate estimates.
actor ClaudeLogUsageScanner {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>
    /// Scoped provider instances pass their stable parse-source identity here. Account or time filters
    /// over the same physical roots deliberately pass the same value and share whole-file records.
    private let cacheIdentityOverride: String?
    private let organizationID: String?
    private let accountID: String?
    private let additionalConfigDirectories: [String]
    private let allowsUnattributedSessions: Bool
    /// The identity Claude Code is signed in to right now, re-read every scan. The card matching it
    /// also owns the default home's sessions that record no account, which is how plain terminal
    /// sessions look; Desktop-indexed sessions stay excluded.
    private let currentDefaultLoginIdentity: @Sendable () -> String?
    private var sessionOwnership: [String: (
        size: Int, mtime: Date, identity: ClaudeSessionIdentity
    )] = [:]

    private let readOwnershipData: @Sendable (URL) throws -> Data

    /// One parsed usage line. Token buckets are pre-normalized into `TokenBreakdown`; dedup fields
    /// ride along so the global dedup pass can run over cached entries.
    struct Entry: Codable, Sendable, Equatable {
        var timestamp: Date
        var tokens: TokenBreakdown
        var messageID: String?
        var requestID: String?
        var isSidechain: Bool = false
        /// The line carried a `speed` field at all (dedup tiebreaker); `tokens.isFast` says it was "fast".
        var hasSpeed: Bool = false
        var costUSD: Double?
        /// `nil` when the line has no model or the placeholder `<synthetic>` (tokens count, cost is $0).
        var model: String?
    }

    /// Cards that read the same Claude home share one actor, so the first scan populates both the
    /// in-memory and disk caches and the rest reuse it. Tests inject an isolated memory-only scanner.
    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("claude"),
        // v2: accept records whose nested `usage.iterations[].model` is null (#1253); cached
        // parses from v1 silently dropped them, so every file must re-parse once.
        persistence: JSONLScanCachePersistence(namespace: "claude", schemaVersion: 2)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil,
        cacheIdentityOverride: String? = nil,
        accountUUID: String? = nil,
        organizationUUID: String? = nil,
        allowsUnattributedSessions: Bool = false,
        currentDefaultLoginIdentity: (@Sendable () -> String?)? = nil,
        additionalConfigDirectories: [String] = [],
        readOwnershipData: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0, options: .mappedIfSafe)
        }
    ) {
        precondition(cacheIdentityOverride?.isEmpty != true)
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
        self.cacheIdentityOverride = cacheIdentityOverride
        self.organizationID = organizationUUID?.lowercased()
        self.accountID = accountUUID?.lowercased()
        self.additionalConfigDirectories = additionalConfigDirectories
        self.allowsUnattributedSessions = allowsUnattributedSessions
        self.currentDefaultLoginIdentity = currentDefaultLoginIdentity ?? {
            let observer = DefaultAccountObserver(environment: environment, homeDirectory: homeDirectory)
            guard case let .resolved(identityKey, _, _) = observer.observeClaude() else { return nil }
            return identityKey
        }
        self.readOwnershipData = readOwnershipData
    }

    /// Scan the last `daysBack` days of Claude logs. Returns `nil` when no Claude data directory or
    /// no log files exist (the spend tiles then render "No data"); returns an empty series when logs
    /// exist but have no usage in the window.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        // A UUID-only login cannot claim any organization's history once multiple identities are
        // known; while it is the default login it still claims the default home's unattributed sessions.
        let claimsDefaultHome = !allowsUnattributedSessions && isCurrentDefaultLogin()
        if accountID != nil, organizationID == nil, !allowsUnattributedSessions, !claimsDefaultHome {
            AppLog.info(LogTag.plugin("claude"), "local spending excluded: login has no organization and multiple accounts are known")
            return nil
        }
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheIdentity = parseCacheIdentity()
        let roots = claudeRoots()
        guard !roots.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile
            )
            return nil
        }

        var files = Self.usageFiles(under: roots)
        if organizationID != nil || claimsDefaultHome {
            files = ownedUsageFiles(files, claimsDefaultHome: claimsDefaultHome)
        }
        guard !Task.isCancelled else { return nil }
        guard !files.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile
            )
            return nil
        }

        // Entries come back concatenated in path-sorted file order, so dedup's keep-first is deterministic.
        guard let entries = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            parse: Self.parseFile
        ), !Task.isCancelled else { return nil }
        return Self.aggregate(entries: Self.dedup(entries), since: since, pricing: pricing)
    }

    /// Stable source configuration identity rather than the discovered root list: Cowork adds session
    /// roots over time, and a new session must extend the same cache instead of cold-parsing every old
    /// file. Scoped root overrides pass an explicit identity so distinct homes stay partitioned.
    private func parseCacheIdentity() -> String {
        if let cacheIdentityOverride { return cacheIdentityOverride }
        let home = homeDirectory().resolvingSymlinksInPath().path
        let allRoots = defaultConfigRoots() + additionalConfigDirectories.map { URL(fileURLWithPath: expandHome($0)) }
        let roots = Set(allRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            .sorted()
            .joined(separator: "\n")
        return "home=\(home)\nroots=\(roots)"
    }

    /// The default Claude home(s) the terminal CLI writes to: `CLAUDE_CONFIG_DIR` entries, else
    /// `$XDG_CONFIG_HOME/claude` and `~/.claude`. Swap and Cowork roots are not included.
    private func defaultConfigRoots() -> [URL] {
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            return raw.split(separator: ",").compactMap { part in
                let value = part.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return nil }
                var url = URL(fileURLWithPath: expandHome(value))
                if url.lastPathComponent == "projects" { url.deleteLastPathComponent() }
                return url
            }
        } else {
            let homeURL = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty
                .map { URL(fileURLWithPath: expandHome($0)) }
                ?? homeURL.appendingPathComponent(".config")
            return [
                xdg.appendingPathComponent("claude"),
                homeURL.appendingPathComponent(".claude"),
            ]
        }
    }

    // MARK: - Root and file discovery

    /// Claude config directories that actually contain a `projects/` folder, in ccusage's order:
    /// every entry of `CLAUDE_CONFIG_DIR` when set (an invalid list logs and yields none), else
    /// `$XDG_CONFIG_HOME/claude` (default `~/.config/claude`) and `~/.claude`. Cowork's per-session
    /// `.claude` sandboxes are always appended — they live under the desktop app's own container,
    /// so `CLAUDE_CONFIG_DIR` (a terminal-CLI override) doesn't speak for them.
    private func claudeRoots() -> [URL] {
        var roots: [URL] = []
        var seen: Set<String> = []

        func addIfValid(_ url: URL) {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("projects").path),
                  seen.insert(url.path).inserted
            else { return }
            roots.append(url)
        }

        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                var url = URL(fileURLWithPath: expandHome(part))
                // Accept the `projects/` directory itself as an alias for its parent config dir.
                if url.lastPathComponent == "projects", FileManager.default.fileExists(atPath: url.path) {
                    url.deleteLastPathComponent()
                }
                addIfValid(url)
            }
            if roots.isEmpty {
                AppLog.warn(LogTag.plugin("claude"), "CLAUDE_CONFIG_DIR is set but contains no Claude data directory with projects/: \(raw)")
            }
        } else {
            let home = homeDirectory()
            let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map { URL(fileURLWithPath: expandHome($0)) }
                ?? home.appendingPathComponent(".config")
            addIfValid(xdg.appendingPathComponent("claude"))
            addIfValid(home.appendingPathComponent(".claude"))
        }

        for directory in additionalConfigDirectories {
            addIfValid(URL(fileURLWithPath: expandHome(directory)))
        }

        for sandbox in Self.coworkClaudeDirs(
            home: homeDirectory(), organizationID: organizationID, accountID: accountID
        ) {
            addIfValid(sandbox)
        }
        return roots
    }

    /// The `.claude` dirs Cowork (the Claude desktop app's agent mode) creates, one per session,
    /// under `~/Library/Application Support/Claude/local-agent-mode-sessions/<group>/<sub>/local_*`
    /// (plus an `agent/local_*` variant one level deeper). Each holds the same `projects/**/*.jsonl`
    /// session logs as `~/.claude`, so they scan as additional roots. The walk is bounded to those
    /// known levels — session dirs contain full sandbox homes we must not recurse into.
    private static func coworkClaudeDirs(home: URL, organizationID: String?, accountID: String?) -> [URL] {
        let base = home
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")

        func subdirectories(of url: URL) -> [URL] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        }

        var dirs: [URL] = []
        for group in subdirectories(of: base) {
            guard organizationID == nil || accountID == nil || group.lastPathComponent.lowercased() == accountID
            else { continue }
            for sub in subdirectories(of: group) {
                guard organizationID == nil || sub.lastPathComponent.lowercased() == organizationID else {
                    continue
                }
                var sessions = subdirectories(of: sub)
                for holder in sessions where holder.lastPathComponent == "agent" {
                    sessions.append(contentsOf: subdirectories(of: holder))
                }
                for session in sessions {
                    dirs.append(session.appendingPathComponent(".claude"))
                }
            }
        }
        return dirs.sorted { $0.path < $1.path }
    }

    /// Every `*.jsonl` under each root's `projects/`, path-sorted so the dedup pass (keep-first wins)
    /// is deterministic — the same order ccusage scans in.
    private static func usageFiles(under roots: [URL]) -> [JSONLScanning.DiscoveredFile] {
        roots
            .flatMap { JSONLScanning.jsonlFiles(under: $0.appendingPathComponent("projects")) }
            .sorted { $0.path < $1.path }
    }

    /// Cowork roots carry their organization in the directory layout. Other sessions identify theirs
    /// in a bridge event or Desktop's account-and-organization-scoped session index; subagent files
    /// inherit their parent session's ownership. Keep this outside the shared parsed-entry cache.
    private func ownedUsageFiles(
        _ files: [JSONLScanning.DiscoveredFile],
        claimsDefaultHome: Bool
    ) -> [JSONLScanning.DiscoveredFile] {
        let coworkPrefix = homeDirectory()
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
            .resolvingSymlinksInPath().path + "/"
        let filesByPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seenPaths: Set<String> = []
        var ownedFiles: [JSONLScanning.DiscoveredFile] = []
        var desktopSessionIDs: Set<String>?
        var allDesktopSessionIDs: Set<String>?
        let defaultProjectPrefixes = claimsDefaultHome
            ? defaultConfigRoots().map { $0.appendingPathComponent("projects").resolvingSymlinksInPath().path + "/" }
            : []
        // Optional values retain read failures for this pass without persisting them.
        var identities: [String: ClaudeSessionIdentity?] = [:]

        for file in files {
            guard !Task.isCancelled else { return [] }
            guard seenPaths.insert(file.path).inserted else { continue }
            let canonicalPath = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().path
            if canonicalPath.hasPrefix(coworkPrefix) {
                let components = canonicalPath.dropFirst(coworkPrefix.count).split(separator: "/")
                if components.count > 1,
                   components[1].lowercased() == organizationID,
                   accountID == nil || components[0].lowercased() == accountID
                {
                    ownedFiles.append(file)
                }
                continue
            }

            let sessionFile = Self.owningSessionFile(for: file, filesByPath: filesByPath)
            guard let sessionFile else { continue }
            if identities[sessionFile.path] == nil {
                identities[sessionFile.path] = .some(sessionIdentity(sessionFile))
            }
            guard let result = identities[sessionFile.path], let ownership = result else { continue }
            if case .conflicted = ownership { continue }
            if case let .owned(owner, ownerAccount) = ownership {
                if owner == organizationID, accountID == nil || ownerAccount == accountID {
                    ownedFiles.append(file)
                }
            } else if allowsUnattributedSessions {
                ownedFiles.append(file)
            } else {
                let sessionID = URL(fileURLWithPath: sessionFile.path)
                    .deletingPathExtension().lastPathComponent.lowercased()
                if let accountID, let organizationID {
                    if desktopSessionIDs == nil {
                        desktopSessionIDs = indexedDesktopSessionIDs(accountID: accountID, organizationID: organizationID)
                    }
                    if desktopSessionIDs?.contains(sessionID) == true {
                        ownedFiles.append(file)
                        continue
                    }
                }
                // Desktop indexes every session it runs; an indexed session belongs to that Desktop login.
                guard defaultProjectPrefixes.contains(where: { canonicalPath.hasPrefix($0) }) else { continue }
                if allDesktopSessionIDs == nil { allDesktopSessionIDs = allIndexedDesktopSessionIDs() }
                if allDesktopSessionIDs?.contains(sessionID) != true {
                    ownedFiles.append(file)
                }
            }
        }
        return ownedFiles
    }

    /// Only a scoped card whose identity is the one Claude Code is signed in to right now.
    private func isCurrentDefaultLogin() -> Bool {
        guard let accountID, let current = currentDefaultLoginIdentity()?.lowercased() else { return false }
        return current == (organizationID.map { "\(accountID)|\($0)" } ?? accountID)
    }

    private var desktopSessionIndexRoot: URL {
        homeDirectory().appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    private func indexedDesktopSessionIDs(accountID: String, organizationID: String) -> Set<String> {
        indexedDesktopSessionIDs(
            in: desktopSessionIndexRoot.appendingPathComponent(accountID).appendingPathComponent(organizationID)
        )
    }

    private func allIndexedDesktopSessionIDs() -> Set<String> {
        func subdirectories(of url: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.hasDirectoryPath }
        }
        return subdirectories(of: desktopSessionIndexRoot)
            .flatMap(subdirectories(of:))
            .reduce(into: Set<String>()) { $0.formUnion(indexedDesktopSessionIDs(in: $1)) }
    }

    private func indexedDesktopSessionIDs(in directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return Set(files.compactMap { file in
            guard file.lastPathComponent.hasPrefix("local_"), file.pathExtension == "json",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let handle = try? FileHandle(forReadingFrom: file)
            else { return nil }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: 512),
                  let header = String(data: prefix, encoding: .utf8),
                  let field = header.range(of: #""cliSessionId"\s*:\s*""#, options: .regularExpression),
                  let end = header[field.upperBound...].firstIndex(of: "\""),
                  let sessionID = UUID(uuidString: String(header[field.upperBound..<end]))
            else { return nil }
            return sessionID.uuidString.lowercased()
        })
    }

    private func sessionIdentity(
        _ file: JSONLScanning.DiscoveredFile
    ) -> ClaudeSessionIdentity? {
        if let cached = sessionOwnership[file.path],
           cached.size == file.size, cached.mtime == file.mtime
        {
            return cached.identity
        }

        do {
            let data = try readOwnershipData(URL(fileURLWithPath: file.path))
            guard let identity = ClaudeSessionIdentity.parse(data), !Task.isCancelled else { return nil }
            sessionOwnership[file.path] = (file.size, file.mtime, identity)
            return identity
        } catch {
            AppLog.warn(LogTag.plugin("claude"), "Failed to read Claude session ownership from \(file.path): \(error)")
            return nil
        }
    }

    // MARK: - Line parsing

    /// Parse every usage line of one session file. Entries keep their raw timestamps — the date
    /// window is applied at aggregation so a cached parse stays valid as the window slides.
    static func parseFile(_ data: Data) -> [Entry] {
        let marker = Data(#""usage":{"#.utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil else { continue }
            entries.append(contentsOf: parseEntries(Data(line)))
        }
        return entries
    }

    /// Decode one JSONL line into an `Entry`, mirroring what ccusage's serde model accepts: `usage`
    /// with numeric `input_tokens`/`output_tokens` is required, everything else optional, and a
    /// malformed or invalid line is skipped rather than failing the file.
    static func parseLine(_ data: Data) -> Entry? {
        parseEntries(data).first
    }

    /// A Claude log line can carry nested advisor work in `usage.iterations`. The top-level usage
    /// remains the main-model entry; only advisor-message iterations become additional entries,
    /// matching ccusage without recounting the ordinary message iterations that feed that total.
    private static func parseEntries(_ data: Data) -> [Entry] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              !hasUnsupportedNullField(object, message: message, usage: usage),
              let parsedUsage = tokenBreakdown(from: usage),
              isValidEntry(object, message: message)
        else { return [] }

        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        let parent = Entry(
            timestamp: timestamp,
            tokens: parsedUsage.tokens,
            messageID: message["id"] as? String,
            requestID: object["requestId"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            hasSpeed: parsedUsage.hasSpeed,
            costUSD: (object["costUSD"] as? NSNumber)?.doubleValue,
            model: model
        )

        guard let iterations = usage["iterations"] as? [[String: Any]] else { return [parent] }

        var entries = [parent]
        var advisorIndex = 0
        for iteration in iterations {
            guard iteration["type"] as? String == "advisor_message",
                  let advisorModel = iteration["model"] as? String,
                  !advisorModel.isEmpty,
                  let advisorUsage = tokenBreakdown(from: iteration)
            else { continue }

            entries.append(Entry(
                timestamp: parent.timestamp,
                tokens: advisorUsage.tokens,
                messageID: parent.messageID.map { "\($0):advisor:\(advisorIndex)" },
                requestID: parent.requestID,
                isSidechain: parent.isSidechain,
                hasSpeed: advisorUsage.hasSpeed,
                costUSD: nil,
                model: advisorModel
            ))
            advisorIndex += 1
        }
        return entries
    }

    private static func tokenBreakdown(
        from usage: [String: Any]
    ) -> (tokens: TokenBreakdown, hasSpeed: Bool)? {
        guard let input = usage["input_tokens"] as? NSNumber,
              let output = usage["output_tokens"] as? NSNumber
        else { return nil }

        // Claude tags fast-mode requests with `speed`; any value outside the known set marks a log
        // shape we don't understand, so the line is skipped (ccusage's enum parse does the same).
        let speed = usage["speed"] as? String
        if let speed, speed != "fast", speed != "standard" { return nil }

        // Cache writes: the 5m/1h split when present (1h bills at 2x input), else the legacy
        // aggregate `cache_creation_input_tokens` treated as all-5m.
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        if let cacheCreation = usage["cache_creation"] as? [String: Any] {
            cacheWrite5m = (cacheCreation["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0
            cacheWrite1h = (cacheCreation["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        } else {
            cacheWrite5m = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
        }

        return (TokenBreakdown(
            input: input.intValue,
            cacheWrite5m: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
            output: output.intValue,
            isFast: speed == "fast"
        ), speed != nil)
    }

    /// ccusage's validity rules: a `version` that isn't semver-ish marks a foreign log format, and
    /// ids/model that are present but empty mark a malformed line.
    private static func isValidEntry(_ object: [String: Any], message: [String: Any]) -> Bool {
        if let version = object["version"] as? String, !isSemverPrefix(version) { return false }
        for value in [object["sessionId"], object["requestId"], message["id"], message["model"]] {
            if let text = value as? String, text.isEmpty { return false }
        }
        return true
    }

    /// `digits.digits.digit…` — accepts "1.0.24" and pre-release suffixes, rejects e.g. "unknown".
    static func isSemverPrefix(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        func digits() -> Bool {
            let start = index
            while index < bytes.count, bytes[index].isASCIIDigit { index += 1 }
            return index > start
        }
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        guard digits(), index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return false }
        index += 1
        return index < bytes.count && bytes[index].isASCIIDigit
    }

    /// Claude never writes `null` into the schema fields we consume; a line that does is a
    /// foreign/corrupt shape that ccusage skips. The check is scoped to the exact objects we read
    /// (top level, `message`, `message.usage`) so unrelated nested keys sharing a name — such as
    /// `usage.iterations[].model`, which Claude Code 2.1.270 writes as `null` for ordinary message
    /// iterations — don't invalidate an otherwise valid record.
    static func hasUnsupportedNullField(
        _ object: [String: Any], message: [String: Any], usage: [String: Any]
    ) -> Bool {
        let levels: [([String: Any], [String])] = [
            (object, ["cwd", "costUSD", "version", "sessionId", "requestId", "isApiErrorMessage"]),
            (message, ["id", "model"]),
            (usage, ["speed", "cache_read_input_tokens", "cache_creation_input_tokens"])
        ]
        for (container, fields) in levels {
            for field in fields where container[field] is NSNull { return true }
        }
        return false
    }

    // MARK: - Deduplication

    private struct ExactKey: Hashable {
        var messageID: String
        var requestID: String?
    }

    /// Drop replayed usage lines, keeping ccusage's preferences. Entries are keyed by
    /// `(message.id, requestId)`; a second index on `message.id` alone catches sidechain logs that
    /// replay a parent message under a new request id. On a collision the existing entry is replaced
    /// only when the candidate wins `shouldReplace`. Entries without a message id are always kept.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var deduped: [Entry] = []
        var exactIndex: [ExactKey: Int] = [:]
        var messageIndex: [String: [Int]] = [:]

        for entry in entries {
            guard let messageID = entry.messageID else {
                deduped.append(entry)
                continue
            }
            let key = ExactKey(messageID: messageID, requestID: entry.requestID)
            let collision = exactIndex[key] ?? messageIndex[messageID]?.first(where: { index in
                entry.isSidechain || deduped[index].isSidechain
            })

            if let index = collision {
                if shouldReplace(candidate: entry, existing: deduped[index]) {
                    let old = deduped[index]
                    if let oldID = old.messageID {
                        exactIndex.removeValue(forKey: ExactKey(messageID: oldID, requestID: old.requestID))
                    }
                    deduped[index] = entry
                    exactIndex[key] = index
                }
                continue
            }

            let index = deduped.count
            deduped.append(entry)
            exactIndex[key] = index
            messageIndex[messageID, default: []].append(index)
        }
        return deduped
    }

    /// Preference order on a duplicate: the non-sidechain (parent) entry, then the larger token
    /// total, then the entry that carries a `speed` field (richer log shape).
    static func shouldReplace(candidate: Entry, existing: Entry) -> Bool {
        if candidate.isSidechain != existing.isSidechain {
            return existing.isSidechain
        }
        let candidateTotal = candidate.tokens.totalTokens
        let existingTotal = existing.tokens.totalTokens
        if candidateTotal != existingTotal {
            return candidateTotal > existingTotal
        }
        return candidate.hasSpeed && !existing.hasSpeed
    }

    // MARK: - Aggregation

    /// Bucket deduplicated entries into local calendar days. Cost mode "auto": a line's `costUSD`
    /// when present, else tokens priced through `pricing`.
    ///
    /// Entries that can't be priced (an unknown model, or unattributed tokens with no carried cost)
    /// are excluded from every displayed total — tokens, dollars, the trend, and the model breakdown —
    /// because mixing measured tokens with unpriceable ones makes the figures incoherent. An unknown
    /// model's name lands in `unknownModelsByDay` (the tile's warning triangle), the only place
    /// unpriceable usage surfaces.
    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()

        for entry in entries where entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            // One trimmed slug for pricing, the unknown-model warning, and the breakdown key alike —
            // diverging spellings would let the warning triangle and the hover panel disagree.
            let trimmedModel = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double
            if let carried = entry.costUSD {
                cost = carried
            } else if let model = trimmedModel, let estimated = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                cost = estimated
            } else {
                if let model = trimmedModel, entry.tokens.totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }

            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: modelName)
        }

        return accumulator.build()
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}
