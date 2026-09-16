import Foundation

/// Live subscription quota for Muse Code: POST `api.meta.ai/muse-code/key`
/// with the CLI's OAuth token returns the subscription snapshot (weekly +
/// window percentages, resets, server-provided plan name) with no inference
/// cost. When OAuth is absent or rejected it falls back to the
/// `response.subscription_usage` SSE event on POST `api.meta.ai/v1/responses` —
/// the same event the `muse` TUI's `/usage` view renders — authenticated by
/// the CLI's own keychain `api_key`. No browser session or page-load tokens.
struct MuseQuotaUsage: Sendable, Equatable {
    var tier: String?
    /// Server-provided display label (`subs_tier_name`), present only on the
    /// account-endpoint path. The probe path carries just the opaque tier ID.
    var planDisplayName: String? = nil
    // Percentages are optional: nil means unknown/unavailable, not 0%.
    // This preserves the distinction between a genuine 0% reading and a
    // missing field in an undocumented response (P2-6).
    var weeklyUsedPercent: Double?
    var windowUsedPercent: Double?
    var weeklyResetsAt: Date?
    var windowResetsAt: Date?
    var windowDurationMinutes: Int?
    /// Set when the probe returns 429 quota-exhausted with a reset time but
    /// without per-window percentages. The dashboard should surface the blocked
    /// state with the reset, not two fabricated 100% bars (P1-1).
    var isQuotaBlocked: Bool = false
    var blockedResetsAt: Date?
}

enum MuseQuotaError: Error, LocalizedError, Equatable {
    case unauthorized
    case requestFailed(Int)
    case missingUsageEvent
    case invalidResponse
    case quotaExhausted(resetsAt: Date?)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Muse quota key rejected. Run `muse login` again."
        case .requestFailed(let status):
            return "Muse quota probe failed (HTTP \(status))."
        case .missingUsageEvent:
            return "Muse quota response carried no usage event."
        case .invalidResponse:
            return "Muse quota response was not usable."
        case .quotaExhausted(let resetsAt):
            if let resetsAt {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .short
                return "Muse quota exhausted, resets \(fmt.string(from: resetsAt))."
            }
            return "Muse quota exhausted."
        }
    }
}

extension MuseQuotaError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .unauthorized: .authExpired
        case .requestFailed(let status): ErrorCategory.http(status)
        case .missingUsageEvent, .invalidResponse: .decoding
        case .quotaExhausted: .rateLimited
        }
    }
}

// In-memory memo for the keychain read: `security find-generic-password`
// pops a keychain approval dialog, so every 5-min poll must not re-prompt.
// Mirrors Go's `museAPIKeyCache` (quota.go) — one successful read is cached
// for the lifetime of this client (the provider is a long-lived singleton,
// so this is effectively one prompt per app launch). The file fallback
// (`~/.config/openusage/muse.json` via `userStore`) makes it persistent
// across launches after the first unlock (see `apiKey()`).
private final class MuseKeychainMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = nil
    private var isSet = false
    func getIfSet() -> String?? {
        lock.lock(); defer { lock.unlock() }
        guard isSet else { return nil }
        return .some(value)
    }
    func set(_ newValue: String?) {
        lock.lock(); value = newValue; isSet = true; lock.unlock()
    }
    /// Forget everything, including a cached miss — the next read goes back
    /// to the source. Used when a 401 proves the memoized token stale.
    func reset() {
        lock.lock(); value = nil; isSet = false; lock.unlock()
    }
}

