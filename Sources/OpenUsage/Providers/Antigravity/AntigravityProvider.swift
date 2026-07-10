import Foundation

/// Tracks pool quota for Antigravity (Google's Codeium/Windsurf-derived AI IDE). Quotas are
/// fraction-based and shown as up to four percent meters: the shared Gemini pool and the shared
/// non-Gemini pool (Claude, GPT-OSS), each with a rolling 5-hour and a weekly window.
///
/// Probe order, best source first:
/// 1. Antigravity language server (running app) — richest, gives the authoritative plan.
/// 2. `agy` language server (running CLI).
/// 3. Keychain token → Google Cloud Code (works with the app closed); refreshes via Google OAuth.
///
/// On each source, `RetrieveUserQuotaSummary` is tried first (the only endpoint reporting the merged
/// pools and the weekly windows); builds without it fall back to the legacy per-model endpoints,
/// which are 5h-only — the weekly meters read "No data" there.
@MainActor
final class AntigravityProvider: ProviderRuntime {
    let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))

    let authStore: AntigravityAuthStore
    let usageClient: AntigravityUsageClient
    let discovery: LanguageServerDiscovery
    let now: @Sendable () -> Date

    init(
        authStore: AntigravityAuthStore = AntigravityAuthStore(),
        usageClient: AntigravityUsageClient = AntigravityUsageClient(),
        discovery: LanguageServerDiscovery = LanguageServerDiscovery(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.discovery = discovery
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: AntigravityMetric.geminiID, provider: provider, title: AntigravityMetric.sessionLabel, isSessionWindow: true),
            .percent(id: AntigravityMetric.geminiWeeklyID, provider: provider, title: AntigravityMetric.weeklyLabel),
            .percent(id: AntigravityMetric.claudeID, provider: provider, title: AntigravityMetric.claudeLabel, isSessionWindow: true),
            .percent(id: AntigravityMetric.claudeWeeklyID, provider: provider, title: AntigravityMetric.claudeWeeklyLabel)
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // The Keychain login is the source of truth. The app-owned access-token cache is derivative
        // and must never independently enable the provider after logout.
        do {
            let keychainToken = try await loadOffMainActor { [authStore] in
                try authStore.loadKeychainToken()
            }
            guard keychainToken != nil else {
                await loadOffMainActor { [authStore] in authStore.discardCachedToken() }
                return false
            }
            return true
        } catch {
            // Detection runs once; keep an indeterminate store enabled so refresh can show the repair.
            return true
        }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let result = try await probe()
            return ProviderSnapshot.make(provider: provider, plan: result.plan, lines: result.lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private struct StrategyResult {
        var plan: String?
        var lines: [MetricLine]
    }

    private func probe() async throws -> StrategyResult {
        if let result = await probeLS(
            processName: "language_server",
            markers: ["antigravity", "antigravity-ide"],
            csrfFlag: "--csrf_token",
            portFlag: "--extension_server_port"
        ) {
            return result
        }
        if let result = await probeLS(processName: "agy", markers: [], csrfFlag: "", portFlag: nil) {
            return result
        }
        return try await probeCloudCode()
    }

    // MARK: - Language server

    private func probeLS(processName: String, markers: [String], csrfFlag: String, portFlag: String?) async -> StrategyResult? {
        let discovery = self.discovery
        let options = LanguageServerDiscovery.Options(
            processName: processName,
            markers: markers,
            csrfFlag: csrfFlag,
            portFlag: portFlag
        )
        guard let discovered = await loadOffMainActor({ discovery.discover(options) }) else { return nil }

        // HTTPS first (the LS serves a self-signed cert), then HTTP, then the HTTP-only extension port.
        var endpoints: [(scheme: String, port: Int)] = []
        for port in discovered.ports {
            endpoints.append(("https", port))
            endpoints.append(("http", port))
        }
        if let extensionPort = discovered.extensionPort {
            endpoints.append(("http", extensionPort))
        }

        for endpoint in endpoints {
            // The quota summary is authoritative (merged pools + weekly windows), so it goes first.
            // A parsed summary — even one with zero usable buckets — ends the probe: the legacy
            // endpoints below fabricate "fully used" from missing quota info, so an authoritative
            // answer must never fall through to them. Empty lines render as "No data" rows.
            if let summary = await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "RetrieveUserQuotaSummary") {
                if (200..<300).contains(summary.statusCode) {
                    if let lines = AntigravityUsageMapper.parseQuotaSummary(summary.body) {
                        // The plan comes from an independent GetUserStatus call; the summary never
                        // gates on it — a failed plan lookup just leaves the plan blank.
                        var plan: String?
                        if let status = await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetUserStatus"),
                           (200..<300).contains(status.statusCode) {
                            plan = AntigravityUsageMapper.parseUserStatus(status.body)?.plan
                        }
                        return StrategyResult(plan: plan, lines: lines)
                    }
                    // 2xx but not a summary payload — the parser warned; fall to the legacy flow.
                } else if summary.statusCode != 404 {
                    // 404 = a build without the RPC (expected; legacy is the truth there, no retry).
                    // Anything else is surprising enough to say before degrading to 5h-only data.
                    AppLog.warn(LogTag.plugin("antigravity"), "RetrieveUserQuotaSummary HTTP \(summary.statusCode); falling back to legacy quota endpoints")
                }
            }

            guard let response = await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetUserStatus"),
                  (200..<300).contains(response.statusCode)
            else {
                continue
            }

            if let parsed = AntigravityUsageMapper.parseUserStatus(response.body) {
                let lines = AntigravityUsageMapper.buildLines(parsed.configs)
                if !lines.isEmpty { return StrategyResult(plan: parsed.plan, lines: lines) }
            }

            // The endpoint answered but GetUserStatus had nothing usable — try the documented fallback.
            if let fallback = await usageClient.callLS(scheme: endpoint.scheme, port: endpoint.port, csrf: discovered.csrf, method: "GetCommandModelConfigs"),
               (200..<300).contains(fallback.statusCode),
               let configs = AntigravityUsageMapper.parseCommandModelConfigs(fallback.body) {
                let lines = AntigravityUsageMapper.buildLines(configs)
                if !lines.isEmpty { return StrategyResult(plan: nil, lines: lines) }
            }
        }
        return nil
    }

    // MARK: - Cloud Code

    private func probeCloudCode() async throws -> StrategyResult {
        let authStore = self.authStore
        let keychainToken = try await loadOffMainActor { try authStore.loadKeychainToken() }

        guard let keychainToken else {
            // Proven logout invalidates the derived cache. A Keychain read failure throws above and
            // deliberately leaves the cache untouched for recovery.
            await loadOffMainActor { authStore.discardCachedToken() }
            throw AntigravityError.notSignedIn
        }

        var tokens: [String] = []
        if let access = keychainToken.accessToken, authStore.isUsable(expiry: keychainToken.expiry) {
            tokens.append(access)
        }
        if let cached = await loadOffMainActor({ authStore.loadCachedToken(matching: keychainToken) }),
           !tokens.contains(cached) {
            tokens.append(cached)
        }

        // We have something to authenticate with if any token was tried or a refresh token exists. Used
        // to tell a transient outage ("temporarily unavailable") apart from a genuine "not signed in".
        let hasCredentials = !tokens.isEmpty || (keychainToken.refreshToken?.isEmpty == false)

        var sawAuthFailure = false
        for token in tokens {
            switch await fetchCloudCode(token: token) {
            case .success(let result): return result
            case .authFailed: sawAuthFailure = true
            case .unavailable: break
            }
        }

        // Only refresh on evidence of an auth failure (or no token to try) — a transient Cloud Code
        // outage must not trigger a Google OAuth refresh every cycle.
        if sawAuthFailure || tokens.isEmpty, let refreshToken = keychainToken.refreshToken {
            switch await usageClient.refreshGoogleToken(refreshToken) {
            case .refreshed(let accessToken, let expiresIn):
                await loadOffMainActor {
                    authStore.cacheToken(
                        accessToken,
                        expiresIn: expiresIn,
                        sourceRefreshToken: refreshToken
                    )
                }
                switch await fetchCloudCode(token: accessToken) {
                case .success(let result): return result
                case .authFailed: throw AntigravityError.authExpired
                // The refreshed token is valid, so a non-2xx here is a transient outage, not bad auth.
                case .unavailable: throw AntigravityError.unavailable
                }
            // The refresh token itself is dead (revoked / expired) — that's expired auth, not an outage.
            case .authFailed: throw AntigravityError.authExpired
            // Refresh was only transiently unavailable (throttled / 5xx / network). The refresh token may
            // still be valid, so report a transient outage — even if a token 401'd, an expired access
            // token is normal and isn't evidence the sign-in is dead.
            case .unavailable: throw AntigravityError.unavailable
            }
        }

        // Reached only when no refresh was attempted (no refresh token): a rejected token with no way to
        // refresh is genuinely expired auth.
        if sawAuthFailure { throw AntigravityError.authExpired }
        // Signed in but every endpoint was unreachable — report a transient failure, not "not signed in".
        if hasCredentials { throw AntigravityError.unavailable }
        throw AntigravityError.notSignedIn
    }

    private enum CloudCodeProbe {
        case success(StrategyResult)
        case authFailed
        case unavailable
    }

    private func fetchCloudCode(token: String) async -> CloudCodeProbe {
        // Authoritative first: the quota summary (merged pools + weekly windows). A parsed summary —
        // even one with zero usable buckets — is the answer and must never fall into the legacy chain
        // below, which fabricates "fully used" from missing quota info. A 404 (build without the RPC)
        // reads as `.unavailable` and falls through.
        switch await usageClient.cloudCode(path: AntigravityUsageClient.quotaSummaryPath, token: token, userAgent: "antigravity", body: [:]) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            if let lines = AntigravityUsageMapper.parseQuotaSummary(data) {
                return .success(StrategyResult(plan: await loadPlan(token: token), lines: lines))
            }
            // 2xx but not a summary payload — the parser warned; fall to the legacy chain.
        case .unavailable:
            break
        }

        // Legacy: fetchAvailableModels — the full Antigravity model set (Gemini + Claude + GPT-OSS).
        switch await usageClient.cloudCode(path: AntigravityUsageClient.fetchModelsPath, token: token, userAgent: "antigravity", body: [:]) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseCloudCodeModels(data))
            if !lines.isEmpty {
                return .success(StrategyResult(plan: await loadPlan(token: token), lines: lines))
            }
        case .unavailable:
            break
        }

        // Fallback: loadCodeAssist (plan + project) → retrieveUserQuota (Gemini-only buckets).
        var plan: String?
        var project: String?
        switch await usageClient.cloudCode(path: AntigravityUsageClient.loadCodeAssistPath, token: token, userAgent: "agy", body: [:]) {
        case .authFailed: return .authFailed
        case .ok(let data):
            plan = AntigravityUsageMapper.parseLoadCodeAssistPlan(data)
            project = AntigravityUsageMapper.parseProject(data)
        case .unavailable: break
        }

        var quota = await usageClient.cloudCode(
            path: AntigravityUsageClient.retrieveQuotaPath,
            token: token,
            userAgent: "agy",
            body: project.map { ["project": $0] } ?? [:]
        )
        if case .unavailable = quota, project != nil {
            quota = await usageClient.cloudCode(path: AntigravityUsageClient.retrieveQuotaPath, token: token, userAgent: "agy", body: [:])
        }
        switch quota {
        case .authFailed: return .authFailed
        case .ok(let data):
            let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseQuotaBuckets(data))
            if !lines.isEmpty { return .success(StrategyResult(plan: plan, lines: lines)) }
        case .unavailable: break
        }
        return .unavailable
    }

    private func loadPlan(token: String) async -> String? {
        if case .ok(let data) = await usageClient.cloudCode(path: AntigravityUsageClient.loadCodeAssistPath, token: token, userAgent: "agy", body: [:]) {
            return AntigravityUsageMapper.parseLoadCodeAssistPlan(data)
        }
        return nil
    }
}
