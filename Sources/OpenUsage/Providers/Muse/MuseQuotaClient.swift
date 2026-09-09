import Foundation

/// Live subscription quota for Muse Code, parsed from the
/// `response.subscription_usage` SSE event on POST `api.meta.ai/v1/responses` —
/// the same event the `muse` TUI's `/usage` view renders. A minimal streamed
/// probe returns weekly + window percentages with no browser session or
/// page-load tokens, authenticated by the CLI's own keychain `api_key`.
struct MuseQuotaUsage: Sendable, Equatable {
    var tier: String?
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
}

struct MuseQuotaClient: Sendable {
    static let keychainService = "ai.meta.dev.credentials"
    static let keychainAccount = "meta"
    static let responsesURL = URL(string: "https://api.meta.ai/v1/responses")!
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
    /// One-prompt memo for the keychain fallback. Instance-scoped (reference
    /// type) so copies of this struct share the memo; a new client in tests
    /// starts unmemoized and does not pollute other tests.
    private let keychainMemo = MuseKeychainMemo()

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        userStore: UserAPIKeyStore? = nil
    ) {
        self.http = http
        self.keychain = keychain
        self.environment = environment
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
        return try Self.parseUsageEvent(from: text)
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

    /// Single blocked-state indicator for the 429 quota-exhausted signal.
    /// The error supplies only a reset instant, not per-window percentages, so
    /// we surface the weekly window as blocked with the reset (P1-1) rather
    /// than two fabricated 100% bars. The weekly window is the one whose reset
    /// is typically ~6 days out (observed Sep 14), matching the error's date.
    static func blockedQuotaLine(resetsAt: Date?) -> MetricLine {
        return .progress(
            label: "Weekly",
            used: 100,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: 7 * 24 * 3_600 * 1_000
        )
    }
}
