import Foundation

/// Tracks Muse Code usage from the CLI's session logs already on this Mac: per-day spend tiles
/// and a usage trend, plus live Session / Weekly quota meters from the same
/// `response.subscription_usage` event the `muse` TUI's `/usage` view renders
/// (see `MuseQuotaClient`). Quota is best-effort and never fails the refresh:
/// without an API key the local scan stands alone.
///
/// No quick links: the provider ships none rather than guessing at Status / Dashboard URLs.
@MainActor
final class MuseProvider: ProviderRuntime {
    let provider = Provider(
        id: "muse",
        displayName: "Muse Code",
        icon: .providerMark("muse")
    )

    let authStore: MuseAuthStore
    let usageScanner: MuseUsageScanner
    let quotaClient: MuseQuotaClient
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    /// Names the local source on hover. Dollars are estimated from Meta's published Muse Spark
    /// rates (not measured), so the estimate marker applies — unlike OpenCode's carried costs.
    private let sourceNote = "From your Muse logs (estimated)"

    /// Edge-triggers the auth-read-failure log so persistently unreadable storage warns once per
    /// run, not once per 5-minute refresh.
    private var loggedAuthReadFailure = false

    init(
        authStore: MuseAuthStore = MuseAuthStore(),
        usageScanner: MuseUsageScanner = MuseUsageScanner(),
        quotaClient: MuseQuotaClient = MuseQuotaClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageScanner = usageScanner
        self.quotaClient = quotaClient
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "muse.session", provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "muse.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "muse.quota", provider: provider, title: "Quota")
                .exportingLimit("quota", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: an exported `META_API_KEY`, the local `auth.json`,
        // the saved `muse.json` quota key file, or any Muse session log already on disk.
        // Local-only, off the main actor. Unreadable storage is itself a Muse footprint
        // — enable the provider so `refresh()` can surface the error. P2-5: previously
        // omitted the saved quota file, so file-only quota setups didn't satisfy detection.
        do {
            if try await loadOffMainActor({ [authStore] in try authStore.credential() }) != nil {
                return true
            }
        } catch {
            return true
        }
        // Saved quota key file (shared with Go) — file-only quota without auth.json
        // should still count as a credential for detection, and `refresh()` can use
        // it via `quotaClient.apiKey()` even when `authStore` is nil.
        if await loadOffMainActor({ [quotaClient] in quotaClient.userStore.loadKey() != nil }) {
            return true
        }
        return await usageScanner.hasLocalUsage()
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()

        var credential: MuseCredential?
        var authReadError: MuseUsageError?
        do {
            credential = try await loadOffMainActor { [authStore] in try authStore.credential() }
            loggedAuthReadFailure = false
        } catch let error as MuseUsageError {
            authReadError = error
            if case .credentialsUnreadable(let detail) = error, !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("muse"), "auth.json unreadable: \(detail)")
            }
        } catch {
            authReadError = .credentialsUnreadable(detail: error.localizedDescription)
        }

        let scan = await usageScanner.scan(now: refreshedAt, pricing: await pricing())