struct MuseQuotaClient: Sendable {
    static let keychainService = "ai.meta.dev.credentials"
    static let keychainAccount = "meta"
    static let responsesURL = URL(string: "https://api.meta.ai/v1/responses")!
    static let keyURL = URL(string: "https://api.meta.ai/muse-code/key")!
    static let probeModel = "muse-spark-1.3-contributor"
    /// App-owned override file (mirrors the OpenRouter `openrouter.json` convention).
    static let userConfigPaths = ["~/.config/openusage/muse.json"]
    static let userEnvironmentNames = ["META_API_KEY"]
    /// Shared OpenUsage settings (also read by the Go TUI): `provider_paths.plan_name`
    /// on the `muse_code` account is the user-attested plan label. The quota probe only
    /// returns an opaque account-scoped tier ID, so the display name can't be derived.
    static let sharedSettingsPath = "~/.config/openusage/settings.json"

    var http: any HTTPClient
    var keychain: KeychainAccessing
    var environment: EnvironmentReading
    /// Explicit user key (Settings card): saved file first, `META_API_KEY` env
    /// second. Wins over the auto-detected CLI keychain entry below.
    let userStore: UserAPIKeyStore
    /// Directory holding the shared 429-attribution memory file (the same
    /// `muse-quota-memory.json` the Go TUI/daemon reads and writes). Defaults
    /// to the real state dir; tests inject a temp dir so fixtures never touch
    /// the user's live attribution memory.
    let quotaMemoryDirectory: @Sendable () -> URL
    /// One-prompt memo for the keychain fallback. Instance-scoped (reference
    /// type) so copies of this struct share the memo; a new client in tests
    /// starts unmemoized and does not pollute other tests.
    private let keychainMemo = MuseKeychainMemo()
    /// Separate memo for the OAuth token: same blob, different field, and a
    /// different lifetime from the API key.
    private let oauthMemo = MuseKeychainMemo()

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        userStore: UserAPIKeyStore? = nil,
        quotaMemoryDirectory: (@Sendable () -> URL)? = nil
    ) {
        self.http = http
        self.keychain = keychain
        self.environment = environment
        self.quotaMemoryDirectory = quotaMemoryDirectory ?? {
            MuseQuotaMemory.stateDirectory(
                environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser)
        }
        self.userStore = userStore ?? UserAPIKeyStore(
            configPaths: Self.userConfigPaths,
            environmentNames: Self.userEnvironmentNames,
            files: LocalTextFileAccessor(),
            environment: environment,
            makeError: { MuseUsageError($0) }
        )
    }

    /// The API bearer: explicit saved key first, `META_API_KEY` env second,
    /// else the `api_key` field of the CLI keychain JSON blob. `nil` means no
    /// usable key — the caller skips the probe and the local spend tiles
    /// stand. Malformed blobs are never sent.
    ///
    /// The keychain read is memoized in-process (one prompt per launch) and,
    /// on first success, best-effort persisted to `~/.config/openusage/muse.json`
    /// (0600) so subsequent launches avoid the keychain entirely — the
    /// "store it somewhere" fix for the periodic password prompt. The
    /// persisted file wins over the keychain on the next launch via
    /// `userStore.loadKey()` above, and `userStore.keyStatus()` then reports
    /// `.saved` (green dot / "Saved in App").
    func apiKey() throws -> String? {
        if let key = userStore.loadKey() {
            return key
        }
        if let cached = keychainMemo.getIfSet() {
            return cached
        }
        let blob: String?
        do {
            blob = try keychain.readGenericPassword(
                service: Self.keychainService, account: Self.keychainAccount
            )
        } catch {
            // Cache the miss so we don't re-prompt every poll after a
            // locked/denied keychain. The first failure still throws so the
            // caller's "probe failed; showing local spend only" warning fires
            // once; subsequent polls are silent nils.
            keychainMemo.set(nil)
            throw error
        }
        guard let blob, let data = blob.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = (json["api_key"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            keychainMemo.set(nil)
            return nil
        }
        keychainMemo.set(key)
        // Persist across launches so the next app start needs no keychain
        // prompt at all. Only when the user hasn't already saved a key —
        // never overwrite an explicit choice or a stale-but-present file.
        if userStore.keyStatus() == .notSet {
            _ = try? userStore.saveKey(key)
        }
        return key
    }

    /// The OAuth token for the muse-code/key account endpoint. Owned copy
    /// first (`oauthToken` in the same `muse.json` the API-key store uses —
    /// silent, no keychain prompt after the first boot), then the
    /// `access_token` field of the CLI keychain blob, bootstrapping the
    /// owned copy on success. `nil` means no OAuth login (API-key-only
    /// setups carry no `access_token`) — the caller falls back to the
    /// Responses probe. The explicit saved key and `META_API_KEY` carry the
    /// Model API key only and are never OAuth, so they are not consulted.
    func oauthToken() throws -> String? {
        // Owned copy first: silent, no keychain prompt after the first boot.
        if let cached = oauthTokenFromOwnedFile() {
            return cached
        }
        if let cached = oauthMemo.getIfSet() {
            return cached
        }
        let blob: String?
        do {
            blob = try keychain.readGenericPassword(
                service: Self.keychainService, account: Self.keychainAccount
            )
        } catch {
            oauthMemo.set(nil)
            throw error
        }
        guard let blob, let data = blob.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["access_token"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            oauthMemo.set(nil)
            return nil
        }
        // Bootstrap the owned copy so later boots never touch the CLI entry.
        _ = saveOAuthTokenToOwnedFile(token)
        oauthMemo.set(token)
        return token
    }

    /// Drop the owned copy and its memo, then re-read from the keychain
    /// (which the CLI keeps fresh) and cache the result. Called once after
    /// a 401 before falling back to the Responses probe. Throws
    /// `unauthorized` when no token exists anywhere, which the caller
    /// treats like any other key failure.
    func refreshOAuthToken() throws -> String {
        clearOAuthTokenOwnedFile()
        oauthMemo.reset()
        guard let token = try oauthToken(), !token.isEmpty else {
            throw MuseQuotaError.unauthorized
        }
        return token
    }

    /// Cached OAuth token from app-owned storage (`oauthToken` in the
    /// `muse.json` the API-key store manages; the API-key logic ignores the
    /// field and vice versa). Silent and prompt-free.
    func oauthTokenFromOwnedFile() -> String? {
        guard let text = try? userStore.files.readTextIfPresent(Self.userConfigPaths[0]),
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["oauthToken"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }
        return token
    }

    /// Cache the OAuth token in the owned file, preserving a saved API key.
    /// Refuses (returning false, touching nothing) when existing content
    /// isn't a JSON object it can merge into — e.g. a hand-maintained
    /// raw-string key file.
    @discardableResult
    func saveOAuthTokenToOwnedFile(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var object: [String: Any] = [:]
        if let text = try? userStore.files.readTextIfPresent(Self.userConfigPaths[0]) {
            guard let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return false
            }
            object = parsed
        }
        if (object["oauthToken"] as? String) == trimmed {
            return true // already cached
        }
        object["oauthToken"] = trimmed
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let out = String(data: data, encoding: .utf8)
        else {
            return false
        }
        do {
            try userStore.files.writeText(Self.userConfigPaths[0], out)
        } catch {
            return false
        }
        return true
    }

    /// Drop the cached OAuth token while preserving a saved API key.
    /// Removes the file when nothing else remains. Absent file or field,
    /// or unparseable content, is a no-op.
    func clearOAuthTokenOwnedFile() {
        guard let text = try? userStore.files.readTextIfPresent(Self.userConfigPaths[0]),
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["oauthToken"] != nil
        else {
            return
        }
        var object = parsed
        object.removeValue(forKey: "oauthToken")
        if object.isEmpty {
            try? userStore.files.remove(Self.userConfigPaths[0])
        } else if let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]),
            let out = String(data: data, encoding: .utf8) {
            try? userStore.files.writeText(Self.userConfigPaths[0], out)
        }
    }

    /// Account subscription snapshot: same meters as the probe plus the
    /// server-provided plan display name, with no inference cost. 401/403
    /// means an expired credential — the caller falls back to the Responses
    /// probe rather than failing the refresh.
    func fetchKeyQuota(oauthToken: String) async throws -> MuseQuotaUsage {
        let body = try JSONSerialization.data(withJSONObject: [:], options: [])
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.keyURL,
            headers: [
                "Authorization": "Bearer \(oauthToken)",
                "Content-Type": "application/json",
            ],
            body: body,
            timeout: 15
        ))
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw MuseQuotaError.unauthorized
            }
            throw MuseQuotaError.requestFailed(response.statusCode)
        }
        let usage = try Self.parseKeyPayload(response.body)
        // Same attribution memory as the probe path: the blocked-state
        // 429 carries only a reset instant, so a later fallback-probe 429
        // still attributes against these meters. Shared file with Go.
        if let memory = MuseQuotaMemory.fromUsage(usage, now: Date()) {
            memory.save(to: MuseQuotaMemory.fileURL(in: quotaMemoryDirectory()))
        }
        return usage
    }

    /// Parse POST muse-code/key. Requires at least one window's
    /// `used_percent`, mirroring the probe parser: an empty `subs_usage`
    /// must not become two 0% meters.
    static func parseKeyPayload(_ data: Data) throws -> MuseQuotaUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MuseQuotaError.invalidResponse
        }
        let subsUsage = json["subs_usage"] as? [String: Any]
        let weeklyDict = subsUsage?["weekly"] as? [String: Any]
        let windowDict = subsUsage?["window"] as? [String: Any]
        let weeklyUsedRaw = weeklyDict?["used_percent"].flatMap(ProviderParse.number)
        let windowUsedRaw = windowDict?["used_percent"].flatMap(ProviderParse.number)
        let hasWeekly = weeklyUsedRaw?.isFinite == true
        let hasWindow = windowUsedRaw?.isFinite == true
        guard hasWeekly || hasWindow else {
            throw MuseQuotaError.invalidResponse
        }
        let tier = ((subsUsage?["tier"] as? String) ?? (json["subs_tier_id"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let displayName = (json["subs_tier_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let windowDuration: Int? = {
            if let v = windowDict?["window_duration_mins"] as? Int, v > 0 { return v }
            if let n = windowDict?["window_duration_mins"].flatMap(ProviderParse.number), n > 0 { return Int(n) }
            return nil
        }()
        return MuseQuotaUsage(
            tier: tier,
            planDisplayName: displayName,
            weeklyUsedPercent: hasWeekly ? weeklyUsedRaw : nil,
            windowUsedPercent: hasWindow ? windowUsedRaw : nil,
            weeklyResetsAt: weeklyDict?["resets_at"].flatMap(epochDate),
            windowResetsAt: windowDict?["resets_at"].flatMap(epochDate),
            windowDurationMinutes: windowDuration
        )
    }

    func fetchQuota(apiKey: String) async throws -> MuseQuotaUsage {
        let payload: [String: Any] = [
            "model": Self.probeModel,
            "store": false,
            "stream": true,
            "input": "hi",
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.responsesURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            ],
            body: body,
            timeout: 15
        ))
        guard response.statusCode == 200 else {
            // 429 with `rate_limit_exceeded` / "quota exhausted" is the
            // exhausted-quota signal, not a transient probe rate limit.
            // The API returns JSON `{"error":{"code":"rate_limit_exceeded",
            // "message":"Subscription quota exhausted…","resets_at":…}}`
            // instead of the SSE stream. Do not fabricate 100% for both
            // windows from a single reset (P1-1): surface the blocked state
            // with the reset so the provider can render it accurately.
            if response.statusCode == 429,
               let text = String(data: response.body, encoding: .utf8),
               let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let code = error["code"] as? String, code == "rate_limit_exceeded",
               let message = error["message"] as? String,
               message.lowercased().contains("quota") {
                 let resetsAtSeconds = ProviderParse.number(error["resets_at"])
                 let resetsAt = resetsAtSeconds.map { Date(timeIntervalSince1970: $0) }
                 throw MuseQuotaError.quotaExhausted(resetsAt: resetsAt)
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw MuseQuotaError.unauthorized
            }
            throw MuseQuotaError.requestFailed(response.statusCode)
        }
        guard let text = String(data: response.body, encoding: .utf8) else {
            throw MuseQuotaError.invalidResponse
        }
        let usage = try Self.parseUsageEvent(from: text)
        // Remember the payload so a later 429 (reset instant only, no window
        // marker) can be attributed to the right window. Best-effort: the
        // poll outcome never depends on this write, and the file is shared
        // with the Go TUI/daemon.
        if let memory = MuseQuotaMemory.fromUsage(usage, now: Date()) {
            memory.save(to: MuseQuotaMemory.fileURL(in: quotaMemoryDirectory()))
        }
        return usage
    }

    /// First `response.subscription_usage` SSE event in a stream.
    /// NOTE: The current `HTTPClient` (`URLSession.data(for:)`) buffers the
    /// entire response before `parseUsageEvent` sees it (P1-2). The early-exit
    /// here saves parsing but not network time; a true streaming transport
    /// would be needed to cancel after the first usage event. The provider
    /// timeout (15s) still bounds it.
    static func parseUsageEvent(from sse: String) throws -> MuseQuotaUsage {
        var event = ""
        for rawLine in sse.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                event = ""
                continue
            }
            if line.hasPrefix("event:") {
                event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                break
            }
            guard event == "response.subscription_usage" else { continue }
            return try parseUsagePayload(String(payload))
        }
        throw MuseQuotaError.missingUsageEvent
    }

    private static func parseUsagePayload(_ payload: String) throws -> MuseQuotaUsage {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subscription = json["subscription"] as? [String: Any]
        else {
            throw MuseQuotaError.invalidResponse
        }
        // Require at least one window's used_percent to be present and finite.
        // An empty subscription `{}` must not become two 0% meters (P2-6).
        // We treat each window independently: a valid window emits a meter,
        // a missing/invalid window stays nil and is not rendered.
        let weeklyDict = subscription["weekly"] as? [String: Any]
        let windowDict = subscription["window"] as? [String: Any]
        let weeklyUsedRaw = weeklyDict?["used_percent"].flatMap(ProviderParse.number)
        let windowUsedRaw = windowDict?["used_percent"].flatMap(ProviderParse.number)
        // At least one must be present and finite.
        let hasWeekly = weeklyUsedRaw?.isFinite == true
        let hasWindow = windowUsedRaw?.isFinite == true
        guard hasWeekly || hasWindow else {
            throw MuseQuotaError.invalidResponse
        }
        let weeklyUsed: Double? = hasWeekly ? weeklyUsedRaw : nil
        let windowUsed: Double? = hasWindow ? windowUsedRaw : nil
        let weeklyResets = weeklyDict?["resets_at"].flatMap(epochDate)
        let windowResets = windowDict?["resets_at"].flatMap(epochDate)
        // window_duration_mins: keep nil if missing/zero so the 300 fallback works (P2-6).
        let windowDuration: Int? = {
            if let v = windowDict?["window_duration_mins"] as? Int, v > 0 { return v }
            if let n = windowDict?["window_duration_mins"].flatMap(ProviderParse.number), n > 0 { return Int(n) }
            return nil
        }()
        return MuseQuotaUsage(
            tier: subscription["tier"] as? String,
            weeklyUsedPercent: weeklyUsed,
            windowUsedPercent: windowUsed,
            weeklyResetsAt: weeklyResets,
            windowResetsAt: windowResets,
            windowDurationMinutes: windowDuration
        )
    }

    private static func epochDate(_ value: Any?) -> Date? {
        guard let seconds = ProviderParse.number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// User-attested plan label from the shared settings file, when set. Never
    /// throws: a missing or unreadable file just means no override, and a display
    /// label must never fail the refresh.
    func planNameOverride() -> String? {
        // `try?` nests the already-optional read (`String??`): a thrown error
        // and an absent file both collapse to nil — either way, no override.
        let text: String? = (try? userStore.files.readTextIfPresent(Self.sharedSettingsPath)) ?? nil
        guard let text = text else { return nil }
        return Self.planNameOverride(from: text)
    }

    /// Pull `provider_paths.plan_name` off the `muse_code` account entry (falling
    /// back to an account id of `muse` / `muse-code`). Pure for testability.
    static func planNameOverride(from settingsText: String) -> String? {
        guard let data = settingsText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [[String: Any]]
        else {
            return nil
        }
        let entry = accounts.first {
            ($0["provider"] as? String) == "muse_code"
                || ["muse", "muse-code"].contains($0["id"] as? String ?? "")
        }
        let paths = entry?["provider_paths"] as? [String: Any]
        guard let name = (paths?["plan_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            return nil
        }
        return name
    }

    /// Display name for a raw tier: "Muse Code Everyday Usage" becomes
    /// "Everyday Usage". Opaque IDs (the event carries an account-scoped tier
    /// ID, not a plan name) pass through unchanged rather than guessed at.
    static func planName(tier: String?) -> String? {
        guard let trimmed = tier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        let stripped = trimmed.hasPrefix("Muse Code ")
            ? String(trimmed.dropFirst("Muse Code ".count)).trimmingCharacters(in: .whitespaces)
            : trimmed
        return stripped.isEmpty ? trimmed : stripped
    }

    /// Session + Weekly percent meters for the snapshot. Periods mirror the
    /// event: the event's own window duration, else the 5-hour rolling default.
    /// Only emits a meter when its percentage is present (nil = unknown, not 0).
    static func quotaLines(usage: MuseQuotaUsage) -> [MetricLine] {
        // Blocked state is handled via MuseQuotaError.quotaExhausted, not via
        // fabricated 100% values here. This keeps the two-window percentages
        // honest (P1-1).
        if usage.isQuotaBlocked {
            return []
        }
        var lines: [MetricLine] = []
        if let windowUsed = usage.windowUsedPercent {
            let sessionPeriodMs = (usage.windowDurationMinutes ?? 300) * 60 * 1_000
            lines.append(.progress(
                label: "Session",
                used: windowUsed,
                limit: 100,
                format: .percent,
                resetsAt: usage.windowResetsAt,
                periodDurationMs: sessionPeriodMs
            ))
        }
        if let weeklyUsed = usage.weeklyUsedPercent {
            lines.append(.progress(
                label: "Weekly",
                used: weeklyUsed,
                limit: 100,
                format: .percent,
                resetsAt: usage.weeklyResetsAt,
                periodDurationMs: 7 * 24 * 3_600 * 1_000
            ))
        }
        return lines
    }

    /// Which window a 429 reset belongs to: "Session" when the reset sits far
    /// sooner than the remembered weekly reset, else "Weekly" (or unknown —
    /// the legacy assumption). Pure for testability.
    static func blockedWindowLabel(resetsAt: Date?, now: Date, memory: MuseQuotaMemory?) -> String {
        guard let resetsAt,
              MuseQuotaMemory.isSessionBlock(resetsAt: resetsAt, now: now, memory: memory)
        else {
            return "Weekly"
        }
        return "Session"
    }

    /// Single blocked-state indicator for the 429 quota-exhausted signal.
    /// The error supplies only a reset instant, not per-window percentages, so
    /// we surface the attributed window as blocked with the reset (P1-1)
    /// rather than two fabricated 100% bars.
    static func blockedQuotaLine(resetsAt: Date?, label: String) -> MetricLine {
        let period: Int = label == "Session" ? 5 * 3_600 * 1_000 : 7 * 24 * 3_600 * 1_000
        return .progress(
            label: label,
            used: 100,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: period
        )
    }
}
