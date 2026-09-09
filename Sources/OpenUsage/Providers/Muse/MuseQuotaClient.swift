import Foundation

/// Live subscription quota for Muse Code, parsed from the
/// `response.subscription_usage` SSE event on POST `api.meta.ai/v1/responses` —
/// the same event the `muse` TUI's `/usage` view renders. A minimal streamed
/// probe returns weekly + window percentages with no browser session or
/// page-load tokens, authenticated by the CLI's own keychain `api_key`.
struct MuseQuotaUsage: Sendable, Equatable {
    var tier: String?
    var weeklyUsedPercent: Double
    var windowUsedPercent: Double
    var weeklyResetsAt: Date?
    var windowResetsAt: Date?
    var windowDurationMinutes: Int?
}

enum MuseQuotaError: Error, LocalizedError, Equatable {
    case unauthorized
    case requestFailed(Int)
    case missingUsageEvent
    case invalidResponse

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
        }
    }
}

extension MuseQuotaError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .unauthorized: .authExpired
        case .requestFailed(let status): ErrorCategory.http(status)
        case .missingUsageEvent, .invalidResponse: .decoding
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
            // instead of the SSE stream. Surface it as 100% used with the
            // reset instant so the dashboard shows "Session 100% / Weekly
            // 100% (resets Sep 14)" rather than "no data" / missing resources.
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
                // Both windows are exhausted when the subscription is out;
                // weekly reset is the authoritative date from the error,
                // window reset reuses it (period is still the 5h default in
                // quotaLines). Tier is opaque/unknown here.
                return MuseQuotaUsage(
                    tier: nil,
                    weeklyUsedPercent: 100,
                    windowUsedPercent: 100,
                    weeklyResetsAt: resetsAt,
                    windowResetsAt: resetsAt,
                    windowDurationMinutes: 300
                )
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

    /// First `response.subscription_usage` SSE event in a stream. Stops at the
    /// event instead of reading to `[DONE]` — provider polls run under tight
    /// timeouts.
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
        let weekly = subscription["weekly"] as? [String: Any] ?? [:]
        let window = subscription["window"] as? [String: Any] ?? [:]
        return MuseQuotaUsage(
            tier: subscription["tier"] as? String,
            weeklyUsedPercent: ProviderParse.number(weekly["used_percent"]) ?? 0,
            windowUsedPercent: ProviderParse.number(window["used_percent"]) ?? 0,
            weeklyResetsAt: epochDate(weekly["resets_at"]),
            windowResetsAt: epochDate(window["resets_at"]),
            windowDurationMinutes: (window["window_duration_mins"] as? Int)
                ?? Int(ProviderParse.number(window["window_duration_mins"]) ?? 0)
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
    static func quotaLines(usage: MuseQuotaUsage) -> [MetricLine] {
        let sessionPeriodMs = (usage.windowDurationMinutes ?? 300) * 60 * 1_000
        return [
            .progress(
                label: "Session",
                used: usage.windowUsedPercent,
                limit: 100,
                format: .percent,
                resetsAt: usage.windowResetsAt,
                periodDurationMs: sessionPeriodMs
            ),
            .progress(
                label: "Weekly",
                used: usage.weeklyUsedPercent,
                limit: 100,
                format: .percent,
                resetsAt: usage.weeklyResetsAt,
                periodDurationMs: 7 * 24 * 3_600 * 1_000
            ),
        ]
    }
}
