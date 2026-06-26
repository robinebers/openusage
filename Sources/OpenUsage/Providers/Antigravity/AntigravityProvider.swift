import Foundation

/// Tracks per-model quota for Antigravity (Google's Codeium/Windsurf-derived AI IDE). Quotas are
/// fraction-based and shown as three percent meters: Gemini Pro, Gemini Flash, and Claude (the shared
/// non-Gemini pool).
///
/// Probe order, best source first:
/// 1. Antigravity language server (running app) — richest, gives the authoritative plan.
/// 2. `agy` language server (running CLI).
/// 3. Keychain token → Google Cloud Code (works with the app closed); refreshes via Google OAuth.
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
            .percent(id: "antigravity.geminiPro", provider: provider, title: "Gemini Pro"),
            .percent(id: "antigravity.geminiFlash", provider: provider, title: "Gemini Flash"),
            .percent(id: "antigravity.claude", provider: provider, title: "Claude")
        ]
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
        let keychainToken = await loadOffMainActor({ authStore.loadKeychainToken() })

        var tokens: [String] = []
        if let keychainToken, let access = keychainToken.accessToken, authStore.isUsable(expiry: keychainToken.expiry) {
            tokens.append(access)
        }
        if let cached = authStore.loadCachedToken(), !tokens.contains(cached) {
            tokens.append(cached)
        }

        // We have something to authenticate with if any token was tried or a refresh token exists. Used
        // to tell a transient outage ("temporarily unavailable") apart from a genuine "not signed in".
        let hasCredentials = !tokens.isEmpty || (keychainToken?.refreshToken?.isEmpty == false)

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
        if sawAuthFailure || tokens.isEmpty, let refreshToken = keychainToken?.refreshToken {
            switch await usageClient.refreshGoogleToken(refreshToken) {
            case .refreshed(let accessToken, let expiresIn):
                authStore.cacheToken(accessToken, expiresIn: expiresIn)
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
        // Primary: fetchAvailableModels — the full Antigravity model set (Gemini + Claude + GPT-OSS).
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
