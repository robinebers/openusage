import Foundation

@MainActor
final class CodexProvider: ProviderRuntime {
    static func makeProvider(id: String = "codex", displayName: String = "Codex") -> Provider {
        Provider(id: id, displayName: displayName, icon: .providerMark("codex"), links: [
            .init(label: "Status", url: "https://status.openai.com/"),
            .init(label: "Dashboard", url: "https://chatgpt.com/codex/settings/usage")
        ])
    }

    let provider: Provider
    let historyScope: CodexHistoryScope

    private let localHistory = CodexHistoryRefresh<CodexLocalHistory>()
    let localHistoryWait: Duration

    let authStore: CodexAuthStore
    let usageClient: CodexUsageClient
    let logUsageScanner: CodexLogUsageScanner
    let piUsageScanner: PiUsageScanner
    let openCodeUsageScanner: OpenCodeCodexUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing
    let fallbackModel: @MainActor () -> String?

    init(
        localHistoryWait: Duration = .seconds(5),
        provider: Provider = CodexProvider.makeProvider(),
        authStore: CodexAuthStore = CodexAuthStore(),
        usageClient: CodexUsageClient = CodexUsageClient(),
        logUsageScanner: CodexLogUsageScanner = CodexLogUsageScanner(),
        piUsageScanner: PiUsageScanner = .shared,
        openCodeUsageScanner: OpenCodeCodexUsageScanner = OpenCodeCodexUsageScanner(),
        historyScope: CodexHistoryScope = .allHomes,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        fallbackModel: @escaping @MainActor () -> String? = { CodexFallbackModelSetting.current() }
    ) {
        self.localHistoryWait = localHistoryWait
        self.provider = provider
        self.historyScope = historyScope
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.piUsageScanner = piUsageScanner
        self.openCodeUsageScanner = openCodeUsageScanner
        self.now = now
        self.pricing = pricing
        self.fallbackModel = fallbackModel
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            // Model-specific Spark limits (GPT-5.3-Codex-Spark), parsed from `additional_rate_limits`.
            // Declared right after Weekly so they group with the core rate-limit meters; seeded On
            // Demand (below the caret) and unpinned in `DefaultLayout`.
            .percent(id: "\(provider.id).spark", provider: provider, title: "Spark")
                .exportingLimit("spark", unit: "percent"),
            .percent(id: "\(provider.id).sparkWeekly", provider: provider, title: "Spark Weekly")
                .exportingLimit("sparkWeekly", unit: "percent"),
            .combined(id: "\(provider.id).credits", provider: provider, title: "Extra Usage", metricLabel: "Credits")
                .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits"))
                .exportingLimit("creditValue", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .values(id: "\(provider.id).rateLimitResets", provider: provider, title: "Rate Limit Resets", metricLabel: "Rate Limit Resets", traySuffix: "resets", showsResetExpiries: true)
                .exportingLimit("rateLimitResets", kind: .balance, unit: "resets", source: .value(kind: .count, label: "available")),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Codex logs (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: auth.json candidates first, keychain as the fallback. Only a
        // usable access token counts (see `hasUsableAccessToken`) — an API-key-only auth.json can't
        // serve the usage API, so seeding it on would just show an error row.
        let fileCandidates = authStore.loadAuthCandidates()
        if fileCandidates.contains(where: \.hasUsableAccessToken) {
            return true
        }
        let keychain = await loadOffMainActor { [authStore] in authStore.loadKeychainAuth() }
        return keychain?.hasUsableAccessToken == true
    }

    func refresh() async -> ProviderSnapshot {
        if authStore.expectedIdentity != nil { return await refreshAccount() }
        let fileCandidates = authStore.loadAuthCandidates()
        var lastFallbackError: Error?

        for candidate in fileCandidates {
            var state = candidate
            do {
                return try await probe(authState: &state)
            } catch let error as CodexAuthError where error.allowsAuthFallback {
                lastFallbackError = error
                continue
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        if var keychainCandidate = await loadOffMainActor({ [authStore] in authStore.loadKeychainAuth() }) {
            do {
                return try await probe(authState: &keychainCandidate)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        if let lastFallbackError {
            return ProviderSnapshot.error(provider: provider, error: lastFallbackError)
        }
        return ProviderSnapshot.error(provider: provider, error: CodexAuthError.notLoggedIn)
    }

    /// Fetches usage for one credential, refreshing and persisting its token when it may. On return
    /// `authState` holds the credential as last written, so callers can check it is still current.
    func probe(authState: inout CodexAuthState) async throws -> ProviderSnapshot {
        var onDisk = authState
        return try await probe(authState: &authState, onDisk: &onDisk)
    }

    /// `authState` is the working credential; `onDisk` is what its source held when we last read or
    /// wrote it. They differ once a rotated token could not be written back: the fresh token keeps
    /// serving this refresh while conflict checks still compare against the source.
    func probe(authState: inout CodexAuthState, onDisk: inout CodexAuthState) async throws -> ProviderSnapshot {
        guard var accessToken = authState.auth.tokens?.accessToken, !accessToken.isEmpty else {
            if authState.auth.apiKey?.isEmpty == false {
                throw CodexAuthError.usageAPIKey
            }
            throw CodexAuthError.notLoggedIn
        }

        if authStore.needsRefresh(authState.auth) {
            // The `codex` CLI may have rotated the token on disk since we loaded it. Re-read the live
            // credential first and adopt its (newer) access token — refreshing our stale copy would send
            // an already-rotated refresh_token and trip `refresh_token_reused` (issue #516).
            if let live = await reloadLiveAuth(source: authState.source),
               let liveToken = live.auth.tokens?.accessToken, !liveToken.isEmpty {
                authState = live
                onDisk = live
                accessToken = liveToken
            }
        }

        if authStore.needsRefresh(authState.auth),
           let refreshToken = authState.auth.tokens?.refreshToken,
           !refreshToken.isEmpty {
            let refreshed = try await refreshAccessToken(authState: &authState, onDisk: &onDisk, refreshToken: refreshToken)
            accessToken = refreshed
        }

        let response = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState, onDisk: &onDisk)
        // The access token may have rotated during the usage fetch's refresh-and-retry; read the live one.
        let currentToken = authState.auth.tokens?.accessToken ?? accessToken
        let resetCredits = await fetchResetCreditsBestEffort(
            accessToken: currentToken,
            accountID: authState.auth.tokens?.accountID
        )
        let mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())

        return await snapshot(mapped: mapped)
    }

    func snapshot(mapped initial: CodexMappedUsage) async -> ProviderSnapshot {
        var mapped = initial
        // pi logs name a provider family, not an account card.
        let piCardID = ProviderAccountID.family(of: provider.id)
        let history = await localHistory.value(wait: localHistoryWait) {
            [pricing, fallbackModel, historyScope, authStore, logUsageScanner, piUsageScanner,
             openCodeUsageScanner, now] in
            let claims = await Self.historyClaims(scope: historyScope, authStore: authStore,
                                                  logUsageScanner: logUsageScanner)
            return await Self.scanLocalHistory(
                claims: claims, claimsPiUsage: historyScope.claimsPiUsage, piCardID: piCardID, pricing: pricing, fallbackModel: fallbackModel, logUsageScanner: logUsageScanner,
                piUsageScanner: piUsageScanner, openCodeUsageScanner: openCodeUsageScanner, now: now
            )
        }
        if let history, let usage = history.usageHistory {
            // A retained scan may be collected on a later day; project Today/Yesterday at collection.
            SpendTileMapper.appendTokenUsage(
                usage.series, to: &mapped.lines, now: now(),
                unknownModelsByDay: usage.unknownModelsByDay, modelUsage: usage.modelUsage,
                modelSourceNote: history.sourceNote,
                fallbackPricingModelsByDay: usage.fallbackPricingModelsByDay
            )
            SpendTileMapper.appendUsageTrend(
                usage.series, to: &mapped.lines, now: now(), note: history.sourceNote,
                fallbackPricingModelsByDay: usage.fallbackPricingModelsByDay
            )
        }
        let warning = history == nil ? "Local token history is still updating." : nil
        if warning != nil {
            AppLog.warn(LogTag.plugin("codex"), "local history scan deferred; publishing live quota")
        }
        // Pending history is not evidence of no usage. The store may restore last-good spend rows.
        if history != nil { MetricLine.appendNoDataIfNeeded(&mapped.lines) }
        return ProviderSnapshot.make(
            provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now(),
            usageHistory: history?.usageHistory, warning: warning
        )
    }

    private struct CodexLocalHistory: Sendable {
        var sourceNote: String
        var usageHistory: ProviderUsageHistory?
    }

    private static func historyClaims(
        scope: CodexHistoryScope, authStore: CodexAuthStore, logUsageScanner: CodexLogUsageScanner
    ) async -> CodexHistoryClaims {
        switch scope {
        case .allHomes:
            return CodexHistoryClaims(logHomes: await logUsageScanner.allHomes(), ownsDefaultLogin: true)
        case let .account(identity, homes, _):
            return await loadOffMainActor { homes.claims(for: identity, authStore: authStore) }
        }
    }

    private static func scanLocalHistory(
        claims: CodexHistoryClaims,
        claimsPiUsage: Bool,
        piCardID: String,
        pricing: @Sendable () async -> ModelPricing,
        fallbackModel: @MainActor () -> String?,
        logUsageScanner: CodexLogUsageScanner,
        piUsageScanner: PiUsageScanner,
        openCodeUsageScanner: OpenCodeCodexUsageScanner,
        now: @Sendable () -> Date
    ) async -> CodexLocalHistory {
        let pricing = await pricing()
        // Three independent local sources: reading rollout files, pi's JSONL, and OpenCode's SQLite
        // concurrently keeps the slowest one — not their sum — on the background scan's path.
        let selectedFallbackModel = fallbackModel()
        async let native = logUsageScanner.scan(
            homes: claims.logHomes, now: now(), pricing: pricing, fallbackModel: selectedFallbackModel
        )
        async let pi = claimsPiUsage ? piUsageScanner.scan(
            cardID: piCardID, now: now(), pricing: pricing,
            estimateCost: { CodexUsagePricing.estimatedCost(pricing: pricing, model: $0, tokens: $1, at: $2) }
        ) : nil
        async let openCode = claims.ownsDefaultLogin ? openCodeUsageScanner.scan(now: now(), pricing: pricing) : nil
        let (nativeScan, piScan, openCodeScan) = await (native, pi, openCode)
        let baseNote = Self.localUsageSourceNote(hasPi: piScan != nil, hasOpenCode: openCodeScan != nil)
        var usageHistory: ProviderUsageHistory?
        // Cancellation must not publish a partial combined history.
        if !Task.isCancelled {
            if let scan = DailyUsageAccumulator.merged([nativeScan, piScan, openCodeScan]) {
                usageHistory = ProviderUsageHistory(
                    series: scan.series, modelUsage: scan.modelUsage,
                    unknownModelsByDay: scan.unknownModelsByDay,
                    fallbackPricingModelsByDay: scan.fallbackPricingModelsByDay
                )
            } else if claims.ownsNoHome && !claimsPiUsage {
                // A card left with no source must clear, or the store keeps showing spend that moved
                // to another card. An owned source that came back empty may have failed to read, so it
                // keeps the last-good history instead.
                usageHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
            }
        }

        AppLog.info(LogTag.plugin("codex"), "local history scan completed")
        return CodexLocalHistory(sourceNote: baseNote, usageHistory: usageHistory)
    }

    private static func localUsageSourceNote(hasPi: Bool, hasOpenCode: Bool) -> String {
        var sources = ["Codex logs"]
        if hasPi { sources.append("pi") }
        if hasOpenCode { sources.append("OpenCode") }
        let joined = sources.count > 2
            ? sources.dropLast().joined(separator: ", ") + ", and " + sources[sources.count - 1]
            : sources.joined(separator: " and ")
        return "From your \(joined) (estimated)"
    }

    /// Fetches the on-demand reset-credit balance (and per-credit expiry) without ever failing the
    /// refresh: this is supplementary to the usage metrics, so a network error, timeout, or non-2xx just
    /// yields `nil` and the mapper falls back to the count embedded in the usage body. Logged, not thrown —
    /// the user still gets Session/Weekly/Credits even if this endpoint is down.
    private func fetchResetCreditsBestEffort(accessToken: String, accountID: String?) async -> HTTPResponse? {
        do {
            return try await usageClient.fetchResetCredits(accessToken: accessToken, accountID: accountID)
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "reset-credit fetch failed; using usage-body count: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchUsageWithRetry(
        accessToken: String, authState: inout CodexAuthState, onDisk: inout CodexAuthState
    ) async throws -> HTTPResponse {
        var working = authState
        var baseline = onDisk
        defer {
            authState = working
            onDisk = baseline
        }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0, accountID: working.auth.tokens?.accountID) },
            refreshAccessToken: {
                guard let refreshToken = working.auth.tokens?.refreshToken, !refreshToken.isEmpty else {
                    throw CodexAuthError.tokenExpired
                }
                do {
                    return try await self.refreshAccessToken(authState: &working, onDisk: &baseline, refreshToken: refreshToken)
                } catch let error as CodexAuthError {
                    throw error
                } catch {
                    throw CodexUsageError.connectionFailed
                }
            },
            connectionFailed: CodexUsageError.connectionFailed,
            authExpired: CodexAuthError.tokenExpired
        )
    }

    /// Re-reads the credential from its original source (the same on-disk file or keychain entry) so a
    /// token the `codex` CLI rotated out-of-band is picked up before we attempt our own refresh. Reads
    /// only that one source — matching how `codex` reads the single `auth.json` from `CODEX_HOME` —
    /// rather than re-scanning every candidate path.
    private func reloadLiveAuth(source: CodexAuthState.Source) async -> CodexAuthState? {
        switch source {
        case .file(let path):
            return authStore.loadAuth(at: path)
        case .keychain(let account):
            return await loadOffMainActor { [authStore] in authStore.loadKeychainAuth(account: account) }
        case .pi(let source):
            return authStore.loadPiAuth(source)
        }
    }

    private func refreshAccessToken(
        authState: inout CodexAuthState, onDisk: inout CodexAuthState, refreshToken: String
    ) async throws -> String {
        let response = try await usageClient.refreshToken(refreshToken)
        // A login that changed while our request was in flight is newer than ours; never write over it.
        guard await reloadLiveAuth(source: authState.source) == onDisk else {
            AppLog.warn(LogTag.auth("codex"), "login changed while refreshing the token; keeping the login on disk")
            throw CodexAuthError.tokenConflict
        }
        var rotated = authState
        rotated.auth.tokens?.accessToken = response.accessToken
        if let refreshToken = response.refreshToken {
            rotated.auth.tokens?.refreshToken = refreshToken
        }
        if let idToken = response.idToken {
            rotated.auth.tokens?.idToken = idToken
        }
        rotated.auth.lastRefresh = OpenUsageISO8601.string(from: now())
        // Fail loudly: a swallowed save strands the rotated token on disk (next launch re-refreshes /
        // can surface a false "token expired"). The refreshed token works for this session, so log and
        // continue. This is also the only call site of authStore.save, so a genuinely undecodable
        // payload (CodexAuthError.invalidAuthPayload) now surfaces in the log instead of vanishing.
        do {
            try authStore.save(rotated, replacing: onDisk)
            onDisk = rotated
        } catch CodexAuthError.tokenConflict {
            AppLog.warn(LogTag.auth("codex"), "login changed while refreshing the token; keeping the login on disk")
            throw CodexAuthError.tokenConflict
        } catch {
            AppLog.error(LogTag.auth("codex"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        authState = rotated
        if authStore.expectedIdentity != nil {
            if authStore.scoped(authState) == nil {
                AppLog.warn(LogTag.auth("codex"), "rotated credential no longer names this account; trying a matching login")
                throw CodexAuthError.tokenConflict
            }
        }
        return response.accessToken
    }
}