        var lines: [MetricLine] = []
        // Live quota first (when an API key exists), local spend after — same
        // order as the Codex card. Best-effort: a quota failure only logs and
        // the local scan stands alone.
        let quota = await fetchQuotaBestEffort()
        // User-attested label wins over the quota-derived name (an opaque
        // numeric ID on the probe path, server-provided on the account path).
        // Off the main actor: file read.
        let planOverride = await loadOffMainActor { [quotaClient] in quotaClient.planNameOverride() }
        lines += quota.lines
        if let scan {
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: refreshedAt,
                estimated: true,
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: sourceNote
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: sourceNote)
        }

        if lines.isEmpty {
            if credential != nil {
                // Logged in but nothing in the window: honest "No data", not an error.
                MetricLine.appendNoDataIfNeeded(&lines)
            } else {
                return ProviderSnapshot.error(
                    provider: provider, error: authReadError ?? MuseUsageError.notLoggedIn
                )
            }
        }

        return ProviderSnapshot.make(
            provider: provider,
            plan: planOverride ?? quota.planName,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: scan.map {
                ProviderUsageHistory(
                    series: $0.series,
                    modelUsage: $0.modelUsage,
                    unknownModelsByDay: $0.unknownModelsByDay
                )
            }
        )
    }

    /// Session / Weekly quota meters plus the plan display name, or empty/nil
    /// when no API key exists or the probe fails. Logged, not thrown — quota
    /// supplements the local scan and must never fail the refresh. Secrets
    /// stay out of the log: only the error description is recorded.
    /// The first keychain read is off the main actor so a locked keychain
    /// (up to 5s `security` wait) does not freeze the UI (P1-3).
    private func fetchQuotaBestEffort() async -> (lines: [MetricLine], planName: String?) {
        // OAuth account endpoint first: same meters plus the server-provided
        // plan name, with no inference cost. Any failure falls through to
        // the Responses probe below, which also covers API-key-only setups.
        if let oauth: String = try? await loadOffMainActor({ [quotaClient] in
            try quotaClient.oauthToken()
        }), !oauth.isEmpty {
            do {
                let usage = try await quotaClient.fetchKeyQuota(oauthToken: oauth)
                let name = usage.planDisplayName.flatMap(MuseQuotaClient.planName)
                    ?? MuseQuotaClient.planName(tier: usage.tier)
                return (MuseQuotaClient.quotaLines(usage: usage), name)
            } catch let error as MuseQuotaError where error == .unauthorized {
                // The owned copy may have gone stale while the CLI refreshed
                // its own token. Re-bootstrap once from the keychain and
                // retry before paying for a probe.
                if let fresh: String = try? await loadOffMainActor({ [quotaClient] in
                    try quotaClient.refreshOAuthToken()
                }), !fresh.isEmpty, fresh != oauth,
                   let usage = try? await quotaClient.fetchKeyQuota(oauthToken: fresh) {
                    let name = usage.planDisplayName.flatMap(MuseQuotaClient.planName)
                        ?? MuseQuotaClient.planName(tier: usage.tier)
                    return (MuseQuotaClient.quotaLines(usage: usage), name)
                }
                AppLog.info(LogTag.plugin("muse"), "account quota endpoint rejected; falling back to probe")
            } catch {
                AppLog.info(LogTag.plugin("muse"), "account quota endpoint failed; falling back to probe: \(error.localizedDescription)")
            }
        }
        do {
            // Move the blocking keychain/file read off the main actor.
            let apiKey: String? = try await loadOffMainActor { [quotaClient] in
                try quotaClient.apiKey()
            }
            guard let apiKey else { return ([], nil) }
            let usage = try await quotaClient.fetchQuota(apiKey: apiKey)
            return (
                MuseQuotaClient.quotaLines(usage: usage),
                MuseQuotaClient.planName(tier: usage.tier)
            )
        } catch let error as MuseQuotaError {
            // Quota exhausted is a known blocked state, not a transient error.
            // Surface it as a single 100% Quota meter with the reset so the
            // dashboard shows the blocked state without fabricating two 100%
            // windows (P1-1).
            if case .quotaExhausted(let resetsAt) = error {
                AppLog.info(LogTag.plugin("muse"), "quota exhausted, resets at \(String(describing: resetsAt))")
                // A 429 carries only a reset instant, no window marker: attribute
                // it against the remembered weekly reset so a 5h session block
                // doesn't render as a weekly one. No memory means the legacy
                // weekly assumption.
                let memory = MuseQuotaMemory.load(from: MuseQuotaMemory.fileURL(
                    in: quotaClient.quotaMemoryDirectory()))
                let label = MuseQuotaClient.blockedWindowLabel(
                    resetsAt: resetsAt, now: now(), memory: memory)
                return ([MuseQuotaClient.blockedQuotaLine(resetsAt: resetsAt, label: label)], nil)
            }
            AppLog.warn(LogTag.plugin("muse"), "quota probe failed; showing local spend only: \(error.localizedDescription)")
            return ([], nil)
        } catch {
            AppLog.warn(LogTag.plugin("muse"), "quota probe failed; showing local spend only: \(error.localizedDescription)")
            return ([], nil)
        }
    }
}

// MARK: - APIKeyManaging
//
// The Settings card manages the *explicit* key only (saved file / env); the
// auto-detected CLI keychain entry stays a silent fallback, so the status dot
// reflects the managed key, not effective quota availability.
extension MuseProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { quotaClient.userStore.keyStatus() }
    func currentAPIKey() -> String? { quotaClient.userStore.loadKey() }
    func saveAPIKey(_ key: String) throws { try quotaClient.userStore.saveKey(key) }
    func deleteAPIKey() throws { try quotaClient.userStore.deleteKey() }
}
