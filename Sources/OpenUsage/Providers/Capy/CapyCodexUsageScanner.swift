import Foundation

/// Reads Codex-subscription usage that ran inside Capy (capy.ai) and returns it in the same normalized
/// shape as Codex's native, pi, and OpenCode scanners, so it folds into the Codex card.
///
/// Capy runs its agent loop in the cloud: when a ChatGPT subscription is connected, Capy's servers call
/// Codex with it and nothing lands in `~/.codex/sessions`. The only record is Capy's own billing API,
/// read here with the desktop app's session (see `CapySession`). Only the `subscription` route's
/// `codex/*` entries count — Capy-credit (`paid`), BYOK, and Claude-subscription traffic stay off this
/// card — and `principal` scopes a team org to the signed-in user.
///
/// Attribution is exact, not "unattributed history": Capy reports which ChatGPT account its Codex
/// connection uses, so usage only reaches the card signed in to that same `account_id`. That keeps it
/// correct with several Codex accounts, where pi and OpenCode have to be skipped.
///
/// Best-effort like the other supplementary sources: failures are logged once, never fail the card.
actor CapyCodexUsageScanner {
    static let shared = CapyCodexUsageScanner()
    static let apiBase = "https://api.capy.ai/app"
    static let codexEntryPrefix = "codex/"

    struct ModelTokens: Sendable, Equatable {
        var model: String
        var tokens: TokenBreakdown
    }

    private let http: any HTTPClient
    private let homeDirectory: @Sendable () -> URL
    private let keyReader: any ClaudeDesktopSafeStorageKeyReading
    private var key: Data?
    /// Finished local days never change, so each `org|day` is fetched once per app run.
    private var completedDays: [String: [ModelTokens]] = [:]
    private var lastFailure: String?

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        keyReader: any ClaudeDesktopSafeStorageKeyReading = ClaudeDesktopSafeStorageKeyReader(
            service: "Capy Safe Storage", account: "Capy Key"
        )
    ) {
        self.http = http
        self.homeDirectory = homeDirectory
        self.keyReader = keyReader
    }

    /// Usage for the Codex card signed in to `codexAccountID`. `allowInteraction` gates the one-time
    /// Keychain prompt; pass true only for a manual refresh so a background refresh never pops a dialog.
    func scan(
        now: Date, daysBack: Int = 30, pricing: ModelPricing, codexAccountID: String, allowInteraction: Bool
    ) async -> LogUsageScan? {
        // No session file means no Capy: stay silent and never touch the Keychain.
        guard CapySession.sessionFileExists(homeDirectory: homeDirectory()) else { return nil }
        do {
            let session = try CapySession.load(
                homeDirectory: homeDirectory(), key: try safeStorageKey(allowInteraction: allowInteraction)
            )
            let jwt = try await session.mintToken(http: http)
            let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)

            var accumulator = DailyUsageAccumulator()
            var preparedByModel: [String: CodexUsagePricing.Prepared?] = [:]
            var added = false
            for org in try await organizationIDs(jwt: jwt) {
                guard try await connectedCodexAccountIDs(org: org, jwt: jwt).contains(codexAccountID) else { continue }
                let principal = "principal=\(session.userID)"
                for dayStart in try await activeLocalDays(org: org, principal: principal, since: since, jwt: jwt) {
                    let day = DailyUsageAccumulator.dayKey(from: dayStart)
                    for row in try await dayUsage(org: org, principal: principal, dayStart: dayStart, now: now, jwt: jwt) {
                        let prepared: CodexUsagePricing.Prepared?
                        if let cached = preparedByModel[row.model] {
                            prepared = cached
                        } else {
                            prepared = CodexUsagePricing.prepare(pricing: pricing, model: row.model)
                            preparedByModel[row.model] = prepared
                        }
                        guard let prepared else {
                            if row.tokens.totalTokens > 0 { accumulator.addUnknownModel(day: day, model: row.model) }
                            continue
                        }
                        accumulator.add(
                            day: day,
                            tokens: row.tokens.totalTokens,
                            cost: CodexUsagePricing.cost(prepared: prepared, tokens: row.tokens),
                            model: row.model
                        )
                        added = true
                    }
                }
            }
            lastFailure = nil
            return added ? accumulator.build() : nil
        } catch {
            report(error, manual: allowInteraction)
            return nil
        }
    }

    // MARK: - API

    private func organizationIDs(jwt: String) async throws -> [String] {
        let payload = try await get("/organizations", jwt: jwt) as? [[String: Any]] ?? []
        return payload.compactMap { $0["id"] as? String }
    }

    /// ChatGPT account ids of the org's connected Codex subscriptions.
    /// ponytail: usage is attributed to the account connected *now*; a reconnect to another account
    /// moves past usage with it. Capy's usage API carries no per-row account to do better.
    private func connectedCodexAccountIDs(org: String, jwt: String) async throws -> Set<String> {
        let payload = try await get("/orgs/\(org)/models/connections", jwt: jwt) as? [String: Any]
        return Self.connectedCodexAccountIDs(connectionsPayload: payload ?? [:])
    }

    /// Local-calendar days (as start-of-day dates) holding any Codex-subscription usage. One `series`
    /// call covers the whole window, so quiet days cost no `breakdown` request. Series buckets are UTC,
    /// so each active bucket marks every local day it overlaps.
    private func activeLocalDays(org: String, principal: String, since: Date, jwt: String) async throws -> [Date] {
        let query = "from=\(OpenUsageISO8601.string(from: since))&dimension=entry&route=subscription&\(principal)"
        let payload = try await get("/orgs/\(org)/billing/usage/series?\(query)", jwt: jwt) as? [String: Any]
        return Self.activeLocalDays(seriesPayload: payload ?? [:], since: since)
    }

    private func dayUsage(org: String, principal: String, dayStart: Date, now: Date, jwt: String) async throws -> [ModelTokens] {
        let cacheKey = "\(org)|\(DailyUsageAccumulator.dayKey(from: dayStart))"
        if let cached = completedDays[cacheKey] { return cached }
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let range = "from=\(OpenUsageISO8601.string(from: dayStart))&to=\(OpenUsageISO8601.string(from: min(dayEnd, now)))"
        let payload = try await get("/orgs/\(org)/billing/usage/breakdown?\(range)&\(principal)", jwt: jwt)
        let rows = Self.codexSubscriptionRows(breakdownPayload: payload as? [String: Any] ?? [:])
        // ponytail: one hour of grace for late-ingested usage; widen it if Capy's billing lags longer.
        if dayEnd.addingTimeInterval(3600) < now { completedDays[cacheKey] = rows }
        return rows
    }

    private func get(_ pathAndQuery: String, jwt: String) async throws -> Any {
        guard let url = URL(string: Self.apiBase + pathAndQuery) else {
            throw CapySession.Failure.unreadable("invalid Capy API URL")
        }
        let response = try await http.send(HTTPRequest(
            method: "GET", url: url,
            headers: ["Authorization": "Bearer \(jwt)", "Accept": "application/json"]
        ))
        guard response.statusCode == 200 else {
            throw CapySession.Failure.unreadable("\(pathAndQuery.split(separator: "?")[0]) answered \(response.statusCode)")
        }
        return try JSONSerialization.jsonObject(with: response.body)
    }

    private func safeStorageKey(allowInteraction: Bool) throws -> Data {
        if let key { return key }
        let password: String?
        do {
            password = try keyReader.readPassword(allowInteraction: allowInteraction)
        } catch ClaudeDesktopCredentialError.permissionRequired {
            throw CapySession.Failure.keychainPermissionRequired
        }
        // The session file exists, so a missing key is an anomaly worth logging, not "signed out".
        guard let password else { throw CapySession.Failure.unreadable("Keychain item \"Capy Safe Storage\" not found") }
        let derived = try ClaudeDesktopAuthStore.deriveKey(password: password)
        key = derived
        return derived
    }

    /// Logs a failure once per distinct reason, so a persistent problem doesn't flood the log on every
    /// background refresh; a manual refresh always logs, since someone is actively looking. Signed-out
    /// is normal and never logged.
    private func report(_ error: Error, manual: Bool) {
        if case CapySession.Failure.notSignedIn = error { return }
        let message: String
        switch error {
        case CapySession.Failure.keychainPermissionRequired:
            message = "needs Keychain access to \"Capy Safe Storage\"; refresh manually and allow it"
        case CapySession.Failure.mintRefused(let status):
            message = "Capy session refused (\(status)); sign in to the Capy app again"
        case CapySession.Failure.unreadable(let detail):
            message = detail
        case ClaudeDesktopCredentialError.keychainFailure(let status):
            message = "Keychain read of \"Capy Safe Storage\" failed (OSStatus \(status))"
        default:
            message = error.localizedDescription
        }
        guard manual || message != lastFailure else { return }
        lastFailure = message
        AppLog.warn(LogTag.plugin("capy"), "Capy Codex usage unavailable: \(message)")
    }

    // MARK: - Parsing (static for tests)

    static func connectedCodexAccountIDs(connectionsPayload: [String: Any]) -> Set<String> {
        let subscriptions = connectionsPayload["subscriptions"] as? [[String: Any]] ?? []
        return Set(subscriptions.compactMap { subscription in
            guard subscription["service"] as? String == "codex", subscription["state"] as? String == "connected"
            else { return nil }
            return (subscription["accountId"] as? String)?.nilIfEmpty
        })
    }

    static func activeLocalDays(seriesPayload: [String: Any], since: Date, calendar: Calendar = .current) -> [Date] {
        let bucketSeconds: TimeInterval = seriesPayload["bucket"] as? String == "hour" ? 3600 : 86_400
        var days = Set<Date>()
        for bucket in seriesPayload["buckets"] as? [[String: Any]] ?? [] {
            guard let start = (bucket["start"] as? String).flatMap(OpenUsageISO8601.date(from:)) else { continue }
            let codexCredits = (bucket["slices"] as? [[String: Any]] ?? [])
                .filter { ($0["key"] as? String)?.hasPrefix(codexEntryPrefix) == true }
                .reduce(0) { $0 + (ProviderParse.number($1["credits"]) ?? 0) }
            guard codexCredits > 0 else { continue }
            for instant in [start, start.addingTimeInterval(bucketSeconds - 1)] {
                let day = calendar.startOfDay(for: instant)
                if day >= since { days.insert(day) }
            }
        }
        return days.sorted()
    }

    /// Per-model tokens from the `subscription` route's `codex/*` entries. Capy's `inputTokens`
    /// includes cache reads (OpenAI's convention — cache reads never exceed it), while `TokenBreakdown`
    /// wants them disjoint, so cache reads are split out of input.
    static func codexSubscriptionRows(breakdownPayload: [String: Any]) -> [ModelTokens] {
        let routes = breakdownPayload["routes"] as? [[String: Any]] ?? []
        return routes.filter { $0["route"] as? String == "subscription" }.flatMap { route in
            (route["entries"] as? [[String: Any]] ?? []).compactMap { entry -> ModelTokens? in
                guard let key = entry["key"] as? String, key.hasPrefix(codexEntryPrefix),
                      let tokens = entry["tokens"] as? [String: Any]
                else { return nil }
                func count(_ name: String) -> Int { Int(max(ProviderParse.number(tokens[name]) ?? 0, 0)) }
                let cacheRead = count("cacheReadTokens")
                return ModelTokens(
                    model: String(key.dropFirst(codexEntryPrefix.count)),
                    tokens: TokenBreakdown(
                        input: max(count("inputTokens") - cacheRead, 0),
                        cacheWrite5m: count("cacheWriteTokens"),
                        cacheRead: cacheRead,
                        output: count("outputTokens")
                    )
                )
            }
        }
    }
}
